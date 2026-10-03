import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Public fixtures for the disposable validation package only, never user PINs.
const securityValidationPackage = 'com.example.mits_kids_youtube.validation';
const securityLegacyFixturePin = '4826';
const securityCurrentFixturePin = '706291';
const _incorrectFixturePin = '999999';
const _security = MethodChannel('mits_kids/parent_security');
const _legacyKey = 'flutter.parent_pin_sha256_v1';

void _require(bool condition, String description) {
  if (!condition) throw StateError(description);
}

Future<Directory> securityValidationDirectory() async {
  if (!Platform.isAndroid) throw StateError('Android validation only.');
  final documents = await getApplicationDocumentsDirectory();
  _require(
    p.basename(documents.parent.path) == securityValidationPackage,
    'Refusing security checks outside the disposable validation package.',
  );
  return documents;
}

Future<void> _authenticate(String pin, {String? replacement}) async {
  final result = await _security.invokeMapMethod<String, dynamic>(
    'authenticate',
    {'pin': pin, if (replacement != null) 'newPin': replacement},
  );
  _require(
    result?['token'] is String && (result!['token'] as String).isNotEmpty,
    'Native authentication did not return authority.',
  );
  // Never write the token, credential, salt or verifier to validation evidence.
}

Future<PlatformException> _rejected(String pin, {String? replacement}) async {
  try {
    await _authenticate(pin, replacement: replacement);
  } on PlatformException catch (failure) {
    return failure;
  }
  throw StateError('Authentication unexpectedly succeeded.');
}

Future<void> _incorrect(String pin, {String? replacement}) async {
  final failure = await _rejected(pin, replacement: replacement);
  _require(
    failure.code == 'REJECTED' && failure.message == 'Incorrect PIN.',
    'An actual incorrect-PIN rejection was required, rather than a cooldown or platform failure.',
  );
}

Future<int> _cooldown() async {
  final failure = await _rejected(securityCurrentFixturePin);
  final matched = RegExp(
    r'^Wait ([0-9]+) seconds before trying again\.$',
  ).firstMatch(failure.message ?? '');
  _require(
    failure.code == 'REJECTED' && matched != null,
    'Correct fixture PIN was not rejected by the persisted cooldown.',
  );
  return int.parse(matched!.group(1)!);
}

Future<Map<String, int>> _retryState(Directory documents) async {
  final xml = await File(
    p.join(documents.parent.path, 'shared_prefs', 'mits_parent_v2.xml'),
  ).readAsString();
  final state = <String, int>{};
  for (final name in [
    'failures',
    'boot',
    'attemptElapsed',
    'untilElapsed',
    'untilWall',
  ]) {
    final match = RegExp(
      '<(?:int|long) name="$name" value="(-?[0-9]+)"\\s*/>',
    ).firstMatch(xml);
    _require(match != null, 'Missing persisted retry-state field: $name.');
    state[name] = int.parse(match!.group(1)!);
  }
  return state;
}

Future<void> _status({required bool legacy}) async {
  final status = await _security.invokeMapMethod<String, dynamic>('status');
  _require(
    status?['configured'] == true && status?['legacy'] == legacy,
    'Unexpected configured/migration status.',
  );
}

/// Uses only production status/authenticate/lock calls. The operator seeds the
/// known legacy fixture while this disposable app is stopped. No test-only
/// authentication bypass, preference writer or production reset method exists.
Future<Map<String, Object?>> runSecurityPersistenceStage() async {
  final documents = await securityValidationDirectory();
  final request = jsonDecode(
    await File(
      p.join(documents.path, 'security-validation-stage.json'),
    ).readAsString(),
  );
  _require(
    request is Map<String, dynamic>,
    'Invalid validation stage request.',
  );
  final stage = (request as Map<String, dynamic>)['stage'];
  _require(stage is String, 'Missing validation stage.');
  final measured = <String, Object?>{
    'stage': stage,
    'pid': pid,
    'package': securityValidationPackage,
  };
  switch (stage) {
    case 'migration':
      await _status(legacy: true);
      await _incorrect('1111', replacement: securityCurrentFixturePin);
      await _status(legacy: true);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final invalid = await _rejected(
        securityLegacyFixturePin,
        replacement: '123',
      );
      _require(
        invalid.code == 'INVALID',
        'Invalid replacement PIN was not rejected.',
      );
      await _status(legacy: true);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await _authenticate(
        securityLegacyFixturePin,
        replacement: securityCurrentFixturePin,
      );
      await _status(legacy: false);
      final legacy = File(
        p.join(
          documents.parent.path,
          'shared_prefs',
          'FlutterSharedPreferences.xml',
        ),
      );
      _require(
        !await legacy.exists() ||
            !(await legacy.readAsString()).contains(_legacyKey),
        'The old legacy credential was not removed after migration.',
      );
      await _security.invokeMethod<void>('lock');
      await _incorrect(securityLegacyFixturePin);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await _authenticate(securityCurrentFixturePin);
      measured.addAll({
        'wrong_legacy_rejected': true,
        'invalid_replacement_preserved_legacy': true,
        'legacy_hash_removed_after_commit': true,
        'old_pin_rejected_after_migration': true,
        'new_pin_authenticated': true,
      });
    case 'seed_cooldown':
      await _status(legacy: false);
      await _authenticate(securityCurrentFixturePin);
      measured['migrated_pin_survived_process_restart'] = true;
      for (var attempt = 1; attempt <= 5; attempt++) {
        await _incorrect(_incorrectFixturePin);
        if (attempt < 5) {
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        }
      }
      final seconds = await _cooldown();
      _require(
        seconds >= 1 && seconds <= 30,
        'Five real failures must establish the 30-second delay.',
      );
      final state = await _retryState(documents);
      _require(
        state['failures'] == 5,
        'Five failed attempts were not durably recorded.',
      );
      measured.addAll({
        'five_real_failures_persisted': true,
        'reported_cooldown_seconds': seconds,
        'boot_count': state['boot'],
        'until_wall_ms': state['untilWall'],
      });
    case 'process_probe':
      await _status(legacy: false);
      final before = await _retryState(documents);
      _require(
        before['failures'] == 5,
        'Expected the previously seeded five-failure state.',
      );
      _require(
        before['untilWall']! - DateTime.now().millisecondsSinceEpoch > 1000,
        'The process probe missed the short cooldown window. Rerun the guarded staged suite; do not count this as a persistence pass.',
      );
      _require(
        request['previous_pid'] is int && request['previous_pid'] != pid,
        'The probe did not run in a new app process.',
      );
      final seconds = await _cooldown();
      final after = await _retryState(documents);
      _require(
        before['failures'] == after['failures'] &&
            before['boot'] == after['boot'] &&
            before['untilElapsed'] == after['untilElapsed'],
        'A blocked same-boot probe changed the persisted retry budget.',
      );
      measured.addAll({
        'process_restart_cooldown_preserved': true,
        'reported_cooldown_seconds': seconds,
        'failure_budget_unchanged': true,
      });
    case 'reboot_probe':
      await _status(legacy: false);
      final before = await _retryState(documents);
      _require(
        before['failures'] == 5,
        'Expected five durable failures after reboot.',
      );
      _require(
        request['boot_before'] is int &&
            request['boot_after'] is int &&
            (request['boot_after'] as int) > (request['boot_before'] as int),
        'The operator did not establish a new emulator boot.',
      );
      final seconds = await _cooldown();
      final after = await _retryState(documents);
      _require(
        seconds >= 29 && seconds <= 30,
        'Reboot did not restore the conservative 30-second delay.',
      );
      _require(
        after['boot'] == request['boot_after'] && after['failures'] == 5,
        'The delay was not durably rebound to the new boot.',
      );
      await Future<void>.delayed(Duration(seconds: seconds + 1));
      await _authenticate(securityCurrentFixturePin);
      final cleared = await _retryState(documents);
      _require(
        cleared['failures'] == 0 &&
            cleared['untilElapsed'] == 0 &&
            cleared['untilWall'] == 0,
        'A successful post-cooldown authentication did not clear retry state.',
      );
      measured.addAll({
        'reboot_cooldown_preserved': true,
        'reported_cooldown_seconds': seconds,
        'boot_before': request['boot_before'],
        'boot_after': request['boot_after'],
        'migrated_pin_and_keystore_survived_reboot': true,
        'successful_auth_cleared_delay': true,
      });
    case 'wall_deadline_probe':
      final before = await _retryState(documents);
      _require(
        before['failures'] == 5 && before['untilWall'] == 0,
        'The isolated expired-wall-deadline fixture was not prepared.',
      );
      final seconds = await _cooldown();
      final after = await _retryState(documents);
      _require(
        seconds >= 1 &&
            seconds <= 30 &&
            before['untilElapsed'] == after['untilElapsed'] &&
            before['boot'] == after['boot'] &&
            after['untilWall'] == 0,
        'The same-boot monotonic delay was bypassed by the expired wall deadline.',
      );
      measured.addAll({
        'expired_wall_deadline_simulation_preserved_cooldown': true,
        'reported_cooldown_seconds': seconds,
        'actual_system_clock_changed': false,
      });
    case 'recover_after_cooldown':
      try {
        await _authenticate(securityCurrentFixturePin);
      } on PlatformException catch (failure) {
        final match = RegExp(
          r'^Wait ([0-9]+) seconds before trying again\.$',
        ).firstMatch(failure.message ?? '');
        _require(
          failure.code == 'REJECTED' && match != null,
          'Unexpected fixture recovery rejection.',
        );
        final seconds = int.parse(match!.group(1)!);
        _require(seconds >= 1 && seconds <= 30, 'Unexpected recovery delay.');
        await Future<void>.delayed(Duration(seconds: seconds + 1));
        await _authenticate(securityCurrentFixturePin);
      }
      measured['fixture_left_usable'] = true;
    default:
      throw StateError('Unknown validation stage.');
  }
  measured['result'] = 'PASS';
  return measured;
}

Future<void> writeSecurityValidationResult(Map<String, Object?> result) async {
  final directory = await securityValidationDirectory();
  final temporary = File(
    p.join(directory.path, 'security-validation-result.json.tmp'),
  );
  await temporary.writeAsString(jsonEncode(result), flush: true);
  await temporary.rename(
    p.join(directory.path, 'security-validation-result.json'),
  );
}

String securityValidationFailure(Object failure) => failure is StateError
    ? failure.message.toString()
    : failure is PlatformException
    ? 'Native security check failed with code ${failure.code}.'
    : 'Validation failed (${failure.runtimeType}).';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preferencesChannel = MethodChannel(
    'plugins.flutter.io/shared_preferences',
  );
  const parentChannel = MethodChannel('test/settings-parent');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const key = 'flutter.filter_config_v1';
  const restrictive = FilterConfig(
    blockedChannels: ['Blocked channel'],
    blockedKeywords: ['unsafe'],
    blockShorts: true,
    blockLive: true,
  );
  late ParentSession session;
  late Map<String, Object> platformMemory;
  late Map<String, Object> durable;
  late List<MethodCall> writes;
  Future<bool> Function(MethodCall)? nextWrite;

  setUp(() async {
    SharedPreferences.resetStatic();
    final initial = jsonEncode(restrictive.toJson());
    platformMemory = {key: initial};
    durable = Map.of(platformMemory);
    writes = [];
    nextWrite = null;
    messenger.setMockMethodCallHandler(preferencesChannel, (call) async {
      if (call.method == 'getAll') return Map.of(platformMemory);
      if (call.method == 'setString' || call.method == 'remove') {
        writes.add(call);
        final arguments = call.arguments as Map;
        if (call.method == 'remove') {
          platformMemory.remove(arguments['key']);
        } else {
          platformMemory[arguments['key'] as String] =
              arguments['value'] as String;
        }
        // Mirror Android commit: native memory may already hold the new value
        // even when persistence fails. Reloading would not repair this alone.
        final succeeded = await (nextWrite?.call(call) ?? Future.value(true));
        if (succeeded) durable = Map.of(platformMemory);
        return succeeded;
      }
      throw StateError('Unexpected preferences call ${call.method}');
    });
    messenger.setMockMethodCallHandler(parentChannel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') return {'token': 'parent'};
      return null;
    });
    session = ParentSession(channel: parentChannel);
    await session.initialise();
    await session.authenticate('123456');
  });

  tearDown(() {
    session.dispose();
    messenger.setMockMethodCallHandler(preferencesChannel, null);
    messenger.setMockMethodCallHandler(parentChannel, null);
    SharedPreferences.resetStatic();
  });

  test(
    'failed permissive write restores confirmed rules for every repository',
    () async {
      final repository = SettingsRepository();
      nextWrite = (_) async => writes.length != 1;
      await expectLater(
        repository.saveConfig(FilterConfig.defaults, session),
        throwsStateError,
      );
      expect(writes.length, 2);
      expect((await repository.loadConfig()).toJson(), restrictive.toJson());
      expect(
        (await SettingsRepository().loadConfig()).toJson(),
        restrictive.toJson(),
      );
      expect(jsonDecode(durable[key] as String), restrictive.toJson());
      expect(platformMemory, durable);
    },
  );

  test(
    'failed rollback closes reads until a later parent save is confirmed',
    () async {
      nextWrite = (_) async => false;
      await expectLater(
        SettingsRepository().saveConfig(FilterConfig.defaults, session),
        throwsStateError,
      );
      await expectLater(SettingsRepository().loadConfig(), throwsStateError);
      nextWrite = (_) async => true;
      await SettingsRepository().saveConfig(restrictive, session);
      expect(
        (await SettingsRepository().loadConfig()).toJson(),
        restrictive.toJson(),
      );
      expect(jsonDecode(durable[key] as String), restrictive.toJson());
    },
  );

  test(
    'platform exception also compensates the already updated caches',
    () async {
      nextWrite = (_) async {
        if (writes.length == 1) throw PlatformException(code: 'WRITE_FAILED');
        return true;
      };
      await expectLater(
        SettingsRepository().saveConfig(FilterConfig.defaults, session),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await SettingsRepository().loadConfig()).toJson(),
        restrictive.toJson(),
      );
      expect(platformMemory, durable);
    },
  );

  test(
    'a failed first save restores the absence of a stored rules value',
    () async {
      platformMemory.clear();
      durable.clear();
      nextWrite = (_) async => writes.length != 1;
      await expectLater(
        SettingsRepository().saveConfig(restrictive, session),
        throwsStateError,
      );
      expect(writes.last.method, 'remove');
      expect(durable.containsKey(key), isFalse);
      expect(
        (await SettingsRepository().loadConfig()).toJson(),
        FilterConfig.defaults.toJson(),
      );
    },
  );

  test(
    'readers and another writer cannot observe or replace an unconfirmed write',
    () async {
      final pending = Completer<bool>();
      final entered = Completer<void>();
      nextWrite = (_) async {
        if (writes.length == 1) {
          entered.complete();
          return pending.future;
        }
        return true;
      };
      await SharedPreferences.getInstance();
      final first = SettingsRepository().saveConfig(
        FilterConfig.defaults,
        session,
      );
      final failed = expectLater(first, throwsStateError);
      // Queue all three together while the idle barrier is still unclaimed;
      // an async check-then-act acquisition would let them all proceed.
      final second = SettingsRepository().saveConfig(restrictive, session);
      var readFinished = false;
      final reading = SettingsRepository().loadConfig().then((value) {
        readFinished = true;
        return value;
      });
      await entered.future;
      // The plugin's raw cache is already permissive here; repository reads
      // must wait instead of letting that temporary value reach playback.
      expect(
        jsonDecode(
          (await SharedPreferences.getInstance()).getString(
            'filter_config_v1',
          )!,
        ),
        FilterConfig.defaults.toJson(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(readFinished, isFalse);
      expect(writes.length, 1);
      pending.complete(false);
      await failed;
      await second;
      expect((await reading).toJson(), restrictive.toJson());
      expect(writes.length, 3);
      expect(jsonDecode(durable[key] as String), restrictive.toJson());
    },
  );

  test('parent lock during persistence restores previous rules', () async {
    final pending = Completer<bool>();
    final entered = Completer<void>();
    nextWrite = (_) async {
      if (writes.length == 1) {
        entered.complete();
        return pending.future;
      }
      return true;
    };
    final saving = SettingsRepository().saveConfig(
      FilterConfig.defaults,
      session,
    );
    final failed = expectLater(saving, throwsStateError);
    await entered.future;
    session.lock();
    pending.complete(true);
    await failed;
    expect(
      (await SettingsRepository().loadConfig()).toJson(),
      restrictive.toJson(),
    );
    expect(jsonDecode(durable[key] as String), restrictive.toJson());
  });
}

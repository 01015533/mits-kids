import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';
import 'package:mits_kids_youtube/src/services/screen_off_recovery_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preferencesChannel = MethodChannel(
    'plugins.flutter.io/shared_preferences',
  );
  const parentChannel = MethodChannel('test/screen-recovery-parent');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const key = 'flutter.screen_off_recovery_v1';
  late ParentSession session;
  late Map<String, Object> platformMemory;
  late Map<String, Object> durable;
  late List<MethodCall> writes;
  Future<bool> Function(MethodCall)? nextWrite;
  bool failRead = false;
  int issuedTokens = 0;

  setUp(() async {
    SharedPreferences.resetStatic();
    platformMemory = {};
    durable = {};
    writes = [];
    nextWrite = null;
    failRead = false;
    issuedTokens = 0;
    messenger.setMockMethodCallHandler(preferencesChannel, (call) async {
      if (call.method == 'getAll') {
        if (failRead) throw PlatformException(code: 'READ_FAILED');
        return Map.of(platformMemory);
      }
      if (call.method == 'setBool' || call.method == 'remove') {
        writes.add(call);
        final arguments = call.arguments as Map;
        if (call.method == 'remove') {
          platformMemory.remove(arguments['key']);
        } else {
          platformMemory[arguments['key'] as String] =
              arguments['value'] as bool;
        }
        // Model caches changing before disk commit, including failed commits.
        final succeeded = await (nextWrite?.call(call) ?? Future.value(true));
        if (succeeded) durable = Map.of(platformMemory);
        return succeeded;
      }
      throw StateError('Unexpected preference operation ${call.method}');
    });
    messenger.setMockMethodCallHandler(parentChannel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') {
        return {'token': 'parent-${++issuedTokens}'};
      }
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
    'recovery defaults off and an authenticated choice survives cache reload',
    () async {
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(writes, isEmpty);
      await ScreenOffRecoveryPreferences().setEnabled(true, session);
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isTrue);
      expect(durable[key], isTrue);
      SharedPreferences.resetStatic();
      platformMemory = Map.of(durable);
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isTrue);
      await ScreenOffRecoveryPreferences().setEnabled(false, session);
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(durable[key], isFalse);
    },
  );

  test(
    'locked Parent cannot enable or disable recovery or write preferences',
    () async {
      session.lock();
      await expectLater(
        ScreenOffRecoveryPreferences().setEnabled(true, session),
        throwsStateError,
      );
      await expectLater(
        ScreenOffRecoveryPreferences().setEnabled(false, session),
        throwsStateError,
      );
      expect(writes, isEmpty);
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(session.unlocked, isFalse);
    },
  );

  test(
    'failed enable restores the confirmed off value for every instance',
    () async {
      platformMemory[key] = false;
      durable[key] = false;
      nextWrite = (_) async => writes.length != 1;
      await expectLater(
        ScreenOffRecoveryPreferences().setEnabled(true, session),
        throwsStateError,
      );
      expect(writes, hasLength(2));
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(platformMemory, durable);
      expect(durable[key], isFalse);
    },
  );

  test('failed first enable restores an absent preference', () async {
    nextWrite = (_) async => writes.length != 1;
    await expectLater(
      ScreenOffRecoveryPreferences().setEnabled(true, session),
      throwsStateError,
    );
    expect(writes.map((call) => call.method), ['setBool', 'remove']);
    expect(platformMemory.containsKey(key), isFalse);
    expect(durable.containsKey(key), isFalse);
    expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
  });

  test(
    'write exception restores caches and reports the original failure',
    () async {
      platformMemory[key] = false;
      durable[key] = false;
      nextWrite = (_) async {
        if (writes.length == 1) throw PlatformException(code: 'WRITE_FAILED');
        return true;
      };
      await expectLater(
        ScreenOffRecoveryPreferences().setEnabled(true, session),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'WRITE_FAILED',
          ),
        ),
      );
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(platformMemory, durable);
    },
  );

  test(
    'uncertain rollback closes all readers until an authenticated repair',
    () async {
      platformMemory[key] = false;
      durable[key] = false;
      nextWrite = (_) async => false;
      final writer = ScreenOffRecoveryPreferences();
      await expectLater(writer.setEnabled(true, session), throwsStateError);
      await expectLater(writer.isEnabled(), throwsStateError);
      await expectLater(
        ScreenOffRecoveryPreferences().isEnabled(),
        throwsStateError,
      );
      session.lock();
      await expectLater(
        ScreenOffRecoveryPreferences().setEnabled(false, session),
        throwsStateError,
      );
      expect(writes, hasLength(2));
      await session.authenticate('123456');
      nextWrite = (_) async => true;
      await ScreenOffRecoveryPreferences().setEnabled(false, session);
      expect(await writer.isEnabled(), isFalse);
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(durable[key], isFalse);
    },
  );

  test(
    'rollback exception closes reads without replacing the original error',
    () async {
      nextWrite = (_) async {
        throw PlatformException(
          code: writes.length == 1 ? 'WRITE_FAILED' : 'ROLLBACK_FAILED',
        );
      };
      await expectLater(
        ScreenOffRecoveryPreferences().setEnabled(true, session),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'WRITE_FAILED',
          ),
        ),
      );
      await expectLater(
        ScreenOffRecoveryPreferences().isEnabled(),
        throwsStateError,
      );
    },
  );

  test(
    'lifecycle lock during a successful disk write compensates the change',
    () async {
      platformMemory[key] = false;
      durable[key] = false;
      final entered = Completer<void>();
      final pending = Completer<bool>();
      nextWrite = (_) async {
        if (writes.length == 1) {
          entered.complete();
          return pending.future;
        }
        return true;
      };
      final saving = ScreenOffRecoveryPreferences().setEnabled(true, session);
      final failed = expectLater(saving, throwsStateError);
      await entered.future;
      session.didChangeAppLifecycleState(AppLifecycleState.inactive);
      pending.complete(true);
      await failed;
      expect(session.unlocked, isFalse);
      expect(writes, hasLength(2));
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(durable[key], isFalse);
    },
  );

  test(
    'a replacement token cannot complete the previous session write',
    () async {
      final entered = Completer<void>();
      final pending = Completer<bool>();
      nextWrite = (_) async {
        if (writes.length == 1) {
          entered.complete();
          return pending.future;
        }
        return true;
      };
      final saving = ScreenOffRecoveryPreferences().setEnabled(true, session);
      final failed = expectLater(saving, throwsStateError);
      await entered.future;
      await session.authenticate('123456');
      pending.complete(true);
      await failed;
      expect(session.unlocked, isTrue);
      expect(issuedTokens, 2);
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(durable.containsKey(key), isFalse);
    },
  );

  test(
    'cross-instance readers and writers cannot observe an unconfirmed value',
    () async {
      platformMemory[key] = false;
      durable[key] = false;
      await SharedPreferences.getInstance();
      final entered = Completer<void>();
      final pending = Completer<bool>();
      nextWrite = (_) async {
        if (writes.length == 1) {
          entered.complete();
          return pending.future;
        }
        return true;
      };
      final first = ScreenOffRecoveryPreferences().setEnabled(true, session);
      final failed = expectLater(first, throwsStateError);
      final second = ScreenOffRecoveryPreferences().setEnabled(false, session);
      var readFinished = false;
      final reading = ScreenOffRecoveryPreferences().isEnabled().then((value) {
        readFinished = true;
        return value;
      });
      await entered.future;
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'screen_off_recovery_v1',
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(readFinished, isFalse);
      expect(writes, hasLength(1));
      pending.complete(false);
      await failed;
      await second;
      expect(await reading, isFalse);
      expect(writes, hasLength(3));
      expect(durable[key], isFalse);
    },
  );

  test(
    'a writer queued before Parent locks must recheck after the barrier',
    () async {
      final entered = Completer<void>();
      final pending = Completer<bool>();
      nextWrite = (_) async {
        if (writes.length == 1) {
          entered.complete();
          return pending.future;
        }
        return true;
      };
      final first = ScreenOffRecoveryPreferences().setEnabled(true, session);
      final firstFailed = expectLater(first, throwsStateError);
      await entered.future;
      final second = ScreenOffRecoveryPreferences().setEnabled(true, session);
      final secondFailed = expectLater(second, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      session.lock();
      pending.complete(true);
      await Future.wait([firstFailed, secondFailed]);
      expect(writes, hasLength(2)); // First write plus its compensation only.
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(durable.containsKey(key), isFalse);
    },
  );

  test(
    'read errors and malformed stored data are reported instead of enabling recovery',
    () async {
      failRead = true;
      await expectLater(
        ScreenOffRecoveryPreferences().isEnabled(),
        throwsA(isA<PlatformException>()),
      );
      failRead = false;
      platformMemory[key] = 'true';
      await expectLater(
        ScreenOffRecoveryPreferences().isEnabled(),
        throwsA(isA<TypeError>()),
      );
      await ScreenOffRecoveryPreferences().setEnabled(false, session);
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      expect(durable[key], isFalse);
    },
  );
}

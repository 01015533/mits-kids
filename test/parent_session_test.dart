import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mits-test-parent');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'locks immediately on inactive and ignores an in-flight successful unlock',
    () async {
      final response = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return {'configured': true, 'legacy': false};
        }
        if (call.method == 'authenticate') return response.future;
        return null;
      });
      final session = ParentSession(channel: channel);
      await session.initialise();
      final unlocking = session.authenticate('123456');
      final assertion = expectLater(unlocking, throwsStateError);
      session.didChangeAppLifecycleState(AppLifecycleState.inactive);
      response.complete({'token': 'late-token'});
      await assertion;
      expect(session.unlocked, isFalse);
      expect(() => session.token, throwsStateError);
      session.dispose();
    },
  );

  testWidgets('parent authority expires and is never restored on resume', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') return {'token': 'parent-token'};
      return null;
    });
    final session = ParentSession(
      channel: channel,
      lifetime: const Duration(seconds: 5),
    );
    await session.initialise();
    await session.authenticate('123456');
    expect(session.unlocked, isTrue);
    await tester.pump(const Duration(seconds: 6));
    expect(session.unlocked, isFalse);
    session.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(session.unlocked, isFalse);
    session.dispose();
  });

  test(
    'missing native security fails closed instead of permitting setup',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'UNAVAILABLE'),
      );
      final session = ParentSession(channel: channel);
      await session.initialise();
      expect(session.ready, isFalse);
      expect(session.unlocked, isFalse);
      expect(session.error, isNotNull);
      session.dispose();
    },
  );

  test(
    'PIN change requires an unlocked session and adopts the new token',
    () async {
      final requests = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        requests.add(call);
        if (call.method == 'status') {
          return {'configured': true, 'legacy': false};
        }
        if (call.method == 'authenticate') return {'token': 'old-token'};
        if (call.method == 'changePin') return {'token': 'new-token'};
        return null;
      });
      final session = ParentSession(channel: channel);
      await session.initialise();
      await expectLater(
        session.changePin('123456', newPin: '654321'),
        throwsStateError,
      );
      expect(requests.where((call) => call.method == 'changePin'), isEmpty);
      await session.authenticate('123456');
      await session.changePin('123456', newPin: '654321');
      expect(session.token, 'new-token');
      expect(requests.last.arguments, {'pin': '123456', 'newPin': '654321'});
      session.dispose();
    },
  );

  test(
    'PIN change cannot restore a session locked during native verification',
    () async {
      final response = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return {'configured': true, 'legacy': false};
        }
        if (call.method == 'authenticate') return {'token': 'old-token'};
        if (call.method == 'changePin') return response.future;
        return null;
      });
      final session = ParentSession(channel: channel);
      await session.initialise();
      await session.authenticate('123456');
      final change = session.changePin('123456', newPin: '654321');
      final assertion = expectLater(change, throwsStateError);
      session.didChangeAppLifecycleState(AppLifecycleState.inactive);
      response.complete({'token': 'late-token'});
      await assertion;
      expect(session.unlocked, isFalse);
      session.dispose();
    },
  );

  test(
    'incorrect current PIN preserves the existing session and surfaces cooldown',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return {'configured': true, 'legacy': false};
        }
        if (call.method == 'authenticate') return {'token': 'old-token'};
        if (call.method == 'changePin') {
          throw PlatformException(
            code: 'THROTTLED',
            message: 'Try again later.',
          );
        }
        return null;
      });
      final session = ParentSession(channel: channel);
      await session.initialise();
      await session.authenticate('123456');
      await expectLater(
        session.changePin('000000', newPin: '654321'),
        throwsA(isA<PlatformException>()),
      );
      expect(session.token, 'old-token');
      session.dispose();
    },
  );
}

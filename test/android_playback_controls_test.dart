import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/android_playback_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/playback-controls');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidPlaybackControls controls;
  late List<bool> requests;
  late Future<Object?> Function(bool) respond;

  setUp(() {
    requests = [];
    respond = (_) async => true;
    controls = AndroidPlaybackControls(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setTouchLocked');
      final value = (call.arguments as Map)['locked'] as bool;
      requests.add(value);
      return respond(value);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('native acknowledgement confirms both lock and unlock', () async {
    expect(await controls.setTouchLocked(true), isTrue);
    expect(await controls.setTouchLocked(false), isTrue);
    expect(requests, [true, false]);
  });

  test('a late lock reply cannot overtake a later route unlock', () async {
    final late = Completer<Object?>();
    respond = (locked) => locked ? late.future : Future.value(true);
    final locking = controls.setTouchLocked(true);
    expect(await controls.setTouchLocked(false), isTrue);
    late.complete(true);
    expect(await locking, isFalse);
    expect(requests, [true, false]);
  });

  test('native refusal returns false and releases an ambiguous lock', () async {
    respond = (locked) async => !locked;
    expect(await controls.setTouchLocked(true), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(requests, [true, false]);
  });

  test(
    'platform failure is reported as unsupported and safely released',
    () async {
      respond = (locked) async {
        if (locked) throw PlatformException(code: 'NO_ACTIVITY');
        return true;
      };
      expect(await controls.setTouchLocked(true), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(requests, [true, false]);
    },
  );

  test('missing plugin returns false without exposing an exception', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await controls.setTouchLocked(true), isFalse);
    expect(await controls.setTouchLocked(false), isFalse);
  });

  test('an older failure cannot unlock a newer accepted lock', () async {
    final old = Completer<Object?>();
    var count = 0;
    respond = (_) => ++count == 1 ? old.future : Future.value(true);
    final first = controls.setTouchLocked(true);
    expect(await controls.setTouchLocked(true), isTrue);
    old.completeError(PlatformException(code: 'OLD_FAILURE'));
    expect(await first, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(requests, [true, true]);
  });

  test(
    'a timed-out lock queues a release and ignores its late reply',
    () async {
      controls = AndroidPlaybackControls(
        channel: channel,
        responseTimeout: const Duration(milliseconds: 10),
      );
      final late = Completer<Object?>();
      respond = (locked) => locked ? late.future : Future.value(true);
      expect(await controls.setTouchLocked(true), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(requests, [true, false]);
      late.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(requests, [true, false]);
    },
  );

  test(
    'presentation intent is independent of foreground volume release',
    () async {
      final pending = Completer<Object?>();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'setLockedPresentation') return await pending.future;
        return true;
      });
      final presenting = controls.setLockedPresentation(true);
      expect(await controls.setTouchLocked(false), isTrue);
      pending.complete(true);
      expect(await presenting, isTrue);
      expect(methods, ['setLockedPresentation', 'setTouchLocked']);
    },
  );

  test(
    'presentation unlock is immediate while hiding bars is pending',
    () async {
      final pending = Completer<Object?>();
      final values = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'setLockedPresentation');
        final locked = (call.arguments as Map)['locked'] as bool;
        values.add(locked);
        if (locked) return await pending.future;
        return true;
      });
      final presenting = controls.setLockedPresentation(true);
      expect(await controls.setLockedPresentation(false), isTrue);
      pending.complete(true);
      expect(await presenting, isFalse);
      expect(values, [true, false]);
    },
  );

  test('failed presentation restores only that window request', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return call.method == 'setTouchLocked' ||
          (call.arguments as Map)['locked'] == false;
    });
    expect(await controls.setTouchLocked(true), isTrue);
    expect(await controls.setLockedPresentation(true), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(methods, [
      'setTouchLocked',
      'setLockedPresentation',
      'setLockedPresentation',
    ]);
  });

  test('malformed native acknowledgement is not reported as support', () async {
    respond = (locked) async => locked ? 'true' : true;
    expect(await controls.setTouchLocked(true), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(requests, [true, false]);
  });
}

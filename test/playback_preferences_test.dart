import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/playback_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const firstId = 'abcdefghijk';
  const secondId = 'lmnopqrstuv';
  const firstKey = 'flutter.playback_repeat_v1_$firstId';
  const secondKey = 'flutter.playback_repeat_v1_$secondId';
  const autoplayKey = 'flutter.playback_autoplay_next_v1';
  late PlaybackPreferences preferences;
  late Map<String, Object> platformMemory;
  late Map<String, Object> durable;
  late List<MethodCall> writes;
  Future<bool> Function(MethodCall)? nextWrite;
  bool failRead = false;

  setUp(() {
    SharedPreferences.resetStatic();
    preferences = PlaybackPreferences();
    platformMemory = {};
    durable = {};
    writes = [];
    nextWrite = null;
    failRead = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') {
        if (failRead) throw PlatformException(code: 'READ_FAILED');
        return Map.of(platformMemory);
      }
      if (call.method == 'setBool' || call.method == 'remove') {
        writes.add(call);
        final arguments = call.arguments as Map;
        final key = arguments['key'] as String;
        if (call.method == 'remove') {
          platformMemory.remove(key);
        } else {
          platformMemory[key] = arguments['value'] as bool;
        }
        // SharedPreferences changes both caches before a durable write result.
        // A reported failure therefore needs compensation, not just a reload.
        final succeeded = await (nextWrite?.call(call) ?? Future.value(true));
        if (succeeded) durable = Map.of(platformMemory);
        return succeeded;
      }
      throw StateError('Unexpected preference method ${call.method}');
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SharedPreferences.resetStatic();
  });

  test(
    'repeat defaults off, persists per video, and survives cache reload',
    () async {
      expect(await preferences.repeatFor(firstId), isFalse);
      expect(await preferences.repeatFor(secondId), isFalse);
      await preferences.setRepeat(firstId, true);
      expect(await preferences.repeatFor(firstId), isTrue);
      expect(await preferences.repeatFor(secondId), isFalse);
      expect(durable[firstKey], isTrue);
      expect(durable.containsKey(secondKey), isFalse);

      // Recreate the Dart cache from the simulated confirmed disk state.
      SharedPreferences.resetStatic();
      platformMemory = Map.of(durable);
      preferences = PlaybackPreferences();
      expect(await preferences.repeatFor(firstId), isTrue);
      expect(await preferences.repeatFor(secondId), isFalse);
      await preferences.setRepeat(secondId, true);
      await preferences.setRepeat(firstId, false);
      expect(await preferences.repeatFor(firstId), isFalse);
      expect(await preferences.repeatFor(secondId), isTrue);
      expect(durable, {firstKey: false, secondKey: true});
    },
  );

  test(
    'a read failure is reported and does not poison later operations',
    () async {
      failRead = true;
      await expectLater(
        preferences.repeatFor(firstId),
        throwsA(isA<PlatformException>()),
      );
      expect(writes, isEmpty);
      failRead = false;
      expect(await preferences.repeatFor(firstId), isFalse);
      await preferences.setRepeat(firstId, true);
      expect(await preferences.repeatFor(firstId), isTrue);
    },
  );

  test('false write result restores the prior confirmed preference', () async {
    platformMemory[firstKey] = true;
    durable[firstKey] = true;
    nextWrite = (_) async => writes.length != 1;
    await expectLater(preferences.setRepeat(firstId, false), throwsStateError);
    expect(writes, hasLength(2));
    expect(await preferences.repeatFor(firstId), isTrue);
    expect(platformMemory, durable);
    expect(durable[firstKey], isTrue);
  });

  test(
    'failed first write restores an absent key rather than persisting a default',
    () async {
      nextWrite = (_) async => writes.length != 1;
      await expectLater(preferences.setRepeat(firstId, true), throwsStateError);
      expect(writes.map((call) => call.method), ['setBool', 'remove']);
      expect(platformMemory.containsKey(firstKey), isFalse);
      expect(durable.containsKey(firstKey), isFalse);
      expect(await preferences.repeatFor(firstId), isFalse);
    },
  );

  test(
    'platform write exception compensates caches and preserves the original error',
    () async {
      platformMemory[firstKey] = false;
      durable[firstKey] = false;
      nextWrite = (_) async {
        if (writes.length == 1) throw PlatformException(code: 'WRITE_FAILED');
        return true;
      };
      await expectLater(
        preferences.setRepeat(firstId, true),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'WRITE_FAILED',
          ),
        ),
      );
      expect(await preferences.repeatFor(firstId), isFalse);
      expect(platformMemory, durable);
      expect(durable[firstKey], isFalse);
    },
  );

  test('uncertain rollback keeps repeat off until a confirmed save', () async {
    platformMemory[firstKey] = true;
    durable[firstKey] = true;
    nextWrite = (_) async => false;
    await expectLater(preferences.setRepeat(firstId, false), throwsStateError);
    // Even the rollback mutates the plugin cache before it reports failure.
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'playback_repeat_v1_$firstId',
      ),
      isTrue,
    );
    expect(await preferences.repeatFor(firstId), isFalse);
    expect(await preferences.repeatFor(secondId), isFalse);

    nextWrite = (_) async => true;
    await preferences.setRepeat(firstId, true);
    expect(await preferences.repeatFor(firstId), isTrue);
    expect(platformMemory, durable);
  });

  test(
    'rollback exception leaves repeat off and does not replace the write error',
    () async {
      platformMemory[firstKey] = true;
      durable[firstKey] = true;
      nextWrite = (_) async {
        if (writes.length == 1) throw PlatformException(code: 'WRITE_FAILED');
        throw PlatformException(code: 'ROLLBACK_FAILED');
      };
      await expectLater(
        preferences.setRepeat(firstId, false),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'WRITE_FAILED',
          ),
        ),
      );
      expect(await preferences.repeatFor(firstId), isFalse);
    },
  );

  test(
    'queued readers and writers wait for an unsuccessful write and rollback',
    () async {
      platformMemory[firstKey] = false;
      durable[firstKey] = false;
      final entered = Completer<void>();
      final pending = Completer<bool>();
      nextWrite = (_) async {
        if (writes.length == 1) {
          entered.complete();
          return pending.future;
        }
        return true;
      };
      final writing = preferences.setRepeat(firstId, true);
      final failed = expectLater(writing, throwsStateError);
      var readFinished = false;
      final reading = preferences.repeatFor(firstId).then((result) {
        readFinished = true;
        return result;
      });
      final nextWriting = preferences.setRepeat(firstId, true);
      await entered.future;
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'playback_repeat_v1_$firstId',
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(readFinished, isFalse);
      expect(writes, hasLength(1));
      pending.complete(false);
      await failed;
      expect(await reading, isFalse);
      await nextWriting;
      expect(await preferences.repeatFor(firstId), isTrue);
      expect(writes, hasLength(3));
      expect(durable[firstKey], isTrue);
    },
  );

  test(
    'autoplay defaults off, is one choice for every video and survives reload',
    () async {
      expect(await preferences.autoplayNext(), isFalse);
      await preferences.setAutoplayNext(true);
      expect(await preferences.autoplayNext(), isTrue);
      expect(durable, {autoplayKey: true});
      expect(await preferences.repeatFor(firstId), isFalse);

      SharedPreferences.resetStatic();
      platformMemory = Map.of(durable);
      preferences = PlaybackPreferences();
      expect(await preferences.autoplayNext(), isTrue);
      await preferences.setAutoplayNext(false);
      expect(await preferences.autoplayNext(), isFalse);
      expect(durable, {autoplayKey: false});
    },
  );

  test('a failed autoplay write restores the prior confirmed choice', () async {
    platformMemory[autoplayKey] = true;
    durable[autoplayKey] = true;
    nextWrite = (_) async => writes.length != 1;
    await expectLater(preferences.setAutoplayNext(false), throwsStateError);
    expect(writes, hasLength(2));
    expect(await preferences.autoplayNext(), isTrue);
    expect(platformMemory, durable);
  });

  test(
    'uncertain autoplay stays off without affecting repeat for a video',
    () async {
      platformMemory[firstKey] = true;
      durable[firstKey] = true;
      platformMemory[autoplayKey] = true;
      durable[autoplayKey] = true;
      nextWrite = (_) async => false;
      await expectLater(preferences.setAutoplayNext(false), throwsStateError);
      expect(await preferences.autoplayNext(), isFalse);
      expect(await preferences.repeatFor(firstId), isTrue);

      nextWrite = (_) async => true;
      await preferences.setAutoplayNext(true);
      expect(await preferences.autoplayNext(), isTrue);
      expect(platformMemory, durable);
    },
  );
}

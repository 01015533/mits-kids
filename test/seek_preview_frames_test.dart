import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/seek_preview_frames.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/seek-preview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final file = File('/private/offline/approved.mp4');
  final jpeg = Uint8List.fromList([0xff, 0xd8, 1, 2, 0xff, 0xd9]);
  late AndroidSeekPreviewFrames frames;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) respond;

  setUp(() {
    calls = [];
    respond = (call) async => call.method == 'frame'
        ? {'bytes': jpeg, 'positionMs': (call.arguments as Map)['positionMs']}
        : true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return respond(call);
    });
    frames = AndroidSeekPreviewFrames(channel: channel);
  });

  tearDown(() async {
    await frames.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'requests private file and exact timestamp with increasing identifiers',
    () async {
      final first = await frames.frame(
        file,
        position: const Duration(milliseconds: 12345),
      );
      expect(first?.bytes, jpeg);
      expect(first?.position, const Duration(milliseconds: 12345));
      await frames.frame(file, position: const Duration(seconds: 42));
      final a = calls[0].arguments as Map;
      final b = calls[1].arguments as Map;
      expect(a['session'], greaterThan(0));
      expect(a['path'], file.path);
      expect(a['positionMs'], 12345);
      expect(b['session'], a['session']);
      expect(b['request'], greaterThan(a['request'] as int));
      expect(b['positionMs'], 42000);
    },
  );

  test('newer frame request invalidates a late older result', () async {
    final pending = Completer<Object?>();
    var count = 0;
    respond = (call) => ++count == 1
        ? pending.future
        : Future.value({'bytes': jpeg, 'positionMs': 2000});
    final older = frames.frame(file, position: const Duration(seconds: 1));
    final current = await frames.frame(
      file,
      position: const Duration(seconds: 2),
    );
    pending.complete({'bytes': jpeg, 'positionMs': 1000});
    expect(await older, isNull);
    expect(current?.position, const Duration(seconds: 2));
  });

  test('cancel rejects late frame but permits a later request', () async {
    final pending = Completer<Object?>();
    respond = (call) =>
        call.method == 'frame' ? pending.future : Future.value(true);
    final old = frames.frame(file, position: const Duration(seconds: 1));
    await frames.cancel();
    pending.complete({'bytes': jpeg, 'positionMs': 1000});
    expect(await old, isNull);
    expect(calls.map((c) => c.method), ['frame', 'cancel']);
    expect(
      (calls[1].arguments as Map)['session'],
      (calls[0].arguments as Map)['session'],
    );
    respond = (_) async => {'bytes': jpeg, 'positionMs': 2000};
    expect(
      await frames.frame(file, position: const Duration(seconds: 2)),
      isNotNull,
    );
  });

  test(
    'dispose permanently rejects work and cannot close a newer owner',
    () async {
      await frames.frame(file, position: Duration.zero);
      final firstSession = (calls.last.arguments as Map)['session'];
      final next = AndroidSeekPreviewFrames(channel: channel);
      await next.frame(file, position: Duration.zero);
      final nextSession = (calls.last.arguments as Map)['session'] as int;
      expect(nextSession, greaterThan(firstSession as int));
      await frames.dispose();
      expect((calls.last.arguments as Map)['session'], firstSession);
      final count = calls.length;
      await frames.dispose();
      await frames.cancel();
      expect(await frames.frame(file, position: Duration.zero), isNull);
      expect(calls, hasLength(count));
      await next.dispose();
    },
  );

  test('malformed and oversized images use unavailable fallback', () async {
    for (final result in <Object?>[
      null,
      true,
      {'bytes': jpeg, 'positionMs': -1},
      {'bytes': jpeg, 'positionMs': '1'},
      {'bytes': Uint8List(0), 'positionMs': 1},
      {
        'bytes': Uint8List.fromList([1, 2, 3, 4]),
        'positionMs': 1,
      },
      {'bytes': Uint8List(1024 * 1024 + 1), 'positionMs': 1},
    ]) {
      respond = (_) async => result;
      expect(await frames.frame(file, position: Duration.zero), isNull);
    }
    final before = calls.length;
    expect(
      await frames.frame(file, position: const Duration(seconds: -1)),
      isNull,
    );
    expect(calls, hasLength(before));
  });

  test('platform failures and timeout do not prevent seeking', () async {
    respond = (_) => Future.error(PlatformException(code: 'UNAVAILABLE'));
    expect(await frames.frame(file, position: Duration.zero), isNull);
    await frames.dispose();
    frames = AndroidSeekPreviewFrames(
      channel: channel,
      responseTimeout: const Duration(milliseconds: 10),
    );
    final pending = Completer<Object?>();
    respond = (call) =>
        call.method == 'frame' ? pending.future : Future.value(true);
    expect(await frames.frame(file, position: Duration.zero), isNull);
    pending.complete({'bytes': jpeg, 'positionMs': 0});
    await Future<void>.delayed(Duration.zero);
  });
}

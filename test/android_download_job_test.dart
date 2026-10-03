import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/android_download_job.dart';
import 'package:mits_kids_youtube/src/services/offline_limits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/approved-download-job');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidDownloadJob adapter;
  late List<MethodCall> calls;
  Completer<Map<String, dynamic>>? pendingStart;
  Completer<void>? pendingUpdate;
  var starts = 0;
  var cancelled = 0;
  var failStart = false;

  Future<void> start() => adapter.start(
    videoId: 'abcdefghijk',
    title: 'Approved video',
    parentToken: 'fresh-parent-token',
    onCancel: () => cancelled++,
  );

  Future<void> nativeCancel(String job) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('cancelled', {'job': job, 'reason': 'user_cancelled'}),
      ),
      (_) {},
    );
  }

  setUp(() {
    calls = [];
    pendingStart = null;
    pendingUpdate = null;
    starts = 0;
    cancelled = 0;
    failStart = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') {
        starts++;
        if (failStart) throw PlatformException(code: 'NOT_VISIBLE');
        return pendingStart == null
            ? {'job': 'job-$starts'}
            : await pendingStart!.future;
      }
      if (call.method == 'update' && pendingUpdate != null) {
        await pendingUpdate!.future;
      }
      return null;
    });
    adapter = AndroidDownloadJob(channel: channel);
  });

  tearDown(() async {
    await adapter.finish();
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'fresh token starts one opaque job; repeated finish is idempotent',
    () async {
      await start();
      expect(calls.single.arguments, {
        'videoId': 'abcdefghijk',
        'title': 'Approved video',
        'token': 'fresh-parent-token',
      });
      adapter.update(status: 'Saving', progress: 2.0);
      await Future<void>.delayed(Duration.zero);
      final update = calls.singleWhere((call) => call.method == 'update');
      expect(update.arguments, {
        'job': 'job-1',
        'status': 'Saving',
        'progress': 1.0,
      });
      await adapter.finish();
      await adapter.finish();
      expect(calls.where((call) => call.method == 'finish'), hasLength(1));
      expect(cancelled, 0);
    },
  );

  test(
    'finish during startup cancels pending and cleans a late successful job',
    () async {
      pendingStart = Completer<Map<String, dynamic>>();
      final starting = start();
      final rejected = expectLater(starting, throwsA(isA<DownloadCancelled>()));
      await Future<void>.delayed(Duration.zero);
      final finishing = adapter.finish();
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((call) => call.method == 'cancelPending'),
        hasLength(1),
      );
      pendingStart!.complete({'job': 'late-job'});
      await rejected;
      await finishing;
      expect(calls.singleWhere((call) => call.method == 'finish').arguments, {
        'job': 'late-job',
      });
      expect(cancelled, 0);
    },
  );

  test(
    'native cancellation before the start result cannot lose cancellation',
    () async {
      pendingStart = Completer<Map<String, dynamic>>();
      final starting = start();
      final rejected = expectLater(starting, throwsA(isA<DownloadCancelled>()));
      await Future<void>.delayed(Duration.zero);
      await nativeCancel('early-job');
      pendingStart!.complete({'job': 'early-job'});
      await rejected;
      expect(cancelled, 1);
      adapter.update(status: 'Must not publish progress');
      expect(calls.where((call) => call.method == 'update'), isEmpty);
    },
  );

  test('stale native events cannot cancel a later job', () async {
    await start();
    await adapter.finish();
    await start();
    await nativeCancel('job-1');
    expect(cancelled, 0);
    await nativeCancel('job-2');
    await nativeCancel('job-2');
    expect(cancelled, 1);
  });

  test('late update failure belongs only to its original generation', () async {
    await start();
    pendingUpdate = Completer<void>();
    adapter.update(status: 'Saving', progress: .1);
    await Future<void>.delayed(Duration.zero);
    await adapter.finish();
    await start();
    pendingUpdate!.completeError(PlatformException(code: 'ALREADY_STOPPED'));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, 0);
    await nativeCancel('job-2');
    expect(cancelled, 1);
  });

  test('native startup refusal is an actionable download failure', () async {
    failStart = true;
    await expectLater(
      start(),
      throwsA(
        isA<DownloadFailure>().having(
          (failure) => failure.message,
          'message',
          contains('Keep the app open'),
        ),
      ),
    );
    expect(cancelled, 0);
  });

  test(
    'duplicate start is rejected while the original job is active',
    () async {
      await start();
      await expectLater(start(), throwsA(isA<DownloadFailure>()));
      expect(starts, 1);
    },
  );
}

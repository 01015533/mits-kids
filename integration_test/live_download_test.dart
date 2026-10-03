import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';
import 'package:mits_kids_youtube/src/services/android_offline_muxer.dart';
import 'package:mits_kids_youtube/src/services/download_service.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/youtube_video_source.dart';
import 'package:mits_kids_youtube/src/services/video_source.dart';

class _ObservedSource implements VideoSource {
  final source = YoutubeVideoSource();
  Future<T> observe<T>(String phase, Future<T> Function() run) async {
    try {
      final result = await run();
      debugPrint('Source phase $phase passed.');
      return result;
    } catch (error) {
      final code = RegExp(
        r'\b[45][0-9]{2}\b',
      ).firstMatch(error.toString())?.group(0);
      debugPrint(
        'Source phase $phase failed: ${error.runtimeType}; HTTP status candidate: $code',
      );
      rethrow;
    }
  }

  @override
  Future<DownloadMetadata> describe(String id) =>
      observe('metadata', () => source.describe(id));
  @override
  Future<DownloadPlan> resolve(String id) async {
    final plan = await observe('resolve', () => source.resolve(id));
    DownloadTrack track(DownloadTrack value, String phase) => DownloadTrack(
      bytes: value.bytes,
      open: () async* {
        try {
          yield* value.open();
        } catch (error) {
          final code = RegExp(
            r'\b[45][0-9]{2}\b',
          ).firstMatch(error.toString())?.group(0);
          debugPrint(
            'Source phase $phase failed: ${error.runtimeType}; HTTP status candidate: $code',
          );
          rethrow;
        }
      },
    );
    return DownloadPlan(
      video: track(plan.video, 'video'),
      audio: plan.audio == null ? null : track(plan.audio!, 'audio'),
    );
  }

  @override
  void close() => source.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const offlineOnly = bool.fromEnvironment('MITS_OFFLINE_CHECK');
  const videoId = String.fromEnvironment(
    'MITS_VIDEO_ID',
    defaultValue: 'YE7VzlLtp-4',
  );
  testWidgets(
    offlineOnly
        ? 'reopened Android local playback with networking disabled'
        : 'approved real YouTube download and native playback',
    (tester) async {
      final documents = await getApplicationDocumentsDirectory();
      if (!documents.path.contains(
        '/com.example.mits_kids_youtube.validation/',
      )) {
        throw StateError(
          'This test only operates on the separate validation installation.',
        );
      }
      final repository = OfflineRepository();
      DownloadService? downloader;
      VideoPlayerController? player;
      final watch = Stopwatch()..start();
      try {
        if (!offlineOnly) {
          const channel = MethodChannel('mits_kids/parent_security');
          final status = await channel.invokeMapMethod<String, dynamic>(
            'status',
          );
          if (status?['configured'] != true) {
            await channel.invokeMethod<Object?>('setup', {'pin': '706291'});
          }
          final auth = await channel.invokeMapMethod<String, dynamic>(
            'authenticate',
            {'pin': '706291'},
          );
          final token = auth!['token'] as String;
          downloader = DownloadService(
            repository,
            sourceFactory: _ObservedSource.new,
            muxer: AndroidOfflineMuxer(),
            parentToken: () => token,
          );
          await downloader
              .save(
                sourceUrl: 'https://www.youtube.com/watch?v=$videoId',
                rules: FilterConfig.defaults,
                approve: (metadata) async =>
                    metadata.author == 'Blender' &&
                    metadata.title == 'Big Buck Bunny',
              )
              .timeout(const Duration(minutes: 4));
        }
        final items = await repository.all();
        final item = items.singleWhere((item) => item.id == videoId);
        final file = await repository.verifyFile(item);
        player = VideoPlayerController.file(file);
        await player.initialize();
        await tester.pumpWidget(MaterialApp(home: VideoPlayer(player)));
        expect(player.value.duration, greaterThan(const Duration(seconds: 10)));
        expect(player.value.size.height, lessThanOrEqualTo(720));
        await player.play();
        await Future<void>.delayed(const Duration(milliseconds: 750));
        expect(await player.position, greaterThan(Duration.zero));
        await player.pause();
        await player.seekTo(const Duration(seconds: 5));
        expect(
          (await player.position)!.inMilliseconds,
          inInclusiveRange(4800, 5300),
        );
        expect(player.value.hasError, isFalse);
        final evidence = {
          'video_id': item.id,
          'title': item.title,
          'author': item.author,
          'bytes': item.bytes,
          'content_sha256': item.contentHash,
          'width': player.value.size.width,
          'height': player.value.size.height,
          'duration_ms': player.value.duration.inMilliseconds,
          'elapsed_ms': watch.elapsedMilliseconds,
          'offline_only': offlineOnly,
          'native_initialize_play_pause_seek': 'PASS',
          'audible_sound_and_visual_quality': 'requires human observation',
        };
        await File(
          p.join(
            documents.path,
            offlineOnly
                ? 'validation-offline.json'
                : 'validation-download.json',
          ),
        ).writeAsString(jsonEncode(evidence));
        debugPrint(jsonEncode(evidence));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await player?.dispose();
        downloader?.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

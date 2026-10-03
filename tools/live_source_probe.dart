import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mits_kids_youtube/src/services/youtube_video_source.dart';

// Read-only metadata/stream-resolution probe. It never downloads media and
// reports no signed CDN URLs, headers or credentials.
Future<void> main(List<String> args) async {
  if (args.length != 1 || !RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(args[0])) {
    stderr.writeln('Usage: dart run tools/live_source_probe.dart VIDEO_ID');
    exitCode = 2;
    return;
  }
  final source = YoutubeVideoSource();
  final watch = Stopwatch()..start();
  try {
    final metadata = await source
        .describe(args.single)
        .timeout(const Duration(seconds: 45));
    final plan = await source
        .resolve(args.single)
        .timeout(const Duration(seconds: 60));
    stdout.writeln(
      jsonEncode({
        'video_id': args.single,
        'title': metadata.title,
        'author': metadata.author,
        'channel_id': metadata.channelId,
        'live': metadata.isLive,
        'source_bytes': plan.bytes,
        'separate_tracks': plan.audio != null,
        'elapsed_ms': watch.elapsedMilliseconds,
        'status': 'resolved',
        'media_downloaded': false,
      }),
    );
  } on TimeoutException {
    stderr.writeln(
      'Live source probe timed out; media transfer is unverified.',
    );
    exitCode = 1;
  } catch (error) {
    // Exception messages may contain expiring signed URLs; keep them local.
    stderr.writeln(
      'Live source probe failed (${error.runtimeType}); media transfer is unverified.',
    );
    exitCode = 1;
  } finally {
    source.close();
  }
}

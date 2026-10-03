import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'offline_limits.dart';
import 'video_source.dart';
import 'secure_youtube_client.dart';

class YoutubeVideoSource implements VideoSource {
  final YoutubeExplode _youtube = YoutubeExplode(
    httpClient: YoutubeHttpClient(SecureYoutubeClient()),
  );
  bool _closed = false;

  @override
  Future<DownloadMetadata> describe(String id) async {
    final video = await _youtube.videos.get(id);
    return DownloadMetadata(
      title: video.title,
      author: video.author,
      isLive: video.isLive,
      channelId: video.channelId.value,
    );
  }

  Future<StreamManifest> _manifest(String id) => _youtube.videos.streams
      .getManifest(id, ytClients: [YoutubeApiClient.androidSdkless]);

  @override
  Future<DownloadPlan> resolve(String id) async {
    final manifest = await _manifest(id);
    final combined =
        manifest.muxed
            .where(
              (stream) =>
                  stream.container == StreamContainer.mp4 &&
                  stream.videoCodec.startsWith('avc1') &&
                  stream.audioCodec.startsWith('mp4a') &&
                  stream.videoResolution.height <= 720 &&
                  stream.size.totalBytes > 0,
            )
            .toList()
          ..sort(
            (a, b) =>
                b.videoResolution.height.compareTo(a.videoResolution.height),
          );
    // A combined stream is the smallest, simplest path when one is available.
    if (combined.isNotEmpty) {
      final stream = combined.first;
      return DownloadPlan(
        video: DownloadTrack(
          bytes: stream.size.totalBytes,
          open: () => _youtube.videos.streams.get(stream),
        ),
      );
    }
    final videos =
        manifest.videoOnly
            .where(
              (stream) =>
                  stream.container == StreamContainer.mp4 &&
                  stream.videoCodec.startsWith('avc1') &&
                  stream.videoResolution.height <= 720 &&
                  stream.size.totalBytes > 0,
            )
            .toList()
          ..sort(
            (a, b) =>
                b.videoResolution.height.compareTo(a.videoResolution.height),
          );
    final audios =
        manifest.audioOnly
            .where(
              (stream) =>
                  stream.container == StreamContainer.mp4 &&
                  stream.audioCodec.startsWith('mp4a') &&
                  (stream.audioTrack == null ||
                      stream.audioTrack!.audioIsDefault) &&
                  stream.size.totalBytes > 0,
            )
            .toList()
          ..sort(
            (a, b) =>
                b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
          );
    if (videos.isEmpty || audios.isEmpty) {
      throw const DownloadFailure(
        'This video has no compatible offline download. Try another public video.',
      );
    }
    final video = videos.first;
    final audio = audios.first;
    return DownloadPlan(
      video: DownloadTrack(
        bytes: video.size.totalBytes,
        open: () => _youtube.videos.streams.get(video),
      ),
      audio: DownloadTrack(
        bytes: audio.size.totalBytes,
        open: () async* {
          // Android stream URLs may be single-use per manifest. Request fresh
          // URLs for the second track while retaining its codec, language and size.
          final fresh = await _manifest(id);
          final candidates = fresh.audioOnly.where(
            (item) =>
                item.tag == audio.tag &&
                item.audioTrack == audio.audioTrack &&
                item.size.totalBytes == audio.size.totalBytes,
          );
          if (candidates.isEmpty) {
            throw const DownloadFailure(
              'The audio changed during download. Tap Save to retry.',
            );
          }
          yield* _youtube.videos.streams.get(candidates.first);
        },
      ),
    );
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      _youtube.close();
    }
  }
}

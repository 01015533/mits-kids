import 'dart:io';

class DownloadMetadata {
  const DownloadMetadata({
    required this.title,
    required this.author,
    required this.isLive,
    required this.channelId,
  });
  final String title;
  final String author;
  final bool isLive;
  final String channelId;
}

class DownloadTrack {
  const DownloadTrack({required this.bytes, required this.open});
  final int bytes;
  final Stream<List<int>> Function() open;
}

class DownloadPlan {
  const DownloadPlan({required this.video, this.audio});
  // Without a separate audio track, video must already include sound.
  final DownloadTrack video;
  final DownloadTrack? audio;
  int get bytes => video.bytes + (audio?.bytes ?? 0);
}

abstract interface class VideoSource {
  Future<DownloadMetadata> describe(String id);
  Future<DownloadPlan> resolve(String id);
  void close();
}

abstract interface class OfflineMuxer {
  Future<void> combine(File video, File audio, File output);
}

import 'dart:io';

import 'package:flutter/services.dart';

import 'offline_limits.dart';
import 'video_source.dart';

class AndroidOfflineMuxer implements OfflineMuxer {
  static const _channel = MethodChannel('mits_kids/offline_media');

  @override
  Future<void> combine(File video, File audio, File output) async {
    try {
      await _channel.invokeMethod<void>('mux', {
        'video': video.path,
        'audio': audio.path,
        'output': output.path,
      });
    } on MissingPluginException {
      throw const DownloadFailure(
        'The offline update needs a full app rebuild. Stop Flutter and run the app again.',
      );
    } on PlatformException {
      throw const DownloadFailure(
        'Could not finish this video. Check free storage and try another video.',
      );
    }
  }
}

import 'dart:io';

import 'package:flutter/services.dart';

import 'offline_limits.dart';

class AndroidOfflineStorage {
  static const _channel = MethodChannel('mits_kids/offline_media');

  static Future<int> availableBytes(Directory directory) async {
    try {
      final bytes = await _channel.invokeMethod<int>('availableBytes', {
        'path': directory.path,
      });
      if (bytes == null || bytes < 0) {
        throw const DownloadFailure(
          'Could not check the tablet’s free storage.',
        );
      }
      return bytes;
    } on MissingPluginException {
      throw const DownloadFailure(
        'The storage update needs a full Android app rebuild. Stop Flutter and run the app again.',
      );
    } on PlatformException {
      throw const DownloadFailure(
        'Could not check the tablet’s free storage. Unlock and retry.',
      );
    }
  }
}

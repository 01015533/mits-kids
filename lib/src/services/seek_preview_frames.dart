import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class SeekPreviewFrame {
  const SeekPreviewFrame({required this.bytes, required this.position});

  final Uint8List bytes;
  final Duration position;
}

abstract interface class SeekPreviewFrames {
  Future<SeekPreviewFrame?> frame(File file, {required Duration position});
  Future<void> cancel();
  Future<void> dispose();
}

/// Private-file thumbnails only. Android owns one decoder worker and a bounded
/// latest-request queue; cancellation never starts another decoder in parallel.
class AndroidSeekPreviewFrames implements SeekPreviewFrames {
  AndroidSeekPreviewFrames({
    MethodChannel? channel,
    this.responseTimeout = const Duration(seconds: 6),
  }) : _channel = channel ?? const MethodChannel('mits_kids/seek_preview'),
       _session = ++_nextSession;

  static int _nextSession = 0;
  static const _maximumFrameBytes = 1024 * 1024;
  final MethodChannel _channel;
  final int _session;
  final Duration responseTimeout;
  int _request = 0;
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<SeekPreviewFrame?> frame(
    File file, {
    required Duration position,
  }) async {
    if (_disposed || position.isNegative) return null;
    final generation = ++_generation;
    try {
      final result = await _channel
          .invokeMethod<Object?>('frame', {
            'session': _session,
            'request': ++_request,
            'path': file.path,
            'positionMs': position.inMilliseconds,
          })
          .timeout(responseTimeout);
      if (_disposed || generation != _generation || result is! Map) return null;
      final bytes = result['bytes'];
      final milliseconds = result['positionMs'];
      if (bytes is! Uint8List ||
          bytes.length < 4 ||
          bytes.length > _maximumFrameBytes ||
          bytes[0] != 0xff ||
          bytes[1] != 0xd8 ||
          bytes[bytes.length - 2] != 0xff ||
          bytes.last != 0xd9 ||
          milliseconds is! int ||
          milliseconds < 0) {
        return null;
      }
      return SeekPreviewFrame(
        bytes: bytes,
        position: Duration(milliseconds: milliseconds),
      );
    } catch (_) {
      // Missing plugins, unsupported codecs and corrupt files leave seeking
      // usable with an explicit preview-unavailable indication.
      return null;
    }
  }

  Future<void> _control(String method) async {
    try {
      await _channel
          .invokeMethod<void>(method, {'session': _session})
          .timeout(responseTimeout);
    } catch (_) {
      // Native deadlines and route/session checks bound work independently.
    }
  }

  @override
  Future<void> cancel() async {
    if (_disposed) return;
    _generation++;
    await _control('cancel');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _control('dispose');
  }
}

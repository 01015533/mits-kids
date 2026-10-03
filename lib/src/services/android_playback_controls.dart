import 'dart:async';

import 'package:flutter/services.dart';

abstract interface class PlaybackControls {
  Future<bool> setTouchLocked(bool locked);
  Future<bool> setLockedPresentation(bool locked);
}

/// Protects player input only. Native pause/focus loss always releases keys.
class AndroidPlaybackControls implements PlaybackControls {
  AndroidPlaybackControls({
    MethodChannel? channel,
    this.responseTimeout = const Duration(seconds: 2),
  }) : _channel = channel ?? const MethodChannel('mits_kids/playback_controls');

  final MethodChannel _channel;
  final Duration responseTimeout;
  final _generations = <String, int>{};

  @override
  Future<bool> setTouchLocked(bool locked) =>
      _setNative('setTouchLocked', locked);

  @override
  Future<bool> setLockedPresentation(bool locked) =>
      _setNative('setLockedPresentation', locked);

  Future<bool> _setNative(String method, bool locked) async {
    final generation = (_generations[method] ?? 0) + 1;
    _generations[method] = generation;
    try {
      // MethodChannel preserves send order. Do not wait for an older reply
      // before sending an unlock on route disposal or lifecycle interruption.
      final acknowledged = await _channel
          .invokeMethod<Object?>(method, {'locked': locked})
          .timeout(responseTimeout);
      if (generation != _generations[method]) return false;
      if (acknowledged == true) return true;
      if (locked) unawaited(_releaseAfterFailure(method, generation));
      return false;
    } catch (_) {
      if (locked && generation == _generations[method]) {
        unawaited(_releaseAfterFailure(method, generation));
      }
      return false;
    }
  }

  Future<void> _releaseAfterFailure(String method, int generation) async {
    if (generation != _generations[method]) return;
    try {
      await _channel
          .invokeMethod<Object?>(method, {'locked': false})
          .timeout(responseTimeout);
    } catch (_) {
      // Unsupported/detached platforms have no acknowledged interception.
      // Native lifecycle/engine cleanup independently resets the lock.
    }
  }
}

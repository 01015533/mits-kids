import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Convenience preferences only; these never change approval or content rules.
class PlaybackPreferences {
  static const _autoplayKey = 'playback_autoplay_next_v1';
  Future<void>? _tail;
  final Set<String> _uncertain = {};

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _tail;
    final completion = Completer<void>();
    _tail = completion.future;
    return () async {
      if (previous != null) await previous;
      try {
        return await action();
      } finally {
        completion.complete();
      }
    }();
  }

  static String _repeatKey(String videoId) => 'playback_repeat_v1_$videoId';

  Future<bool> repeatFor(String videoId) => _read(_repeatKey(videoId));

  Future<void> setRepeat(String videoId, bool enabled) =>
      _write(_repeatKey(videoId), enabled, 'repeat');

  /// One choice for every saved video. A video's own repeat takes priority.
  Future<bool> autoplayNext() => _read(_autoplayKey);

  Future<void> setAutoplayNext(bool enabled) =>
      _write(_autoplayKey, enabled, 'autoplay');

  Future<bool> _read(String key) => _serial(() async {
    if (_uncertain.contains(key)) return false;
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(key) ?? false;
  });

  Future<void> _write(String key, bool enabled, String name) => _serial(
    () async {
      final preferences = await SharedPreferences.getInstance();
      final previous = preferences.getBool(key);
      try {
        if (!await preferences.setBool(key, enabled)) {
          throw StateError('The $name preference could not be saved.');
        }
        _uncertain.remove(key);
      } catch (_) {
        // The plugin updates its cache before it reports a failed disk write.
        // Restore the previous preference; use off locally if that also fails.
        _uncertain.add(key);
        try {
          final restored = previous == null
              ? await preferences.remove(key)
              : await preferences.setBool(key, previous);
          if (restored) _uncertain.remove(key);
        } catch (_) {
          // The choice stays off in this service until another confirmed save.
        }
        rethrow;
      }
    },
  );
}

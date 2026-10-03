import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'parent_session.dart';

class _RecoveryStorageState {
  _RecoveryStorageState(this.confirmedValue);
  Object? confirmedValue;
  Completer<void>? writing;
  bool uncertain = false;
}

/// An optional playback convenience controlled by a live parent session.
/// This preference never grants device-management or content-approval powers.
class ScreenOffRecoveryPreferences {
  static const _key = 'screen_off_recovery_v1';
  static final _states = Expando<_RecoveryStorageState>();

  static _RecoveryStorageState _state(SharedPreferences preferences) =>
      _states[preferences] ??= _RecoveryStorageState(preferences.get(_key));

  Future<bool> isEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    final state = _state(preferences);
    while (state.writing != null) {
      await state.writing!.future;
    }
    if (state.uncertain) {
      throw StateError('Screen-off recovery could not be confirmed.');
    }
    return preferences.getBool(_key) ?? false;
  }

  Future<void> setEnabled(bool enabled, ParentSession session) async {
    final token = session.token;
    final preferences = await SharedPreferences.getInstance();
    final state = _state(preferences);
    while (state.writing != null) {
      await state.writing!.future;
    }
    // Claim the barrier synchronously after the final wait. All instances use
    // the same state, so neither another writer nor a reader sees plugin cache
    // updates until the entire write/compensation sequence finishes.
    if (session.token != token) throw StateError('Parent access expired.');
    final completion = Completer<void>();
    state.writing = completion;
    try {
      if (!await preferences.setBool(_key, enabled)) {
        throw StateError('Screen-off recovery could not be saved.');
      }
      if (session.token != token) throw StateError('Parent access expired.');
      state.confirmedValue = enabled;
      state.uncertain = false;
    } catch (_) {
      state.uncertain = true;
      try {
        final previous = state.confirmedValue;
        if (previous == null) {
          state.uncertain = !await preferences.remove(_key);
        } else if (previous is bool) {
          state.uncertain = !await preferences.setBool(_key, previous);
        }
      } catch (_) {
        // Playback treats an unreadable/uncertain setting as off. A later
        // confirmed parent save can repair the preference for every instance.
      }
      rethrow;
    } finally {
      state.writing = null;
      completion.complete();
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/filter_config.dart';
import 'parent_session.dart';

class _RulesStorageState {
  _RulesStorageState(this.confirmedValue);
  Object? confirmedValue;
  Completer<void>? writing;
  bool uncertain = false;
}

class SettingsRepository {
  static const _configKey = 'filter_config_v1';
  // Every repository in this isolate uses the same plugin singleton. Keep the
  // write barrier and last confirmed value with that instance, not one screen.
  static final _states = Expando<_RulesStorageState>();

  static _RulesStorageState _state(SharedPreferences preferences) =>
      _states[preferences] ??= _RulesStorageState(preferences.get(_configKey));

  Future<FilterConfig> loadConfig() async {
    final preferences = await SharedPreferences.getInstance();
    final state = _state(preferences);
    while (state.writing != null) {
      await state.writing!.future;
    }
    if (state.uncertain) {
      throw StateError(
        'Content rules could not be confirmed. Save parent settings again.',
      );
    }
    final value = preferences.getString(_configKey);
    if (value == null) return FilterConfig.defaults;
    return FilterConfig.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> saveConfig(FilterConfig config, ParentSession session) async {
    final token = session.token;
    final preferences = await SharedPreferences.getInstance();
    final state = _state(preferences);
    while (state.writing != null) {
      await state.writing!.future;
    }
    if (session.token != token) throw StateError('Parent access expired.');
    final encoded = jsonEncode(config.toJson());
    final completion = Completer<void>();
    state.writing = completion;
    try {
      if (!await preferences.setString(_configKey, encoded)) {
        throw StateError('Parent settings could not be written to storage.');
      }
      if (session.token != token) throw StateError('Parent access expired.');
      state.confirmedValue = encoded;
      state.uncertain = false;
    } catch (_) {
      // Both Dart and Android caches can change before persistence reports
      // failure. A reload alone does not prove the new rules reached disk.
      state.uncertain = true;
      try {
        final previous = state.confirmedValue;
        if (previous == null) {
          state.uncertain = !await preferences.remove(_configKey);
        } else if (previous is String) {
          state.uncertain = !await preferences.setString(_configKey, previous);
        }
      } catch (_) {
        // Every reader remains closed until a parent save can be confirmed.
      }
      rethrow;
    } finally {
      state.writing = null;
      completion.complete();
    }
  }
}

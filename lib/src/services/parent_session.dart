import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Parent authority lives only in memory. A lifecycle change invalidates even
/// an authentication request which has not returned from Android yet.
class ParentSession extends ChangeNotifier with WidgetsBindingObserver {
  ParentSession({
    MethodChannel? channel,
    this.lifetime = const Duration(minutes: 5),
  }) : _channel = channel ?? const MethodChannel('mits_kids/parent_security') {
    WidgetsBinding.instance.addObserver(this);
  }

  final MethodChannel _channel;
  final Duration lifetime;
  String? _token;
  Timer? _expiry;
  int _epoch = 0;
  bool _disposed = false;
  bool ready = false;
  bool configured = false;
  bool legacy = false;
  String? error;
  bool get unlocked => _token != null;
  String get token {
    if (_token == null) throw StateError('Parent access is locked.');
    return _token!;
  }

  Future<void> initialise() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('status');
      if (_disposed) return;
      configured = status?['configured'] == true;
      legacy = status?['legacy'] == true;
      error = null;
      ready = true;
    } catch (_) {
      error =
          'Parent security could not start. Fully rebuild the Android app and try again.';
      ready = false;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> authenticate(String pin, {String? newPin}) async {
    final epoch = _epoch;
    Map<String, dynamic>? result;
    try {
      result = await _channel.invokeMapMethod<String, dynamic>(
        configured ? 'authenticate' : 'setup',
        {'pin': pin, if (newPin != null) 'newPin': newPin},
      );
    } catch (_) {
      // A setup commit may succeed just as the OS backgrounds the activity.
      await initialise();
      rethrow;
    }
    if (_disposed || epoch != _epoch) {
      throw StateError('The app was interrupted. Unlock again.');
    }
    final received = result?['token'];
    if (received is! String || received.isEmpty) {
      throw StateError('Parent authentication failed.');
    }
    _token = received;
    configured = true;
    legacy = false;
    _expiry?.cancel();
    _expiry = Timer(lifetime, lock);
    notifyListeners();
  }

  Future<void> changePin(String currentPin, {required String newPin}) async {
    final previousToken = token;
    final epoch = _epoch;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'changePin',
      {'pin': currentPin, 'newPin': newPin},
    );
    if (_disposed || epoch != _epoch || _token != previousToken) {
      throw StateError('The app was interrupted. Unlock again.');
    }
    final received = result?['token'];
    if (received is! String || received.isEmpty) {
      throw StateError('The PIN change could not be confirmed.');
    }
    _token = received;
    _expiry?.cancel();
    _expiry = Timer(lifetime, lock);
    notifyListeners();
  }

  void lock() {
    _epoch++;
    _token = null;
    _expiry?.cancel();
    // Lock locally first. Never wait for Android before removing parent UI.
    unawaited(_channel.invokeMethod<void>('lock').catchError((Object _) {}));
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) lock();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    lock();
    super.dispose();
  }
}

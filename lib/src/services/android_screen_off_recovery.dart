import 'dart:async';

import 'package:flutter/services.dart';

enum ScreenOffRecoveryStatus { recovering, recovered, unavailable }

class ScreenOffRecoveryEvent {
  const ScreenOffRecoveryEvent(this.status, {this.cycle = 0});

  final ScreenOffRecoveryStatus status;
  final int cycle;

  // Cycle zero also supports implementations without a native screen cycle.
  static const recovering = ScreenOffRecoveryEvent(
    ScreenOffRecoveryStatus.recovering,
  );
  static const recovered = ScreenOffRecoveryEvent(
    ScreenOffRecoveryStatus.recovered,
  );
  static const unavailable = ScreenOffRecoveryEvent(
    ScreenOffRecoveryStatus.unavailable,
  );

  @override
  bool operator ==(Object other) =>
      other is ScreenOffRecoveryEvent &&
      status == other.status &&
      cycle == other.cycle;

  @override
  int get hashCode => Object.hash(status, cycle);
}

abstract interface class ScreenOffRecovery {
  Stream<ScreenOffRecoveryEvent> get events;

  /// true requests visibility/recovery for this cycle; an older cycle is a
  /// benign no-op. false revokes both for the entire player session. A successful
  /// false confirms native concealment before unlocking player controls.
  Future<bool> setEligible(bool eligible, {int? cycle});
  Future<void> dispose();
}

/// Eligibility acknowledgements never guarantee that this device can wake.
/// Native cycle ownership and time limits are independent of Dart delivery.
class AndroidScreenOffRecovery implements ScreenOffRecovery {
  AndroidScreenOffRecovery({
    MethodChannel? channel,
    this.responseTimeout = const Duration(seconds: 2),
  }) : _channel =
           channel ?? const MethodChannel('mits_kids/screen_off_recovery'),
       _session = ++_nextSession {
    _owners[_channel.name] = this;
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static int _nextSession = 0;
  static final Map<String, AndroidScreenOffRecovery> _owners = {};
  final MethodChannel _channel;
  final int _session;
  final Duration responseTimeout;
  final _events = StreamController<ScreenOffRecoveryEvent>.broadcast();
  bool _disposed = false;
  int _generation = 0;
  int _latestCycle = 0;
  int _revokedThroughCycle = -1;
  ScreenOffRecoveryStatus? _latestStatus;
  bool _acceptEvents = false;

  @override
  Stream<ScreenOffRecoveryEvent> get events => _events.stream.where(
    (event) =>
        !_disposed && _acceptEvents && event.cycle > _revokedThroughCycle,
  );

  Future<void> _onMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    if (_disposed ||
        !_acceptEvents ||
        arguments is! Map ||
        arguments['session'] != _session) {
      return;
    }
    final status = switch (call.method) {
      'recovering' => ScreenOffRecoveryStatus.recovering,
      'recovered' => ScreenOffRecoveryStatus.recovered,
      'unavailable' => ScreenOffRecoveryStatus.unavailable,
      _ => null,
    };
    final cycle = arguments['cycle'];
    if (status == null ||
        cycle is! int ||
        cycle < _latestCycle ||
        cycle <= _revokedThroughCycle ||
        cycle < 0 ||
        (cycle == 0 && status != ScreenOffRecoveryStatus.unavailable)) {
      return;
    }
    if (cycle > _latestCycle) {
      _latestCycle = cycle;
      _latestStatus = null;
    }
    // A delayed completion cannot act on a later screen-off, and duplicate
    // broadcasts cannot make Dart play or re-arm twice for the same cycle.
    if ((status == ScreenOffRecoveryStatus.recovering &&
            _latestStatus != null) ||
        (status == ScreenOffRecoveryStatus.recovered &&
            (_latestStatus == ScreenOffRecoveryStatus.recovered ||
                _latestStatus == ScreenOffRecoveryStatus.unavailable)) ||
        (status == ScreenOffRecoveryStatus.unavailable &&
            _latestStatus == ScreenOffRecoveryStatus.unavailable)) {
      return;
    }
    _latestStatus = status;
    _events.add(ScreenOffRecoveryEvent(status, cycle: cycle));
  }

  Future<Object?> _send(bool eligible, {int? cycle}) => _channel
      .invokeMethod<Object?>('setEligible', {
        'eligible': eligible,
        'session': _session,
        if (eligible) 'cycle': cycle ?? _latestCycle,
      })
      .timeout(responseTimeout);

  bool _recordRevocation(Object? result) {
    if (result is! Map || result['confirmed'] != true) return false;
    final revokedCycle = result['cycle'];
    if (revokedCycle is! int || revokedCycle < 0) return false;
    // Android may have started a cycle whose event has not reached Dart.
    // Advance monotonically: an old reply cannot disable a newer cycle.
    if (revokedCycle > _latestCycle) _latestCycle = revokedCycle;
    if (revokedCycle > _revokedThroughCycle) {
      _revokedThroughCycle = revokedCycle;
    }
    return true;
  }

  @override
  Future<bool> setEligible(bool eligible, {int? cycle}) async {
    if (_disposed) return false;
    final generation = ++_generation;
    final requestedCycle = cycle ?? _latestCycle;
    _acceptEvents = eligible;
    if (!eligible) _revokedThroughCycle = _latestCycle;
    try {
      final result = await _send(eligible, cycle: requestedCycle);
      final confirmedRevoke = !eligible && _recordRevocation(result);
      if (_disposed || generation != _generation) return false;
      if (result == true || confirmedRevoke) return true;
    } catch (_) {
      // Missing plugins and failed/late acknowledgements leave recovery off.
    }
    if (eligible &&
        !_disposed &&
        generation == _generation &&
        requestedCycle == _latestCycle) {
      _acceptEvents = false;
      _revokedThroughCycle = _latestCycle;
      // Finish cleanup and learn its cycle boundary before a retry is offered.
      await _release();
    }
    return false;
  }

  Future<void> _release() async {
    try {
      _recordRevocation(await _send(false));
    } catch (_) {
      // Native pause, grace expiry and destruction independently clean up.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    if (identical(_owners[_channel.name], this)) {
      _owners.remove(_channel.name);
      _channel.setMethodCallHandler(null);
    }
    // Send before awaiting; disposing an old player must never delay release.
    final release = _release();
    await _events.close();
    await release;
  }
}

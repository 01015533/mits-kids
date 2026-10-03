import 'dart:async';

import 'package:flutter/services.dart';

import 'download_service.dart';
import 'offline_limits.dart';

/// Native lifetime belongs to this one approved transfer, never to Parent UI.
class AndroidDownloadJob implements DownloadJobLifecycle {
  AndroidDownloadJob({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('mits_kids/download_job') {
    _channel.setMethodCallHandler(_nativeCall);
  }

  final MethodChannel _channel;
  String? _job;
  int _generation = 0;
  Future<void>? _starting;
  VoidCallback? _onCancel;
  final Set<String> _earlyCancellations = {};

  @override
  Future<void> start({
    required String videoId,
    required String title,
    required String parentToken,
    required VoidCallback onCancel,
  }) async {
    if (_job != null || _starting != null) {
      throw const DownloadFailure('Another approved download is active.');
    }
    final generation = ++_generation;
    final completion = Completer<void>();
    final starting = completion.future;
    _starting = starting;
    _onCancel = onCancel;
    _earlyCancellations.clear();
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('start', {
            'videoId': videoId,
            'title': title,
            'token': parentToken,
          })
          .timeout(const Duration(seconds: 10));
      final job = result?['job'];
      if (job is! String || job.isEmpty) {
        await _cancelPending();
        throw const DownloadFailure('The background download did not start.');
      }
      if (generation != _generation) {
        await _finishJob(job);
        throw const DownloadCancelled();
      }
      _job = job;
      if (_earlyCancellations.contains(job)) {
        _cancelled(job);
        throw const DownloadCancelled();
      }
    } on PlatformException {
      throw const DownloadFailure(
        'Could not start background saving. Keep the app open and try again.',
      );
    } on TimeoutException {
      await _cancelPending();
      throw const DownloadFailure(
        'Android could not start background saving. Keep the app open and retry.',
      );
    } on MissingPluginException {
      throw const DownloadFailure(
        'Background saving needs the updated Android app. Rebuild or reinstall the update.',
      );
    } finally {
      if (identical(_starting, starting)) _starting = null;
      if (_job == null) _onCancel = null;
      _earlyCancellations.clear();
      completion.complete();
    }
  }

  Future<void> _nativeCall(MethodCall call) async {
    if (call.method != 'cancelled' || call.arguments is! Map) return;
    final job = (call.arguments as Map)['job'];
    if (job is! String) return;
    if (_job == job) {
      _cancelled(job);
    } else if (_starting != null && _earlyCancellations.length < 8) {
      // Cancellation may arrive before the result of the in-flight start.
      _earlyCancellations.add(job);
    }
  }

  void _cancelled(String job) {
    if (_job != job) return;
    final callback = _onCancel;
    _job = null;
    _onCancel = null;
    _generation++;
    callback?.call();
  }

  @override
  void update({required String status, double? progress}) {
    final job = _job;
    if (job == null) return;
    final generation = _generation;
    unawaited(
      _channel
          .invokeMethod<void>('update', {
            'job': job,
            'status': status,
            'progress': progress != null && progress.isFinite
                ? progress.clamp(0.0, 1.0)
                : null,
          })
          .catchError((Object _) {
            if (generation == _generation) _cancelled(job);
          }),
    );
  }

  Future<void> _finishJob(String job) async {
    try {
      await _channel.invokeMethod<void>('finish', {'job': job});
    } catch (_) {
      // Native engine teardown and the independent deadline also stop the job.
    }
  }

  Future<void> _cancelPending() async {
    try {
      await _channel.invokeMethod<void>('cancelPending');
    } catch (_) {
      // The native startup watchdog independently rejects unpromoted jobs.
    }
  }

  @override
  Future<void> finish() async {
    _generation++;
    final job = _job;
    final starting = _starting;
    _job = null;
    _onCancel = null;
    if (job != null) await _finishJob(job);
    // A late start result cancels its own opaque job before this completes.
    if (starting != null) {
      await _cancelPending();
      await starting;
    }
  }
}

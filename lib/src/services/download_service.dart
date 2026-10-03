import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/filter_config.dart';
import '../models/offline_item.dart';
import 'offline_limits.dart';
import 'offline_repository.dart';
import 'url_policy.dart';
import 'video_source.dart';
import 'playback_policy.dart';
import 'android_offline_storage.dart';

/// Keeps one approved download alive and exposes a cancellation action.
/// Production Android callers must provide the foreground-service adapter.
abstract interface class DownloadJobLifecycle {
  Future<void> start({
    required String videoId,
    required String title,
    required String parentToken,
    required VoidCallback onCancel,
  });
  void update({required String status, double? progress});
  Future<void> finish();
}

class _LocalDownloadJob implements DownloadJobLifecycle {
  const _LocalDownloadJob();
  @override
  Future<void> start({
    required String videoId,
    required String title,
    required String parentToken,
    required VoidCallback onCancel,
  }) async {}
  @override
  void update({required String status, double? progress}) {}
  @override
  Future<void> finish() async {}
}

class _DownloadApproval {
  _DownloadApproval(this.videoId, this.metadata) : at = DateTime.now().toUtc();
  final String videoId;
  final DownloadMetadata metadata;
  final DateTime at;
}

class DownloadService extends ChangeNotifier {
  DownloadService(
    this.repository, {
    required this.sourceFactory,
    required this.muxer,
    required this.parentToken,
    Future<Directory> Function()? directoryProvider,
    Future<int> Function(Directory)? availableBytes,
    this.ruleLoader,
    DownloadJobLifecycle? jobLifecycle,
    this.jobTimeout = const Duration(minutes: 30),
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _availableBytes = availableBytes ?? AndroidOfflineStorage.availableBytes,
       _jobLifecycle = jobLifecycle ?? const _LocalDownloadJob();

  final OfflineStore repository;
  final VideoSource Function() sourceFactory;
  final OfflineMuxer muxer;
  final String? Function() parentToken;
  final Future<FilterConfig> Function()? ruleLoader;
  final Duration jobTimeout;
  final DownloadJobLifecycle _jobLifecycle;
  String? _authorisingToken;
  _DownloadApproval? _approval;
  bool get approved => busy && _approval != null;
  String? get approvedVideoId => approved ? _approval!.videoId : null;
  String? lastError;
  OfflineItem? lastSaved;
  Timer? _deadline;
  Stopwatch? _elapsed;
  bool _timedOut = false;
  Completer<void>? _interrupted;
  bool _lifecycleStarted = false;
  Future<void>? _lifecycleFinish;
  final Future<Directory> Function() _directoryProvider;
  final Future<int> Function(Directory) _availableBytes;
  bool busy = false;
  bool canCancel = false;
  bool _cancelled = false;
  bool _disposed = false;
  VideoSource? _source;
  double? progress;
  String status = '';
  int _received = 0;
  int _expected = 0;
  int _lastPercent = -1;

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationDocumentsDirectory()).path, 'offline'),
  );

  void _changed() {
    if (_lifecycleStarted && _lifecycleFinish == null) {
      _jobLifecycle.update(status: status, progress: progress);
    }
    if (!_disposed) notifyListeners();
  }

  void cancel() {
    if (!busy || !canCancel) return;
    _cancelled = true;
    if (!(_interrupted?.isCompleted ?? true)) _interrupted!.complete();
    _source?.close();
    status = 'Cancelling…';
    unawaited(_finishLifecycle());
    _changed();
  }

  void _checkCancelled() {
    if (_timedOut || (_elapsed?.elapsed ?? Duration.zero) >= jobTimeout) {
      throw const DownloadFailure(
        'The download reached its 30-minute limit. Unlock Parent and save it again.',
      );
    }
    if (_cancelled ||
        _disposed ||
        (_approval == null &&
            (_authorisingToken == null ||
                parentToken() != _authorisingToken))) {
      throw const DownloadCancelled();
    }
  }

  void cancelForLock() {
    if (busy && !approved) cancel();
  }

  void clearResult() {
    if (busy) return;
    lastError = null;
    lastSaved = null;
    status = '';
    progress = null;
    _changed();
  }

  Future<void> _finishLifecycle() {
    if (!_lifecycleStarted) return Future<void>.value();
    return _lifecycleFinish ??= Future<void>.sync(_jobLifecycle.finish)
        .catchError((Object _) {
          // Native also bounds the job and stops it when its engine detaches.
        });
  }

  Future<T> _wait<T>(Future<T> operation) async {
    final result = await Future.any<T>([
      operation,
      _interrupted!.future.then<T>((_) {
        _checkCancelled();
        throw const DownloadCancelled();
      }),
    ]);
    _checkCancelled();
    return result;
  }

  Future<OfflineItem> save({
    required String sourceUrl,
    required FilterConfig rules,
    required Future<bool> Function(DownloadMetadata) approve,
  }) async {
    if (_disposed) throw const DownloadCancelled();
    if (busy) throw const DownloadFailure('A video is already downloading.');
    _authorisingToken = parentToken();
    if (_authorisingToken == null) {
      throw const DownloadFailure('Unlock parent access before saving.');
    }
    final id = UrlPolicy.videoId(Uri.tryParse(sourceUrl));
    if (id == null) {
      throw const DownloadFailure('Open a YouTube video before saving.');
    }
    busy = true;
    canCancel = true;
    _cancelled = false;
    _timedOut = false;
    _approval = null;
    _lifecycleStarted = false;
    _lifecycleFinish = null;
    _interrupted = Completer<void>();
    _elapsed = Stopwatch()..start();
    _deadline = Timer(jobTimeout, () {
      _timedOut = true;
      cancel();
    });
    lastError = null;
    lastSaved = null;
    progress = null;
    status = 'Preparing download…';
    _received = 0;
    _lastPercent = -1;
    _changed();
    Directory? staging;
    File? published;
    bool committed = false;
    OfflineMutationLease? lease;
    try {
      if (repository is OfflineRepository) {
        lease = (repository as OfflineRepository).acquireMutation();
      }
      final existing = await _wait(repository.all());
      _checkCancelled();
      final directory = await _directoryProvider();
      await directory.create(recursive: true);
      await _cleanAbandonedFiles(directory, existing);
      _checkCancelled();
      for (final item in existing) {
        if (UrlPolicy.videoId(Uri.tryParse(item.sourceUrl)) == id) {
          if (!PlaybackPolicy.allows(item, FilterConfig.defaults)) {
            throw const DownloadFailure(
              'This earlier saved video needs approval. Delete it in Parent, then review and save it again.',
            );
          }
          if (!PlaybackPolicy.allows(item, rules)) {
            throw const DownloadFailure(
              'This saved video is blocked by the current Parent settings.',
            );
          }
          try {
            await repository.verifyFile(item);
          } catch (_) {
            throw const DownloadFailure(
              'The saved copy could not be verified. Delete it in Parent, then review and save it again.',
            );
          }
          _checkCancelled();
          canCancel = false;
          _deadline?.cancel();
          status = 'Already available offline';
          lastSaved = item;
          return item;
        }
      }
      if (existing.length >= maxOfflineVideos) throw const LibraryFull();
      _checkCancelled();
      final source = sourceFactory();
      _source = source;
      final metadata = await _wait(
        source.describe(id).timeout(const Duration(seconds: 45)),
      );
      _checkCancelled();
      if (metadata.isLive) {
        throw const DownloadFailure('Live streams cannot be saved.');
      }
      if (!RegExp(r'^UC[a-zA-Z0-9_-]{22}$').hasMatch(metadata.channelId) ||
          !PlaybackPolicy.matchesRules(
            title: metadata.title,
            author: metadata.author,
            channelId: metadata.channelId,
            rules: rules,
          )) {
        throw const DownloadFailure(
          'This video is blocked by your parent settings.',
        );
      }
      if (!await _wait(approve(metadata))) throw const DownloadCancelled();
      _checkCancelled();
      // No await may separate the final session check and this single-video
      // approval. It grants no parent capability and never survives a restart.
      final approval = _DownloadApproval(id, metadata);
      _approval = approval;
      _lifecycleStarted = true;
      await _wait(
        _jobLifecycle.start(
          videoId: id,
          title: metadata.title,
          parentToken: _authorisingToken!,
          onCancel: () {
            if (identical(_approval, approval)) cancel();
          },
        ),
      );
      _changed();
      final plan = await _wait(
        source.resolve(id).timeout(const Duration(seconds: 60)),
      );
      _checkCancelled();
      _expected = plan.bytes;
      if (plan.video.bytes <= 0 ||
          (plan.audio != null && plan.audio!.bytes <= 0)) {
        throw const DownloadFailure(
          'This video has no complete downloadable stream.',
        );
      }
      if (_expected > maxDownloadBytes) {
        throw const DownloadFailure(
          'This video is over the 1 GB download limit.',
        );
      }
      final muxBytes = plan.audio == null
          ? 0
          : _expected + offlineMuxAllowanceBytes;
      await _requireStorage(directory, _expected + muxBytes);
      _checkCancelled();
      staging = await directory.createTemp('.pending-');
      final videoFile = File(p.join(staging.path, 'video.part'));
      final audioFile = File(p.join(staging.path, 'audio.part'));
      final readyFile = File(p.join(staging.path, 'ready.mp4'));
      status = 'Downloading ${metadata.title}';
      _changed();
      await _writeTrack(plan.video, videoFile);
      if (plan.audio != null) {
        await _writeTrack(plan.audio!, audioFile);
        _checkCancelled();
        await _requireStorage(directory, muxBytes);
        _checkCancelled();
        status = 'Finishing video…';
        progress = null;
        _changed();
        await muxer.combine(videoFile, audioFile, readyFile);
      } else {
        await videoFile.rename(readyFile.path);
      }
      _checkCancelled();
      final bytes = await readyFile.length();
      if (bytes <= 0) {
        throw const DownloadFailure('The downloaded file is empty.');
      }
      final contentHash = (await sha256.bind(readyFile.openRead()).first)
          .toString();
      _checkCancelled();
      // Unique output prevents a failed save overwriting an older download.
      final output = p.join(
        directory.path,
        '$id-${DateTime.now().microsecondsSinceEpoch}.mp4',
      );
      published = await readyFile.rename(output);
      final item = OfflineItem(
        id: id,
        title: metadata.title,
        sourceUrl: 'https://www.youtube.com/watch?v=$id',
        filePath: output,
        bytes: bytes,
        createdAt: DateTime.now().toUtc(),
        author: metadata.author,
        channelId: metadata.channelId,
        contentHash: contentHash,
        approvedAt: _approval!.at,
      );
      await _checkCurrentRules(_approval!.metadata, rules);
      if (repository is OfflineRepository) {
        await (repository as OfflineRepository).add(item, lease: lease);
      } else {
        await repository.add(item);
      }
      try {
        // A rules edit can race the SQLite operation; revoke the new row and
        // file if it became blocked or current settings cannot be loaded.
        await _checkCurrentRules(_approval!.metadata, rules);
      } catch (_) {
        if (repository is OfflineRepository) {
          await (repository as OfflineRepository).delete(item, lease: lease);
        } else {
          await repository.delete(item);
        }
        rethrow;
      }
      committed = true;
      // Publication has completed. A late notification tap during private
      // cleanup cannot turn this completed save into a reported cancellation.
      canCancel = false;
      _deadline?.cancel();
      lastSaved = item;
      status = 'Saved for offline viewing';
      progress = 1;
      return item;
    } catch (error) {
      final DownloadFailure failure;
      if (_timedOut) {
        failure = const DownloadFailure(
          'The download reached its 30-minute limit. Unlock Parent and save it again.',
        );
      } else if (_cancelled || _disposed) {
        failure = const DownloadCancelled();
      } else if (error is DownloadFailure) {
        failure = error;
      } else if (error is FileSystemException) {
        failure = const DownloadFailure(
          'Could not save the file. Check the tablet’s free storage and retry.',
        );
      } else if (error is TimeoutException || error is SocketException) {
        failure = const DownloadFailure(
          'The connection was interrupted. Reconnect and tap Save to retry.',
        );
      } else {
        failure = const DownloadFailure(
          'YouTube could not provide a downloadable video. Try another public video or retry later.',
        );
      }
      lastError = failure.message;
      status = failure is DownloadCancelled
          ? 'Download cancelled'
          : 'Download not saved';
      throw failure;
    } finally {
      _deadline?.cancel();
      _elapsed?.stop();
      _source?.close();
      _source = null;
      try {
        if (!committed && published != null && await published.exists()) {
          await published.delete();
        }
        if (staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } on FileSystemException {
        /* Retry staging cleanup on next Save. */
      }
      lease?.release();
      await _finishLifecycle();
      busy = false;
      canCancel = false;
      _approval = null;
      _authorisingToken = null;
      _changed();
    }
  }

  Future<void> _checkCurrentRules(
    DownloadMetadata metadata,
    FilterConfig fallback,
  ) async {
    _checkCancelled();
    final FilterConfig current;
    try {
      current = ruleLoader == null ? fallback : await _wait(ruleLoader!());
    } on DownloadCancelled {
      rethrow;
    } catch (_) {
      _checkCancelled();
      throw const DownloadFailure(
        'Current Parent settings could not be checked. The video was not saved.',
      );
    }
    _checkCancelled();
    if (!PlaybackPolicy.matchesRules(
      title: metadata.title,
      author: metadata.author,
      channelId: metadata.channelId,
      rules: current,
    )) {
      throw const DownloadFailure(
        'This video is now blocked by Parent settings and was not saved.',
      );
    }
  }

  Future<void> _requireStorage(Directory directory, int workingBytes) async {
    final available = await _wait(_availableBytes(directory));
    final required = workingBytes + offlineStorageReserveBytes;
    if (available < required) {
      final requiredMb = (required / (1024 * 1024)).ceil();
      throw DownloadFailure(
        'Not enough free storage. This step needs at least $requiredMb MB free, including a 128 MB reserve. Free storage in Parent or Android settings and retry.',
      );
    }
  }

  Future<void> _cleanAbandonedFiles(
    Directory directory,
    List<OfflineItem> existing,
  ) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const DownloadFailure('The offline storage directory is invalid.');
    }
    // Android may expose its private data directory through a platform alias.
    // Resolve that alias, while refusing a symlink as the offline root itself.
    final canonicalDirectory = Directory(
      await directory.resolveSymbolicLinks(),
    );
    final referenced = <String>{};
    for (final item in existing) {
      referenced.add(p.normalize(p.absolute(item.filePath)));
      try {
        referenced.add(await File(item.filePath).resolveSymbolicLinks());
      } on FileSystemException {
        // A missing or damaged file keeps its database entry for Parent.
      }
    }
    final generatedVideo = RegExp(r'^[a-zA-Z0-9_-]{11}-[0-9]{16,20}\.mp4$');
    final generatedStaging = RegExp(r'^\.pending-[a-zA-Z0-9]+$');
    await for (final entity in canonicalDirectory.list(followLinks: false)) {
      _checkCancelled();
      final path = p.normalize(p.absolute(entity.path));
      if (referenced.any((entry) => entry == path || p.isWithin(path, entry))) {
        continue;
      }
      final name = p.basename(path);
      if (entity is File && generatedVideo.hasMatch(name)) {
        await entity.delete();
      } else if (entity is Directory && generatedStaging.hasMatch(name)) {
        // Dart recursive deletion removes links themselves, never their targets.
        await entity.delete(recursive: true);
      }
    }
  }

  Future<void> _writeTrack(DownloadTrack track, File target) async {
    final file = await target.open(mode: FileMode.write);
    var bytes = 0;
    final iterator = StreamIterator(
      track.open().timeout(const Duration(seconds: 30)),
    );
    try {
      while (await _wait(iterator.moveNext())) {
        final chunk = iterator.current;
        _checkCancelled();
        bytes += chunk.length;
        _received += chunk.length;
        if (bytes > track.bytes || _received > maxDownloadBytes) {
          throw const DownloadFailure(
            'The video download exceeded its expected size.',
          );
        }
        await file.writeFrom(chunk);
        progress = _received / _expected;
        final percent = (progress! * 100).floor();
        if (percent != _lastPercent) {
          _lastPercent = percent;
          _changed();
        }
      }
      _checkCancelled();
      if (bytes != track.bytes) {
        throw const DownloadFailure(
          'The download was incomplete. Tap Save to retry.',
        );
      }
      await file.flush();
    } finally {
      unawaited(iterator.cancel().catchError((Object _) {}));
      await file.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

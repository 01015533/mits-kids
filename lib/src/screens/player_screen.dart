import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/offline_item.dart';
import '../services/android_playback_controls.dart';
import '../services/android_screen_off_recovery.dart';
import '../services/offline_repository.dart';
import '../services/settings_repository.dart';
import '../services/playback_policy.dart';
import '../services/playback_preferences.dart';
import '../services/screen_off_recovery_preferences.dart';
import '../services/seek_preview_frames.dart';
import '../widgets/seek_preview_timeline.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    required this.item,
    required this.repository,
    required this.settings,
    this.playbackControls,
    this.playbackPreferences,
    this.screenOffRecovery,
    this.screenOffRecoveryPreferences,
    this.seekPreviewFrames,
    super.key,
  });
  final OfflineRepository repository;
  final SettingsRepository settings;
  final OfflineItem item;
  final PlaybackControls? playbackControls;
  final PlaybackPreferences? playbackPreferences;
  final ScreenOffRecovery? screenOffRecovery;
  final ScreenOffRecoveryPreferences? screenOffRecoveryPreferences;
  final SeekPreviewFrames? seekPreviewFrames;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  VideoPlayerController? _player;
  File? _verifiedFile;
  late final Future<void> ready;
  late final PlaybackControls _controls;
  late final PlaybackPreferences _preferences;
  late final ScreenOffRecovery _recovery;
  StreamSubscription<ScreenOffRecoveryEvent>? _recoveryEvents;
  Timer? _recoveryExpiry;
  Timer? _recoveryArmRetry;
  Future<void>? _lifecyclePause;
  bool _recoveryEnabled = false;
  bool _recoveryCandidate = false;
  bool _recoveryConfirmed = false;
  bool _recovering = false;
  bool _recoveryMayShowWhenLocked = false;
  bool _unlocking = false;
  String? _unlockError;
  bool? _lastRecoveryEligibility;
  int _recoveryGeneration = 0;
  int _recoveryCycle = 0;
  late final AnimationController _hold;
  final FocusNode _unlockFocus = FocusNode(debugLabel: 'Unlock playback');
  int _nativeGeneration = 0;
  final Set<int> _holdPointers = {};
  Offset? _holdOrigin;
  int _seekGeneration = 0;
  bool _scrubbing = false;
  bool _seekCommitting = false;
  bool _resumeAfterScrub = false;
  Future<void>? _scrubPause;
  bool _touchLocked = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _playingWhileInactive = false;
  // Autoplay replaces the video inside this screen, so the touch lock, native
  // key handling and recovery bridge continue unchanged into the next video.
  late OfflineItem _item;
  VideoPlayerController? _incoming;
  bool _repeat = false;
  bool _autoplay = false;
  bool _advancing = false;
  bool _endHandled = false;
  int _controlGeneration = 0;
  int _departures = 0;
  bool _prepared = false;
  bool _preferenceSaving = false;
  bool _volumeUnavailable = false;
  String? _notice;

  static const _preparingNext = 'Getting the next video ready…';

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    WidgetsBinding.instance.addObserver(this);
    _controls = widget.playbackControls ?? AndroidPlaybackControls();
    _preferences = widget.playbackPreferences ?? PlaybackPreferences();
    _recovery = widget.screenOffRecovery ?? AndroidScreenOffRecovery();
    _recoveryEvents = _recovery.events.listen(_onRecoveryEvent);
    _hold =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) unawaited(_unlock());
          });
    ready = prepare();
  }

  Future<void> prepare() async {
    final records = await widget.repository.all();
    final item = records.where((entry) => entry.id == _item.id).firstOrNull;
    if (item == null ||
        !PlaybackPolicy.allows(item, await widget.settings.loadConfig())) {
      throw StateError('This video is no longer approved.');
    }
    final file = await widget.repository.verifyFile(item);
    if (!mounted) return;
    _verifiedFile = file;
    final controller = VideoPlayerController.file(file);
    _player = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      var repeat = false;
      try {
        repeat = await _preferences.repeatFor(item.id);
      } catch (_) {
        _notice = 'The repeat preference could not be read. Repeat is off.';
      }
      var autoplay = false;
      try {
        autoplay = await _preferences.autoplayNext();
      } catch (_) {
        const unread =
            'The autoplay preference could not be read. Autoplay is off.';
        _notice = _notice == null ? unread : '$_notice $unread';
      }
      if (!mounted) return;
      await controller.setLooping(repeat);
      if (!mounted) return;
      try {
        _recoveryEnabled =
            await (widget.screenOffRecoveryPreferences ??
                    ScreenOffRecoveryPreferences())
                .isEnabled();
      } catch (_) {
        _recoveryEnabled = false;
        _notice =
            'Screen-off recovery could not be read. It is off for this video.';
      }
      if (!mounted) return;
      controller
        ..addListener(_syncRecoveryEligibility)
        ..addListener(_watchForEnd);
      setState(() {
        _repeat = repeat;
        _autoplay = autoplay;
        _prepared = true;
      });
      _syncRecoveryEligibility();
    } catch (_) {
      if (mounted) {
        _player = null;
        await controller.dispose();
      }
      rethrow;
    }
  }

  void _syncRecoveryEligibility({bool retry = true}) {
    if (_disposed ||
        (!_foreground && !_playingWhileInactive) ||
        _recoveryCandidate ||
        _recovering ||
        _unlocking) {
      return;
    }
    final controller = _player;
    final eligible =
        _recoveryEnabled &&
        _touchLocked &&
        _prepared &&
        ModalRoute.of(context)?.isCurrent == true &&
        controller != null &&
        !controller.value.hasError &&
        controller.value.isPlaying;
    if (_lastRecoveryEligibility == eligible) return;
    _lastRecoveryEligibility = eligible;
    // Mark before sending: a timed-out reply can still mean Android applied
    // the visibility flag. Only a confirmed revoke permits normal navigation.
    if (eligible) _recoveryMayShowWhenLocked = true;
    _recoveryArmRetry?.cancel();
    final generation = ++_recoveryGeneration;
    final cycle = _recoveryCycle > 0 ? _recoveryCycle : null;
    unawaited(() async {
      var armed = false;
      try {
        armed = await _recovery.setEligible(eligible, cycle: cycle);
      } catch (_) {
        // Injected/platform implementations may fail; playback still works.
      }
      if (generation == _recoveryGeneration && !eligible && armed) {
        _recoveryMayShowWhenLocked = false;
        _recoveryCycle = 0;
      }
      if (_disposed ||
          generation != _recoveryGeneration ||
          !eligible ||
          armed) {
        return;
      }
      // Failed arming completes native cleanup before returning. Its snapshot
      // may include an unseen cycle, so any retry uses the bridge's latest ID.
      _recoveryCycle = 0;
      // Android can deliver Flutter resumed before the window regains focus.
      if (retry && _foreground && !_recoveryCandidate) {
        _recoveryArmRetry = Timer(const Duration(milliseconds: 250), () {
          if (_disposed || generation != _recoveryGeneration) return;
          _lastRecoveryEligibility = null;
          _syncRecoveryEligibility(retry: false);
        });
      } else if (mounted && _foreground && !_recoveryCandidate) {
        setState(
          () => _notice =
              'Screen-off recovery is unavailable right now. Playback still works.',
        );
      }
    }());
  }

  Future<bool> _cancelRecovery() {
    final generation = ++_recoveryGeneration;
    _recoveryExpiry?.cancel();
    _recoveryArmRetry?.cancel();
    _recoveryCandidate = false;
    _recoveryConfirmed = false;
    _lastRecoveryEligibility = false;
    return _recovery
        .setEligible(false)
        .then((confirmed) {
          if (confirmed && generation == _recoveryGeneration) {
            _recoveryMayShowWhenLocked = false;
            // Native may have started another cycle before its notification
            // reached Dart. The bridge learns that number from this revoke
            // ACK; a fresh lock must use its latest cycle, not our old one.
            _recoveryCycle = 0;
          }
          return confirmed;
        })
        .catchError((Object _) => false);
  }

  void _onRecoveryEvent(ScreenOffRecoveryEvent event) {
    if (_disposed || !mounted || _unlocking) return;
    if (event.cycle < _recoveryCycle) return;
    if (event.status == ScreenOffRecoveryStatus.recovering) {
      // Every real screen-off is a separate native attempt. Its announcement
      // also covers quick wake-ups that never change Flutter's lifecycle.
      if (event.cycle <= _recoveryCycle) return;
      final controller = _player;
      final wantedPlayback =
          _recoveryCandidate || controller?.value.isPlaying == true;
      _recoveryCycle = event.cycle;
      _recoveryGeneration++;
      _recoveryArmRetry?.cancel();
      _lastRecoveryEligibility = null;
      _recoveryCandidate =
          wantedPlayback &&
          _recoveryEnabled &&
          _touchLocked &&
          _prepared &&
          controller != null &&
          !controller.value.hasError &&
          ModalRoute.of(context)?.isCurrent == true;
      _recoveryConfirmed = false;
      _recoveryExpiry?.cancel();
      if (_recoveryCandidate) {
        _recoveryExpiry = Timer(const Duration(seconds: 4), _cancelRecovery);
      } else {
        _cancelRecovery();
      }
      return;
    }
    if (event.status == ScreenOffRecoveryStatus.unavailable) {
      _recoveryCycle = event.cycle;
      _cancelRecovery();
      setState(
        () => _notice =
            'Screen-off recovery did not complete. Unlock and press Play to continue.',
      );
      return;
    }
    // A positive cycle must first announce its own screen-off. A late result
    // cannot borrow a candidate belonging to a different power-button press.
    if (event.cycle != _recoveryCycle) return;
    if (!_recoveryCandidate || !_recoveryEnabled || !_touchLocked) return;
    _recoveryConfirmed = true;
    unawaited(_resumeRecoveredPlayback());
  }

  Future<void> _resumeRecoveredPlayback() async {
    if (_recovering ||
        !_foreground ||
        !_recoveryCandidate ||
        !_recoveryConfirmed) {
      return;
    }
    _recovering = true;
    final generation = _recoveryGeneration;
    final controller = _player;
    try {
      // A late pause completion must not overtake our single recovery play.
      await _lifecyclePause;
      if (_disposed ||
          !mounted ||
          !_foreground ||
          !_touchLocked ||
          !_recoveryEnabled ||
          !_recoveryCandidate ||
          generation != _recoveryGeneration ||
          controller == null ||
          !identical(controller, _player) ||
          controller.value.hasError ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      // video_player.play() performs an asynchronous seek at EOF, after which
      // it starts unconditionally. Recovery must never restart a finished video
      // or race an unlock/background transition across that hidden seek.
      if (controller.value.position >= controller.value.duration) {
        _cancelRecovery();
        return;
      }
      _recoveryExpiry?.cancel();
      _recoveryCandidate = false;
      _recoveryConfirmed = false;
      // With showWhenLocked, a quick off/on may never pause Flutter or the
      // decoder. Confirm this cycle without restarting already-playing media.
      if (!controller.value.isPlaying) await controller.play();
      if (!_disposed &&
          mounted &&
          (generation != _recoveryGeneration ||
              (!_foreground && !_playingWhileInactive) ||
              !_touchLocked ||
              ModalRoute.of(context)?.isCurrent != true)) {
        await controller.pause();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice =
              'Playback could not resume. Unlock and press Play to continue.',
        );
      }
    } finally {
      _recovering = false;
      if (!_disposed) {
        _lastRecoveryEligibility = null;
        // A newer cycle may finish while an older platform play is pending.
        // Finish (and, if invalidated, pause) the old request before servicing
        // the latest confirmation; do not lose it behind _recovering.
        if (generation != _recoveryGeneration &&
            _foreground &&
            _recoveryCandidate &&
            _recoveryConfirmed) {
          unawaited(_resumeRecoveredPlayback());
        } else {
          _syncRecoveryEligibility();
        }
      }
    }
  }

  // Send unlock immediately even while an older reply is pending. The platform
  // channel preserves send order; stale replies cannot alter this screen.
  void _requestVolumeLock(bool locked) {
    final generation = ++_nativeGeneration;
    unawaited(() async {
      var confirmed = false;
      try {
        confirmed = await _controls.setTouchLocked(locked);
      } catch (_) {
        // Touch controls remain locked even if this platform cannot lock keys.
      }
      if (mounted && generation == _nativeGeneration && locked) {
        setState(() => _volumeUnavailable = !confirmed);
      }
    }());
  }

  void _lock() {
    if (_touchLocked) return;
    _cancelScrub();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _touchLocked = true;
      _volumeUnavailable = false;
      _unlockError = null;
    });
    _requestVolumeLock(_foreground);
    _requestLockedPresentation(true);
    _syncRecoveryEligibility();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _touchLocked) _unlockFocus.requestFocus();
    });
  }

  void _startUnlock() {
    if (_disposed ||
        !_touchLocked ||
        !_foreground ||
        _hold.isAnimating ||
        _unlocking) {
      return;
    }
    _hold.forward(from: 0);
  }

  void _cancelHold() {
    if (_disposed) return;
    _hold.stop();
    _hold.value = 0;
    _holdOrigin = null;
  }

  Future<void> _unlock() async {
    if (_disposed || !mounted || !_touchLocked || _unlocking) return;
    _cancelHold();
    final mustConfirm = _recoveryMayShowWhenLocked;
    setState(() {
      _unlocking = true;
      _unlockError = null;
    });
    final revoking = _cancelRecovery();
    // Native covers Flutter before removing showWhenLocked when Android is
    // locked. Keep every player control and Back blocked until it acknowledges
    // that handoff. Parent/Browse can never be reached through this unlock first.
    if (mustConfirm && !await revoking) {
      if (!_disposed && mounted) {
        setState(() {
          _unlocking = false;
          _recoveryEnabled = false;
          _unlockError =
              'Unlock could not finish. Hold the lock again to retry.';
        });
      }
      return;
    }
    if (_disposed || !mounted) return;
    setState(() {
      _unlocking = false;
      _touchLocked = false;
      _volumeUnavailable = false;
      _recoveryMayShowWhenLocked = false;
    });
    _requestVolumeLock(false);
    _requestLockedPresentation(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    final wasPlayingWhileInactive = _playingWhileInactive;
    setState(() => _foreground = state == AppLifecycleState.resumed);
    if (!_foreground) {
      _cancelScrub();
      _holdPointers.clear();
      _cancelHold();
      // The notification shade loses Flutter focus while the Android activity
      // can remain resumed. Keep only already-playing, touch-locked media going;
      // hidden/paused still pause it below. Native independently ends lock-screen
      // visibility on an actual activity departure or failed screen-off recovery.
      final controller = _player;
      if (state == AppLifecycleState.inactive &&
          _touchLocked &&
          !_unlocking &&
          _prepared &&
          controller != null &&
          controller.value.isPlaying &&
          !controller.value.hasError &&
          ModalRoute.of(context)?.isCurrent == true) {
        _playingWhileInactive = true;
        _requestVolumeLock(false);
        return;
      }
      _playingWhileInactive = false;
      _departures++;
      if (wasForeground || wasPlayingWhileInactive) {
        _recoveryGeneration++;
        _recoveryArmRetry?.cancel();
        _lastRecoveryEligibility = null;
        _recoveryCandidate =
            _recoveryEnabled &&
            !_unlocking &&
            _touchLocked &&
            _player?.value.isPlaying == true &&
            _player?.value.hasError == false;
        _recoveryConfirmed = false;
        _recoveryExpiry?.cancel();
        if (_recoveryCandidate) {
          // Native has three seconds; permit callback/lifecycle delivery only
          // briefly beyond it. Home/app switching supplies no recovery event.
          _recoveryExpiry = Timer(const Duration(seconds: 4), _cancelRecovery);
        }
      }
      _lifecyclePause = _pause();
      _requestVolumeLock(false);
    } else {
      _playingWhileInactive = false;
      if (_touchLocked) {
        _requestVolumeLock(true);
        _requestLockedPresentation(true);
      }
      unawaited(_resumeRecoveredPlayback());
      _syncRecoveryEligibility();
    }
  }

  Future<void> _pause() async {
    try {
      await _player?.pause();
    } catch (_) {
      // A decoder can already be shutting down during lifecycle teardown.
    }
  }

  void _requestLockedPresentation(bool locked) {
    unawaited(() async {
      try {
        await _controls.setLockedPresentation(locked);
      } catch (_) {
        // In-app locking remains available if Android cannot hide its bars.
      }
    }());
  }

  bool get _canSeek =>
      !_disposed &&
      mounted &&
      _foreground &&
      !_touchLocked &&
      _prepared &&
      _player != null &&
      !_player!.value.hasError &&
      ModalRoute.of(context)?.isCurrent == true;

  bool _seekIsCurrent(int generation, VideoPlayerController controller) =>
      generation == _seekGeneration &&
      identical(controller, _player) &&
      _canSeek;

  void _startScrub(Duration position) {
    if (!_canSeek || _seekCommitting) return;
    _controlGeneration++;
    _seekGeneration++;
    setState(() {
      _scrubbing = true;
      _resumeAfterScrub = _player!.value.isPlaying;
    });
    _scrubPause = _pause();
  }

  Future<void> _finishScrub(Duration? position) async {
    if (!_scrubbing || !_canSeek) return;
    final controller = _player!;
    final generation = _seekGeneration;
    final resume = _resumeAfterScrub;
    setState(() {
      _scrubbing = false;
      _seekCommitting = true;
    });
    try {
      await _scrubPause;
      if (!_seekIsCurrent(generation, controller)) return;
      if (position != null) await controller.seekTo(position);
      if (!_seekIsCurrent(generation, controller)) return;
      // Seeking to the very end must not invoke video_player's automatic
      // rewind-on-play. A previously paused video also remains paused.
      if (resume && controller.value.position < controller.value.duration) {
        await controller.play();
        if (!_disposed && mounted && !_seekIsCurrent(generation, controller)) {
          await controller.pause();
        }
      }
    } catch (_) {
      if (!_disposed && mounted && generation == _seekGeneration) {
        setState(() => _notice = 'Could not move to that scene. Try again.');
      }
    } finally {
      if (!_disposed && mounted && generation == _seekGeneration) {
        setState(() {
          _seekCommitting = false;
          _resumeAfterScrub = false;
        });
      }
    }
  }

  void _cancelScrub({bool resume = false}) {
    if (resume && _scrubbing && _canSeek) {
      unawaited(_finishScrub(null));
      return;
    }
    if (!_scrubbing && !_seekCommitting) return;
    _seekGeneration++;
    void clear() {
      _scrubbing = false;
      _seekCommitting = false;
      _resumeAfterScrub = false;
    }

    if (!_disposed && mounted) {
      setState(clear);
    } else {
      clear();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelScrub();
    WidgetsBinding.instance.removeObserver(this);
    _cancelRecovery();
    unawaited(_recoveryEvents?.cancel());
    unawaited(_recovery.dispose());
    _requestVolumeLock(false);
    _requestLockedPresentation(false);
    _hold.dispose();
    _unlockFocus.dispose();
    final controller = _player;
    _player = null;
    if (controller != null) {
      controller
        ..removeListener(_syncRecoveryEligibility)
        ..removeListener(_watchForEnd);
      unawaited(controller.dispose().catchError((Object _) {}));
    }
    final incoming = _incoming;
    _incoming = null;
    if (incoming != null) {
      unawaited(incoming.dispose().catchError((Object _) {}));
    }
    super.dispose();
  }

  String time(Duration value) {
    final hours = value.inHours;
    final minutes = (hours > 0 ? value.inMinutes % 60 : value.inMinutes)
        .toString()
        .padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '${hours > 0 ? '$hours:' : ''}$minutes:$seconds';
  }

  Future<void> toggle() async {
    final controller = _player;
    if (_touchLocked || _scrubbing || _seekCommitting || controller == null) {
      return;
    }
    _controlGeneration++;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        if (controller.value.position >= controller.value.duration) {
          await controller.seekTo(Duration.zero);
        }
        if (mounted && !_touchLocked && _foreground) await controller.play();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _notice = 'Playback failed. Reopen this video.');
      }
    }
  }

  Future<void> _restart() async {
    if (_touchLocked || _scrubbing || _seekCommitting) return;
    _controlGeneration++;
    try {
      await _player?.seekTo(Duration.zero);
    } catch (_) {
      if (mounted) {
        setState(() => _notice = 'Restart failed. Reopen this video.');
      }
    }
  }

  void _watchForEnd() {
    final value = _player?.value;
    if (value == null) return;
    // video_player seeks to the end after completion; wait for that position
    // so a stale completion flag can never move on from a replayed video.
    if (!value.isCompleted ||
        value.isPlaying ||
        value.duration <= Duration.zero ||
        value.position < value.duration) {
      _endHandled = false;
      return;
    }
    if (_endHandled) return;
    _endHandled = true;
    unawaited(_playNext(_player!));
  }

  /// The next video in Offline's order that passes the current content rules
  /// and file integrity check. Damaged files are skipped, as Offline hides them.
  Future<(OfflineItem, File)?> _nextVideo(String id) async {
    final records = await widget.repository.all();
    final rules = await widget.settings.loadConfig();
    final allowed = [
      for (final item in records)
        if (PlaybackPolicy.allows(item, rules)) item,
    ];
    final index = allowed.indexWhere((item) => item.id == id);
    if (index < 0) return null;
    for (final item in allowed.skip(index + 1)) {
      if (_disposed) return null;
      try {
        return (item, await widget.repository.verifyFile(item));
      } catch (_) {
        // Try the following saved video.
      }
    }
    return null;
  }

  Future<void> _playNext(VideoPlayerController finished) async {
    final controls = _controlGeneration;
    final departures = _departures;
    // Any player control, leaving the app, settings or an unlock in progress
    // keeps the finished video. Returning to the app never starts the next one.
    bool stillWanted() =>
        !_disposed &&
        mounted &&
        _autoplay &&
        !_repeat &&
        identical(_player, finished) &&
        !finished.value.isPlaying &&
        !finished.value.isLooping &&
        !finished.value.hasError &&
        controls == _controlGeneration &&
        departures == _departures &&
        (_foreground || _playingWhileInactive) &&
        !_scrubbing &&
        !_seekCommitting &&
        !_unlocking &&
        !_recovering &&
        ModalRoute.of(context)?.isCurrent == true;
    if (_advancing || !stillWanted()) return;
    setState(() {
      _advancing = true;
      _notice = _preparingNext;
    });
    VideoPlayerController? incoming;
    String? outcome;
    try {
      final next = await _nextVideo(_item.id);
      if (!stillWanted()) return;
      if (next == null) {
        outcome = 'No more videos to play next.';
        return;
      }
      final (item, file) = next;
      incoming = _incoming = VideoPlayerController.file(file);
      await incoming.initialize();
      if (!stillWanted()) return;
      var repeat = false;
      String? notice;
      try {
        repeat = await _preferences.repeatFor(item.id);
      } catch (_) {
        notice = 'The repeat preference could not be read. Repeat is off.';
      }
      if (!stillWanted()) return;
      await incoming.setLooping(repeat);
      if (!stillWanted()) return;
      finished
        ..removeListener(_syncRecoveryEligibility)
        ..removeListener(_watchForEnd);
      final started = incoming;
      _player = started;
      _incoming = incoming = null;
      started
        ..addListener(_syncRecoveryEligibility)
        ..addListener(_watchForEnd);
      setState(() {
        _item = item;
        _verifiedFile = file;
        _repeat = repeat;
        _notice = notice;
      });
      unawaited(finished.dispose().catchError((Object _) {}));
      await started.play();
      if (!_disposed &&
          mounted &&
          identical(_player, started) &&
          !_foreground &&
          !_playingWhileInactive) {
        await started.pause();
      }
    } catch (_) {
      if (!_disposed && mounted) {
        setState(() => _notice = 'The next video could not be played.');
      }
    } finally {
      if (incoming != null) {
        if (identical(_incoming, incoming)) _incoming = null;
        unawaited(incoming.dispose().catchError((Object _) {}));
      }
      if (!_disposed && mounted) {
        setState(() {
          _advancing = false;
          if (_notice == _preparingNext) _notice = outcome;
        });
      } else {
        _advancing = false;
      }
    }
  }

  Future<bool> _setRepeat(bool enabled) async {
    final controller = _player;
    if (_preferenceSaving || _touchLocked || controller == null) return false;
    _preferenceSaving = true;
    final previous = _repeat;
    try {
      await controller.setLooping(enabled);
      if (!mounted) return false;
      await _preferences.setRepeat(_item.id, enabled);
      if (!mounted) return false;
      setState(() {
        _repeat = enabled;
        _notice = null;
      });
      return true;
    } catch (_) {
      if (mounted) {
        try {
          await controller.setLooping(previous);
        } catch (_) {
          await _pause();
        }
        if (mounted) {
          setState(
            () => _notice = 'Repeat could not be changed and saved. Try again.',
          );
        }
      }
      return false;
    } finally {
      _preferenceSaving = false;
    }
  }

  Future<bool> _setAutoplay(bool enabled) async {
    if (_preferenceSaving || _touchLocked) return false;
    _preferenceSaving = true;
    try {
      await _preferences.setAutoplayNext(enabled);
      if (!mounted) return false;
      setState(() {
        _autoplay = enabled;
        _notice = null;
      });
      return true;
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice = 'Autoplay could not be changed and saved. Try again.',
        );
      }
      return false;
    } finally {
      _preferenceSaving = false;
    }
  }

  Future<void> _showSettings() async {
    if (_touchLocked ||
        _scrubbing ||
        _seekCommitting ||
        !_prepared ||
        _player == null) {
      return;
    }
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) {
          Future<void> save(
            Future<bool> Function() change,
            String failure,
          ) async {
            updateDialog(() {
              saving = true;
              error = null;
            });
            final saved = await change();
            if (!dialogContext.mounted) return;
            updateDialog(() {
              saving = false;
              error = saved ? null : failure;
            });
          }

          return AlertDialog(
            scrollable: true,
            title: const Text('Playback settings'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Repeat this video'),
                  subtitle: const Text(
                    'Start this video again when it ends. Remembered for this video.',
                  ),
                  value: _repeat,
                  onChanged: saving
                      ? null
                      : (enabled) => save(
                          () => _setRepeat(enabled),
                          'Repeat could not be saved. Try again.',
                        ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Play next video automatically'),
                  subtitle: const Text(
                    'When a video ends, play the next one in Offline. Used for all videos. Repeat this video takes priority.',
                  ),
                  value: _autoplay,
                  onChanged: saving
                      ? null
                      : (enabled) => save(
                          () => _setAutoplay(enabled),
                          'Autoplay could not be saved. Try again.',
                        ),
                ),
                if (saving) const LinearProgressIndicator(),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(error!, semanticsLabel: error),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Tap the lock at the top right to block player controls and volume buttons where supported. Hold it for two seconds to unlock. Power, Home, and other system controls remain available.',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _unlockTarget() => AnimatedBuilder(
    animation: _hold,
    builder: (context, _) => Semantics(
      button: true,
      label: 'Unlock playback',
      value: _unlocking
          ? 'Unlocking'
          : _hold.isAnimating
          ? '${(_hold.value * 100).floor()} percent'
          : 'Locked',
      hint:
          'Press and hold for two seconds. With a screen reader, use the long-press action.',
      onLongPress: _startUnlock,
      child: ExcludeSemantics(
        child: Focus(
          focusNode: _unlockFocus,
          onFocusChange: (focused) {
            if (!focused) _cancelHold();
          },
          onKeyEvent: (_, event) {
            if (event.logicalKey != LogicalKeyboardKey.space &&
                event.logicalKey != LogicalKeyboardKey.enter) {
              return KeyEventResult.ignored;
            }
            if (event is KeyDownEvent) _startUnlock();
            if (event is KeyUpEvent) _cancelHold();
            return KeyEventResult.handled;
          },
          child: Listener(
            key: const ValueKey('playback-unlock'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              _holdPointers.add(event.pointer);
              if (_holdPointers.length != 1) {
                _cancelHold();
                return;
              }
              _holdOrigin = event.position;
              _startUnlock();
            },
            onPointerUp: (event) {
              _holdPointers.remove(event.pointer);
              _cancelHold();
            },
            onPointerCancel: (event) {
              _holdPointers.remove(event.pointer);
              _cancelHold();
            },
            onPointerMove: (event) {
              if ((_holdOrigin != null &&
                      (event.position - _holdOrigin!).distance > 12) ||
                  !(const Rect.fromLTWH(
                    0,
                    0,
                    64,
                    64,
                  )).contains(event.localPosition)) {
                _cancelHold();
              }
            },
            child: Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 64,
                height: 64,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: _unlocking ? 1 : _hold.value,
                            strokeWidth: 3,
                          ),
                          const Icon(Icons.lock, size: 22),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _unlocking ? 'Unlocking…' : 'Hold 2s',
                          textScaler: TextScaler.noScaling,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 12, height: 1.2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _body() => FutureBuilder<void>(
    future: ready,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This video is unavailable or no longer approved. Ask a parent to review the saved library.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }
      if (snapshot.connectionState != ConnectionState.done || _player == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final controller = _player!;
      return ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          if (value.hasError) {
            return const Center(
              child: Text('Playback failed. Please reopen this video.'),
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: value.aspectRatio,
                      child: GestureDetector(
                        key: const ValueKey('playback-video'),
                        onTap: toggle,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            VideoPlayer(controller),
                            if (_advancing)
                              const CircularProgressIndicator()
                            else if (!value.isPlaying)
                              const Icon(Icons.play_circle_fill, size: 72),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * 0.55,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: Column(
                        children: [
                          if (_notice != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                _notice!,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          SeekPreviewTimeline(
                            file: _verifiedFile!,
                            position: value.position,
                            duration: value.duration,
                            enabled:
                                !_touchLocked &&
                                _foreground &&
                                !_seekCommitting,
                            frames: widget.seekPreviewFrames,
                            onChangeStart: _startScrub,
                            onChangeEnd: (position) =>
                                unawaited(_finishScrub(position)),
                            onChangeCancel: () => _cancelScrub(resume: true),
                          ),
                          Row(
                            children: [
                              IconButton(
                                tooltip: value.isPlaying ? 'Pause' : 'Play',
                                onPressed: _scrubbing || _seekCommitting
                                    ? null
                                    : toggle,
                                icon: Icon(
                                  value.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Restart',
                                onPressed: _scrubbing || _seekCommitting
                                    ? null
                                    : _restart,
                                icon: const Icon(Icons.replay),
                              ),
                              Expanded(
                                child: Text(
                                  '${time(value.position)} / ${time(value.duration)}',
                                ),
                              ),
                              if (_repeat)
                                const Tooltip(
                                  message: 'Repeat is on',
                                  child: Icon(
                                    Icons.repeat_one,
                                    semanticLabel: 'Repeat is on',
                                  ),
                                )
                              else if (_autoplay)
                                const Tooltip(
                                  message: 'Next video plays automatically',
                                  child: Icon(
                                    Icons.playlist_play,
                                    semanticLabel:
                                        'Next video plays automatically',
                                  ),
                                ),
                              const SizedBox(width: 8),
                              const Tooltip(
                                message: 'On this tablet',
                                child: Icon(
                                  Icons.offline_pin_outlined,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_touchLocked,
    child: Stack(
      children: [
        ExcludeFocus(
          excluding: _touchLocked,
          child: ExcludeSemantics(
            excluding: _touchLocked,
            child: IgnorePointer(
              ignoring: _touchLocked,
              child: Scaffold(
                appBar: AppBar(
                  toolbarHeight: 72,
                  title: Text(
                    _item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    IconButton(
                      tooltip: 'Playback settings',
                      onPressed: _prepared ? _showSettings : null,
                      icon: const Icon(Icons.settings),
                    ),
                    const SizedBox(width: 76),
                  ],
                ),
                body: SafeArea(top: false, child: _body()),
              ),
            ),
          ),
        ),
        if (_touchLocked)
          Positioned.fill(
            child: Listener(
              onPointerDown: (_) => _cancelHold(),
              onPointerMove: (_) => _cancelHold(),
              child: RawGestureDetector(
                key: const ValueKey('playback-drag-shield'),
                behavior: HitTestBehavior.opaque,
                gestures: {
                  // Claim delivered pointers immediately. Waiting for pan slop
                  // lets an ancestor's vertical-dismiss recognizer win first.
                  EagerGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        EagerGestureRecognizer
                      >(EagerGestureRecognizer.new, (_) {}),
                },
                child: const ModalBarrier(
                  dismissible: false,
                  color: Colors.transparent,
                  barrierSemanticsDismissible: false,
                ),
              ),
            ),
          ),
        if (_touchLocked && (_volumeUnavailable || _unlockError != null))
          Positioned(
            top: MediaQuery.paddingOf(context).top + 76,
            left: 12,
            right: 12,
            child: IgnorePointer(
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _unlockError ??
                          'Touch controls are locked. Volume buttons are not locked right now. Unlock and lock again to retry.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 4,
          right: MediaQuery.paddingOf(context).right + 8,
          child: _touchLocked
              ? _unlockTarget()
              : SizedBox(
                  width: 64,
                  height: 64,
                  child: Material(
                    color: Colors.transparent,
                    child: IconButton(
                      tooltip: 'Lock playback controls',
                      onPressed: _lock,
                      icon: const Icon(Icons.lock_open),
                    ),
                  ),
                ),
        ),
      ],
    ),
  );
}

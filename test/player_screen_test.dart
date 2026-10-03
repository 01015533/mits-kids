import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/screens/player_screen.dart';
import 'package:mits_kids_youtube/src/services/android_playback_controls.dart';
import 'package:mits_kids_youtube/src/services/android_screen_off_recovery.dart';
import 'package:mits_kids_youtube/src/services/screen_off_recovery_preferences.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/playback_preferences.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';
import 'package:mits_kids_youtube/src/services/seek_preview_frames.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final looping = <int, bool>{};
  final positions = <int, Duration>{};
  final calls = <String>[];
  final disposed = <int>[];
  bool initializeImmediately = true;
  Completer<void>? pendingPlay;
  Completer<void>? pendingPause;
  Completer<void>? pendingSeek;
  int nextId = 0;

  @override
  Future<void> init() async {}
  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    final id = ++nextId;
    events[id] = StreamController<VideoEvent>();
    if (initializeImmediately) initialize(id);
    return id;
  }

  void initialize(int id) => events[id]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 2),
      size: const Size(1280, 720),
    ),
  );

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool enabled) async {
    looping[playerId] = enabled;
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play:$playerId');
    await pendingPlay?.future;
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause:$playerId');
    await pendingPause?.future;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seek:$playerId');
    await pendingSeek?.future;
    positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Color(0xFF204050));

  Future<void> close() async {
    for (final stream in events.values) {
      await stream.close();
    }
  }
}

class _Controls implements PlaybackControls {
  final calls = <bool>[];
  final presentationCalls = <bool>[];
  bool supported = true;
  Completer<bool>? pendingLock;
  @override
  Future<bool> setTouchLocked(bool locked) {
    calls.add(locked);
    return locked && pendingLock != null
        ? pendingLock!.future
        : Future.value(supported);
  }

  @override
  Future<bool> setLockedPresentation(bool locked) async {
    presentationCalls.add(locked);
    return supported;
  }
}

class _Library extends OfflineRepository {
  _Library(this.item);
  final OfflineItem item;
  // Saved earlier than [item], so Offline lists them after it.
  final following = <OfflineItem>[];
  final damaged = <String>{};
  Completer<void>? pendingVerification;
  int verifications = 0;
  bool available = true;
  bool corrupt = false;
  @override
  Future<List<OfflineItem>> all() async =>
      available ? [item, ...following] : [];
  @override
  Future<File> verifyFile(OfflineItem item) async {
    verifications++;
    if (corrupt) throw StateError('Integrity failed');
    if (identical(item, this.item)) return File('/private/verified.mp4');
    await pendingVerification?.future;
    if (damaged.contains(item.id)) throw StateError('Integrity failed');
    return File('/private/${item.id}.mp4');
  }
}

class _Frames implements SeekPreviewFrames {
  final files = <String>[];
  final positions = <Duration>[];
  int cancellations = 0;
  @override
  Future<SeekPreviewFrame?> frame(
    File file, {
    required Duration position,
  }) async {
    files.add(file.path);
    positions.add(position);
    return null;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
  }

  @override
  Future<void> dispose() async {}
}

class _Recovery implements ScreenOffRecovery {
  final notifications = StreamController<ScreenOffRecoveryEvent>.broadcast();
  final calls = <bool>[];
  final cycles = <int?>[];
  bool supported = true;
  bool failDisable = false;
  Completer<bool>? pendingDisable;
  @override
  Stream<ScreenOffRecoveryEvent> get events => notifications.stream;
  @override
  Future<bool> setEligible(bool eligible, {int? cycle}) async {
    calls.add(eligible);
    cycles.add(cycle);
    if (!eligible && pendingDisable != null) return pendingDisable!.future;
    if (!eligible && failDisable) return false;
    return supported;
  }

  @override
  Future<void> dispose() async {
    calls.add(false);
  }
}

class _RecoveryPreferences extends ScreenOffRecoveryPreferences {
  bool enabled = false;
  bool failRead = false;
  @override
  Future<bool> isEnabled() async {
    if (failRead) throw StateError('Storage unavailable');
    return enabled;
  }
}

class _Preferences extends PlaybackPreferences {
  bool failRead = false;
  bool failWrite = false;
  bool failAutoplayWrite = false;
  Completer<void>? pendingWrite;
  Completer<bool>? pendingRead;
  @override
  Future<bool> repeatFor(String videoId) async {
    if (failRead) throw StateError('Storage unavailable');
    if (pendingRead != null) return pendingRead!.future;
    return super.repeatFor(videoId);
  }

  @override
  Future<void> setRepeat(String videoId, bool enabled) async {
    if (pendingWrite != null) await pendingWrite!.future;
    if (failWrite) throw StateError('Storage full');
    await super.setRepeat(videoId, enabled);
  }

  @override
  Future<void> setAutoplayNext(bool enabled) async {
    if (failAutoplayWrite) throw StateError('Storage full');
    await super.setAutoplayNext(enabled);
  }
}

OfflineItem _item(String id, {String title = 'A reviewed offline video'}) =>
    OfflineItem(
      id: id,
      title: title,
      sourceUrl: 'https://www.youtube.com/watch?v=$id',
      filePath: '/private/verified.mp4',
      bytes: 100,
      createdAt: DateTime.utc(2026),
      approvedAt: DateTime.utc(2026),
      contentHash: 'a' * 64,
      channelId: 'UC${'a' * 22}',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform original;
  late _VideoPlatform video;
  late _Controls controls;
  late _Preferences preferences;
  late _Library library;
  late _Recovery recovery;
  late _RecoveryPreferences recoveryPreferences;
  late _Frames frames;
  var routeDrags = 0;

  setUp(() {
    original = VideoPlayerPlatform.instance;
    video = _VideoPlatform();
    VideoPlayerPlatform.instance = video;
    controls = _Controls();
    preferences = _Preferences();
    library = _Library(_item('abcdefghijk'));
    recovery = _Recovery();
    recoveryPreferences = _RecoveryPreferences();
    frames = _Frames();
    routeDrags = 0;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    VideoPlayerPlatform.instance = original;
    await video.close();
    await recovery.notifications.close();
    library.dispose();
  });

  Widget app({double textScale = 1}) => MaterialApp(
    builder: (context, child) => GestureDetector(
      onVerticalDragUpdate: (_) => routeDrags++,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen(
                  item: library.item,
                  repository: library,
                  settings: SettingsRepository(),
                  playbackControls: controls,
                  playbackPreferences: preferences,
                  screenOffRecovery: recovery,
                  screenOffRecoveryPreferences: recoveryPreferences,
                  seekPreviewFrames: frames,
                ),
              ),
            ),
            child: const Text('Open saved video'),
          ),
        ),
      ),
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    double textScale = 1,
    bool settle = true,
  }) async {
    await tester.pumpWidget(app(textScale: textScale));
    await tester.tap(find.text('Open saved video'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> lock(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Lock playback controls'));
    await tester.pumpAndSettle();
  }

  Future<void> holdUnlock(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('playback-unlock'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2100));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  Future<void> startAndLock(WidgetTester tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await lock(tester);
  }

  void background(WidgetTester tester) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }

  testWidgets(
    'hold unlock waits for native concealment before exposing controls',
    (tester) async {
      final semantics = tester.ensureSemantics();
      recoveryPreferences.enabled = true;
      await startAndLock(tester);
      recovery.pendingDisable = Completer<bool>();
      await holdUnlock(tester);
      expect(find.text('Unlocking…'), findsOneWidget);
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      expect(find.bySemanticsLabel('Playback settings'), findsNothing);
      final beforeVideo = List<String>.of(video.calls);
      final beforeRecovery = List<bool>.of(recovery.calls);
      await tester.tap(find.byTooltip('Pause'), warnIfMissed: false);
      await tester.tap(
        find.byTooltip('Playback settings'),
        warnIfMissed: false,
      );
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(seconds: 1));
      expect(video.calls, beforeVideo);
      expect(recovery.calls, beforeRecovery);
      expect(find.byType(PlayerScreen), findsOneWidget);
      recovery.pendingDisable!.complete(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('playback-unlock')), findsNothing);
      await tester.tap(find.byTooltip('Playback settings'));
      await tester.pumpAndSettle();
      expect(find.text('Repeat this video'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsNothing);
      await clean(tester);
      semantics.dispose();
    },
  );

  testWidgets(
    'an unconfirmed arm still requires concealment before unlocking',
    (tester) async {
      recoveryPreferences.enabled = true;
      recovery.supported = false;
      await startAndLock(tester);
      expect(recovery.calls, contains(true));
      recovery.pendingDisable = Completer<bool>();
      await holdUnlock(tester);
      expect(find.text('Unlocking…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(PlayerScreen), findsOneWidget);
      recovery.pendingDisable!.complete(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('playback-unlock')), findsNothing);
      await clean(tester);
    },
  );

  testWidgets(
    'failed concealment keeps controls locked and a retry can unlock',
    (tester) async {
      recoveryPreferences.enabled = true;
      await startAndLock(tester);
      recovery.failDisable = true;
      await holdUnlock(tester);
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      expect(
        find.text('Unlock could not finish. Hold the lock again to retry.'),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      final requestCount = recovery.calls.length;
      await tester.pump(const Duration(seconds: 1));
      expect(recovery.calls.length, requestCount);
      recovery.failDisable = false;
      await holdUnlock(tester);
      expect(find.byTooltip('Lock playback controls'), findsOneWidget);
      expect(controls.calls.last, isFalse);
      await clean(tester);
    },
  );

  testWidgets('keyguard lifecycle during concealment never resumes the video', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    recovery.pendingDisable = Completer<bool>();
    await holdUnlock(tester);
    background(tester);
    await tester.pump();
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    recovery.pendingDisable!.complete(true);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Lock playback controls'), findsOneWidget);
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(recovery.calls.last, isFalse);
    await clean(tester);
  });

  testWidgets('pending concealment acknowledgement after disposal is ignored', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    recovery.pendingDisable = Completer<bool>();
    await holdUnlock(tester);
    await clean(tester);
    recovery.pendingDisable!.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
    expect(recovery.calls.last, isFalse);
  });

  testWidgets(
    'feature off unlocks normally without waiting on recovery platform',
    (tester) async {
      await startAndLock(tester);
      recovery.pendingDisable = Completer<bool>();
      await holdUnlock(tester);
      expect(find.byTooltip('Lock playback controls'), findsOneWidget);
      recovery.pendingDisable!.complete(false);
      await clean(tester);
    },
  );

  testWidgets('recovery arms only for enabled, playing, locked video', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await open(tester);
    await lock(tester);
    expect(recovery.calls, [false]);
    await holdUnlock(tester);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(recovery.calls.contains(true), isFalse);
    await lock(tester);
    expect(recovery.calls.last, isTrue);
    await holdUnlock(tester);
    expect(recovery.calls.last, isFalse);
    await clean(tester);
  });

  testWidgets('recovery off never arms even during locked playback', (
    tester,
  ) async {
    await startAndLock(tester);
    expect(recovery.calls.contains(true), isFalse);
    background(tester);
    await tester.pump();
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    await clean(tester);
  });

  testWidgets('only confirmed screen recovery resumes once and retains lock', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    await tester.pump(const Duration(milliseconds: 150));
    expect(video.calls.last, 'pause:1');
    expect(recovery.calls.last, isTrue);
    // A native result can precede Flutter's resumed callback.
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
    expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
    await clean(tester);
  });

  testWidgets('Home without confirmed recovery returns paused and expires', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    await tester.pump(const Duration(milliseconds: 300));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    await tester.pump(const Duration(seconds: 5));
    expect(recovery.calls.last, isFalse);
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    await clean(tester);
  });

  testWidgets('five quick recovery cycles rearm without extra play commands', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    for (var cycle = 1; cycle <= 5; cycle++) {
      recovery.notifications.add(
        ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: cycle,
        ),
      );
      recovery.notifications.add(
        ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: cycle),
      );
      await tester.pump();
      expect(recovery.calls.last, isTrue);
      expect(recovery.cycles.last, cycle);
      expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
      expect(video.calls.where((c) => c.startsWith('pause:')), hasLength(1));
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
    }
    await clean(tester);
  });

  for (final recoveryEnabled in [false, true]) {
    testWidgets(
      'locked playing video survives a long inactive shade with recovery $recoveryEnabled',
      (tester) async {
        recoveryPreferences.enabled = recoveryEnabled;
        await startAndLock(tester);
        final beforePlayback = List<String>.of(video.calls);
        final beforeRecovery = List<bool>.of(recovery.calls);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(seconds: 8));
        expect(video.calls, beforePlayback);
        expect(recovery.calls, beforeRecovery);
        expect(controls.calls.last, isFalse);
        expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
        expect(
          tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller
              .value
              .isPlaying,
          isTrue,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(video.calls, beforePlayback);
        expect(controls.calls.last, isTrue);
        expect(recovery.calls, beforeRecovery);
        await clean(tester);
      },
    );

    testWidgets(
      'inactive then hidden and paused never auto resumes with recovery $recoveryEnabled',
      (tester) async {
        recoveryPreferences.enabled = recoveryEnabled;
        await startAndLock(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(
          tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller
              .value
              .isPlaying,
          isFalse,
        );
        // Exercise the package's own paused/resumed observer too. It must see
        // the explicit pause, never remember true and automatically restart.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
        expect(
          tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller
              .value
              .isPlaying,
          isFalse,
        );
        await clean(tester);
      },
    );
  }

  testWidgets(
    'shade after successful screen-off recovery keeps its live player',
    (tester) async {
      recoveryPreferences.enabled = true;
      await startAndLock(tester);
      background(tester);
      recovery.notifications.add(
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: 1,
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      recovery.notifications.add(
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovered,
          cycle: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
      final beforePlayback = List<String>.of(video.calls);
      final beforeRecovery = List<bool>.of(recovery.calls);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 12));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(video.calls, beforePlayback);
      expect(recovery.calls, beforeRecovery);
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      await clean(tester);
    },
  );

  testWidgets(
    'paused locked and playing unlocked media never start on shade return',
    (tester) async {
      await open(tester);
      await lock(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(video.calls.where((c) => c.startsWith('play:')), isEmpty);
      await holdUnlock(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 6));
      expect(
        tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller
            .value
            .isPlaying,
        isFalse,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
      await clean(tester);
    },
  );

  testWidgets(
    'real recovery announced during inactive survives hidden and paused',
    (tester) async {
      recoveryPreferences.enabled = true;
      await startAndLock(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 2));
      recovery.notifications.add(
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: 1,
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      recovery.notifications.add(
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovered,
          cycle: 1,
        ),
      );
      await tester.pump();
      expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
      expect(recovery.cycles.last, 1);
      recovery.notifications.add(
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovered,
          cycle: 1,
        ),
      );
      await tester.pump();
      expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
      await clean(tester);
    },
  );

  testWidgets(
    'inactive cancels an unlock hold while locked video keeps playing',
    (tester) async {
      await startAndLock(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('playback-unlock'))),
      );
      await tester.pump(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      expect(
        tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller
            .value
            .isPlaying,
        isTrue,
      );
      await clean(tester);
    },
  );

  testWidgets('pending recovery play is not paused by an inactive-only shade', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
    );
    await tester.pump();
    video.pendingPlay = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 1),
    );
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
    final beforePlayback = List<String>.of(video.calls);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final beforeAcknowledgement = recovery.calls.length;
    video.pendingPlay!.complete();
    video.pendingPlay = null;
    await tester.pump();
    expect(recovery.calls.length, greaterThan(beforeAcknowledgement));
    expect(recovery.calls.last, isTrue);
    expect(recovery.cycles.last, 1);
    final afterAcknowledgement = List<bool>.of(recovery.calls);
    await tester.pump(const Duration(seconds: 6));
    expect(video.calls, beforePlayback);
    expect(recovery.calls, afterAcknowledgement);
    expect(
      tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller
          .value
          .isPlaying,
      isTrue,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls, beforePlayback);
    await clean(tester);
  });

  testWidgets('genuine background invalidates a confirmation waiting on pause', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    final pause = Completer<void>();
    video.pendingPause = pause;
    background(tester);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 1),
    );
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    // The confirmation is now waiting for pause. Leaving again must invalidate
    // it even though _recoveryCandidate is already true.
    background(tester);
    pause.complete();
    video.pendingPause = null;
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(
      tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller
          .value
          .isPlaying,
      isFalse,
    );
    await clean(tester);
  });

  testWidgets('EOF while inactive does not replay when the shade closes', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final controller = tester
        .widget<VideoPlayer>(find.byType(VideoPlayer))
        .controller;
    controller.value = controller.value.copyWith(
      isPlaying: false,
      position: controller.value.duration,
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(video.calls.where((c) => c.startsWith('seek:')), isEmpty);
    expect(controller.value.isPlaying, isFalse);
    expect(recovery.calls.last, isFalse);
    await clean(tester);
  });

  testWidgets('five paused recovery cycles each resume exactly once', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    for (var cycle = 1; cycle <= 5; cycle++) {
      background(tester);
      recovery.notifications.add(
        ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: cycle,
        ),
      );
      await tester.pump();
      recovery.notifications.add(
        ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: cycle),
      );
      await tester.pump();
      expect(video.calls.where((c) => c.startsWith('play:')), hasLength(cycle));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        video.calls.where((c) => c.startsWith('play:')),
        hasLength(cycle + 1),
      );
      expect(recovery.calls.last, isTrue);
      expect(recovery.cycles.last, cycle);
      recovery.notifications.add(
        ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: cycle),
      );
      await tester.pump();
      expect(
        video.calls.where((c) => c.startsWith('play:')),
        hasLength(cycle + 1),
      );
    }
    await clean(tester);
  });

  testWidgets('latest confirmed cycle survives an older pending play', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
    );
    await tester.pump();
    video.pendingPlay = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 1),
    );
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));

    // The second attempt can arrive while the previous platform play Future
    // is pending, without another Flutter lifecycle callback.
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 2,
      ),
    );
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 2),
    );
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
    video.pendingPlay!.complete();
    video.pendingPlay = null;
    await tester.pumpAndSettle();
    expect(video.calls.sublist(video.calls.length - 2), ['pause:1', 'play:1']);
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(3));
    expect(recovery.calls.last, isTrue);
    expect(recovery.cycles.last, 2);
    expect(
      tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller
          .value
          .isPlaying,
      isTrue,
    );
    await clean(tester);
  });

  testWidgets('stale cycles cannot cancel or complete a newer recovery', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
    );
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 1),
    );
    await tester.pump();
    background(tester);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 2,
      ),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final requestCount = recovery.calls.length;
    for (final status in ScreenOffRecoveryStatus.values) {
      recovery.notifications.add(ScreenOffRecoveryEvent(status, cycle: 1));
    }
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pump();
    expect(recovery.calls, hasLength(requestCount));
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 2),
    );
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
    expect(recovery.cycles.last, 2);
    await clean(tester);
  });

  testWidgets('unlock rejects a late newer cycle without playback or rearm', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
    );
    await tester.pump();
    await holdUnlock(tester);
    final playCount = video.calls.where((c) => c.startsWith('play:')).length;
    for (var cycle = 1; cycle <= 2; cycle++) {
      recovery.notifications.add(
        ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: cycle,
        ),
      );
      recovery.notifications.add(
        ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: cycle),
      );
    }
    await tester.pump();
    expect(
      video.calls.where((c) => c.startsWith('play:')),
      hasLength(playCount),
    );
    expect(recovery.calls.last, isFalse);
    expect(find.byKey(const ValueKey('playback-unlock')), findsNothing);
    await clean(tester);
  });

  testWidgets('relock uses the bridge cycle after confirmed native revocation', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
    );
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 1),
    );
    await tester.pump();
    expect(recovery.cycles.last, 1);

    // Native's revoke ACK can reveal a later cycle whose recovering callback
    // had not arrived. Only the bridge knows it; null selects its fresh value.
    recovery.pendingDisable = Completer<bool>();
    await holdUnlock(tester);
    expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
    recovery.pendingDisable!.complete(true);
    recovery.pendingDisable = null;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playback-unlock')), findsNothing);
    await lock(tester);
    expect(recovery.calls.last, isTrue);
    expect(recovery.cycles.last, isNull);
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));

    recovery.notifications.add(
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 3,
      ),
    );
    recovery.notifications.add(
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 3),
    );
    await tester.pump();
    expect(recovery.cycles.last, 3);
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    await clean(tester);
  });

  testWidgets('unlocking cancels pending recovery before late native event', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await holdUnlock(tester);
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(recovery.calls.last, isFalse);
    await clean(tester);
  });

  testWidgets('failed wake remains paused and explains manual continuation', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recovery.notifications.add(ScreenOffRecoveryEvent.unavailable);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Screen-off recovery did not complete'),
      findsOneWidget,
    );
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(recovery.calls.last, isFalse);
    await clean(tester);
  });

  testWidgets('recovery preference read failure stays off for this video', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    recoveryPreferences.failRead = true;
    await startAndLock(tester);
    expect(recovery.calls.contains(true), isFalse);
    expect(
      find.textContaining('Screen-off recovery could not be read'),
      findsOneWidget,
    );
    await clean(tester);
  });

  testWidgets('disposing a pending recovery prevents late resume', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    await tester.pump();
    // Paused Flutter does not render frames; return without a recovery event
    // before unmounting, then prove that a later event cannot resurrect it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await clean(tester);
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.runAsync(() async {});
    await tester.pump();
    expect(video.disposed, [1]);
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(recovery.calls.last, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery does not replay a video that reached its end', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    final controller = tester
        .widget<VideoPlayer>(find.byType(VideoPlayer))
        .controller;
    background(tester);
    await tester.pump();
    controller.value = controller.value.copyWith(
      position: controller.value.duration,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(video.calls.where((c) => c.startsWith('seek:')), isEmpty);
    expect(recovery.calls.last, isFalse);
    await clean(tester);
  });

  testWidgets('backgrounding during delayed recovery play ends paused', (
    tester,
  ) async {
    recoveryPreferences.enabled = true;
    await startAndLock(tester);
    background(tester);
    await tester.pump();
    video.pendingPlay = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recovery.notifications.add(ScreenOffRecoveryEvent.recovered);
    await tester.pump();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
    background(tester);
    await tester.pump();
    video.pendingPlay!.complete();
    await tester.pump();
    expect(video.calls.last, 'pause:1');
    await tester.pump(const Duration(seconds: 5));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(2));
    await clean(tester);
  });

  testWidgets(
    'lock blocks player, settings, scrubbing and Back; tap cannot unlock',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);
      expect(library.verifications, 1);
      await lock(tester);
      final before = List<String>.of(video.calls);
      await tester.tap(
        find.byKey(const ValueKey('playback-video')),
        warnIfMissed: false,
      );
      await tester.tap(find.byTooltip('Play'), warnIfMissed: false);
      await tester.tap(find.byTooltip('Restart'), warnIfMissed: false);
      await tester.tap(
        find.byTooltip('Playback settings'),
        warnIfMissed: false,
      );
      await tester.drag(
        find.byKey(const ValueKey('playback-seek-track')),
        const Offset(100, 0),
        warnIfMissed: false,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(video.calls, before);
      expect(find.text('Repeat this video'), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.bySemanticsLabel('Unlock playback'), findsOneWidget);
      expect(find.bySemanticsLabel('Playback settings'), findsNothing);
      expect(find.bySemanticsLabel('Restart'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('playback-unlock')));
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      await holdUnlock(tester);
      expect(find.byTooltip('Lock playback controls'), findsOneWidget);
      expect(controls.calls, [true, false]);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsNothing);
      await clean(tester);
      semantics.dispose();
    },
  );

  testWidgets('locked player consumes drags before route gestures', (
    tester,
  ) async {
    await startAndLock(tester);
    final before = List<String>.of(video.calls);
    final shield = find.byKey(const ValueKey('playback-drag-shield'));
    for (final drag in [
      const Offset(0, 220),
      const Offset(0, -220),
      const Offset(220, 0),
      const Offset(-220, 0),
    ]) {
      await tester.drag(shield, drag);
    }
    await tester.pumpAndSettle();
    expect(routeDrags, 0);
    expect(video.calls, before);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
    await clean(tester);
  });

  testWidgets('a drag inside the lock button cannot complete the hold', (
    tester,
  ) async {
    await open(tester);
    await lock(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('playback-unlock'))),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump(const Duration(seconds: 3));
    await gesture.up();
    expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
    await holdUnlock(tester);
    expect(find.byTooltip('Lock playback controls'), findsOneWidget);
    await clean(tester);
  });

  testWidgets('another touch on the drag shield cancels an unlock hold', (
    tester,
  ) async {
    await open(tester);
    await lock(tester);
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('playback-unlock'))),
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 700));
    final drag = await tester.startGesture(const Offset(150, 250), pointer: 2);
    await drag.moveBy(const Offset(0, 80));
    await tester.pump(const Duration(seconds: 3));
    await drag.up();
    await hold.up();
    expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
    await clean(tester);
  });

  testWidgets(
    'locked presentation survives focus loss and restores on unlock',
    (tester) async {
      await startAndLock(tester);
      expect(controls.presentationCalls, [true]);
      background(tester);
      await tester.pump();
      expect(controls.presentationCalls, [true]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(controls.presentationCalls, [true, true]);
      await holdUnlock(tester);
      expect(controls.presentationCalls.last, isFalse);
      await clean(tester);
    },
  );

  testWidgets(
    'scrubbing previews the verified file and commits once on release',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('playback-seek-track'))),
      );
      await gesture.moveBy(const Offset(90, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.byKey(const ValueKey('seek-scene-preview')), findsOneWidget);
      expect(frames.files, ['/private/verified.mp4']);
      expect(video.calls.last, 'pause:1');
      expect(video.calls.where((c) => c.startsWith('seek:')), isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(video.calls.where((c) => c.startsWith('seek:')), hasLength(1));
      expect(video.calls.last, 'play:1');
      expect(find.byKey(const ValueKey('seek-scene-preview')), findsNothing);
      await clean(tester);
    },
  );

  testWidgets('seeking a paused video never starts playback', (tester) async {
    await open(tester);
    await tester.drag(
      find.byKey(const ValueKey('playback-seek-track')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('seek:')), hasLength(1));
    expect(video.calls.where((c) => c.startsWith('play:')), isEmpty);
    await clean(tester);
  });

  testWidgets('opening system UI cancels a scrub without seeking or resuming', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('playback-seek-track'))),
    );
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 150));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await gesture.up();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('seek:')), isEmpty);
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(find.byKey(const ValueKey('seek-scene-preview')), findsNothing);
    await clean(tester);
  });

  testWidgets('a pending seek cannot resume playback after locking', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    video.pendingSeek = Completer<void>();
    await tester.drag(
      find.byKey(const ValueKey('playback-seek-track')),
      const Offset(80, 0),
    );
    await tester.pump();
    await lock(tester);
    video.pendingSeek!.complete();
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('play:')), hasLength(1));
    expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
    await clean(tester);
  });

  testWidgets(
    'hold progress cancels on early release, movement and multitouch',
    (tester) async {
      await open(tester);
      await lock(tester);
      final target = tester.getCenter(
        find.byKey(const ValueKey('playback-unlock')),
      );
      var gesture = await tester.startGesture(target);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        closeTo(0.5, 0.05),
      );
      await gesture.up();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      gesture = await tester.startGesture(target);
      await tester.pump();
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump(const Duration(seconds: 3));
      await gesture.up();
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      gesture = await tester.startGesture(target, pointer: 1);
      await tester.pump();
      final second = await tester.startGesture(target, pointer: 2);
      await tester.pump(const Duration(seconds: 3));
      await second.up();
      await gesture.up();
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      await holdUnlock(tester);
      await lock(tester);
      final interrupted = await tester.startGesture(target);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await clean(tester);
      await tester.pump(const Duration(seconds: 3));
      await interrupted.up();
      expect(controls.calls.last, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a scrub already in progress cannot seek or resume after locking',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      final scrub = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('playback-seek-track'))),
        pointer: 1,
      );
      await scrub.moveBy(const Offset(60, 0));
      await tester.pump();
      await tester.tap(find.byTooltip('Lock playback controls'), pointer: 2);
      await tester.pumpAndSettle();
      final before = List<String>.of(video.calls);
      await scrub.moveBy(const Offset(100, 0));
      await scrub.up();
      await tester.pumpAndSettle();
      expect(video.calls, before);
      await clean(tester);
    },
  );

  testWidgets(
    'repeat uses platform looping and persists only for the selected video',
    (tester) async {
      await open(tester);
      expect(video.looping[1], isFalse);
      await tester.tap(find.byTooltip('Playback settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repeat this video'));
      await tester.pumpAndSettle();
      expect(video.looping[1], isTrue);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Repeat is on'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open saved video'));
      await tester.pumpAndSettle();
      expect(video.looping[2], isTrue);
      expect(await PlaybackPreferences().repeatFor('other-video'), isFalse);
      expect(await PlaybackPreferences().repeatFor(library.item.id), isTrue);
      await clean(tester);
    },
  );

  testWidgets(
    'read failure defaults repeat off and write failure restores current playback',
    (tester) async {
      preferences.failRead = true;
      preferences.failWrite = true;
      await open(tester);
      expect(
        find.textContaining('repeat preference could not be read'),
        findsOneWidget,
      );
      expect(video.looping[1], isFalse);
      await tester.tap(find.byTooltip('Playback settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repeat this video'));
      await tester.pumpAndSettle();
      expect(video.looping[1], isFalse);
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Repeat this video'),
            )
            .value,
        isFalse,
      );
      expect(
        find.text('Repeat could not be saved. Try again.'),
        findsOneWidget,
      );
      await clean(tester);
    },
  );

  testWidgets(
    'settings wait for initialization and pending repeat saves are dispose safe',
    (tester) async {
      preferences.pendingRead = Completer<bool>();
      await open(tester, settle: false);
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.settings))
            .onPressed,
        isNull,
      );
      preferences.pendingRead!.complete(false);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Playback settings'));
      await tester.pumpAndSettle();
      preferences.pendingWrite = Completer<void>();
      await tester.tap(find.text('Repeat this video'));
      await tester.pump();
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Repeat this video'),
            )
            .onChanged,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      preferences.pendingWrite!.complete();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {});
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(video.disposed, [1]);
    },
  );

  testWidgets(
    'background cancels hold, releases keys, pauses playback and resumes still paused',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await lock(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('playback-unlock'))),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await gesture.up();
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      expect(controls.calls, [true, false, false, true]);
      expect(video.calls.where((call) => call.startsWith('play:')).length, 1);
      await holdUnlock(tester);
      expect(find.byTooltip('Play'), findsOneWidget);
      await clean(tester);
      expect(controls.calls.last, isFalse);
    },
  );

  testWidgets(
    'late native lock acknowledgement cannot delay release after disposal',
    (tester) async {
      controls.pendingLock = Completer<bool>();
      await open(tester);
      await lock(tester);
      expect(controls.calls, [true]);
      await clean(tester);
      expect(controls.calls, [true, false]);
      controls.pendingLock!.complete(true);
      await tester.pumpAndSettle();
      expect(controls.calls, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsupported volume lock and decoder errors leave hold-to-unlock available',
    (tester) async {
      controls.supported = false;
      await open(tester);
      await lock(tester);
      expect(
        find.textContaining('Volume buttons are not locked right now'),
        findsOneWidget,
      );
      video.events[1]!.addError(
        PlatformException(code: 'decoder', message: 'Decoder failed'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Playback failed. Please reopen this video.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      await holdUnlock(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsNothing);
      await clean(tester);
    },
  );

  testWidgets('approval and integrity checks still reject unavailable files', (
    tester,
  ) async {
    library.corrupt = true;
    await open(tester);
    expect(
      find.textContaining('unavailable or no longer approved'),
      findsOneWidget,
    );
    expect(video.nextId, 0);
    await clean(tester);
  });

  testWidgets(
    'lock and settings fit narrow portrait and landscape with enlarged text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await open(tester, textScale: 2);
      await lock(tester);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(const Size(640, 360));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await holdUnlock(tester);
      await tester.tap(find.byTooltip('Playback settings'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await clean(tester);
    },
  );

  void finish(int player) => video.events[player]!.add(
    VideoEvent(eventType: VideoEventType.completed),
  );

  Future<void> turnOnAutoplay(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next video automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  }

  testWidgets('without autoplay an ended video stays on its last frame', (
    tester,
  ) async {
    library.following.add(_item('lmnopqrstuv'));
    await open(tester);
    expect(find.byTooltip('Next video plays automatically'), findsNothing);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    finish(1);
    await tester.pumpAndSettle();
    expect(video.nextId, 1);
    expect(library.verifications, 1);
    expect(find.text('Getting the next video ready…'), findsNothing);
    await clean(tester);
  });

  testWidgets(
    'autoplay continues into the next approved video without unlocking',
    (tester) async {
      recoveryPreferences.enabled = true;
      library.following.add(
        _item('lmnopqrstuv', title: 'The next saved video'),
      );
      await open(tester);
      await turnOnAutoplay(tester);
      expect(find.byTooltip('Next video plays automatically'), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await lock(tester);
      final keys = List<bool>.of(controls.calls);
      final presentation = List<bool>.of(controls.presentationCalls);
      finish(1);
      await tester.pumpAndSettle();
      // Controller disposal awaits a root-zone future; let it finish.
      await tester.runAsync(() async {});
      await tester.pump();
      expect(video.calls, contains('play:2'));
      expect(video.disposed, [1]);
      expect(video.looping[2], isFalse);
      expect(library.verifications, 2);
      expect(find.text('The next saved video'), findsOneWidget);
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      // The same lock continues: no key or system-bar release in between.
      expect(controls.calls, keys);
      expect(controls.presentationCalls, presentation);
      // Recovery follows the new video's playback through the moved listener.
      expect(recovery.calls.last, isTrue);
      await clean(tester);
      await tester.runAsync(() async {});
      expect(video.disposed, [1, 2]);
    },
  );

  testWidgets('repeat on the current video takes priority over autoplay', (
    tester,
  ) async {
    library.following.add(_item('lmnopqrstuv'));
    await preferences.setAutoplayNext(true);
    await preferences.setRepeat(library.item.id, true);
    await open(tester);
    expect(video.looping[1], isTrue);
    expect(find.byTooltip('Repeat is on'), findsOneWidget);
    expect(find.byTooltip('Next video plays automatically'), findsNothing);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    finish(1);
    await tester.pumpAndSettle();
    expect(video.nextId, 1);
    expect(library.verifications, 1);
    await clean(tester);
  });

  testWidgets(
    'autoplay skips damaged or blocked videos and stops after the last one',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'filter_config_v1': '{"blockedKeywords":["Bedtime"]}',
      });
      library.following.addAll([
        _item('damaged0001'),
        _item('bedtime0001', title: 'Bedtime story'),
        _item('lastvideo01', title: 'Last saved video'),
      ]);
      library.damaged.add('damaged0001');
      await preferences.setAutoplayNext(true);
      await preferences.setRepeat('lastvideo01', true);
      await preferences.setRepeat('lastvideo01', false);
      await open(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      finish(1);
      await tester.pumpAndSettle();
      expect(find.text('Last saved video'), findsOneWidget);
      expect(video.calls, contains('play:2'));
      // Blocked videos are never opened; the damaged one fails verification.
      expect(library.verifications, 3);
      finish(2);
      await tester.pumpAndSettle();
      expect(find.text('No more videos to play next.'), findsOneWidget);
      expect(video.nextId, 2);
      expect(find.text('Last saved video'), findsOneWidget);
      await clean(tester);
    },
  );

  testWidgets(
    'a player control used while the next video is prepared keeps this one',
    (tester) async {
      library.following.add(
        _item('lmnopqrstuv', title: 'The next saved video'),
      );
      await preferences.setAutoplayNext(true);
      await open(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      library.pendingVerification = Completer<void>();
      finish(1);
      await tester.pump();
      await tester.pump();
      expect(find.text('Getting the next video ready…'), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      library.pendingVerification!.complete();
      await tester.pumpAndSettle();
      expect(video.nextId, 1);
      expect(video.calls.where((call) => call == 'play:1'), hasLength(2));
      expect(find.text('The next saved video'), findsNothing);
      expect(find.text('Getting the next video ready…'), findsNothing);
      await clean(tester);
    },
  );

  testWidgets(
    'leaving the app while the next video is prepared never starts it',
    (tester) async {
      library.following.add(_item('lmnopqrstuv'));
      await preferences.setAutoplayNext(true);
      await open(tester);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await lock(tester);
      library.pendingVerification = Completer<void>();
      finish(1);
      await tester.pump();
      await tester.pump();
      expect(find.text('Getting the next video ready…'), findsOneWidget);
      background(tester);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      library.pendingVerification!.complete();
      await tester.pumpAndSettle();
      expect(video.nextId, 1);
      expect(
        video.calls.where((call) => call.startsWith('play:')),
        hasLength(1),
      );
      expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      await clean(tester);
    },
  );

  testWidgets('closing the player while the next video loads releases it', (
    tester,
  ) async {
    library.following.add(_item('lmnopqrstuv'));
    await preferences.setAutoplayNext(true);
    await open(tester);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    video.initializeImmediately = false;
    finish(1);
    await tester.pump();
    await tester.pump();
    expect(video.nextId, 2);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    expect(find.byType(PlayerScreen), findsNothing);
    expect(video.disposed, containsAll([1, 2]));
    expect(tester.takeException(), isNull);
    await clean(tester);
  });

  testWidgets('autoplay is one saved choice and a failed save keeps it', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
    final autoplay = find.widgetWithText(
      SwitchListTile,
      'Play next video automatically',
    );
    expect(tester.widget<SwitchListTile>(autoplay).value, isFalse);
    await tester.tap(autoplay);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(autoplay).value, isTrue);
    expect(await PlaybackPreferences().autoplayNext(), isTrue);
    expect(await PlaybackPreferences().repeatFor(library.item.id), isFalse);
    preferences.failAutoplayWrite = true;
    await tester.tap(autoplay);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(autoplay).value, isTrue);
    expect(
      find.text('Autoplay could not be saved. Try again.'),
      findsOneWidget,
    );
    expect(await PlaybackPreferences().autoplayNext(), isTrue);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Next video plays automatically'), findsOneWidget);
    await clean(tester);
  });
}

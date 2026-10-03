import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'package:mits_kids_youtube/src/app.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/screens/library_screen.dart';
import 'package:mits_kids_youtube/src/screens/player_screen.dart';
import 'package:mits_kids_youtube/src/services/android_offline_muxer.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/offline_thumbnails.dart';
import 'package:mits_kids_youtube/src/services/playback_preferences.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';

import 'fixtures/media_fixture.dart';

// This known fixture PIN is ONLY for the separate .validation installation.
// No production credential is supplied or read by these tests.
const fixturePin = '706291';
const security = MethodChannel('mits_kids/parent_security');
const media = MethodChannel('mits_kids/offline_media');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory offline;

  setUpAll(() async {
    final documents = await getApplicationDocumentsDirectory();
    if (!documents.path.contains(
      '/com.example.mits_kids_youtube.validation/',
    )) {
      throw StateError(
        'Refusing native tests outside the isolated .validation installation. '
        'Run tools/test_android.sh.',
      );
    }
    offline = await Directory(p.join(documents.path, 'offline')).create();
  });

  testWidgets('real Android setup, Keystore authentication and lock epoch', (
    tester,
  ) async {
    final status = await security.invokeMapMethod<String, dynamic>('status');
    if (status?['configured'] != true) {
      await tester.pumpWidget(const MitsKidsApp());
      await tester.pumpAndSettle();
      expect(find.text('Parent setup'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, fixturePin);
      await tester.enterText(find.byType(TextField).last, fixturePin);
      await tester.tap(find.text('Complete parent setup'));
      // Native PBKDF work does not necessarily hold a Flutter scheduled frame.
      for (
        var i = 0;
        i < 100 && find.text('Parent setup').evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Parent setup'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    final configured = await security.invokeMapMethod<String, dynamic>(
      'status',
    );
    expect(configured?['configured'], isTrue);
    final authenticated = await security.invokeMapMethod<String, dynamic>(
      'authenticate',
      {'pin': fixturePin},
    );
    expect(authenticated?['token'], isA<String>());
    final late = security.invokeMethod<Object?>('authenticate', {
      'pin': fixturePin,
    });
    final rejected = expectLater(late, throwsA(isA<PlatformException>()));
    await security.invokeMethod<void>('lock');
    await rejected;
    // Interruption retains the committed conservative attempt delay.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await security.invokeMethod<Object?>('authenticate', {'pin': fixturePin});
  });

  testWidgets(
    'native PIN change requires the old PIN and persists the new verifier',
    (tester) async {
      const replacement = '628104';
      var changed = false;
      try {
        await security.invokeMethod<Object?>('changePin', {
          'pin': fixturePin,
          'newPin': replacement,
        });
        changed = true;
        await expectLater(
          security.invokeMethod<Object?>('authenticate', {'pin': fixturePin}),
          throwsA(isA<PlatformException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final result = await security.invokeMapMethod<String, dynamic>(
          'authenticate',
          {'pin': replacement},
        );
        expect(result?['token'], isA<String>());
      } finally {
        if (changed) {
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          await security.invokeMethod<Object?>('changePin', {
            'pin': replacement,
            'newPin': fixturePin,
          });
        }
      }
    },
  );

  testWidgets(
    'native free-space query rejects a path outside private offline storage',
    (tester) async {
      final bytes = await media.invokeMethod<int>('availableBytes', {
        'path': offline.path,
      });
      expect(bytes, isNotNull);
      expect(bytes, greaterThan(0));
      await expectLater(
        media.invokeMethod<int>('availableBytes', {
          'path': offline.parent.path,
        }),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  testWidgets('native AVC/AAC mux and local playback, pause and seek', (
    tester,
  ) async {
    final staging = await offline.createTemp('.pending-');
    final video = await File(
      p.join(staging.path, 'video.part'),
    ).writeAsBytes(base64Decode(videoFixture));
    final audio = await File(
      p.join(staging.path, 'audio.part'),
    ).writeAsBytes(base64Decode(audioFixture));
    final output = File(p.join(staging.path, 'ready.mp4'));
    VideoPlayerController? controller;
    try {
      await AndroidOfflineMuxer().combine(video, audio, output);
      expect(await output.length(), greaterThan(0));
      controller = VideoPlayerController.file(output);
      await controller.initialize();
      expect(controller.value.size.width, greaterThan(0));
      expect(
        controller.value.duration,
        greaterThan(const Duration(seconds: 1)),
      );
      await tester.pumpWidget(MaterialApp(home: VideoPlayer(controller)));
      await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(await controller.position, greaterThan(Duration.zero));
      await controller.pause();
      expect(controller.value.isPlaying, isFalse);
      await controller.seekTo(const Duration(seconds: 1));
      final position = await controller.position;
      expect(position!.inMilliseconds, inInclusiveRange(800, 1300));
      expect(controller.value.hasError, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await controller?.dispose();
      await staging.delete(recursive: true);
    }
  });

  /// Saves the video fixture as approved entries, newest first. They are dated
  /// in 2000 so no other saved entry can fall between them in Offline's order.
  Future<List<OfflineItem>> saveFixtures(
    OfflineRepository repository,
    List<String> titles,
  ) async {
    final bytes = base64Decode(videoFixture);
    final hash = sha256.convert(bytes).toString();
    final saved = <OfflineItem>[];
    for (var index = 0; index < titles.length; index++) {
      final id = 'fixture${index.toString().padLeft(4, '0')}';
      for (final old in await repository.all()) {
        if (old.id == id) await repository.delete(old);
      }
      final file = await File(
        p.join(
          offline.path,
          '$id-${DateTime.now().microsecondsSinceEpoch}.mp4',
        ),
      ).writeAsBytes(bytes, flush: true);
      final item = OfflineItem(
        id: id,
        title: titles[index],
        sourceUrl: 'https://www.youtube.com/watch?v=$id',
        filePath: file.path,
        bytes: bytes.length,
        createdAt: DateTime.utc(2000, 1, 1, 0, titles.length - index),
        approvedAt: DateTime.utc(2000),
        channelId: 'UC${'a' * 22}',
        contentHash: hash,
      );
      await repository.add(item);
      saved.add(item);
    }
    return saved;
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    // Native decoding and playback do not hold Flutter frames; poll instead.
    for (var i = 0; i < 300 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets);
  }

  testWidgets('Offline pictures come from saved files via the native decoder', (
    tester,
  ) async {
    final repository = OfflineRepository();
    final pictures = Directory(
      p.join((await getApplicationCacheDirectory()).path, 'offline-thumbnails'),
    );
    if (await pictures.exists()) await pictures.delete(recursive: true);
    final saved = await saveFixtures(repository, [
      'Fixture picture one',
      'Fixture picture two',
    ]);
    try {
      expect(
        await readMp4Duration(File(saved.first.filePath)),
        const Duration(milliseconds: 1968),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            repository: repository,
            settings: SettingsRepository(),
          ),
        ),
      );
      for (final item in saved) {
        await waitFor(
          tester,
          find.descendant(
            of: find.ancestor(
              of: find.text(item.title),
              matching: find.byType(Card),
            ),
            matching: find.byWidgetPredicate(
              (widget) => widget is Image && widget.image is MemoryImage,
            ),
          ),
        );
        final stored = File(
          p.join(
            pictures.path,
            '${p.basenameWithoutExtension(item.filePath)}.jpg',
          ),
        );
        final codec = await ui.instantiateImageCodec(
          await stored.readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, inInclusiveRange(1, 320));
        expect(frame.image.height, inInclusiveRange(1, 180));
        frame.image.dispose();
        codec.dispose();
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final item in saved) {
        await repository.delete(item);
      }
      if (await pictures.exists()) await pictures.delete(recursive: true);
    }
  });

  testWidgets(
    'autoplay continues locked into the next saved video and stops at the end',
    (tester) async {
      final repository = OfflineRepository();
      final preferences = PlaybackPreferences();
      final previous = await preferences.autoplayNext();
      final saved = await saveFixtures(repository, [
        'Fixture autoplay first',
        'Fixture autoplay last',
      ]);
      await preferences.setAutoplayNext(true);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              item: saved.first,
              repository: repository,
              settings: SettingsRepository(),
            ),
          ),
        );
        await waitFor(tester, find.byTooltip('Play'));
        expect(
          find.byTooltip('Next video plays automatically'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Play'));
        await tester.pump();
        await tester.tap(find.byTooltip('Lock playback controls'));
        await waitFor(tester, find.text('Fixture autoplay last'));
        await waitFor(tester, find.byTooltip('Pause'));
        expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
        await waitFor(tester, find.text('No more videos to play next.'));
        expect(find.text('Fixture autoplay last'), findsOneWidget);
        expect(find.byKey(const ValueKey('playback-unlock')), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await preferences.setAutoplayNext(previous);
        for (final item in saved) {
          await repository.delete(item);
        }
      }
    },
  );
}

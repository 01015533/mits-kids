import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/seek_preview_frames.dart';
import 'package:mits_kids_youtube/src/widgets/seek_preview_timeline.dart';

class _Frames implements SeekPreviewFrames {
  final requests = <Duration>[];
  final pending = <Completer<SeekPreviewFrame?>>[];
  int cancellations = 0;
  int disposals = 0;
  int active = 0;
  int maximumActive = 0;

  @override
  Future<SeekPreviewFrame?> frame(
    File file, {
    required Duration position,
  }) async {
    requests.add(position);
    active++;
    if (active > maximumActive) maximumActive = active;
    final result = Completer<SeekPreviewFrame?>();
    pending.add(result);
    try {
      return await result.future;
    } finally {
      active--;
    }
  }

  @override
  Future<void> cancel() async {
    cancellations++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  late _Frames frames;
  late List<Duration> starts;
  late List<Duration> commits;
  late int cancellations;
  final picture = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  const track = ValueKey('playback-seek-track');

  setUp(() {
    frames = _Frames();
    starts = [];
    commits = [];
    cancellations = 0;
  });

  Widget app({
    bool enabled = true,
    double scale = 1,
    String path = '/private/video.mp4',
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SeekPreviewTimeline(
            file: File(path),
            position: const Duration(seconds: 10),
            duration: const Duration(minutes: 2),
            enabled: enabled,
            frames: frames,
            onChangeStart: starts.add,
            onChangeEnd: commits.add,
            onChangeCancel: () {
              cancellations++;
            },
          ),
        ),
      ),
    ),
  );

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final pending in frames.pending) {
      if (!pending.isCompleted) pending.complete(null);
    }
    await tester.pump();
  }

  testWidgets('drag shows target frame and commits only on release', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(track)),
    );
    await tester.pump(const Duration(milliseconds: 130));
    expect(starts, hasLength(1));
    expect(commits, isEmpty);
    expect(frames.requests, hasLength(1));
    expect(find.text('Loading preview…'), findsOneWidget);
    final target = frames.requests.single;
    frames.pending.single.complete(
      SeekPreviewFrame(bytes: picture, position: target),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const ValueKey('seek-preview-time')), findsOneWidget);
    expect(commits, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(commits, [target]);
    expect(find.byKey(const ValueKey('seek-scene-preview')), findsNothing);
    await clean(tester);
  });

  testWidgets('many drag positions debounce and never run parallel requests', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(track)),
    );
    await tester.pump(const Duration(milliseconds: 130));
    expect(frames.requests, hasLength(1));
    for (var index = 0; index < 12; index++) {
      await gesture.moveBy(const Offset(5, 0));
      await tester.pump(const Duration(milliseconds: 15));
    }
    await tester.pump(const Duration(milliseconds: 130));
    expect(frames.requests, hasLength(1));
    expect(frames.cancellations, 1);
    frames.pending.first.complete(
      SeekPreviewFrame(bytes: picture, position: frames.requests.first),
    );
    await tester.pump();
    expect(frames.requests, hasLength(2));
    expect(frames.maximumActive, 1);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Loading preview…'), findsOneWidget);
    expect(frames.requests.last, greaterThan(frames.requests.first));
    frames.pending.last.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Preview unavailable'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(commits, hasLength(1));
    await clean(tester);
  });

  testWidgets('moving clears the old frame instead of relabelling it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(track)),
    );
    await tester.pump(const Duration(milliseconds: 130));
    frames.pending.single.complete(
      SeekPreviewFrame(bytes: picture, position: frames.requests.single),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.text('Loading preview…'), findsOneWidget);
    await gesture.cancel();
    await tester.pump();
    expect(commits, isEmpty);
    expect(cancellations, 1);
    await clean(tester);
  });

  testWidgets('disabling during a drag cancels preview and rejects release', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(track)),
    );
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pumpWidget(app(enabled: false));
    await tester.pump();
    expect(find.byKey(const ValueKey('seek-scene-preview')), findsNothing);
    expect(frames.cancellations, 1);
    expect(cancellations, 1);
    frames.pending.single.complete(
      SeekPreviewFrame(bytes: picture, position: frames.requests.single),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(commits, isEmpty);
    expect(find.byType(Image), findsNothing);
    await clean(tester);
  });

  testWidgets('file replacement and disposal ignore old preview results', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(track)),
    );
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pumpWidget(app(path: '/private/next.mp4'));
    await tester.pump();
    expect(cancellations, 1);
    await gesture.up();
    await clean(tester);
    expect(commits, isEmpty);
    expect(frames.cancellations, 1);
    expect(frames.disposals, 0); // Injected services remain caller-owned.
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait and landscape previews fit enlarged text', (
    tester,
  ) async {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(2.5),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SeekPreviewTimeline(
                  file: File('/private/video.mp4'),
                  position: Duration.zero,
                  duration: const Duration(hours: 2),
                  enabled: true,
                  frames: frames,
                  onChangeEnd: commits.add,
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(track)),
      );
      await tester.pump(const Duration(milliseconds: 130));
      frames.pending.last.complete(null);
      await tester.pump();
      final rect = tester.getRect(
        find.byKey(const ValueKey('seek-scene-preview')),
      );
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
      await gesture.cancel();
      await tester.pump();
      await clean(tester);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('accessible increase commits an intentional keyboard-free seek', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app());
    tester.semantics.increase(
      find.semantics.byAction(ui.SemanticsAction.increase),
    );
    await tester.pumpAndSettle();
    expect(starts, hasLength(1));
    expect(commits, hasLength(1));
    expect(commits.single, greaterThan(const Duration(seconds: 10)));
    expect(find.byKey(const ValueKey('seek-scene-preview')), findsNothing);
    expect(frames.requests, isEmpty);
    await clean(tester);
    semantics.dispose();
  });

  testWidgets('focused keyboard arrow commits one seek without pointer input', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(starts, hasLength(1));
    expect(commits, hasLength(1));
    expect(commits.single, greaterThan(const Duration(seconds: 10)));
    expect(frames.requests, isEmpty);
    expect(find.byKey(const ValueKey('seek-scene-preview')), findsNothing);
    await clean(tester);
  });

  if (const bool.fromEnvironment('CAPTURE_SEEK_PREVIEW')) {
    testWidgets('capture scene-preview layouts for visual review', (
      tester,
    ) async {
      final scene = await tester.runAsync(() async {
        final fonts = File(Platform.resolvedExecutable).parent.parent.parent;
        for (final entry in {
          'Roboto': 'Roboto-Regular.ttf',
          'MaterialIcons': 'MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(entry.key)
            ..addFont(
              File(
                '${fonts.path}/material_fonts/${entry.value}',
              ).readAsBytes().then(ByteData.sublistView),
            );
          await loader.load();
        }
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 320, 180),
          Paint()..color = const Color(0xffc9e9f5),
        );
        canvas.drawCircle(
          const Offset(250, 35),
          17,
          Paint()..color = const Color(0xffffdf7b),
        );
        final hills = Path()
          ..moveTo(0, 140)
          ..quadraticBezierTo(60, 30, 150, 135)
          ..quadraticBezierTo(255, 20, 320, 135)
          ..lineTo(320, 180)
          ..lineTo(0, 180)
          ..close();
        canvas.drawPath(hills, Paint()..color = const Color(0xff537d63));
        canvas.drawOval(
          const Rect.fromLTWH(65, 128, 200, 60),
          Paint()..color = const Color(0xff579cae),
        );
        canvas.drawRect(
          const Rect.fromLTWH(37, 89, 8, 58),
          Paint()..color = const Color(0xff816343),
        );
        canvas.drawCircle(
          const Offset(41, 83),
          26,
          Paint()..color = const Color(0xff2f665b),
        );
        final recording = recorder.endRecording();
        final image = await recording.toImage(320, 180);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        recording.dispose();
        return bytes!.buffer.asUint8List();
      });
      for (final entry in {
        'portrait': const Size(360, 640),
        'landscape': const Size(640, 360),
      }.entries) {
        await tester.binding.setSurfaceSize(entry.value);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff1769e0),
                  brightness: Brightness.dark,
                ),
                scaffoldBackgroundColor: const Color(0xff07111f),
                fontFamily: 'Roboto',
              ),
              home: Scaffold(
                appBar: AppBar(title: const Text('Offline video')),
                body: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.memory(scene!, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                    SeekPreviewTimeline(
                      file: File('/private/scene.mp4'),
                      position: const Duration(seconds: 15),
                      duration: const Duration(minutes: 2),
                      enabled: true,
                      frames: frames,
                      onChangeEnd: commits.add,
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        children: [
                          Icon(Icons.pause),
                          SizedBox(width: 16),
                          Text('00:15 / 02:00'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => precacheImage(MemoryImage(scene), boundary.currentContext!),
        );
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(track)),
        );
        await tester.pump(const Duration(milliseconds: 130));
        frames.pending.last.complete(
          SeekPreviewFrame(bytes: scene, position: frames.requests.last),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/mits-seek-preview-${entry.key}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
        await gesture.cancel();
        await clean(tester);
      }
      await tester.binding.setSurfaceSize(null);
    });
  }
}

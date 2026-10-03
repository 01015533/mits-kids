import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/screens/library_screen.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/offline_thumbnails.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A real 16×9 JPEG, so Offline is given decodable picture data.
final _jpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
  'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
  'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAJABADASIA'
  'AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA'
  'AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3'
  'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm'
  'p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA'
  'AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx'
  'BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK'
  'U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3'
  'uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDtq8xr'
  '06vMaw4F/wCYj/t3/wBuMuJv+XX/AG9+h//Z',
);

Uint8List _picture() => Uint8List.fromList(_jpeg);

class _SizedFile implements File {
  _SizedFile(this.path);
  @override
  final String path;

  @override
  Future<int> length() async => 1048576;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends OfflineRepository {
  _Library(this.items);
  final List<OfflineItem> items;

  @override
  Future<List<OfflineItem>> all() async => List.of(items);

  @override
  Future<File?> privateFile(String path) async => _SizedFile(path);

  void remove(OfflineItem item) {
    items.remove(item);
    notifyListeners();
  }
}

class _Thumbnails extends OfflineThumbnails {
  final kept = <String, Uint8List>{};
  final made = <String, Completer<Uint8List?>>{};
  final requested = <String>[];
  final removedFor = <Set<String>>[];

  @override
  Future<Uint8List?> stored(OfflineItem item) async => kept[item.filePath];

  @override
  Future<Uint8List?> create(OfflineItem item, File video) {
    requested.add(item.filePath);
    return (made[item.filePath] ??= Completer<Uint8List?>()).future;
  }

  @override
  Future<void> removeUnused(Iterable<OfflineItem> records) async {
    removedFor.add({for (final item in records) item.filePath});
  }
}

OfflineItem _video(String id, {String title = 'A saved video'}) => OfflineItem(
  id: id,
  title: title,
  sourceUrl: 'https://www.youtube.com/watch?v=$id',
  filePath: '/offline/$id-1234567890123456.mp4',
  bytes: 1048576,
  createdAt: DateTime.utc(2026),
  approvedAt: DateTime.utc(2026),
  contentHash: 'a' * 64,
  channelId: 'UC${'a' * 22}',
);

Finder _showing(Uint8List picture) => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is MemoryImage &&
      identical((widget.image as MemoryImage).bytes, picture),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget offline(_Library library, _Thumbnails thumbnails) => MaterialApp(
    home: LibraryScreen(
      repository: library,
      settings: SettingsRepository(),
      thumbnails: thumbnails,
    ),
  );

  testWidgets(
    'Offline shows stored pictures and makes missing ones one at a time',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'filter_config_v1': '{"blockedKeywords":["Hidden"]}',
      });
      final kept = _video('aaaaaaaaaaa', title: 'Kept picture');
      final fresh = _video('bbbbbbbbbbb', title: 'New picture');
      final failing = _video('ccccccccccc', title: 'Unsupported video');
      final hidden = _video('ddddddddddd', title: 'Hidden video');
      final library = _Library([kept, fresh, failing, hidden]);
      addTearDown(library.dispose);
      final keptPicture = _picture();
      final freshPicture = _picture();
      final thumbnails = _Thumbnails()..kept[kept.filePath] = keptPicture;
      await tester.pumpWidget(offline(library, thumbnails));
      await tester.pumpAndSettle();

      expect(find.text('3 videos available to watch'), findsOneWidget);
      expect(_showing(keptPicture), findsOneWidget);
      expect(thumbnails.requested, [fresh.filePath]);
      thumbnails.made[fresh.filePath]!.complete(freshPicture);
      await tester.pumpAndSettle();
      expect(_showing(freshPicture), findsOneWidget);
      expect(thumbnails.requested, [fresh.filePath, failing.filePath]);
      thumbnails.made[failing.filePath]!.complete(null);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);

      // A picture that could not be made is not attempted again in a loop,
      // and videos hidden by the rules are never decoded.
      await tester.tap(find.byTooltip('Refresh library'));
      await tester.pumpAndSettle();
      expect(thumbnails.requested, [fresh.filePath, failing.filePath]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('pictures wait while another screen covers Offline', (
    tester,
  ) async {
    final first = _video('aaaaaaaaaaa');
    final second = _video('bbbbbbbbbbb');
    final library = _Library([first, second]);
    addTearDown(library.dispose);
    final thumbnails = _Thumbnails();
    await tester.pumpWidget(offline(library, thumbnails));
    await tester.pumpAndSettle();
    expect(thumbnails.requested, [first.filePath]);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Player')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final firstPicture = _picture();
    thumbnails.made[first.filePath]!.complete(firstPicture);
    await tester.pumpAndSettle();
    // The player's scene previews own the decoder while it is open.
    expect(thumbnails.requested, [first.filePath]);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(thumbnails.requested, [first.filePath, second.filePath]);
    expect(_showing(firstPicture), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pictures of deleted videos are removed', (tester) async {
    final first = _video('aaaaaaaaaaa');
    final second = _video('bbbbbbbbbbb');
    final library = _Library([first, second]);
    addTearDown(library.dispose);
    final thumbnails = _Thumbnails()
      ..kept[first.filePath] = _picture()
      ..kept[second.filePath] = _picture();
    await tester.pumpWidget(offline(library, thumbnails));
    await tester.pumpAndSettle();
    expect(thumbnails.removedFor, [
      {first.filePath, second.filePath},
    ]);

    await tester.tap(find.byTooltip('Refresh library'));
    await tester.pumpAndSettle();
    expect(thumbnails.removedFor, hasLength(1));

    library.remove(second);
    await tester.pumpAndSettle();
    expect(find.text('1 video available to watch'), findsOneWidget);
    expect(thumbnails.removedFor.last, {first.filePath});
    expect(thumbnails.requested, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'the picture grid fits wide screens and narrow enlarged-text screens',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final videos = [
        for (var index = 0; index < 8; index++)
          _video('vid0000000$index', title: 'Video $index'),
      ];
      final library = _Library(videos);
      addTearDown(library.dispose);
      final thumbnails = _Thumbnails()
        ..kept.addAll({for (final video in videos) video.filePath: _picture()});

      await tester.binding.setSurfaceSize(const Size(1280, 800));
      await tester.pumpWidget(offline(library, thumbnails));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      double top(String title) => tester.getTopLeft(find.text(title)).dy;
      expect(top('Video 4'), top('Video 0'));
      expect(top('Video 5'), greaterThan(top('Video 0')));

      await tester.binding.setSurfaceSize(const Size(360, 740));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: LibraryScreen(
            repository: library,
            settings: SettingsRepository(),
            thumbnails: thumbnails,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // One column: the second card is laid out below the first, off screen.
      Offset at(String title) =>
          tester.getTopLeft(find.text(title, skipOffstage: false));
      expect(at('Video 1').dy, greaterThan(at('Video 0').dy));
      expect(at('Video 1').dx, at('Video 0').dx);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

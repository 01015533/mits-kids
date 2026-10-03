import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/screens/library_screen.dart';
import 'package:mits_kids_youtube/src/screens/parent_screen.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SizedFile implements File {
  _SizedFile(this.size);
  final int size;

  @override
  Future<int> length() async => size;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends OfflineRepository {
  _Library(this.items);
  final List<OfflineItem> items;
  final deleted = <String>[];

  @override
  Future<List<OfflineItem>> all() async => List.of(items);

  @override
  Future<Directory> storageDirectory() async => Directory('/offline');

  @override
  Future<File?> privateFile(String path) async =>
      path == 'missing' ? null : _SizedFile(1048576);

  @override
  Future<void> delete(OfflineItem item, {OfflineMutationLease? lease}) async {
    deleted.add(item.id);
    items.removeWhere((saved) => saved.id == item.id);
    notifyListeners();
  }
}

List<OfflineItem> _fullLibrary() => List.generate(
  8,
  (index) => OfflineItem(
    id: 'video$index',
    title: index == 0 ? 'Allowed video' : 'Hidden video $index',
    sourceUrl: 'https://www.youtube.com/watch?v=abcdefghijk',
    filePath: index == 7 ? 'missing' : 'saved$index',
    bytes: 1048576,
    createdAt: DateTime.utc(2026),
    approvedAt: index == 6 ? null : DateTime.utc(2026),
    contentHash: 'a' * 64,
    channelId: 'UC${'a' * 22}',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mits_kids/parent_security');
  const mediaChannel = MethodChannel('mits_kids/offline_media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'filter_config_v1': '{"blockedKeywords":["Hidden"]}',
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') return {'token': 'parent-session'};
      return null;
    });
    messenger.setMockMethodCallHandler(
      mediaChannel,
      (call) async => 4294967296,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(mediaChannel, null);
  });

  testWidgets(
    'child count describes playable entries without implying free slots',
    (tester) async {
      final library = _Library(_fullLibrary());
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            repository: library,
            settings: SettingsRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 video available to watch'), findsOneWidget);
      expect(find.text('Allowed video'), findsOneWidget);
      expect(find.textContaining('/ 8'), findsNothing);
      expect(library.items.length, 8);
      expect(library.deleted, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'parent counts hidden and missing entries and updates after deletion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final library = _Library(_fullLibrary());
      final session = ParentSession();
      addTearDown(library.dispose);
      addTearDown(session.dispose);
      await session.initialise();
      await session.authenticate('123456');
      await tester.pumpWidget(
        MaterialApp(
          home: ParentScreen(session: session, library: library),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('8 / 8 slots used'), findsOneWidget);
      expect(find.text('7.0 MiB of saved video files'), findsOneWidget);
      expect(find.text('4.00 GiB free on this tablet'), findsOneWidget);
      expect(
        find.text('Hidden from your child by the saved content rules.'),
        findsNWidgets(5),
      );
      expect(
        find.textContaining('Needs a new approved download:'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Saved file is missing or damaged.'),
        findsOneWidget,
      );

      final missingRow = find.ancestor(
        of: find.text('Hidden video 7'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: missingRow,
          matching: find.byIcon(Icons.delete_outline),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(library.deleted, ['video7']);
      expect(find.text('7 / 8 slots used'), findsOneWidget);
      expect(find.text('7.0 MiB of saved video files'), findsOneWidget);
      expect(find.textContaining('All slots are full.'), findsNothing);
      session.lock();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing approved file stays in parent storage but out of child library',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final missing = _fullLibrary().last;
      final library = _Library([missing]);
      addTearDown(library.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            repository: library,
            settings: SettingsRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('0 videos available to watch'), findsOneWidget);
      expect(find.text(missing.title), findsNothing);
      expect(library.items, [missing]);
      expect(library.deleted, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'PIN change checks confirmation and forwards current and new PIN',
    (tester) async {
      var changes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return {'configured': true, 'legacy': false};
        }
        if (call.method == 'authenticate') return {'token': 'old-token'};
        if (call.method == 'changePin') {
          changes++;
          expect(call.arguments, {'pin': '123456', 'newPin': '654321'});
          return {'token': 'new-token'};
        }
        return null;
      });
      final library = _Library([]);
      final session = ParentSession();
      addTearDown(library.dispose);
      addTearDown(session.dispose);
      await session.initialise();
      await session.authenticate('123456');
      await tester.pumpWidget(
        MaterialApp(
          home: ParentScreen(session: session, library: library),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change parent PIN'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '123456');
      await tester.enterText(fields.at(1), '654321');
      await tester.enterText(fields.at(2), '654322');
      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();
      expect(changes, 0);
      expect(
        find.textContaining('the same new 6–12 digit PIN twice'),
        findsOneWidget,
      );
      await tester.enterText(fields.at(2), '654321');
      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();
      expect(changes, 1);
      expect(session.token, 'new-token');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Parent PIN changed.'), findsOneWidget);
      session.lock();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'parent controls and library wrap on a narrow enlarged-text screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final library = _Library(_fullLibrary());
      final session = ParentSession();
      addTearDown(library.dispose);
      addTearDown(session.dispose);
      Widget app(Widget screen) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: screen,
      );
      await tester.pumpWidget(
        app(ParentScreen(session: session, library: library)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('8 / 8 slots used'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        app(LibraryScreen(repository: library, settings: SettingsRepository())),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 video available to watch'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

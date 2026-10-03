import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/offline_limits.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/playback_policy.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late Database db;
  late OfflineRepository repository;
  Future<OfflineItem> item(int i) async {
    final file = await File('${directory.path}/$i.mp4').writeAsBytes([1, 2, 3]);
    return OfflineItem(
      id: '$i',
      title: 'Video $i',
      sourceUrl: 'https://youtube.com/watch?v=abcdefghi0$i',
      filePath: file.path,
      bytes: 3,
      contentHash: sha256.convert([1, 2, 3]).toString(),
      createdAt: DateTime.now().toUtc(),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mits-repository-test-');
    db = await databaseFactoryFfi.openDatabase(
      '${directory.path}/library.db',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: OfflineRepository.createSchema,
      ),
    );
    repository = OfflineRepository(
      openDatabaseForTest: () async => db,
      directoryProvider: () async => directory,
    );
  });
  tearDown(() async {
    repository.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'database transaction refuses ninth entry and deletion frees one slot',
    () async {
      for (var i = 0; i < 8; i++) {
        await repository.add(await item(i));
      }
      await expectLater(
        repository.add(await item(8)),
        throwsA(isA<LibraryFull>()),
      );
      expect(await repository.all(), hasLength(8));
      final first = (await repository.all()).first;
      await repository.delete(first);
      expect(await File(first.filePath).exists(), isFalse);
      await repository.add(await item(8));
      expect(await repository.all(), hasLength(8));
    },
  );

  test(
    'saved metadata survives reopening the database without a network source',
    () async {
      final saved = await item(0);
      await repository.add(saved);
      await db.close();
      db = await databaseFactoryFfi.openDatabase(
        '${directory.path}/library.db',
      );
      final reopened = OfflineRepository(
        openDatabaseForTest: () async => db,
        directoryProvider: () async => directory,
      );
      final contents = await reopened.all();
      expect(contents.single.title, saved.title);
      expect(await File(contents.single.filePath).readAsBytes(), [1, 2, 3]);
      reopened.dispose();
    },
  );

  test(
    'missing and truncated entries remain manageable until parent deletion',
    () async {
      final missing = await item(0);
      final truncated = await item(1);
      await repository.add(missing);
      await repository.add(truncated);
      await File(missing.filePath).delete();
      await File(truncated.filePath).writeAsBytes([1]);
      expect(await repository.all(), hasLength(2));
      expect(await db.query('offline_items'), hasLength(2));
      await expectLater(repository.verifyFile(missing), throwsStateError);
      await expectLater(repository.verifyFile(truncated), throwsStateError);
      await repository.delete(missing);
      await repository.delete(truncated);
      expect(await repository.all(), isEmpty);
      expect(await File(truncated.filePath).exists(), isFalse);
    },
  );
  test('same-length tampering fails integrity validation', () async {
    final saved = await item(0);
    await repository.add(saved);
    await File(saved.filePath).writeAsBytes([3, 2, 1]);
    await expectLater(repository.verifyFile(saved), throwsStateError);
  });

  test('listing never removes a file awaiting publication', () async {
    final unpublished = await File(
      '${directory.path}/abcdefghijk-1777777777777777.mp4',
    ).writeAsBytes([1, 2, 3]);
    expect(await repository.all(), isEmpty);
    expect(await unpublished.readAsBytes(), [1, 2, 3]);
  });

  test(
    'real version-one database migration preserves files without granting approval',
    () async {
      final path = '${directory.path}/legacy.db';
      var legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE offline_items (id TEXT PRIMARY KEY, title TEXT NOT NULL, source_url TEXT NOT NULL, file_path TEXT NOT NULL, bytes INTEGER NOT NULL, created_at TEXT NOT NULL, thumbnail_url TEXT)',
            );
          },
        ),
      );
      final saved = await item(5);
      await legacy.insert('offline_items', {
        'id': saved.id,
        'title': saved.title,
        'source_url': saved.sourceUrl,
        'file_path': saved.filePath,
        'bytes': saved.bytes,
        'created_at': saved.createdAt.toIso8601String(),
      });
      await legacy.close();
      legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onUpgrade: OfflineRepository.upgradeSchema,
        ),
      );
      final migrated = OfflineRepository(
        openDatabaseForTest: () async => legacy,
        directoryProvider: () async => directory,
      );
      final entries = await migrated.all();
      expect(entries, hasLength(1));
      expect(
        PlaybackPolicy.allows(entries.single, FilterConfig.defaults),
        isFalse,
      );
      expect(await File(saved.filePath).readAsBytes(), [1, 2, 3]);
      migrated.dispose();
      await legacy.close();
    },
  );

  test(
    'symlink outside the offline directory is never opened or deleted',
    () async {
      final outside = await Directory.systemTemp.createTemp('mits-outside-');
      try {
        final file = await File(
          '${outside.path}/private.txt',
        ).writeAsBytes([1, 2, 3]);
        final link = Link('${directory.path}/escape.mp4');
        await link.create(file.path);
        expect(await repository.privateFile(link.path), isNull);
        expect(await file.readAsBytes(), [1, 2, 3]);
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
}

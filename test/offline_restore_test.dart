import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/offline_limits.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late Database db;
  late OfflineRepository repository;
  const job = '0123456789abcdef0123456789abcdef';

  Future<File> journal(List<String> names) =>
      File('${directory.path}/.restore-journal-$job.json').writeAsString(
        jsonEncode({'version': 1, 'job': job, 'files': names}),
        flush: true,
      );

  OfflineItem item(String id, String path) => OfflineItem(
    id: id,
    title: 'Reviewed',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
    filePath: path,
    bytes: 3,
    createdAt: DateTime.now().toUtc(),
    author: 'Example',
    channelId: 'UCabcdefghijklmnopqrstuv',
    contentHash: sha256.convert([1, 2, 3]).toString(),
    approvedAt: DateTime.now().toUtc(),
  );

  Future<OfflineItem> staged(String id) async {
    final stage = await Directory('${directory.path}/.restore-test').create();
    final file = await File('${stage.path}/$id.mp4').writeAsBytes([1, 2, 3]);
    return item(id, file.path);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mits-restore-test-');
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 3,
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
    'restore inserts selected videos together with a durable commit marker',
    () async {
      final a = await staged('abcdefghij0');
      final b = await staged('abcdefghij1');
      final lease = repository.acquireMutation();
      final restored = await repository.addMany(
        [a, b],
        lease: lease,
        authorised: () => true,
      );
      lease.release();
      expect(await repository.all(), hasLength(2));
      expect(await db.query('restore_commits'), hasLength(1));
      for (final entry in restored) {
        expect(await repository.verifyFile(entry), isA<File>());
      }
      expect(
        directory.listSync().whereType<File>().where(
          (f) => f.path.contains('.restore-journal-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'revocation between file moves rolls back all new files and records',
    () async {
      final a = await staged('abcdefghij0');
      final b = await staged('abcdefghij1');
      var checks = 0;
      final lease = repository.acquireMutation();
      await expectLater(
        repository.addMany(
          [a, b],
          lease: lease,
          authorised: () => ++checks < 5,
        ),
        throwsStateError,
      );
      lease.release();
      expect(await repository.all(), isEmpty);
      expect(await db.query('restore_commits'), isEmpty);
      expect(directory.listSync().whereType<File>(), isEmpty);
    },
  );

  test('restore cannot evict or replace existing entries', () async {
    final file = await File(
      '${directory.path}/existing.mp4',
    ).writeAsBytes([1, 2, 3]);
    await repository.add(item('abcdefghij0', file.path));
    final duplicate = await staged('abcdefghij0');
    final lease = repository.acquireMutation();
    await expectLater(
      repository.addMany([duplicate], lease: lease, authorised: () => true),
      throwsA(isA<DownloadFailure>()),
    );
    lease.release();
    expect((await repository.all()).single.filePath, file.path);
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test(
    'writer lease rejects add and deletion without blocking reads',
    () async {
      final file = await File(
        '${directory.path}/existing.mp4',
      ).writeAsBytes([1, 2, 3]);
      final saved = item('abcdefghij0', file.path);
      await repository.add(saved);
      final lease = repository.acquireMutation();
      await expectLater(
        repository.delete(saved),
        throwsA(isA<DownloadFailure>()),
      );
      await expectLater(repository.add(saved), throwsA(isA<DownloadFailure>()));
      expect(await repository.all(), hasLength(1));
      lease.release();
      await repository.delete(saved);
      expect(await repository.all(), isEmpty);
    },
  );

  test(
    'startup rolls back an uncommitted final file using its journal',
    () async {
      const name = 'abcdefghij0-1777777777777777.mp4';
      final orphan = await File(
        '${directory.path}/$name',
      ).writeAsBytes([1, 2, 3]);
      final record = await journal([name]);
      expect(await repository.all(), isEmpty);
      expect(await orphan.exists(), isFalse);
      expect(await record.exists(), isFalse);
    },
  );

  test(
    'startup preserves committed files and removes only the finished journal',
    () async {
      const name = 'abcdefghij0-1777777777777777.mp4';
      final file = await File(
        '${directory.path}/$name',
      ).writeAsBytes([1, 2, 3]);
      await db.insert('restore_commits', {'job_id': job});
      final record = await journal([name]);
      expect(await repository.all(), isEmpty);
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(await record.exists(), isFalse);
    },
  );

  test(
    'startup journal cannot delete a database-referenced existing file',
    () async {
      const name = 'abcdefghij0-1777777777777777.mp4';
      final file = await File(
        '${directory.path}/$name',
      ).writeAsBytes([1, 2, 3]);
      await db.insert('offline_items', {
        'id': 'existing',
        'title': 'Existing',
        'source_url': 'https://www.youtube.com/watch?v=abcdefghij0',
        'file_path': file.path,
        'bytes': 3,
        'created_at': DateTime.now().toIso8601String(),
      });
      await journal([name]);
      expect(await repository.all(), hasLength(1));
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'unsafe recovery journal fails without following an arbitrary path',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'mits-recovery-outside-',
      );
      try {
        final file = await File('${outside.path}/keep.mp4').writeAsBytes([9]);
        await journal([file.path]);
        await expectLater(repository.all(), throwsStateError);
        expect(await file.readAsBytes(), [9]);
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );

  test(
    'startup removes an interrupted temporary journal without parsing it',
    () async {
      final temporary = await File(
        '${directory.path}/.restore-journal-$job.json.tmp',
      ).writeAsString('{"version":1,"files":[');
      final valid = await File(
        '${directory.path}/existing.mp4',
      ).writeAsBytes([1, 2, 3]);
      expect(await repository.all(), isEmpty);
      expect(await temporary.exists(), isFalse);
      expect(await valid.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'startup removes abandoned native staging without following its links',
    () async {
      final stage = await Directory(
        '${directory.path}/.restore-12345678-1234-1234-1234-123456789abc',
      ).create();
      await File('${stage.path}/0.mp4').writeAsBytes([1, 2, 3]);
      final valid = await File(
        '${directory.path}/existing.mp4',
      ).writeAsBytes([9]);
      await Link('${stage.path}/outside').create(valid.path);
      expect(await repository.all(), isEmpty);
      expect(await stage.exists(), isFalse);
      expect(await valid.readAsBytes(), [9]);
    },
  );
}

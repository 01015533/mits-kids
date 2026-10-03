import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

import '../models/offline_item.dart';
import 'offline_limits.dart';

abstract interface class OfflineStore {
  Future<List<OfflineItem>> all();
  Future<File> verifyFile(OfflineItem item);
  Future<void> add(OfflineItem item);
  Future<void> delete(OfflineItem item);
}

class OfflineMutationLease {
  OfflineMutationLease._(this._owner);
  final OfflineRepository _owner;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    if (identical(_owner._lease, this)) _owner._lease = null;
  }
}

class OfflineRepository extends ChangeNotifier implements OfflineStore {
  OfflineRepository({
    Future<Database> Function()? openDatabaseForTest,
    Future<Directory> Function()? directoryProvider,
  }) : _opener = openDatabaseForTest,
       _directoryProvider =
           directoryProvider ??
           (() async => Directory(
             p.join((await getApplicationDocumentsDirectory()).path, 'offline'),
           ));
  final Future<Database> Function()? _opener;
  final Future<Directory> Function() _directoryProvider;
  Future<Database>? _database;
  OfflineMutationLease? _lease;

  OfflineMutationLease acquireMutation() {
    if (_lease != null) {
      throw const DownloadFailure(
        'The saved library is busy. Finish or cancel the current download or backup first.',
      );
    }
    return _lease = OfflineMutationLease._(this);
  }

  Future<T> _mutating<T>(
    OfflineMutationLease? lease,
    Future<T> Function() action,
  ) async {
    final active = lease ?? acquireMutation();
    if (!identical(_lease, active) || active._released) {
      throw StateError('The library operation is no longer active.');
    }
    try {
      return await action();
    } finally {
      if (lease == null) active.release();
    }
  }

  Future<Database> get database async {
    final opening = _database ??= _initialise();
    try {
      return await opening;
    } catch (_) {
      if (identical(_database, opening)) _database = null;
      rethrow;
    }
  }

  Future<Database> _initialise() async {
    final db = await (_opener?.call() ?? _open());
    await _recoverRestores(db);
    return db;
  }

  Future<Directory> storageDirectory() async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    return directory;
  }

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'mits_kids.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: createSchema,
      onUpgrade: upgradeSchema,
    );
  }

  static Future<void> createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE offline_items (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        source_url TEXT NOT NULL,
        file_path TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        thumbnail_url TEXT,
        author TEXT NOT NULL DEFAULT '',
        channel_id TEXT NOT NULL DEFAULT '',
        content_hash TEXT NOT NULL DEFAULT '',
        approved_at TEXT
      )
    ''');
    await db.execute('CREATE TABLE restore_commits (job_id TEXT PRIMARY KEY)');
  }

  static Future<void> upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      for (final column in ['author', 'channel_id', 'content_hash']) {
        await db.execute(
          "ALTER TABLE offline_items ADD COLUMN $column TEXT NOT NULL DEFAULT ''",
        );
      }
      await db.execute('ALTER TABLE offline_items ADD COLUMN approved_at TEXT');
    }
    if (oldVersion < 3) {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS restore_commits (job_id TEXT PRIMARY KEY)',
      );
    }
  }

  Future<File?> privateFile(String path) async {
    final root = await _directoryProvider();
    if (!await root.exists() || !await File(path).exists()) return null;
    final canonical = await File(path).resolveSymbolicLinks();
    if (p.dirname(canonical) != await root.resolveSymbolicLinks()) return null;
    return File(canonical);
  }

  @override
  Future<File> verifyFile(OfflineItem item) async {
    final file = await privateFile(item.filePath);
    if (item.bytes <= 0 ||
        file == null ||
        await file.length() != item.bytes ||
        (await sha256.bind(file.openRead()).first).toString() !=
            item.contentHash) {
      throw StateError('Saved video failed its integrity check.');
    }
    return file;
  }

  @override
  Future<List<OfflineItem>> all() async {
    final db = await database;
    final rows = await db.query('offline_items', orderBy: 'created_at DESC');
    // Keep damaged and legacy entries available for deliberate parent deletion.
    // Listing must not discard the only record of a file or race publication.
    return rows.map(OfflineItem.fromMap).toList();
  }

  @override
  Future<void> add(OfflineItem item, {OfflineMutationLease? lease}) =>
      _mutating(lease, () async {
        final db = await database;
        await db.transaction((txn) async {
          final existing = await txn.query(
            'offline_items',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [item.id],
          );
          final count =
              Sqflite.firstIntValue(
                await txn.rawQuery('SELECT COUNT(*) FROM offline_items'),
              ) ??
              0;
          if (existing.isEmpty && count >= maxOfflineVideos) {
            throw const LibraryFull();
          }
          await txn.insert(
            'offline_items',
            _record(item),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        });
        notifyListeners();
      });

  static Map<String, Object?> _record(OfflineItem item) => {
    'id': item.id,
    'title': item.title,
    'source_url': item.sourceUrl,
    'file_path': item.filePath,
    'bytes': item.bytes,
    'created_at': item.createdAt.toIso8601String(),
    'thumbnail_url': item.thumbnailUrl,
    'author': item.author,
    'channel_id': item.channelId,
    'content_hash': item.contentHash,
    'approved_at': item.approvedAt?.toUtc().toIso8601String(),
  };

  @override
  Future<void> delete(OfflineItem item, {OfflineMutationLease? lease}) =>
      _mutating(lease, () async {
        final file = await privateFile(item.filePath);
        if (file != null) await file.delete();
        await (await database).delete(
          'offline_items',
          where: 'id = ?',
          whereArgs: [item.id],
        );
        notifyListeners();
      });

  Future<File> verifyRestoreFile(OfflineItem item) async {
    final root = await (await storageDirectory()).resolveSymbolicLinks();
    final file = File(item.filePath);
    final path = await file.resolveSymbolicLinks();
    final parent = p.dirname(path);
    if (await FileSystemEntity.type(item.filePath, followLinks: false) !=
            FileSystemEntityType.file ||
        p.dirname(parent) != root ||
        !RegExp(r'^\.restore-[a-zA-Z0-9-]+$').hasMatch(p.basename(parent)) ||
        await FileSystemEntity.type(
              p.dirname(item.filePath),
              followLinks: false,
            ) !=
            FileSystemEntityType.directory ||
        item.bytes <= 0 ||
        item.bytes > maxDownloadBytes + offlineMuxAllowanceBytes ||
        await file.length() != item.bytes ||
        (await sha256.bind(file.openRead()).first).toString() !=
            item.contentHash ||
        await file.length() != item.bytes) {
      throw StateError('The restored file failed verification.');
    }
    return File(path);
  }

  Future<List<OfflineItem>> addMany(
    List<OfflineItem> staged, {
    required OfflineMutationLease lease,
    required bool Function() authorised,
  }) => _mutating(lease, () async {
    void check() {
      if (!authorised()) throw StateError('Parent approval was interrupted.');
    }

    check();
    if (staged.isEmpty) return <OfflineItem>[];
    if (staged.length > maxOfflineVideos ||
        staged.map((e) => e.id).toSet().length != staged.length) {
      throw const DownloadFailure(
        'The restore contains too many or duplicate videos.',
      );
    }
    final db = await database;
    final root = await storageDirectory();
    final current = await all();
    if (current.length + staged.length > maxOfflineVideos) {
      throw const LibraryFull();
    }
    if (staged.any((entry) => current.any((old) => old.id == entry.id))) {
      throw const DownloadFailure(
        'An existing saved video cannot be replaced by a restore.',
      );
    }
    final sources = <File>[];
    for (final item in staged) {
      if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(item.id) ||
          item.approvedAt == null) {
        throw const DownloadFailure(
          'Fresh parent approval is required for every restored video.',
        );
      }
      sources.add(await verifyRestoreFile(item));
      check();
    }
    final job = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final now = DateTime.now().toUtc();
    final results = <OfflineItem>[
      for (var i = 0; i < staged.length; i++)
        OfflineItem(
          id: staged[i].id,
          title: staged[i].title,
          sourceUrl: staged[i].sourceUrl,
          filePath: p.join(
            root.path,
            '${staged[i].id}-${now.microsecondsSinceEpoch + i}.mp4',
          ),
          bytes: staged[i].bytes,
          createdAt: now,
          author: staged[i].author,
          channelId: staged[i].channelId,
          contentHash: staged[i].contentHash,
          approvedAt: now,
        ),
    ];
    for (final item in results) {
      if (await FileSystemEntity.type(item.filePath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('A restore destination already exists.');
      }
    }
    final journal = File(p.join(root.path, '.restore-journal-$job.json'));
    final pendingJournal = File('${journal.path}.tmp');
    await pendingJournal.writeAsString(
      jsonEncode({
        'version': 1,
        'job': job,
        'files': results.map((item) => p.basename(item.filePath)).toList(),
      }),
      flush: true,
    );
    await pendingJournal.rename(journal.path);
    var committed = false;
    try {
      for (var i = 0; i < sources.length; i++) {
        check();
        await sources[i].rename(results[i].filePath);
      }
      check();
      await db.transaction((txn) async {
        final count =
            Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COUNT(*) FROM offline_items'),
            ) ??
            0;
        if (count + results.length > maxOfflineVideos) {
          throw const LibraryFull();
        }
        for (final item in results) {
          check();
          await txn.insert('offline_items', _record(item));
        }
        await txn.insert('restore_commits', {'job_id': job});
        check();
      });
      committed = true;
      if (!authorised()) {
        await db.transaction((txn) async {
          for (final item in results) {
            await txn.delete(
              'offline_items',
              where: 'id = ? AND file_path = ?',
              whereArgs: [item.id, item.filePath],
            );
          }
          await txn.delete(
            'restore_commits',
            where: 'job_id = ?',
            whereArgs: [job],
          );
        });
        committed = false;
        check();
      }
      // The durable marker stays, so recovery cannot roll back a committed job.
      try {
        await journal.delete();
      } on FileSystemException {
        /* Recovery sees the durable commit marker. */
      }
      notifyListeners();
      return results;
    } catch (_) {
      if (!committed) {
        for (final item in results) {
          final file = await privateFile(item.filePath);
          if (file != null) await file.delete();
        }
        if (await journal.exists()) await journal.delete();
      }
      rethrow;
    }
  });

  Future<void> _recoverRestores(Database db) async {
    final root = await _directoryProvider();
    if (!await root.exists()) return;
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Invalid offline directory.');
    }
    final abandonedStaging = <Directory>[];
    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory &&
          RegExp(
            r'^\.restore-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
          ).hasMatch(name)) {
        abandonedStaging.add(entity);
        continue;
      }
      if (entity is File &&
          RegExp(
            r'^\.restore-journal-[a-f0-9]{32}\.json\.tmp$',
          ).hasMatch(name)) {
        await entity.delete();
        continue;
      }
      if (entity is! File ||
          !RegExp(r'^\.restore-journal-[a-f0-9]{32}\.json$').hasMatch(name)) {
        continue;
      }
      if (await entity.length() > 65536) {
        throw StateError('Invalid restore journal.');
      }
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['job'] is! String ||
          name != '.restore-journal-${decoded['job']}.json' ||
          decoded['files'] is! List ||
          (decoded['files'] as List).length > maxOfflineVideos) {
        throw StateError('Invalid restore journal.');
      }
      final files = <String>[];
      for (final value in decoded['files'] as List) {
        if (value is! String ||
            !RegExp(r'^[a-zA-Z0-9_-]{11}-[0-9]{16,20}\.mp4$').hasMatch(value)) {
          throw StateError('Invalid restore journal path.');
        }
        files.add(value);
      }
      final marker = await db.query(
        'restore_commits',
        where: 'job_id = ?',
        whereArgs: [decoded['job']],
      );
      if (marker.isEmpty) {
        for (final name in files) {
          final path = p.join(root.path, name);
          // An existing database row always wins over an uncommitted journal.
          final references = await db.query(
            'offline_items',
            columns: ['id'],
            where: 'file_path = ?',
            whereArgs: [path],
          );
          if (references.isEmpty &&
              await FileSystemEntity.type(path, followLinks: false) ==
                  FileSystemEntityType.file) {
            final file = await privateFile(path);
            if (file != null) await file.delete();
          }
        }
      }
      await entity.delete();
    }
    // Initialization completes before native inspect is permitted to start.
    // Recursive Directory deletion removes links, never their external targets.
    for (final staging in abandonedStaging) {
      await staging.delete(recursive: true);
    }
  }
}

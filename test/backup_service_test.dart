import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/backup_service.dart';
import 'package:mits_kids_youtube/src/services/offline_limits.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const parentChannel = MethodChannel('test/backup-parent');
  const backupChannel = MethodChannel('test/backup');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const password = 'a separate backup password';
  const id = 'abcdefghijk';
  late Directory directory;
  late Database db;
  late OfflineRepository repository;
  late ParentSession session;
  late SettingsRepository settings;
  late BackupService service;
  late List<MethodCall> calls;
  late Map<String, dynamic> response;
  Future<Map<String, dynamic>>? delayedInspect;
  bool failInspect = false;
  bool failExport = false;
  int token = 0;

  OfflineItem item(String path) => OfflineItem(
    id: id,
    title: 'Reviewed video',
    sourceUrl: 'https://www.youtube.com/watch?v=$id',
    filePath: path,
    bytes: 4,
    createdAt: DateTime.now().toUtc(),
    author: 'Example channel',
    channelId: 'UCabcdefghijklmnopqrstuv',
    contentHash: sha256.convert([1, 2, 3, 4]).toString(),
    approvedAt: DateTime.now().toUtc(),
  );

  Future<void> staged({FilterConfig? rules}) async {
    final stage = await Directory('${directory.path}/.restore-test').create();
    final file = await File('${stage.path}/0.mp4').writeAsBytes([1, 2, 3, 4]);
    final entry = item(file.path);
    response = {
      'job': 'test-job',
      'manifest': jsonEncode({
        'version': 1,
        'videos': [
          {
            'id': entry.id,
            'title': entry.title,
            'author': entry.author,
            'channel_id': entry.channelId,
            'source_url': entry.sourceUrl,
            'bytes': entry.bytes,
            'sha256': entry.contentHash,
          },
        ],
        'rules': rules?.toJson(),
      }),
      'files': [
        {'id': id, 'path': file.path},
      ],
    };
  }

  Future<void> selectRestore() async {
    await service.chooseRestoreArchive();
    expect(session.unlocked, isFalse);
    await session.authenticate('123456');
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('mits-backup-service-');
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
    settings = SettingsRepository();
    token = 0;
    messenger.setMockMethodCallHandler(parentChannel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') return {'token': 'parent-${++token}'};
      return null;
    });
    session = ParentSession(channel: parentChannel);
    await session.initialise();
    await session.authenticate('123456');
    calls = [];
    delayedInspect = null;
    failInspect = false;
    failExport = false;
    response = {};
    messenger.setMockMethodCallHandler(backupChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'chooseExport':
        case 'chooseRestore':
          return {'handle': 'opaque-handle', 'name': 'Family.mitsbackup'};
        case 'export':
          if (failExport) throw PlatformException(code: 'BACKUP_FAILED');
          return {'bytes': 123};
        case 'inspect':
          if (failInspect) throw PlatformException(code: 'BACKUP_FAILED');
          return delayedInspect == null ? response : await delayedInspect;
        case 'discard':
          final stage = Directory('${directory.path}/.restore-test');
          if (await stage.exists()) await stage.delete(recursive: true);
          return null;
        default:
          return null;
      }
    });
    service = BackupService(
      repository: repository,
      settings: settings,
      session: session,
      channel: backupChannel,
    );
  });

  tearDown(() async {
    await service.clear();
    service.dispose();
    session.dispose();
    repository.dispose();
    await db.close();
    await directory.delete(recursive: true);
    messenger.setMockMethodCallHandler(parentChannel, null);
    messenger.setMockMethodCallHandler(backupChannel, null);
  });

  test(
    'picker selection survives lock; no export crypto before a new unlock',
    () async {
      final file = await File(
        '${directory.path}/saved.mp4',
      ).writeAsBytes([1, 2, 3, 4]);
      await repository.add(item(file.path));
      await service.chooseExportDestination();
      expect(session.unlocked, isFalse);
      expect(service.selectionName, 'Family.mitsbackup');
      await service.exportArchive(password, ids: {id});
      expect(calls.where((call) => call.method == 'export'), isEmpty);
      await session.authenticate('123456');
      await service.exportArchive(password, ids: {id});
      expect(calls.where((call) => call.method == 'export'), hasLength(1));
      expect(service.phase, BackupPhase.completed);
      expect(service.hasRestoredRules, isFalse);
      expect(await repository.all(), hasLength(1));
    },
  );

  test('a short PIN-like password never reaches the crypto worker', () async {
    await service.chooseExportDestination();
    await session.authenticate('123456');
    await service.exportArchive('123456');
    expect(calls.where((call) => call.method == 'export'), isEmpty);
    expect(service.error, contains('at least 16'));
  });

  test(
    'failed native export consumes its handle and explains incomplete output',
    () async {
      await service.chooseExportDestination();
      await session.authenticate('123456');
      failExport = true;
      await service.exportArchive(password);
      expect(service.phase, BackupPhase.idle);
      expect(service.error, contains('incomplete archive'));
      expect(calls.where((call) => call.method == 'forget'), hasLength(1));
      await service.exportArchive(password);
      expect(calls.where((call) => call.method == 'export'), hasLength(1));
    },
  );

  test(
    'authenticated inspection stages only; explicit approval publishes fresh records',
    () async {
      await staged();
      await selectRestore();
      await service.inspectArchive(password);
      expect(service.phase, BackupPhase.restoreReview);
      expect(await repository.all(), isEmpty);
      expect(await (await service.previewFile(id)).readAsBytes(), [1, 2, 3, 4]);
      await service.approveRestore({id});
      final restored = (await repository.all()).single;
      expect(restored.approvedAt, isNotNull);
      expect(await repository.verifyFile(restored), isA<File>());
      expect(service.phase, BackupPhase.completed);
      expect(
        await Directory('${directory.path}/.restore-test').exists(),
        isFalse,
      );
    },
  );

  test(
    'wrong password or native authentication failure publishes nothing and releases lease',
    () async {
      await selectRestore();
      failInspect = true;
      await service.inspectArchive(password);
      expect(service.error, isNotNull);
      expect(await repository.all(), isEmpty);
      repository.acquireMutation().release();
    },
  );

  test(
    'lock after acknowledged publication retains a truthful completed result',
    () async {
      await staged();
      await selectRestore();
      await service.inspectArchive(password);
      repository.addListener(session.lock);
      await service.approveRestore({id});
      await service.cancel();
      repository.removeListener(session.lock);
      expect(session.unlocked, isFalse);
      expect(await repository.all(), hasLength(1));
      expect(service.phase, BackupPhase.completed);
      expect(service.status, contains('1 reviewed videos restored'));
    },
  );

  test(
    'late inspect callback after lock cannot offer or publish staged videos',
    () async {
      await staged();
      await selectRestore();
      final pending = Completer<Map<String, dynamic>>();
      delayedInspect = pending.future;
      final inspecting = service.inspectArchive(password);
      while (!calls.any((call) => call.method == 'inspect')) {
        await Future<void>.delayed(Duration.zero);
      }
      session.lock();
      pending.complete(response);
      await inspecting;
      await service.cancel();
      expect(service.phase, BackupPhase.restoreSelected);
      expect(await repository.all(), isEmpty);
      expect(
        await Directory('${directory.path}/.restore-test').exists(),
        isFalse,
      );
      repository.acquireMutation().release();
    },
  );

  test(
    'review holds mutation lease; child reads proceed; lock discards plaintext',
    () async {
      await staged();
      await selectRestore();
      await service.inspectArchive(password);
      expect(repository.acquireMutation, throwsA(isA<DownloadFailure>()));
      expect(await repository.all(), isEmpty);
      session.lock();
      await service.cancel();
      expect(
        await Directory('${directory.path}/.restore-test').exists(),
        isFalse,
      );
      repository.acquireMutation().release();
    },
  );

  test('a duplicate archive never replaces an existing saved video', () async {
    final file = await File(
      '${directory.path}/existing.mp4',
    ).writeAsBytes([1, 2, 3, 4]);
    await repository.add(item(file.path));
    await staged();
    await selectRestore();
    await service.inspectArchive(password);
    expect(service.items.single.eligible, isFalse);
    await service.approveRestore({id});
    expect(service.error, isNotNull);
    expect((await repository.all()).single.filePath, file.path);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'archived rules stay inactive until separately applied after approval',
    () async {
      const rules = FilterConfig(
        blockedChannels: ['another channel'],
        blockedKeywords: [],
        blockShorts: true,
        blockLive: true,
      );
      await staged(rules: rules);
      await selectRestore();
      await service.inspectArchive(password);
      await service.approveRestore({});
      expect(await repository.all(), isEmpty);
      expect((await settings.loadConfig()).blockedChannels, isEmpty);
      expect(service.hasRestoredRules, isTrue);
      await service.applyRestoredRules();
      expect((await settings.loadConfig()).blockedChannels, [
        'another channel',
      ]);
      expect(service.hasRestoredRules, isFalse);
    },
  );

  test(
    'rule changes after inspection prevent newly blocked publication',
    () async {
      await staged();
      await selectRestore();
      await service.inspectArchive(password);
      await settings.saveConfig(
        const FilterConfig(
          blockedChannels: [],
          blockedKeywords: ['reviewed'],
          blockShorts: true,
          blockLive: true,
        ),
        session,
      );
      await service.approveRestore({id});
      expect(await repository.all(), isEmpty);
      expect(service.error, contains('no longer allowed'));
    },
  );

  test(
    'staged path escape is refused without touching the outside file',
    () async {
      await staged();
      final outside = await Directory.systemTemp.createTemp(
        'mits-backup-outside-',
      );
      try {
        final file = await File(
          '${outside.path}/private.mp4',
        ).writeAsBytes([1, 2, 3, 4]);
        response['files'] = [
          {'id': id, 'path': file.path},
        ];
        await selectRestore();
        await service.inspectArchive(password);
        expect(service.error, isNotNull);
        expect(await repository.all(), isEmpty);
        expect(await file.readAsBytes(), [1, 2, 3, 4]);
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
}

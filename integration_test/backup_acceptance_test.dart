import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/android_offline_muxer.dart';
import 'package:mits_kids_youtube/src/services/backup_service.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';

import 'fixtures/media_fixture.dart';

// The two real Android document-picker steps are driven by the emulator test
// operator. All content, PIN and password here belong to the validation app.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('encrypted SAF export and freshly approved restore preserve media', (
    tester,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    if (!documents.path.contains(
      '/com.example.mits_kids_youtube.validation/',
    )) {
      throw StateError(
        'Refusing backup fixture test on the production installation.',
      );
    }
    final repository = OfflineRepository();
    final session = ParentSession();
    final backups = BackupService(
      repository: repository,
      settings: SettingsRepository(),
      session: session,
    );
    const id = 'BackupVid01';
    const password = 'validation archive password only';
    Directory? staging;
    VideoPlayerController? player;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('MITS isolated backup acceptance test')),
          ),
        ),
      );
      await session.initialise();
      await session.authenticate('706291');
      final root = await repository.storageDirectory();
      for (final old in await repository.all()) {
        if (old.id == id) await repository.delete(old);
      }
      staging = await root.createTemp('.pending-');
      final video = await File(
        p.join(staging.path, 'video.part'),
      ).writeAsBytes(base64Decode(videoFixture));
      final audio = await File(
        p.join(staging.path, 'audio.part'),
      ).writeAsBytes(base64Decode(audioFixture));
      final output = File(p.join(staging.path, 'ready.mp4'));
      await AndroidOfflineMuxer().combine(video, audio, output);
      final hash = (await sha256.bind(output.openRead()).first).toString();
      final finalFile = await output.rename(
        p.join(root.path, '$id-${DateTime.now().microsecondsSinceEpoch}.mp4'),
      );
      final item = OfflineItem(
        id: id,
        title: 'Native codec fixture',
        sourceUrl: 'https://www.youtube.com/watch?v=$id',
        filePath: finalFile.path,
        bytes: await finalFile.length(),
        createdAt: DateTime.now().toUtc(),
        author: 'MITS validation',
        channelId: 'UCaaaaaaaaaaaaaaaaaaaaaa',
        contentHash: hash,
        approvedAt: DateTime.now().toUtc(),
      );
      await repository.add(item);
      debugPrint('BACKUP_TEST: select Save in Android export picker.');
      await backups.chooseExportDestination();
      expect(backups.phase, BackupPhase.exportSelected);
      expect(session.unlocked, isFalse);
      debugPrint(
        'BACKUP_TEST: export selected ${backups.selectionName}; parent is locked.',
      );
      await session.authenticate('706291');
      await backups.exportArchive(password, ids: {id});
      expect(backups.error, isNull);
      expect(backups.phase, BackupPhase.completed);
      await repository.delete(item);
      debugPrint(
        'BACKUP_TEST: select the just-created MITS encrypted archive in Android restore picker.',
      );
      await backups.chooseRestoreArchive();
      expect(backups.phase, BackupPhase.restoreSelected);
      expect(session.unlocked, isFalse);
      await session.authenticate('706291');
      await backups.inspectArchive('deliberately incorrect backup password');
      expect(backups.error, isNotNull);
      expect((await repository.all()).where((item) => item.id == id), isEmpty);
      await backups.inspectArchive(password);
      expect(backups.error, isNull);
      expect(backups.phase, BackupPhase.restoreReview);
      expect((await repository.all()).where((item) => item.id == id), isEmpty);
      await backups.approveRestore({id});
      expect(backups.error, isNull);
      expect(backups.phase, BackupPhase.completed);
      final restored = (await repository.all()).singleWhere(
        (item) => item.id == id,
      );
      expect(restored.contentHash, hash);
      expect(restored.filePath, isNot(item.filePath));
      player = VideoPlayerController.file(
        await repository.verifyFile(restored),
      );
      await player.initialize();
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await player.position, greaterThan(Duration.zero));
      await player.pause();
      expect(player.value.hasError, isFalse);
      await player.dispose();
      player = null;
      await repository.delete(restored);
      debugPrint(
        'BACKUP_TEST: PASS export, mandatory relock, wrong-password rejection, fresh approval, same hash, native restored playback.',
      );
    } finally {
      await player?.dispose();
      await backups.clear();
      backups.dispose();
      session.dispose();
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

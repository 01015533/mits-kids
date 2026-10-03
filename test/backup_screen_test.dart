import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';
import 'package:mits_kids_youtube/src/screens/backup_screen.dart';
import 'package:mits_kids_youtube/src/services/backup_service.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';
import 'package:mits_kids_youtube/src/services/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Item implements BackupItem {
  const _Item(this.id, this.title, {this.eligible = true, this.reason});
  @override
  final String id;
  @override
  final String title;
  @override
  final bool eligible;
  @override
  final String? reason;
  @override
  String get author => 'Reviewed channel';
  @override
  int get bytes => 1048576;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backup extends ChangeNotifier implements BackupService {
  _Backup(this.session, this.phase);
  @override
  final ParentSession session;
  @override
  final settings = SettingsRepository();
  @override
  BackupPhase phase;
  @override
  bool busy = false;
  @override
  String? error;
  @override
  String status = '';
  @override
  String? selectionName = 'Family videos.mitsbackup';
  @override
  List<BackupItem> items = [const _Item('one', 'Reviewed animal video')];
  @override
  FilterConfig? restoredRules;
  @override
  bool get hasRestoredRules =>
      phase == BackupPhase.completed && restoredRules != null;
  @override
  bool get canResume => phase != BackupPhase.idle;
  String? exportedPassword;
  Set<String>? exportedIds;
  Set<String>? approvedIds;
  int appliedRules = 0;

  @override
  Future<void> exportArchive(
    String password, {
    bool includeRules = true,
    Set<String>? ids,
  }) async {
    exportedPassword = password;
    exportedIds = ids;
    phase = BackupPhase.completed;
    status = 'Encrypted backup saved.';
    notifyListeners();
  }

  @override
  Future<void> approveRestore(Set<String> ids) async {
    approvedIds = ids;
    phase = BackupPhase.completed;
    status = 'Selected videos restored.';
    notifyListeners();
  }

  @override
  Future<void> applyRestoredRules() async {
    appliedRules++;
    restoredRules = null;
    status = 'Archived rules applied.';
    notifyListeners();
  }

  @override
  Future<void> clear() async {
    phase = BackupPhase.idle;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mits_kids/parent_security');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'filter_config_v1': '{"blockedKeywords":["unsafe"]}',
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') return {'token': 'parent'};
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<ParentSession> unlocked() async {
    final session = ParentSession();
    await session.initialise();
    await session.authenticate('123456');
    return session;
  }

  testWidgets(
    'export requires matching separate password and selected eligible entries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = await unlocked();
      final service = _Backup(session, BackupPhase.exportSelected);
      addTearDown(session.dispose);
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(home: BackupScreen(service: service)),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'long backup password');
      await tester.enterText(fields.at(1), 'different password');
      await tester.tap(find.text('Export encrypted backup'));
      await tester.pumpAndSettle();
      expect(service.exportedPassword, isNull);
      expect(
        find.text('Enter the same backup password twice.'),
        findsOneWidget,
      );
      await tester.enterText(fields.at(1), 'long backup password');
      await tester.tap(find.text('Export encrypted backup'));
      await tester.pumpAndSettle();
      expect(service.exportedPassword, 'long backup password');
      expect(service.exportedIds, {'one'});
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Encrypted backup saved.'), findsOneWidget);
      session.lock();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'restore requires explicit video selection and separate rules confirmation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = await unlocked();
      final service = _Backup(session, BackupPhase.restoreReview)
        ..items = [
          const _Item('one', 'Reviewed animal video'),
          const _Item(
            'existing',
            'Existing video',
            eligible: false,
            reason: 'Already saved. Keeping the current copy.',
          ),
        ]
        ..restoredRules = FilterConfig.defaults;
      addTearDown(session.dispose);
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(home: BackupScreen(service: service)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Approve & restore 0 videos'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.widgetWithText(CheckboxListTile, 'Reviewed animal video'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve & restore 1 video'));
      await tester.pumpAndSettle();
      expect(service.approvedIds, {'one'});
      expect(service.appliedRules, 0);
      await tester.tap(find.text('Review archived rules'));
      await tester.pumpAndSettle();
      expect(find.text('Blocked title keywords: unsafe'), findsOneWidget);
      expect(find.text('Blocked title keywords: None'), findsOneWidget);
      await tester.tap(find.text('Keep current rules'));
      await tester.pumpAndSettle();
      expect(service.appliedRules, 0);
      await tester.tap(find.text('Review archived rules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply archived rules'));
      await tester.pumpAndSettle();
      expect(service.appliedRules, 1);
      session.lock();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('locking hides backup metadata and discards password entry', (
    tester,
  ) async {
    final session = await unlocked();
    final service = _Backup(session, BackupPhase.restoreSelected);
    addTearDown(session.dispose);
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(home: BackupScreen(service: service)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'long backup password');
    session.lock();
    await tester.pumpAndSettle();
    expect(
      find.text('Selected document: Family videos.mitsbackup'),
      findsNothing,
    );
    expect(find.byType(TextField), findsNothing);
    await session.authenticate('123456');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    session.lock();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'rules-only review changes no videos and does not apply rules automatically',
    (tester) async {
      final session = await unlocked();
      final service = _Backup(session, BackupPhase.restoreReview)
        ..items = []
        ..restoredRules = FilterConfig.defaults;
      addTearDown(session.dispose);
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(home: BackupScreen(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep current videos and review rules only'));
      await tester.pumpAndSettle();
      expect(service.approvedIds, isEmpty);
      expect(service.appliedRules, 0);
      expect(find.text('Review archived rules'), findsOneWidget);
      session.lock();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

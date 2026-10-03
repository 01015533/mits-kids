import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mits_kids_youtube/src/app.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/download_service.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';

class _Library extends OfflineRepository {
  @override
  Future<List<OfflineItem>> all() async => [];
}

class _Download extends ChangeNotifier implements DownloadService {
  @override
  bool busy = false;
  @override
  bool approved = false;
  @override
  bool canCancel = false;
  @override
  double? progress;
  @override
  String status = '';
  @override
  String? lastError;
  @override
  OfflineItem? lastSaved;
  int cancellations = 0;

  void begin({required bool afterApproval}) {
    busy = true;
    approved = afterApproval;
    canCancel = true;
    progress = afterApproval ? 0.25 : null;
    status = afterApproval
        ? 'Downloading parent-only video title'
        : 'Preparing download…';
    notifyListeners();
  }

  @override
  void cancelForLock() {
    if (busy && !approved) cancel();
  }

  @override
  void cancel() {
    cancellations++;
    busy = false;
    approved = false;
    canCancel = false;
    status = 'Download cancelled';
    lastError = 'Download cancelled.';
    notifyListeners();
  }

  void finish({bool success = true}) {
    busy = false;
    approved = false;
    canCancel = false;
    status = success ? 'Saved for offline viewing' : 'Download not saved';
    lastError = success
        ? null
        : 'The connection was interrupted. Reconnect and retry.';
    lastSaved = success
        ? OfflineItem(
            id: 'abcdefghijk',
            title: 'Reviewed video',
            sourceUrl: 'https://www.youtube.com/watch?v=abcdefghijk',
            filePath: '/unused',
            bytes: 100,
            createdAt: DateTime.utc(2026),
          )
        : null;
    notifyListeners();
  }

  @override
  void clearResult() {
    if (busy) return;
    status = '';
    lastError = null;
    lastSaved = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ParentBrowser extends StatefulWidget {
  const _ParentBrowser({required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<_ParentBrowser> createState() => _ParentBrowserState();
}

class _ParentBrowserState extends State<_ParentBrowser> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Test parent browser'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/approved-download-parent');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ParentSession session;
  late _Library library;
  late _Download download;
  late int browserDisposals;
  late int authentications;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    browserDisposals = 0;
    authentications = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') {
        authentications++;
        return {'token': 'parent'};
      }
      return null;
    });
    session = ParentSession(
      channel: channel,
      lifetime: const Duration(seconds: 5),
    );
    library = _Library();
    download = _Download();
  });

  tearDown(() {
    session.dispose();
    library.dispose();
    download.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Widget app() => MaterialApp(
    home: AppShell(
      session: session,
      repository: library,
      downloader: download,
      browserBuilder: (_, __) =>
          _ParentBrowser(onDispose: () => browserDisposals++),
    ),
  );

  Future<void> openParentBrowser(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browse · Parent'));
    await tester.pumpAndSettle();
    expect(find.text('Test parent browser'), findsNothing);
    await session.authenticate('123456');
    await tester.pumpAndSettle();
    expect(find.text('Test parent browser'), findsOneWidget);
  }

  testWidgets(
    'approved save remains visible while parent browser and settings lock',
    (tester) async {
      await openParentBrowser(tester);
      download.begin(afterApproval: true);
      await tester.pumpAndSettle();
      session.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(session.unlocked, isFalse);
      expect(browserDisposals, 1);
      expect(find.text('Test parent browser'), findsNothing);
      expect(download.busy, isTrue);
      expect(download.cancellations, 0);
      await tester.tap(find.text('Offline'));
      await tester.pumpAndSettle();
      expect(find.text('Saving approved video'), findsOneWidget);
      expect(find.text('25% · Saving on this tablet'), findsOneWidget);
      expect(find.text('Downloading parent-only video title'), findsNothing);
      await tester.tap(find.text('Parent'));
      await tester.pumpAndSettle();
      expect(find.text('Parent access'), findsOneWidget);
      expect(find.text('Save settings'), findsNothing);
      expect(find.text('Change parent PIN'), findsNothing);
      download.finish();
      await tester.pumpAndSettle();
      expect(find.text('Saved for offline viewing'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss save message'));
      await tester.pumpAndSettle();
      expect(find.text('Saved for offline viewing'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'child can stop an approved save without unlocking parent access',
    (tester) async {
      await openParentBrowser(tester);
      download.begin(afterApproval: true);
      await tester.tap(find.text('Offline'));
      await tester.pumpAndSettle();
      final beforeCancel = authentications;
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(download.cancellations, 1);
      expect(session.unlocked, isFalse);
      expect(authentications, beforeCancel);
      expect(find.text('Download cancelled'), findsOneWidget);
      expect(find.text('Saving approved video'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('preapproval work still cancels when parent access locks', (
    tester,
  ) async {
    await openParentBrowser(tester);
    download.begin(afterApproval: false);
    await tester.pump();
    session.lock();
    await tester.pumpAndSettle();
    expect(download.cancellations, 1);
    expect(download.busy, isFalse);
    expect(browserDisposals, 1);
    expect(find.text('Saving approved video'), findsNothing);
    expect(find.text('Test parent browser'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'session expiry does not extend parent privileges or stop an approved job',
    (tester) async {
      await openParentBrowser(tester);
      download.begin(afterApproval: true);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(session.unlocked, isFalse);
      expect(browserDisposals, 1);
      expect(download.busy, isTrue);
      expect(download.cancellations, 0);
      expect(find.text('Parent access'), findsOneWidget);
      download.finish(success: false);
      await tester.pumpAndSettle();
      expect(find.text('Download not saved'), findsOneWidget);
      expect(
        find.text('The connection was interrupted. Reconnect and retry.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

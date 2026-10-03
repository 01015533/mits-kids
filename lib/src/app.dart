import 'package:flutter/material.dart';

import 'screens/browser_screen.dart';
import 'screens/library_screen.dart';
import 'screens/parent_screen.dart';
import 'screens/parent_gate.dart';
import 'services/parent_session.dart';
import 'services/settings_repository.dart';
import 'services/android_offline_muxer.dart';
import 'services/download_service.dart';
import 'services/offline_repository.dart';
import 'services/youtube_video_source.dart';
import 'services/backup_service.dart';
import 'services/android_download_job.dart';

class MitsKidsApp extends StatelessWidget {
  const MitsKidsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1769E0),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MITS Kids',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF07111F),
        cardTheme: const CardThemeData(color: Color(0xFF101E31)),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({
    this.session,
    this.repository,
    this.downloader,
    this.browserBuilder,
    super.key,
  });

  // Injected dependencies remain owned by their caller, allowing lifecycle
  // tests to exercise the real gates without an Android platform view.
  final ParentSession? session;
  final OfflineRepository? repository;
  final DownloadService? downloader;
  final Widget Function(DownloadService, ParentSession)? browserBuilder;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 1;
  late final ParentSession session;
  late final OfflineRepository repository;
  late final DownloadService downloader;
  late final backups = BackupService(
    repository: repository,
    settings: SettingsRepository(),
    session: session,
  );

  @override
  void initState() {
    super.initState();
    session = widget.session ?? ParentSession();
    repository = widget.repository ?? OfflineRepository();
    downloader =
        widget.downloader ??
        DownloadService(
          repository,
          sourceFactory: YoutubeVideoSource.new,
          muxer: AndroidOfflineMuxer(),
          parentToken: () => session.unlocked ? session.token : null,
          ruleLoader: SettingsRepository().loadConfig,
          jobLifecycle: AndroidDownloadJob(),
        );
    session.addListener(parentChanged);
    session.initialise();
  }

  void parentChanged() {
    if (!session.unlocked) {
      // An explicit approval authorizes only its existing save, never Browse
      // or Parent. Preparation which has not been approved is still revoked.
      downloader.cancelForLock();
      if (index != 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !session.unlocked) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        });
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    backups.dispose();
    if (widget.downloader == null) downloader.dispose();
    session.removeListener(parentChanged);
    if (widget.session == null) session.dispose();
    // A final in-flight save may still notify the repository during teardown.
    super.dispose();
  }

  Widget statusPanel(BoxConstraints constraints, Widget child) =>
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.4),
        child: SingleChildScrollView(child: child),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: downloader,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: !session.ready
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(session.error ?? 'Starting parent security…'),
                    if (session.error != null)
                      TextButton(
                        onPressed: session.initialise,
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              )
            : !session.configured
            ? ParentGate(session: session)
            : LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    if (downloader.busy &&
                        (session.unlocked || downloader.approved))
                      statusPanel(
                        constraints,
                        Material(
                          color: const Color(0xFF152A43),
                          child: Column(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.downloading),
                                title: Text(
                                  downloader.approved
                                      ? 'Saving approved video'
                                      : downloader.status,
                                ),
                                subtitle: Text(
                                  downloader.progress == null
                                      ? downloader.approved
                                            ? 'You can leave the app. Parent access still locks.'
                                            : 'A parent must review and approve this video.'
                                      : '${(downloader.progress! * 100).floor()}% · Saving on this tablet',
                                ),
                                trailing: downloader.canCancel
                                    ? TextButton(
                                        onPressed: downloader.cancel,
                                        child: const Text('Cancel'),
                                      )
                                    : null,
                              ),
                              LinearProgressIndicator(
                                value: downloader.progress,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (!downloader.busy && downloader.status.isNotEmpty)
                      statusPanel(
                        constraints,
                        Material(
                          color: const Color(0xFF152A43),
                          child: Semantics(
                            liveRegion: true,
                            child: ListTile(
                              leading: Icon(
                                downloader.lastError == null
                                    ? Icons.offline_pin_outlined
                                    : Icons.info_outline,
                              ),
                              title: Text(downloader.status),
                              subtitle: downloader.lastSaved != null
                                  ? const Text(
                                      'Saved on this tablet. Offline shows videos allowed by your rules.',
                                    )
                                  : downloader.lastError != null
                                  ? Text(downloader.lastError!)
                                  : null,
                              trailing: IconButton(
                                tooltip: 'Dismiss save message',
                                onPressed: downloader.clearResult,
                                icon: const Icon(Icons.close),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: IndexedStack(
                        index: index,
                        children: [
                          if (index == 0 && session.unlocked)
                            widget.browserBuilder?.call(downloader, session) ??
                                BrowserScreen(
                                  downloader: downloader,
                                  session: session,
                                )
                          else if (index == 0)
                            ParentGate(session: session)
                          else
                            const SizedBox.shrink(),
                          LibraryScreen(
                            repository: repository,
                            settings: SettingsRepository(),
                          ),
                          if (index == 2 && session.unlocked)
                            ParentScreen(
                              session: session,
                              library: repository,
                              backup: backups,
                            )
                          else if (index == 2)
                            ParentGate(session: session)
                          else
                            const SizedBox.shrink(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() {
          index = value;
          if (value == 1) session.lock();
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            label: 'Browse · Parent',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_done),
            label: 'Offline',
          ),
          NavigationDestination(
            icon: Icon(Icons.admin_panel_settings_outlined),
            label: 'Parent',
          ),
        ],
      ),
    ),
  );
}

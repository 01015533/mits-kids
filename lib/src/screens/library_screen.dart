import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/offline_item.dart';
import '../services/offline_repository.dart';
import '../services/offline_thumbnails.dart';
import '../services/settings_repository.dart';
import '../services/playback_policy.dart';
import 'player_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.repository,
    required this.settings,
    this.thumbnails,
    super.key,
  });
  final SettingsRepository settings;
  final OfflineRepository repository;
  final OfflineThumbnails? thumbnails;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<OfflineItem>> items;
  late final OfflineThumbnails _thumbnails =
      widget.thumbnails ?? OfflineThumbnails();
  // Keyed by saved file path, which is unique for every save of a video.
  final _pictures = <String, Uint8List>{};
  final _withoutPicture = <String>{};
  List<OfflineItem> _wanted = const [];
  Set<String>? _savedFiles;
  int _loads = 0;
  bool _picturesBusy = false;

  @override
  void initState() {
    super.initState();
    items = loadApproved();
    widget.repository.addListener(refresh);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resume pictures once a covering route, such as the player, has closed.
    if (ModalRoute.isCurrentOf(context) != false) unawaited(_loadPictures());
  }

  @override
  void dispose() {
    widget.repository.removeListener(refresh);
    super.dispose();
  }

  void refresh() {
    if (mounted) {
      setState(() {
        items = loadApproved();
      });
    }
  }

  Future<List<OfflineItem>> loadApproved() async {
    final load = ++_loads;
    final rules = await widget.settings.loadConfig();
    final records = await widget.repository.all();
    final available = <OfflineItem>[];
    for (final item in records) {
      if (!PlaybackPolicy.allows(item, rules)) continue;
      try {
        final file = await widget.repository.privateFile(item.filePath);
        if (file != null &&
            item.bytes > 0 &&
            await file.length() == item.bytes) {
          available.add(item);
        }
      } catch (_) {
        // Keep unavailable records for a parent to review and delete.
      }
    }
    if (mounted && load == _loads) _showPictures(records, available);
    return available;
  }

  void _showPictures(List<OfflineItem> records, List<OfflineItem> available) {
    final saved = {for (final item in records) item.filePath};
    if (!setEquals(saved, _savedFiles)) {
      _savedFiles = saved;
      _pictures.removeWhere((path, _) => !saved.contains(path));
      _withoutPicture.removeWhere((path) => !saved.contains(path));
      unawaited(_thumbnails.removeUnused(records));
    }
    _wanted = available;
    unawaited(_loadPictures());
  }

  // The Android decoder behind scene previews serves only its newest session.
  // Never start a picture while another route, such as the player, is on top.
  bool get _mayCreatePictures =>
      mounted && ModalRoute.isCurrentOf(context) != false;

  Future<void> _loadPictures() async {
    if (_picturesBusy) return;
    _picturesBusy = true;
    try {
      // Show every stored picture before spending time decoding new ones.
      for (final item in List.of(_wanted)) {
        if (!mounted) return;
        if (_pictures.containsKey(item.filePath) ||
            _withoutPicture.contains(item.filePath)) {
          continue;
        }
        final stored = await _thumbnails.stored(item);
        if (stored != null && mounted) {
          setState(() => _pictures[item.filePath] = stored);
        }
      }
      while (_mayCreatePictures) {
        final item = _wanted
            .where(
              (entry) =>
                  !_pictures.containsKey(entry.filePath) &&
                  !_withoutPicture.contains(entry.filePath),
            )
            .firstOrNull;
        if (item == null) return;
        Uint8List? picture;
        try {
          picture = await _thumbnails.stored(item);
          if (picture == null) {
            final video = await widget.repository.privateFile(item.filePath);
            if (video != null) picture = await _thumbnails.create(item, video);
          }
        } catch (_) {
          // The placeholder remains; playback does not depend on pictures.
        }
        if (!mounted) return;
        final made = picture;
        if (made != null) {
          setState(() => _pictures[item.filePath] = made);
        } else if (_mayCreatePictures) {
          // A covering route may have replaced the request; retry only those.
          _withoutPicture.add(item.filePath);
        }
      }
    } finally {
      _picturesBusy = false;
    }
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(refresh);
      widget.repository.addListener(refresh);
    }
    items = loadApproved();
  }

  void _open(OfflineItem item) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        item: item,
        repository: widget.repository,
        settings: widget.settings,
      ),
    ),
  );

  Widget _placeholder(ColorScheme colors) => Center(
    child: Icon(Icons.movie_outlined, size: 40, color: colors.onSurfaceVariant),
  );

  Widget _videoCard(BuildContext context, OfflineItem item) {
    final theme = Theme.of(context);
    final picture = _pictures[item.filePath];
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: picture == null
                              ? _placeholder(theme.colorScheme)
                              : Image.memory(
                                  picture,
                                  key: ValueKey(item.filePath),
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  excludeFromSemantics: true,
                                  errorBuilder: (_, _, _) =>
                                      _placeholder(theme.colorScheme),
                                ),
                        ),
                        const Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.play_arrow,
                                size: 36,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(item.bytes / 1048576).toStringAsFixed(1)} MiB · Available offline',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Offline videos'),
      actions: [
        IconButton(
          tooltip: 'Refresh library',
          onPressed: refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<List<OfflineItem>>(
      future: items,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not open the offline library.'),
                TextButton(onPressed: refresh, child: const Text('Retry')),
              ],
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final library = snapshot.data!;
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.offline_pin_outlined),
              title: Text(
                '${library.length} ${library.length == 1 ? 'video' : 'videos'} available to watch',
              ),
              subtitle: const Text('Parent-approved · Ready without internet'),
            ),
            const Divider(height: 1),
            Expanded(
              child: library.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'No approved videos are available.\nAsk a parent to review and save videos in Browse.\nUp to 8 videos stay on this tablet.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        // Cards are at least 240 wide, with 12 between them.
                        final columns = math.max(
                          1,
                          ((constraints.maxWidth - 12) / 252).floor(),
                        );
                        final rows = (library.length / columns).ceil();
                        return ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: rows,
                          itemBuilder: (context, row) => Padding(
                            padding: EdgeInsets.only(
                              bottom: row == rows - 1 ? 0 : 12,
                            ),
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (
                                    var column = 0;
                                    column < columns;
                                    column++
                                  ) ...[
                                    if (column > 0) const SizedBox(width: 12),
                                    Expanded(
                                      child:
                                          row * columns + column <
                                              library.length
                                          ? _videoCard(
                                              context,
                                              library[row * columns + column],
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}

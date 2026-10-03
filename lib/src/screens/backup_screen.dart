import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/filter_config.dart';
import '../services/backup_service.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({required this.service, super.key});
  final BackupService service;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final password = TextEditingController();
  final confirmation = TextEditingController();
  final selected = <String>{};
  bool includeRules = true;
  String? formError;
  late BackupPhase previousPhase;

  @override
  void initState() {
    super.initState();
    previousPhase = widget.service.phase;
    if (previousPhase == BackupPhase.exportSelected) {
      selected.addAll(
        widget.service.items
            .where((item) => item.eligible)
            .map((item) => item.id),
      );
    }
    widget.service.addListener(changed);
    widget.service.session.addListener(changed);
  }

  void changed() {
    if (!mounted) return;
    if (!widget.service.session.unlocked ||
        widget.service.phase != previousPhase) {
      password.clear();
      confirmation.clear();
      formError = null;
    }
    if (widget.service.phase != previousPhase) {
      selected.clear();
      if (widget.service.phase == BackupPhase.exportSelected) {
        selected.addAll(
          widget.service.items
              .where((item) => item.eligible)
              .map((item) => item.id),
        );
      }
      previousPhase = widget.service.phase;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.service.removeListener(changed);
    widget.service.session.removeListener(changed);
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => formError = null);
    try {
      await action();
    } catch (_) {
      if (mounted && widget.service.session.unlocked) {
        setState(
          () => formError =
              widget.service.error ??
              'The backup operation could not finish. Please try again.',
        );
      }
    }
  }

  Future<void> submitPassword({required bool exporting}) async {
    final value = password.text;
    if (value.runes.length < 16 || utf8.encode(value).length > 1024) {
      setState(
        () => formError =
            'Use a separate backup password of at least 16 characters (up to 1,024 bytes).',
      );
      return;
    }
    if (exporting && value != confirmation.text) {
      setState(() => formError = 'Enter the same backup password twice.');
      return;
    }
    password.clear();
    confirmation.clear();
    await run(
      () => exporting
          ? widget.service.exportArchive(
              value,
              includeRules: includeRules,
              ids: Set.of(selected),
            )
          : widget.service.inspectArchive(value),
    );
  }

  Future<void> reviewRules() async {
    final restored = widget.service.restoredRules;
    if (restored == null) return;
    final current = await widget.service.settings.loadConfig();
    if (!mounted || !widget.service.session.unlocked) return;
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace current content rules?'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Archived rules may allow videos that are currently blocked. Review both sets before choosing to apply them.',
            ),
            const SizedBox(height: 16),
            ruleSummary('Current rules', current),
            const SizedBox(height: 16),
            ruleSummary('Archived rules', restored),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep current rules'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply archived rules'),
          ),
        ],
      ),
    );
    if (apply == true && mounted && widget.service.session.unlocked) {
      await run(widget.service.applyRestoredRules);
    }
  }

  Widget ruleSummary(String title, FilterConfig config) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      Text(
        'Blocked channels: ${config.blockedChannels.isEmpty ? 'None' : config.blockedChannels.join(', ')}',
      ),
      Text(
        'Blocked title keywords: ${config.blockedKeywords.isEmpty ? 'None' : config.blockedKeywords.join(', ')}',
      ),
      Text('Hide Shorts: ${config.blockShorts ? 'Yes' : 'No'}'),
      Text('Hide live streams: ${config.blockLive ? 'Yes' : 'No'}'),
    ],
  );

  Widget passwordField(TextEditingController controller, String label) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 1024,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            counterText: '',
          ),
        ),
      );

  Widget videoChoices({required bool restoring}) {
    final items = widget.service.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isEmpty)
          const Text('No videos are available for this backup.'),
        for (final item in items)
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckboxListTile(
                  value: selected.contains(item.id),
                  onChanged: item.eligible
                      ? (checked) => setState(() {
                          if (checked == true) {
                            selected.add(item.id);
                          } else {
                            selected.remove(item.id);
                          }
                        })
                      : null,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(item.title),
                  subtitle: Text(
                    '${item.author} · ${(item.bytes / 1048576).toStringAsFixed(1)} MiB${item.reason == null ? '' : '\n${item.reason}'}',
                  ),
                ),
                if (item.eligible)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _BackupPreviewScreen(
                            service: widget.service,
                            item: item,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.play_circle_outline),
                      label: Text(
                        restoring ? 'Review restored video' : 'Preview video',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Text(
          '${selected.length} ${selected.length == 1 ? 'video selected' : 'videos selected'}',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    if (!service.session.unlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('Parent access locked')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Unlock Parent again, then choose Encrypted backups to continue.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final exporting = service.phase == BackupPhase.exportSelected;
    return Scaffold(
      appBar: AppBar(title: const Text('Encrypted backups')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Save a password-protected copy of reviewed videos, or restore from a MITS backup. Your parent PIN stays on this tablet.',
          ),
          const SizedBox(height: 12),
          if (service.selectionName != null)
            Text('Selected document: ${service.selectionName}'),
          if (formError != null || service.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  formError ?? service.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          if (service.busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(service.status)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => run(service.cancel),
              child: const Text('Cancel backup operation'),
            ),
          ] else if (service.phase == BackupPhase.idle) ...[
            const Text(
              'Android will ask where to save or open the archive. That location may sync to a cloud account. Returning from the file picker locks parent access; unlock again to continue.',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => run(service.chooseExportDestination),
              icon: const Icon(Icons.save_alt),
              label: const Text('Choose backup destination'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => run(service.chooseRestoreArchive),
              icon: const Icon(Icons.restore),
              label: const Text('Choose backup to restore'),
            ),
          ] else if (exporting ||
              service.phase == BackupPhase.restoreSelected) ...[
            const SizedBox(height: 16),
            if (exporting) ...[
              const Text(
                'Choose the reviewed videos to include. Videos without approval, blocked by current rules or unavailable on this tablet cannot be exported.',
              ),
              const SizedBox(height: 12),
              videoChoices(restoring: false),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: includeRules,
                onChanged: (value) => setState(() => includeRules = value),
                title: const Text('Include current content rules'),
              ),
            ],
            const Text(
              'Use a separate password of at least 16 characters, such as a long multiword phrase. Keep it somewhere safe: a forgotten backup password cannot be recovered. It is separate from your parent PIN.',
            ),
            passwordField(
              password,
              exporting ? 'New backup password' : 'Backup password',
            ),
            if (exporting)
              passwordField(confirmation, 'Confirm backup password'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: exporting && selected.isEmpty && !includeRules
                  ? null
                  : () => submitPassword(exporting: exporting),
              child: Text(
                exporting
                    ? 'Export encrypted backup'
                    : 'Open backup for review',
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => run(service.clear),
              child: const Text('Choose a different document'),
            ),
          ] else if (service.phase == BackupPhase.restoreReview) ...[
            const SizedBox(height: 16),
            const Text(
              'Review each video and select only those you approve for your child. Existing downloads and current content rules are kept. Duplicate videos are not replaced.',
            ),
            const SizedBox(height: 12),
            videoChoices(restoring: true),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => run(() => service.approveRestore(Set.of(selected))),
              child: Text(
                'Approve & restore ${selected.length} ${selected.length == 1 ? 'video' : 'videos'}',
              ),
            ),
            if (selected.isEmpty && service.restoredRules != null)
              OutlinedButton(
                onPressed: () => run(() => service.approveRestore({})),
                child: const Text('Keep current videos and review rules only'),
              ),
            TextButton(
              onPressed: () => run(service.clear),
              child: const Text('Discard this restore'),
            ),
          ] else if (service.phase == BackupPhase.completed) ...[
            const SizedBox(height: 16),
            Semantics(liveRegion: true, child: Text(service.status)),
            if (service.hasRestoredRules) ...[
              const SizedBox(height: 12),
              const Text(
                'Your current content rules remain active. You can separately review the archived rules and choose whether to apply them.',
              ),
              OutlinedButton(
                onPressed: () => run(reviewRules),
                child: const Text('Review archived rules'),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => run(service.clear),
              child: const Text('Done'),
            ),
          ],
        ],
      ),
    );
  }
}

class _BackupPreviewScreen extends StatefulWidget {
  const _BackupPreviewScreen({required this.service, required this.item});
  final BackupService service;
  final BackupItem item;

  @override
  State<_BackupPreviewScreen> createState() => _BackupPreviewScreenState();
}

class _BackupPreviewScreenState extends State<_BackupPreviewScreen> {
  VideoPlayerController? player;
  late final Future<void> ready;

  @override
  void initState() {
    super.initState();
    widget.service.session.addListener(sessionChanged);
    ready = prepare();
  }

  Future<void> prepare() async {
    final file = await widget.service.previewFile(widget.item.id);
    if (!mounted || !widget.service.session.unlocked) return;
    final controller = VideoPlayerController.file(file);
    player = controller;
    await controller.initialize();
    if (!mounted || !widget.service.session.unlocked) await controller.pause();
  }

  void sessionChanged() {
    if (!widget.service.session.unlocked) player?.pause();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.service.session.removeListener(sessionChanged);
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.service.session.unlocked) {
      return const Scaffold(
        body: Center(child: Text('Parent access is locked.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Parent video review')),
      body: FutureBuilder<void>(
        future: ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text('This video could not be opened for review.'),
            );
          }
          if (snapshot.connectionState != ConnectionState.done ||
              player == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: player!,
            builder: (context, value, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${widget.item.title}\n${widget.item.author}',
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: value.hasError
                        ? const Text(
                            'Playback failed. Return to the backup review.',
                          )
                        : AspectRatio(
                            aspectRatio: value.aspectRatio,
                            child: VideoPlayer(player!),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      VideoProgressIndicator(player!, allowScrubbing: true),
                      IconButton(
                        tooltip: value.isPlaying
                            ? 'Pause preview'
                            : 'Play preview',
                        onPressed: value.hasError
                            ? null
                            : () async {
                                if (!widget.service.session.unlocked) return;
                                if (value.isPlaying) {
                                  await player!.pause();
                                } else {
                                  if (value.position >= value.duration) {
                                    await player!.seekTo(Duration.zero);
                                  }
                                  if (widget.service.session.unlocked) {
                                    await player!.play();
                                  }
                                }
                              },
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      const Text(
                        'Review only. Return to choose which videos to approve.',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

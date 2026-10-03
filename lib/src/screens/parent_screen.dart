import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/filter_config.dart';
import '../services/settings_repository.dart';
import '../services/parent_session.dart';
import '../services/offline_repository.dart';
import '../services/offline_limits.dart';
import '../services/playback_policy.dart';
import '../services/android_offline_storage.dart';
import '../services/backup_service.dart';
import '../services/screen_off_recovery_preferences.dart';
import '../models/offline_item.dart';
import 'backup_screen.dart';

class _SavedLibrary {
  const _SavedLibrary(
    this.items,
    this.unavailableFiles,
    this.bytes,
    this.freeBytes,
  );
  final List<OfflineItem> items;
  final Set<String> unavailableFiles;
  final int bytes;
  final int? freeBytes;
}

class ParentScreen extends StatefulWidget {
  const ParentScreen({
    required this.session,
    required this.library,
    this.backup,
    this.screenOffRecoveryPreferences,
    super.key,
  });
  final ParentSession session;
  final OfflineRepository library;
  final BackupService? backup;
  final ScreenOffRecoveryPreferences? screenOffRecoveryPreferences;

  @override
  State<ParentScreen> createState() => _ParentScreenState();
}

class _ParentScreenState extends State<ParentScreen> {
  final repository = SettingsRepository();
  bool loading = true;
  String? loadError;
  FilterConfig? savedRules;
  late Future<_SavedLibrary> savedItems;
  final channels = TextEditingController();
  final keywords = TextEditingController();
  bool blockShorts = true;
  bool blockLive = true;
  late final ScreenOffRecoveryPreferences recoveryPreferences;
  bool recoveryLoading = true;
  bool recoverySaving = false;
  bool recoveryEnabled = false;
  bool recoveryReadFailed = false;
  String? recoveryError;

  @override
  void initState() {
    super.initState();
    savedItems = loadLibrary();
    widget.library.addListener(refreshLibrary);
    recoveryPreferences =
        widget.screenOffRecoveryPreferences ?? ScreenOffRecoveryPreferences();
    load();
    loadRecovery();
  }

  Future<void> loadRecovery() async {
    setState(() {
      recoveryLoading = true;
      recoveryError = null;
    });
    try {
      final enabled = await recoveryPreferences.isEnabled();
      if (!mounted) return;
      setState(() {
        recoveryEnabled = enabled;
        recoveryReadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        recoveryEnabled = false;
        recoveryReadFailed = true;
        recoveryError =
            'Recovery could not be confirmed, so playback will treat it as off. Retry loading or save Off.';
      });
    } finally {
      if (mounted) setState(() => recoveryLoading = false);
    }
  }

  Future<void> saveRecovery(bool enabled) async {
    if (recoverySaving || !widget.session.unlocked) return;
    setState(() {
      recoverySaving = true;
      recoveryError = null;
    });
    try {
      await recoveryPreferences.setEnabled(enabled, widget.session);
      if (!mounted) return;
      setState(() {
        recoveryEnabled = enabled;
        recoveryReadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      var confirmed = false;
      var readable = false;
      try {
        confirmed = await recoveryPreferences.isEnabled();
        readable = true;
      } catch (_) {
        // A failed compensation must not make the experimental switch look on.
      }
      if (!mounted) return;
      setState(() {
        recoveryEnabled = confirmed;
        recoveryReadFailed = !readable;
        recoveryError = !widget.session.unlocked
            ? 'Recovery could not be saved. Unlock Parent and try again.'
            : readable
            ? 'Recovery could not be saved. The previous confirmed setting is shown. Try again.'
            : 'Recovery could not be confirmed, so playback will treat it as off. Retry loading or save Off.';
      });
    } finally {
      if (mounted) setState(() => recoverySaving = false);
    }
  }

  Widget playbackSettings() => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Playback',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Experimental',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        SwitchListTile(
          key: const ValueKey('screen-off-recovery-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Recover from accidental screen-off'),
          subtitle: const Text(
            'Saved automatically for this tablet. Off by default.',
          ),
          value: recoveryEnabled,
          onChanged:
              recoveryLoading ||
                  recoverySaving ||
                  recoveryReadFailed ||
                  !widget.session.unlocked
              ? null
              : saveRecovery,
        ),
        const Text(
          'While a video is playing with the touch lock on, try to bring it back after an accidental screen-off. The video may stay visible while the tablet is locked. The screen may briefly go dark, and device support varies.',
        ),
        const SizedBox(height: 8),
        const Text(
          'If Android is still locked, holding the playback lock to unlock or leaving the player restores the normal Android lock screen before other controls become available. Your Android PIN, pattern or password remains in place. This does not prevent shutdown or restart. Home and system controls remain available.',
        ),
        if (recoveryLoading || recoverySaving)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                Text(
                  recoverySaving
                      ? 'Saving recovery setting…'
                      : 'Loading recovery setting…',
                ),
              ],
            ),
          ),
        if (recoveryError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(liveRegion: true, child: Text(recoveryError!)),
          ),
        if (recoveryReadFailed)
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: recoveryLoading || recoverySaving
                    ? null
                    : loadRecovery,
                child: const Text('Retry recovery setting'),
              ),
              TextButton(
                onPressed:
                    recoveryLoading ||
                        recoverySaving ||
                        !widget.session.unlocked
                    ? null
                    : () => saveRecovery(false),
                child: const Text('Keep recovery off'),
              ),
            ],
          ),
      ],
    ),
  );

  void refreshLibrary() {
    if (mounted) {
      setState(() {
        savedItems = loadLibrary();
      });
    }
  }

  Future<_SavedLibrary> loadLibrary() async {
    final library = await widget.library.all();
    final unavailable = <String>{};
    var totalBytes = 0;
    for (final item in library) {
      try {
        final file = await widget.library.privateFile(item.filePath);
        final bytes = file == null ? 0 : await file.length();
        totalBytes += bytes;
        if (file == null || item.bytes <= 0 || bytes != item.bytes) {
          unavailable.add(item.id);
        }
      } catch (_) {
        unavailable.add(item.id);
      }
    }
    int? freeBytes;
    try {
      freeBytes = await AndroidOfflineStorage.availableBytes(
        await widget.library.storageDirectory(),
      );
    } catch (_) {
      // Failure to query free space must not prevent deliberate deletion.
    }
    return _SavedLibrary(library, unavailable, totalBytes, freeBytes);
  }

  @override
  void didUpdateWidget(covariant ParentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(refreshLibrary);
      widget.library.addListener(refreshLibrary);
      savedItems = loadLibrary();
    }
  }

  Future<void> load() async {
    try {
      final config = await repository.loadConfig();
      if (!mounted) return;
      channels.text = config.blockedChannels.join('\n');
      keywords.text = config.blockedKeywords.join('\n');
      blockShorts = config.blockShorts;
      blockLive = config.blockLive;
      savedRules = config;
    } catch (_) {
      loadError =
          'The saved rules could not be read. Enter replacement rules and save to restore playback.';
    }
    if (mounted) setState(() => loading = false);
  }

  List<String> lines(String value) => value
      .split(RegExp(r'[\n,]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();

  Future<void> save() async {
    final config = FilterConfig(
      blockedChannels: lines(channels.text),
      blockedKeywords: lines(keywords.text),
      blockShorts: blockShorts,
      blockLive: blockLive,
    );
    await repository.saveConfig(config, widget.session);
    if (!mounted) return;
    setState(() {
      savedRules = config;
      loadError = null;
    });
    message('Parent settings saved. Offline playback uses the updated rules.');
  }

  String availability(OfflineItem item, Set<String> unavailableFiles) {
    if (unavailableFiles.contains(item.id)) {
      return 'Saved file is missing or damaged. Delete this entry, then review and save it again in Browse.';
    }
    if (!PlaybackPolicy.allows(item, FilterConfig.defaults)) {
      return 'Needs a new approved download: delete this saved copy, then review and save it again in Browse.';
    }
    final rules = savedRules;
    if (rules == null) return 'Unavailable until content rules are restored.';
    if (!PlaybackPolicy.allows(item, rules)) {
      return 'Hidden from your child by the saved content rules.';
    }
    return 'Available to your child.';
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(refreshLibrary);
    channels.dispose();
    keywords.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Parent settings'),
        actions: [
          IconButton(
            tooltip: 'Lock parent access',
            onPressed: widget.session.lock,
            icon: const Icon(Icons.lock),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (loadError != null) Text(loadError!),
          if (widget.backup != null)
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BackupScreen(service: widget.backup!),
                ),
              ),
              icon: const Icon(Icons.lock_outline),
              label: const Text('Encrypted backups'),
            ),
          if (widget.backup != null)
            ListenableBuilder(
              listenable: widget.backup!,
              builder: (context, _) => widget.backup!.canResume
                  ? const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'A backup selection is ready. Open Encrypted backups to continue.',
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          OutlinedButton.icon(
            onPressed: () async {
              final changed = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => _ChangePinDialog(session: widget.session),
              );
              if (changed == true) message('Parent PIN changed.');
            },
            icon: const Icon(Icons.password),
            label: const Text('Change parent PIN'),
          ),
          const SizedBox(height: 16),
          playbackSettings(),
          const Divider(height: 32),
          const Text(
            'Content rules',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: channels,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Blocked channels',
              helperText: 'One channel name or channel ID per line',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: keywords,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Blocked title keywords',
              helperText: 'One keyword per line',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            value: blockShorts,
            onChanged: (value) => setState(() => blockShorts = value),
            title: const Text('Hide Shorts'),
          ),
          SwitchListTile(
            value: blockLive,
            onChanged: (value) => setState(() => blockLive = value),
            title: const Text('Hide live streams'),
          ),
          const Divider(height: 32),
          const Text(
            'Offline videos',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Review a video in Browse, then approve it for your child and save it. An approved save can finish after parent access locks or you leave the app, for up to 30 minutes. Parent access still ends after five minutes.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Downloads use up to 720p and 1 GiB per video. All saved videos use a slot, including videos hidden by your rules and earlier downloads needing new approval. When all $maxOfflineVideos slots are full, delete a saved video here before saving another.',
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () async {
              try {
                await save();
              } catch (_) {
                message('Settings could not be saved. Unlock and retry.');
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save settings'),
          ),
          const Divider(height: 32),
          const Text(
            'Manage saved videos',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          FutureBuilder<_SavedLibrary>(
            future: savedItems,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Column(
                  children: [
                    const Text('The saved library could not be loaded.'),
                    TextButton(
                      onPressed: refreshLibrary,
                      child: const Text('Retry'),
                    ),
                  ],
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final saved = snapshot.data!;
              final library = saved.items;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Text('${library.length} / $maxOfflineVideos slots used'),
                  Text(
                    '${(saved.bytes / 1048576).toStringAsFixed(1)} MiB of saved video files',
                  ),
                  Text(
                    saved.freeBytes == null
                        ? 'Free storage could not be checked.'
                        : '${(saved.freeBytes! / 1073741824).toStringAsFixed(2)} GiB free on this tablet',
                  ),
                  const Text(
                    'Saving keeps at least 128 MiB free and needs extra space when combining audio and video.',
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: refreshLibrary,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh storage'),
                    ),
                  ),
                  if (library.length >= maxOfflineVideos)
                    const Text(
                      'All slots are full. Delete a saved video below to make room.',
                    ),
                  if (library.isEmpty)
                    const Text('No videos saved on this tablet.'),
                  for (final item in library)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.title),
                      subtitle: Text(
                        availability(item, saved.unavailableFiles),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete saved video',
                        onPressed: () async {
                          try {
                            final token = widget.session.token;
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Delete saved video?'),
                                content: Text(item.title),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Keep'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true ||
                                widget.session.token != token) {
                              return;
                            }
                            await widget.library.delete(item);
                            message(
                              'Saved video deleted. A slot is available.',
                            );
                          } catch (_) {
                            message('Unlock parent access and try again.');
                          }
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog({required this.session});
  final ParentSession session;

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final current = TextEditingController();
  final replacement = TextEditingController();
  final confirmation = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    current.dispose();
    replacement.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (!RegExp(r'^\d{6,12}$').hasMatch(current.text) ||
        !RegExp(r'^\d{6,12}$').hasMatch(replacement.text) ||
        replacement.text != confirmation.text) {
      setState(
        () => error =
            'Enter your current PIN and the same new 6–12 digit PIN twice.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.changePin(current.text, newPin: replacement.text);
      if (mounted) Navigator.of(context).pop(true);
    } on PlatformException catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.message ?? 'The PIN could not be changed.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'PIN change was interrupted. Unlock again to check whether the change completed.',
        );
      }
    } finally {
      if (mounted) {
        current.clear();
        replacement.clear();
        confirmation.clear();
        setState(() => busy = false);
      }
    }
  }

  Widget pinField(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: controller,
      enabled: !busy,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      maxLength: 12,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Change parent PIN'),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Your current PIN is required. The new PIN keeps your saved videos and content rules.',
            ),
            pinField(current, 'Current PIN'),
            pinField(replacement, 'New PIN'),
            pinField(confirmation, 'Confirm new PIN'),
            if (error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : submit,
          child: Text(busy ? 'Changing…' : 'Change PIN'),
        ),
      ],
    ),
  );
}

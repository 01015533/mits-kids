import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/filter_config.dart';
import '../models/offline_item.dart';
import 'offline_limits.dart';
import 'offline_repository.dart';
import 'parent_session.dart';
import 'playback_policy.dart';
import 'settings_repository.dart';

enum BackupPhase {
  idle,
  exportSelected,
  restoreSelected,
  restoreReview,
  completed,
}

class BackupItem {
  const BackupItem({
    required this.id,
    required this.title,
    required this.author,
    required this.bytes,
    required this.eligible,
    this.reason,
  });
  final String id;
  final String title;
  final String author;
  final int bytes;
  final bool eligible;
  final String? reason;
}

/// Own this beside ParentSession in AppShell, so a document-picker round-trip
/// keeps only its selection while the parent surface is removed and rebuilt.
class BackupService extends ChangeNotifier {
  BackupService({
    required this.repository,
    required this.settings,
    required this.session,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('mits_kids/backup') {
    session.addListener(_parentChanged);
  }

  final OfflineRepository repository;
  final SettingsRepository settings;
  final ParentSession session;
  final MethodChannel _channel;
  BackupPhase phase = BackupPhase.idle;
  String? error;
  String status = '';
  String? selectionName;
  List<BackupItem> items = const [];
  FilterConfig? restoredRules;
  bool get hasRestoredRules =>
      phase == BackupPhase.completed && restoredRules != null;
  bool get canResume =>
      phase != BackupPhase.idle && phase != BackupPhase.completed;
  bool get busy => _choosing || _working != null || _cancelling != null;
  bool _choosing = false;
  bool _disposed = false;
  int _generation = 0;
  String? _handle;
  String? _job;
  String? _reviewToken;
  final Map<String, OfflineItem> _staged = {};
  OfflineMutationLease? _lease;
  Completer<void>? _working;
  Future<void>? _cancelling;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool _authorised(int generation, String token) =>
      !_disposed &&
      generation == _generation &&
      session.unlocked &&
      session.token == token;
  void _check(int generation, String token) {
    if (!_authorised(generation, token)) {
      throw StateError('Parent access was interrupted.');
    }
  }

  void _parentChanged() {
    if (!session.unlocked && !_choosing && (_working != null || _job != null)) {
      unawaited(cancel());
    }
  }

  static void _password(String value) {
    if (value.runes.length < 16 || utf8.encode(value).length > 1024) {
      throw const DownloadFailure(
        'Use a separate backup password of at least 16 characters.',
      );
    }
  }

  Future<void> chooseExportDestination() => _choose(true);
  Future<void> chooseRestoreArchive() => _choose(false);

  Future<void> _choose(bool exporting) async {
    if (busy) return;
    try {
      final token = session.token;
      await clear();
      final generation = _generation;
      _check(generation, token);
      if (exporting) {
        final rules = await settings.loadConfig();
        final display = <BackupItem>[];
        for (final item in await repository.all()) {
          final file = await repository.privateFile(item.filePath);
          final intactSize =
              file != null &&
              item.bytes > 0 &&
              await file.length() == item.bytes;
          display.add(
            _display(
              item,
              intactSize && PlaybackPolicy.allows(item, rules),
              intactSize
                  ? 'Not currently approved under Parent rules.'
                  : 'The saved file is missing or damaged.',
            ),
          );
        }
        items = display;
        _check(generation, token);
      } else {
        // Finish database recovery before any native staging begins.
        await repository.all();
        _check(generation, token);
      }
      await repository.storageDirectory();
      _check(generation, token);
      _choosing = true;
      status = 'Choose a document, then unlock Parent again to continue.';
      _changed();
      final result = await _channel.invokeMapMethod<String, dynamic>(
        exporting ? 'chooseExport' : 'chooseRestore',
      );
      if (generation != _generation || _disposed) {
        if (result?['handle'] is String) {
          await _forget(result!['handle'] as String);
        }
        return;
      }
      if (result == null) {
        phase = BackupPhase.idle;
        items = const [];
        status = 'Document selection cancelled.';
        return;
      }
      if (result['handle'] is! String || (result['handle'] as String).isEmpty) {
        throw StateError('Invalid document selection.');
      }
      _handle = result['handle'] as String;
      selectionName = result['name'] is String
          ? result['name'] as String
          : 'Selected archive';
      phase = exporting
          ? BackupPhase.exportSelected
          : BackupPhase.restoreSelected;
      // Require an explicit new unlock even if a provider did not emit pause.
      session.lock();
      status = 'Unlock Parent to continue with the selected document.';
    } catch (failure) {
      _report(failure);
    } finally {
      _choosing = false;
      _changed();
    }
  }

  Future<void> exportArchive(
    String password, {
    bool includeRules = true,
    Set<String>? ids,
  }) async {
    if (busy || phase != BackupPhase.exportSelected) return;
    final completion = Completer<void>();
    _working = completion;
    error = null;
    var nativeStarted = false;
    try {
      final token = session.token;
      final generation = _generation;
      _password(password);
      _lease = repository.acquireMutation();
      status = 'Verifying and encrypting selected videos…';
      _changed();
      final rules = await settings.loadConfig();
      final current = await repository.all();
      final eligible = current
          .where((entry) => PlaybackPolicy.allows(entry, rules))
          .toList();
      final selected = ids == null
          ? eligible
          : eligible.where((entry) => ids.contains(entry.id)).toList();
      if (ids != null && selected.length != ids.length) {
        throw const DownloadFailure(
          'Some selected videos are no longer eligible for export.',
        );
      }
      if (selected.isEmpty && !includeRules) {
        throw const DownloadFailure('Select videos or include Parent rules.');
      }
      for (final item in selected) {
        await repository.verifyFile(item);
        _check(generation, token);
      }
      final manifest = jsonEncode({
        'version': 1,
        'videos': selected.map(_manifestItem).toList(),
        'rules': includeRules ? rules.toJson() : null,
      });
      _validateManifest(manifest, const {});
      restoredRules = null;
      _check(generation, token);
      nativeStarted = true;
      await _channel.invokeMethod<dynamic>('export', {
        'handle': _handle,
        'password': password,
        'token': token,
        'manifest': manifest,
        'files': selected
            .map((item) => {'id': item.id, 'path': item.filePath})
            .toList(),
      });
      _check(generation, token);
      phase = BackupPhase.completed;
      status =
          'Encrypted backup saved. Keep its separate password in a safe place.';
      items = const [];
      await _releaseSelection();
    } catch (failure) {
      _report(failure);
    } finally {
      if (nativeStarted) {
        await _releaseSelection();
        if (phase != BackupPhase.completed) phase = BackupPhase.idle;
      }
      _lease?.release();
      _lease = null;
      _working = null;
      completion.complete();
      _changed();
    }
  }

  Future<void> inspectArchive(String password) async {
    if (busy || phase != BackupPhase.restoreSelected) return;
    final completion = Completer<void>();
    _working = completion;
    error = null;
    try {
      final token = session.token;
      final generation = _generation;
      _password(password);
      _lease = repository.acquireMutation();
      status = 'Decrypting and verifying the backup…';
      _changed();
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'inspect',
        {'handle': _handle, 'password': password, 'token': token},
      );
      if (result?['job'] is String) _job = result!['job'] as String;
      _check(generation, token);
      if (_job == null ||
          result?['manifest'] is! String ||
          result?['files'] is! List) {
        throw StateError('Invalid restored archive response.');
      }
      final files = <String, String>{};
      for (final entry in result!['files'] as List) {
        if (entry is! Map ||
            entry['id'] is! String ||
            entry['path'] is! String ||
            files.containsKey(entry['id'])) {
          throw StateError('Invalid restored file response.');
        }
        files[entry['id'] as String] = entry['path'] as String;
      }
      final decoded = _validateManifest(result['manifest'] as String, files);
      if (files.length != decoded.length) {
        throw StateError('Unexpected restored files.');
      }
      final rules = await settings.loadConfig();
      final existingIds = (await repository.all())
          .map((item) => item.id)
          .toSet();
      final display = <BackupItem>[];
      for (final item in decoded) {
        await repository.verifyRestoreFile(item);
        _check(generation, token);
        _staged[item.id] = item;
        final duplicate = existingIds.contains(item.id);
        final allowed = PlaybackPolicy.matchesRules(
          title: item.title,
          author: item.author,
          channelId: item.channelId,
          rules: rules,
        );
        display.add(
          _display(
            item,
            !duplicate && allowed,
            duplicate
                ? 'Already saved; existing videos are never replaced.'
                : 'Blocked by current Parent rules.',
          ),
        );
      }
      items = List.unmodifiable(display);
      _reviewToken = token;
      phase = BackupPhase.restoreReview;
      status =
          'Review each video, then explicitly approve the selected videos.';
    } catch (failure) {
      await _discardStaging();
      _report(failure);
    } finally {
      if (phase != BackupPhase.restoreReview) {
        _lease?.release();
        _lease = null;
      }
      _working = null;
      completion.complete();
      _changed();
    }
  }

  Future<File> previewFile(String id) async {
    final token = session.token;
    final generation = _generation;
    if (busy) throw StateError('The backup is still working.');
    if (phase == BackupPhase.restoreReview && _reviewToken == token) {
      final item = _staged[id];
      if (item == null) throw StateError('Unknown restored video.');
      final file = await repository.verifyRestoreFile(item);
      _check(generation, token);
      return file;
    }
    if (phase == BackupPhase.exportSelected) {
      final item = (await repository.all())
          .where((item) => item.id == id)
          .firstOrNull;
      if (item == null ||
          !PlaybackPolicy.allows(item, await settings.loadConfig())) {
        throw StateError('This video is no longer approved.');
      }
      final file = await repository.verifyFile(item);
      _check(generation, token);
      return file;
    }
    throw StateError('Unlock and inspect the backup before reviewing videos.');
  }

  Future<void> approveRestore(Set<String> ids) async {
    if (busy || phase != BackupPhase.restoreReview) return;
    final completion = Completer<void>();
    _working = completion;
    error = null;
    status = 'Restoring selected videos…';
    _changed();
    try {
      final token = session.token;
      final generation = _generation;
      if (_reviewToken != token || _lease == null) {
        throw StateError('Review was interrupted.');
      }
      final rules = await settings.loadConfig();
      final approved = <OfflineItem>[];
      for (final id in ids) {
        final item = _staged[id];
        if (item == null ||
            !PlaybackPolicy.matchesRules(
              title: item.title,
              author: item.author,
              channelId: item.channelId,
              rules: rules,
            )) {
          throw const DownloadFailure(
            'A selected video is no longer allowed by Parent rules.',
          );
        }
        approved.add(
          OfflineItem(
            id: item.id,
            title: item.title,
            sourceUrl: item.sourceUrl,
            filePath: item.filePath,
            bytes: item.bytes,
            createdAt: DateTime.now().toUtc(),
            author: item.author,
            channelId: item.channelId,
            contentHash: item.contentHash,
            approvedAt: DateTime.now().toUtc(),
          ),
        );
      }
      _check(generation, token);
      await repository.addMany(
        approved,
        lease: _lease!,
        authorised: () => _authorised(generation, token),
      );
      // The repository has completed its final authority check and publication.
      // A subsequent lock removes Parent UI but does not undo this valid commit.
      await _discardStaging(keepRules: true);
      phase = BackupPhase.completed;
      status = approved.isEmpty
          ? 'No videos changed. You can separately review the archived rules.'
          : '${approved.length} reviewed videos restored. Current Parent rules still apply.';
      items = const [];
      await _releaseSelection();
    } catch (failure) {
      await _discardStaging();
      phase = _handle == null ? BackupPhase.idle : BackupPhase.restoreSelected;
      _report(failure);
    } finally {
      _lease?.release();
      _lease = null;
      _working = null;
      completion.complete();
      _changed();
    }
  }

  Future<void> applyRestoredRules() async {
    if (busy || !hasRestoredRules) return;
    error = null;
    try {
      await settings.saveConfig(restoredRules!, session);
      restoredRules = null;
      status =
          'Archived Parent rules applied after your separate confirmation.';
    } catch (failure) {
      _report(failure);
    }
    _changed();
  }

  Future<void> cancel() {
    final active = _cancelling;
    if (active != null) return active;
    final operation = _cancel();
    _cancelling = operation;
    return operation.whenComplete(() {
      if (identical(_cancelling, operation)) _cancelling = null;
      _changed();
    });
  }

  Future<void> _cancel() async {
    _generation++;
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      /* Local revocation wins. */
    }
    final working = _working;
    if (working != null) await working.future;
    await _discardStaging();
    _lease?.release();
    _lease = null;
    if (phase == BackupPhase.restoreReview) phase = BackupPhase.restoreSelected;
    if (phase != BackupPhase.completed) {
      status = 'Backup operation stopped. Unlock Parent to start again.';
    }
    _changed();
  }

  Future<void> clear() async {
    await cancel();
    await _releaseSelection();
    phase = BackupPhase.idle;
    selectionName = null;
    restoredRules = null;
    items = const [];
    error = null;
    status = '';
    _changed();
  }

  Future<void> _discardStaging({bool keepRules = false}) async {
    final job = _job;
    _job = null;
    _staged.clear();
    _reviewToken = null;
    if (!keepRules) restoredRules = null;
    if (job != null) {
      try {
        await _channel.invokeMethod<void>('discard', {'job': job});
      } catch (_) {
        /* Native startup cleanup must recover interrupted staging. */
      }
    }
  }

  Future<void> _releaseSelection() async {
    final handle = _handle;
    _handle = null;
    if (handle != null) await _forget(handle);
  }

  Future<void> _forget(String handle) async {
    try {
      await _channel.invokeMethod<void>('forget', {'handle': handle});
    } catch (_) {}
  }

  static BackupItem _display(OfflineItem item, bool eligible, String reason) =>
      BackupItem(
        id: item.id,
        title: item.title,
        author: item.author,
        bytes: item.bytes,
        eligible: eligible,
        reason: eligible ? null : reason,
      );
  static Map<String, Object> _manifestItem(OfflineItem item) => {
    'id': item.id,
    'title': item.title,
    'author': item.author,
    'channel_id': item.channelId,
    'source_url': item.sourceUrl,
    'bytes': item.bytes,
    'sha256': item.contentHash,
  };

  List<OfflineItem> _validateManifest(
    String encoded,
    Map<String, String> files,
  ) {
    if (utf8.encode(encoded).length > 256 * 1024) {
      throw StateError('Manifest too large.');
    }
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        value['version'] != 1 ||
        !value.containsKey('rules') ||
        value['videos'] is! List ||
        (value['videos'] as List).length > maxOfflineVideos) {
      throw StateError('Invalid manifest.');
    }
    final result = <OfflineItem>[];
    final ids = <String>{};
    for (final raw in value['videos'] as List) {
      if (raw is! Map<String, dynamic> ||
          raw.length != 7 ||
          raw['id'] is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(raw['id'] as String) ||
          !ids.add(raw['id'] as String) ||
          raw['channel_id'] is! String ||
          !RegExp(
            r'^UC[a-zA-Z0-9_-]{22}$',
          ).hasMatch(raw['channel_id'] as String) ||
          raw['source_url'] != 'https://www.youtube.com/watch?v=${raw['id']}' ||
          raw['bytes'] is! int ||
          (raw['bytes'] as int) <= 0 ||
          (raw['bytes'] as int) > maxDownloadBytes + offlineMuxAllowanceBytes ||
          raw['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['sha256'] as String)) {
        throw StateError('Invalid archive video metadata.');
      }
      for (final key in ['title', 'author']) {
        if (raw[key] is! String ||
            (raw[key] as String).isEmpty ||
            utf8.encode(raw[key] as String).length > 4096) {
          throw StateError('Invalid archive text.');
        }
      }
      if (files.isNotEmpty && !files.containsKey(raw['id'])) {
        throw StateError('Missing restored file.');
      }
      result.add(
        OfflineItem(
          id: raw['id'] as String,
          title: raw['title'] as String,
          sourceUrl: raw['source_url'] as String,
          filePath: files[raw['id']] ?? '',
          bytes: raw['bytes'] as int,
          createdAt: DateTime.now().toUtc(),
          author: raw['author'] as String,
          channelId: raw['channel_id'] as String,
          contentHash: raw['sha256'] as String,
        ),
      );
    }
    final rules = value['rules'];
    if (rules != null) {
      if (rules is! Map<String, dynamic> ||
          rules.length != 4 ||
          rules['blockShorts'] is! bool ||
          rules['blockLive'] is! bool) {
        throw StateError('Invalid archive rules.');
      }
      for (final name in ['blockedChannels', 'blockedKeywords']) {
        final terms = rules[name];
        if (terms is! List ||
            terms.length > 256 ||
            terms.any(
              (term) =>
                  term is! String ||
                  term.trim().isEmpty ||
                  utf8.encode(term).length > 1024,
            )) {
          throw StateError('Invalid archive rules.');
        }
      }
      restoredRules = FilterConfig.fromJson(rules);
    } else {
      restoredRules = null;
    }
    return result;
  }

  void _report(Object failure) {
    error = failure is DownloadFailure
        ? failure.message
        : !session.unlocked
        ? 'Parent access was interrupted. Unlock and start again.'
        : failure is PlatformException && failure.code == 'LOCKED'
        ? 'Parent access expired. Unlock and start again.'
        : failure is PlatformException &&
              failure.code == 'BACKUP_FAILED' &&
              phase == BackupPhase.exportSelected
        ? 'The export could not finish. An incomplete archive may remain in the selected folder. Delete that incomplete file and choose a new export destination to retry.'
        : 'The backup could not be completed or verified. Check the password, document and free storage, then retry.';
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_parentChanged);
    unawaited(clear());
    super.dispose();
  }
}

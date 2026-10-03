import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/download_service.dart';
import 'package:mits_kids_youtube/src/services/offline_limits.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/video_source.dart';

class MemoryStore implements OfflineStore {
  final items = <OfflineItem>[];
  bool rejectAdd = false;
  void Function()? onAdd;
  @override
  Future<List<OfflineItem>> all() async => List.of(items);
  @override
  Future<File> verifyFile(OfflineItem item) async {
    final file = File(item.filePath);
    if (await file.length() != item.bytes ||
        (await sha256.bind(file.openRead()).first).toString() !=
            item.contentHash) {
      throw StateError('Invalid saved file');
    }
    return file;
  }

  @override
  Future<void> add(OfflineItem item) async {
    if (rejectAdd) throw StateError('Database write failed');
    items.add(item);
    onAdd?.call();
  }

  @override
  Future<void> delete(OfflineItem item) async {
    items.remove(item);
  }
}

class FakeSource implements VideoSource {
  int calls = 0;
  int resolveCalls = 0;
  Future<void> Function()? onResolve;
  bool closed = false;
  bool live = false;
  String title = 'Example video';
  DownloadPlan plan = DownloadPlan(
    video: DownloadTrack(
      bytes: 4,
      open: () => Stream.fromIterable([
        [1, 2],
        [3, 4],
      ]),
    ),
  );
  @override
  Future<DownloadMetadata> describe(String id) async {
    calls++;
    return DownloadMetadata(
      title: title,
      author: 'Example channel',
      isLive: live,
      channelId: 'UCabcdefghijklmnopqrstuv',
    );
  }

  @override
  Future<DownloadPlan> resolve(String id) async {
    resolveCalls++;
    await onResolve?.call();
    return plan;
  }

  @override
  void close() {
    closed = true;
  }
}

class FakeMuxer implements OfflineMuxer {
  int calls = 0;
  bool fail = false;
  Future<void> Function()? onCombine;
  @override
  Future<void> combine(File video, File audio, File output) async {
    calls++;
    await onCombine?.call();
    if (fail) throw StateError('Mux failure');
    await output.writeAsBytes([
      ...await video.readAsBytes(),
      ...await audio.readAsBytes(),
    ]);
  }
}

class FakeJobLifecycle implements DownloadJobLifecycle {
  int starts = 0;
  int finishes = 0;
  bool failStart = false;
  Future<void> Function()? onFinish;
  String? videoId;
  String? token;
  void Function()? cancelFromNotification;
  final updates = <double?>[];

  @override
  Future<void> start({
    required String videoId,
    required String title,
    required String parentToken,
    required void Function() onCancel,
  }) async {
    starts++;
    this.videoId = videoId;
    token = parentToken;
    cancelFromNotification = onCancel;
    if (failStart) throw StateError('Foreground service unavailable');
  }

  @override
  void update({required String status, double? progress}) {
    updates.add(progress);
  }

  @override
  Future<void> finish() async {
    finishes++;
    await onFinish?.call();
  }
}

void main() {
  late Directory directory;
  late MemoryStore store;
  late FakeSource source;
  late FakeMuxer muxer;
  late DownloadService service;
  String? parentToken;
  late int freeBytes;
  late int storageChecks;
  late FakeJobLifecycle lifecycle;
  late FilterConfig latestRules;
  bool rulesUnavailable = false;
  int ruleChecks = 0;
  const url = 'https://m.youtube.com/watch?v=abcdefghijk';
  Future<OfflineItem> save([String link = url]) => service.save(
    sourceUrl: link,
    rules: FilterConfig.defaults,
    approve: (_) async => true,
  );

  setUp(() async {
    parentToken = 'parent-test-token';
    freeBytes = 4 * maxDownloadBytes;
    storageChecks = 0;
    lifecycle = FakeJobLifecycle();
    latestRules = FilterConfig.defaults;
    rulesUnavailable = false;
    ruleChecks = 0;
    directory = await Directory.systemTemp.createTemp('mits-download-test-');
    store = MemoryStore();
    source = FakeSource();
    muxer = FakeMuxer();
    service = DownloadService(
      store,
      sourceFactory: () => source,
      muxer: muxer,
      parentToken: () => parentToken,
      jobLifecycle: lifecycle,
      ruleLoader: () async {
        ruleChecks++;
        if (rulesUnavailable) throw StateError('Settings unavailable');
        return latestRules;
      },
      directoryProvider: () async => directory,
      availableBytes: (_) async {
        storageChecks++;
        return freeBytes;
      },
    );
  });
  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'saves complete bytes locally and deduplicates another URL for same video',
    () async {
      final item = await save();
      expect(await File(item.filePath).readAsBytes(), [1, 2, 3, 4]);
      expect(store.items, hasLength(1));
      expect(source.closed, isTrue);
      expect(service.busy, isFalse);
      expect(await save('https://youtu.be/abcdefghijk?si=x'), same(item));
      expect(source.calls, 1);
      expect(directory.listSync(), hasLength(1));
      expect(lifecycle.starts, 1);
      expect(lifecycle.finishes, 1);
      expect(service.lastSaved, same(item));
      expect(service.lastError, isNull);
    },
  );

  test(
    'ninth video is refused before any network call; deletion frees slot',
    () async {
      for (var i = 0; i < 8; i++) {
        store.items.add(
          OfflineItem(
            id: '$i',
            title: '$i',
            sourceUrl: 'https://youtube.com/watch?v=abcdefghi0$i',
            filePath: 'unused',
            bytes: 1,
            createdAt: DateTime.now(),
          ),
        );
      }
      await expectLater(save(), throwsA(isA<LibraryFull>()));
      expect(source.calls, 0);
      await store.delete(store.items.first);
      await save();
      expect(store.items, hasLength(8));
    },
  );

  test('truncated stream cleans files and occupies no slot', () async {
    source.plan = DownloadPlan(
      video: DownloadTrack(bytes: 8, open: () => Stream.value([1, 2])),
    );
    await expectLater(save(), throwsA(isA<DownloadFailure>()));
    expect(store.items, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('failed database commit removes the finished file', () async {
    store.rejectAdd = true;
    await expectLater(save(), throwsA(isA<DownloadFailure>()));
    expect(directory.listSync(), isEmpty);
  });

  test(
    'separate video and audio tracks are combined before publication',
    () async {
      source.plan = DownloadPlan(
        video: DownloadTrack(bytes: 2, open: () => Stream.value([1, 2])),
        audio: DownloadTrack(bytes: 2, open: () => Stream.value([3, 4])),
      );
      final item = await save();
      expect(muxer.calls, 1);
      expect(await File(item.filePath).readAsBytes(), [1, 2, 3, 4]);
      expect(directory.listSync(), hasLength(1));
    },
  );

  test(
    'mux failure cleans both tracks and does not register a video',
    () async {
      muxer.fail = true;
      source.plan = DownloadPlan(
        video: DownloadTrack(bytes: 2, open: () => Stream.value([1, 2])),
        audio: DownloadTrack(bytes: 2, open: () => Stream.value([3, 4])),
      );
      await expectLater(save(), throwsA(isA<DownloadFailure>()));
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'cancellation removes partial bytes; concurrent Save is refused',
    () async {
      final firstChunk = Completer<void>();
      final resume = Completer<void>();
      source.plan = DownloadPlan(
        video: DownloadTrack(
          bytes: 4,
          open: () async* {
            yield [1, 2];
            firstChunk.complete();
            await resume.future;
            yield [3, 4];
          },
        ),
      );
      final operation = save();
      await firstChunk.future;
      await expectLater(save(), throwsA(isA<DownloadFailure>()));
      service.cancel();
      final assertion = expectLater(
        operation,
        throwsA(isA<DownloadCancelled>()),
      );
      resume.complete();
      await assertion;
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(service.busy, isFalse);
    },
  );

  test('stale staging data is removed without touching a saved file', () async {
    final old = await Directory('${directory.path}/.pending-old').create();
    await File('${old.path}/video.part').writeAsBytes([1]);
    final saved = await File(
      '${directory.path}/existing.mp4',
    ).writeAsBytes([9]);
    await save();
    expect(await old.exists(), isFalse);
    expect(await saved.readAsBytes(), [9]);
  });

  test('blocked metadata and live streams never download', () async {
    source.title = 'Blocked title';
    await expectLater(
      service.save(
        sourceUrl: url,
        approve: (_) async => true,
        rules: const FilterConfig(
          blockedChannels: [],
          blockedKeywords: ['blocked'],
          blockShorts: true,
          blockLive: true,
        ),
      ),
      throwsA(isA<DownloadFailure>()),
    );
    source.live = true;
    await expectLater(save(), throwsA(isA<DownloadFailure>()));
    expect(store.items, isEmpty);
  });

  test('oversized advertised content is refused before transfer', () async {
    source.plan = DownloadPlan(
      video: DownloadTrack(
        bytes: maxDownloadBytes + 1,
        open: () => throw StateError('Must not transfer'),
      ),
    );
    await expectLater(save(), throwsA(isA<DownloadFailure>()));
    expect(directory.listSync(), isEmpty);
  });
  test('locked parent cannot start a download', () async {
    parentToken = null;
    await expectLater(save(), throwsA(isA<DownloadFailure>()));
    expect(source.calls, 0);
  });

  test('parent refusal prevents media transfer and approval', () async {
    await expectLater(
      service.save(
        sourceUrl: url,
        rules: FilterConfig.defaults,
        approve: (_) async => false,
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(store.items, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('parent lock during approval cannot publish a video', () async {
    await expectLater(
      service.save(
        sourceUrl: url,
        rules: FilterConfig.defaults,
        approve: (_) async {
          parentToken = null;
          return true;
        },
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(store.items, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('late approval cannot revive a preparation cancelled by lock', () async {
    final asked = Completer<void>();
    final answer = Completer<bool>();
    final operation = service.save(
      sourceUrl: url,
      rules: FilterConfig.defaults,
      approve: (_) {
        asked.complete();
        return answer.future;
      },
    );
    final assertion = expectLater(operation, throwsA(isA<DownloadCancelled>()));
    await asked.future;
    parentToken = null;
    service.cancelForLock();
    await assertion;
    parentToken = 'new-parent-token';
    answer.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(source.resolveCalls, 0);
    expect(lifecycle.starts, 0);
    expect(store.items, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('replacement token cannot authorize an old approval callback', () async {
    await expectLater(
      service.save(
        sourceUrl: url,
        rules: FilterConfig.defaults,
        approve: (_) async {
          parentToken = 'replacement-token';
          return true;
        },
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(lifecycle.starts, 0);
    expect(source.resolveCalls, 0);
  });

  test(
    'one approved job survives lock and cannot authorize another save',
    () async {
      final started = Completer<void>();
      final resume = Completer<void>();
      source.plan = DownloadPlan(
        video: DownloadTrack(
          bytes: 4,
          open: () async* {
            yield [1, 2];
            started.complete();
            await resume.future;
            yield [3, 4];
          },
        ),
      );
      final operation = save();
      await started.future;
      expect(service.approved, isTrue);
      expect(service.approvedVideoId, 'abcdefghijk');
      parentToken = null;
      service.cancelForLock();
      expect(service.busy, isTrue);
      await expectLater(save(), throwsA(isA<DownloadFailure>()));
      resume.complete();
      final item = await operation;
      expect(await File(item.filePath).readAsBytes(), [1, 2, 3, 4]);
      expect(store.items, [item]);
      expect(lifecycle.videoId, 'abcdefghijk');
      expect(lifecycle.token, 'parent-test-token');
      expect(lifecycle.finishes, 1);
      expect(service.approved, isFalse);
      expect(service.approvedVideoId, isNull);
      expect(ruleChecks, 2);
      await expectLater(save(), throwsA(isA<DownloadFailure>()));
      expect(source.resolveCalls, 1);
    },
  );

  test(
    'native cancellation stops a stalled stream and cleans private files',
    () async {
      final started = Completer<void>();
      final resume = Completer<void>();
      source.plan = DownloadPlan(
        video: DownloadTrack(
          bytes: 4,
          open: () async* {
            yield [1, 2];
            started.complete();
            await resume.future;
            yield [3, 4];
          },
        ),
      );
      final operation = save();
      final assertion = expectLater(
        operation,
        throwsA(isA<DownloadCancelled>()),
      );
      await started.future;
      parentToken = null;
      service.cancelForLock();
      lifecycle.cancelFromNotification!();
      await assertion.timeout(const Duration(seconds: 2));
      expect(lifecycle.finishes, 1);
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(service.status, 'Download cancelled');
      expect(service.lastError, isNotNull);
      resume.complete();
    },
  );

  test(
    'cancel during mux always rejects publication and finishes lifecycle',
    () async {
      final started = Completer<void>();
      final resume = Completer<void>();
      muxer.onCombine = () {
        started.complete();
        return resume.future;
      };
      source.plan = DownloadPlan(
        video: DownloadTrack(bytes: 2, open: () => Stream.value([1, 2])),
        audio: DownloadTrack(bytes: 2, open: () => Stream.value([3, 4])),
      );
      final operation = save();
      final assertion = expectLater(
        operation,
        throwsA(isA<DownloadCancelled>()),
      );
      await started.future;
      expect(service.canCancel, isTrue);
      service.cancel();
      expect(lifecycle.finishes, 1);
      resume.complete();
      await assertion;
      expect(lifecycle.finishes, 1);
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
    },
  );

  test('dispose cancels an approved job with no publication', () async {
    final started = Completer<void>();
    final resume = Completer<void>();
    source.onResolve = () {
      started.complete();
      return resume.future;
    };
    final operation = save();
    final assertion = expectLater(operation, throwsA(isA<DownloadCancelled>()));
    await started.future;
    service.dispose();
    await assertion;
    expect(lifecycle.finishes, 1);
    expect(store.items, isEmpty);
    resume.complete();
    // The common teardown still disposes a service; replace the disposed one.
    service = DownloadService(
      store,
      sourceFactory: () => source,
      muxer: muxer,
      parentToken: () => null,
    );
  });

  test('one total deadline stops a stalled approved operation', () async {
    service.dispose();
    final started = Completer<void>();
    final resume = Completer<void>();
    source.onResolve = () {
      started.complete();
      return resume.future;
    };
    service = DownloadService(
      store,
      sourceFactory: () => source,
      muxer: muxer,
      parentToken: () => parentToken,
      directoryProvider: () async => directory,
      availableBytes: (_) async => freeBytes,
      jobLifecycle: lifecycle,
      jobTimeout: const Duration(milliseconds: 500),
    );
    final operation = save();
    final assertion = expectLater(
      operation,
      throwsA(
        isA<DownloadFailure>().having(
          (error) => error.message,
          'message',
          contains('30-minute limit'),
        ),
      ),
    );
    await started.future;
    parentToken = null;
    service.cancelForLock();
    await assertion.timeout(const Duration(seconds: 2));
    expect(lifecycle.finishes, 1);
    expect(store.items, isEmpty);
    expect(directory.listSync(), isEmpty);
    resume.complete();
  });

  test(
    'foreground service start failure never transfers and always finishes',
    () async {
      lifecycle.failStart = true;
      await expectLater(save(), throwsA(isA<DownloadFailure>()));
      expect(lifecycle.starts, 1);
      expect(lifecycle.finishes, 1);
      expect(source.resolveCalls, 0);
      expect(store.items, isEmpty);
    },
  );

  test('rules revoked before publication prevent any saved row', () async {
    source.onResolve = () async {
      latestRules = const FilterConfig(
        blockedChannels: [],
        blockedKeywords: ['example'],
        blockShorts: true,
        blockLive: true,
      );
    };
    await expectLater(
      save(),
      throwsA(
        isA<DownloadFailure>().having(
          (error) => error.message,
          'message',
          contains('now blocked'),
        ),
      ),
    );
    expect(store.items, isEmpty);
    expect(directory.listSync(), isEmpty);
    expect(lifecycle.finishes, 1);
  });

  test(
    'rules revoked during database publication roll back the row and file',
    () async {
      store.onAdd = () {
        latestRules = const FilterConfig(
          blockedChannels: [],
          blockedKeywords: ['example'],
          blockShorts: true,
          blockLive: true,
        );
      };
      await expectLater(
        save(),
        throwsA(
          isA<DownloadFailure>().having(
            (error) => error.message,
            'message',
            contains('now blocked'),
          ),
        ),
      );
      expect(ruleChecks, 2);
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(service.lastSaved, isNull);
      expect(lifecycle.finishes, 1);
    },
  );

  test(
    'unreadable current settings after publication fail closed and roll back',
    () async {
      store.onAdd = () {
        rulesUnavailable = true;
      };
      await expectLater(
        save(),
        throwsA(
          isA<DownloadFailure>().having(
            (error) => error.message,
            'message',
            contains('could not be checked'),
          ),
        ),
      );
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(lifecycle.finishes, 1);
    },
  );

  test(
    'lock during database publication preserves the approved video',
    () async {
      store.onAdd = () {
        parentToken = null;
        service.cancelForLock();
      };
      final item = await save();
      expect(store.items, [item]);
      expect(lifecycle.finishes, 1);
      service.clearResult();
      expect(service.lastSaved, isNull);
      expect(service.lastError, isNull);
      expect(service.status, isEmpty);
    },
  );

  test(
    'late cancellation during native cleanup preserves a completed save',
    () async {
      final finishing = Completer<void>();
      final finish = Completer<void>();
      lifecycle.onFinish = () {
        finishing.complete();
        return finish.future;
      };
      final operation = save();
      await finishing.future;
      expect(service.busy, isTrue);
      expect(service.canCancel, isFalse);
      service.cancel();
      lifecycle.cancelFromNotification!();
      parentToken = null;
      service.cancelForLock();
      expect(service.status, 'Saved for offline viewing');
      expect(service.lastError, isNull);
      finish.complete();
      final item = await operation;
      expect(service.lastSaved, same(item));
      expect(store.items, [item]);
      expect(await File(item.filePath).exists(), isTrue);
    },
  );

  test(
    'explicit cancellation during database publication rolls back',
    () async {
      store.onAdd = service.cancel;
      await expectLater(save(), throwsA(isA<DownloadCancelled>()));
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(lifecycle.finishes, 1);
    },
  );

  test(
    'a previous job cancellation callback cannot cancel a new approval',
    () async {
      await save();
      final oldCancel = lifecycle.cancelFromNotification!;
      source.onResolve = () async {
        oldCancel();
      };
      await save('https://youtu.be/lmnopqrstuv');
      expect(store.items, hasLength(2));
      expect(lifecycle.starts, 2);
      expect(lifecycle.finishes, 2);
    },
  );

  test(
    'insufficient reserve refuses transfer before opening a stream',
    () async {
      freeBytes = offlineStorageReserveBytes + 3;
      source.plan = DownloadPlan(
        video: DownloadTrack(
          bytes: 4,
          open: () => throw StateError('Must not open media stream'),
        ),
      );
      await expectLater(
        save(),
        throwsA(
          isA<DownloadFailure>().having(
            (error) => error.message,
            'message',
            contains('Not enough free storage'),
          ),
        ),
      );
      expect(storageChecks, 1);
      expect(store.items, isEmpty);
      expect(directory.listSync(), isEmpty);
    },
  );

  test('separate tracks budget source plus output before transfer', () async {
    freeBytes = offlineStorageReserveBytes + offlineMuxAllowanceBytes + 7;
    source.plan = DownloadPlan(
      video: DownloadTrack(
        bytes: 2,
        open: () => throw StateError('No transfer'),
      ),
      audio: DownloadTrack(
        bytes: 2,
        open: () => throw StateError('No transfer'),
      ),
    );
    await expectLater(
      save(),
      throwsA(
        isA<DownloadFailure>().having(
          (error) => error.message,
          'message',
          contains('Not enough free storage'),
        ),
      ),
    );
    expect(muxer.calls, 0);
    expect(directory.listSync(), isEmpty);
  });

  test('space lost during transfer stops mux and cleans staging', () async {
    source.plan = DownloadPlan(
      video: DownloadTrack(bytes: 2, open: () => Stream.value([1, 2])),
      audio: DownloadTrack(
        bytes: 2,
        open: () async* {
          freeBytes = offlineStorageReserveBytes + offlineMuxAllowanceBytes + 3;
          yield [3, 4];
        },
      ),
    );
    await expectLater(save(), throwsA(isA<DownloadFailure>()));
    expect(storageChecks, 2);
    expect(muxer.calls, 0);
    expect(store.items, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test(
    'save reconciles a crash orphan and preserves referenced legacy files',
    () async {
      final orphan = await File(
        '${directory.path}/orphanvid01-1777777777777777.mp4',
      ).writeAsBytes([9]);
      final legacy = await File(
        '${directory.path}/legacyvid01-1777777777777778.mp4',
      ).writeAsBytes([8]);
      store.items.add(
        OfflineItem(
          id: 'legacyvid01',
          title: 'Earlier download',
          sourceUrl: 'https://youtube.com/watch?v=legacyvid01',
          filePath: legacy.path,
          bytes: 9,
          createdAt: DateTime.now(),
        ),
      );
      final unknown = await File(
        '${directory.path}/personal.mp4',
      ).writeAsBytes([7]);
      await save();
      expect(await orphan.exists(), isFalse);
      expect(await legacy.readAsBytes(), [8]);
      expect(await unknown.readAsBytes(), [7]);
      expect(store.items, hasLength(2));
    },
  );

  test('staging cleanup never follows links outside private storage', () async {
    final outside = await Directory.systemTemp.createTemp(
      'mits-cleanup-outside-',
    );
    try {
      final protected = await File(
        '${outside.path}/keep.mp4',
      ).writeAsBytes([9]);
      final staging = await Directory(
        '${directory.path}/.pending-old',
      ).create();
      await Link('${staging.path}/escape').create(outside.path);
      final rootLink = await Link(
        '${directory.path}/.pending-linked',
      ).create(outside.path);
      final videoLink = await Link(
        '${directory.path}/linkedvid01-1777777777777779.mp4',
      ).create(protected.path);
      await save();
      expect(await protected.readAsBytes(), [9]);
      expect(await rootLink.exists(), isTrue);
      expect(await videoLink.exists(), isTrue);
      expect(await staging.exists(), isFalse);
    } finally {
      await outside.delete(recursive: true);
    }
  });

  test('legacy duplicate requires deliberate deletion and approval', () async {
    final file = await File('${directory.path}/legacy.mp4').writeAsBytes([1]);
    store.items.add(
      OfflineItem(
        id: 'abcdefghijk',
        title: 'Legacy',
        sourceUrl: url,
        filePath: file.path,
        bytes: 1,
        createdAt: DateTime.now(),
      ),
    );
    await expectLater(
      save(),
      throwsA(
        isA<DownloadFailure>().having(
          (error) => error.message,
          'message',
          contains('needs approval'),
        ),
      ),
    );
    expect(source.calls, 0);
    expect(await file.readAsBytes(), [1]);
    expect(store.items, hasLength(1));
  });

  test('same-size damaged duplicate is not reported as available', () async {
    final saved = await save();
    await File(saved.filePath).writeAsBytes([4, 3, 2, 1]);
    await expectLater(
      save(),
      throwsA(
        isA<DownloadFailure>().having(
          (error) => error.message,
          'message',
          contains('could not be verified'),
        ),
      ),
    );
    expect(store.items, hasLength(1));
    expect(await File(saved.filePath).readAsBytes(), [4, 3, 2, 1]);
  });

  test(
    'duplicate blocked by current rules is not reported as available',
    () async {
      await save();
      await expectLater(
        service.save(
          sourceUrl: url,
          rules: const FilterConfig(
            blockedChannels: [],
            blockedKeywords: ['example'],
            blockShorts: true,
            blockLive: true,
          ),
          approve: (_) async => throw StateError('Already saved'),
        ),
        throwsA(
          isA<DownloadFailure>().having(
            (error) => error.message,
            'message',
            contains('blocked'),
          ),
        ),
      );
      expect(store.items, hasLength(1));
    },
  );
}

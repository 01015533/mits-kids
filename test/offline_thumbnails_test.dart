import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/offline_thumbnails.dart';
import 'package:mits_kids_youtube/src/services/seek_preview_frames.dart';
import 'package:path/path.dart' as p;

class _Frames implements SeekPreviewFrames {
  _Frames(this.results);
  final List<Uint8List?> results;
  final positions = <Duration>[];
  int disposals = 0;

  @override
  Future<SeekPreviewFrame?> frame(
    File file, {
    required Duration position,
  }) async {
    positions.add(position);
    final bytes = results.isEmpty ? null : results.removeAt(0);
    return bytes == null
        ? null
        : SeekPreviewFrame(bytes: bytes, position: position);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

/// JPEG start and end markers around [length] bytes of picture data.
Uint8List _jpeg(int length) => Uint8List(length)
  ..[0] = 0xff
  ..[1] = 0xd8
  ..[length - 2] = 0xff
  ..[length - 1] = 0xd9;

List<int> _box(String type, List<int> payload) => [
  ...(ByteData(4)..setUint32(0, payload.length + 8)).buffer.asUint8List(),
  ...type.codeUnits,
  ...payload,
];

List<int> _movieHeader(int timescale, int duration, {int version = 0}) {
  final body = ByteData(version == 0 ? 100 : 112)..setUint8(0, version);
  if (version == 0) {
    body
      ..setUint32(12, timescale)
      ..setUint32(16, duration);
  } else {
    body
      ..setUint32(20, timescale)
      ..setUint64(24, duration);
  }
  return body.buffer.asUint8List();
}

// Android's muxer writes the movie box after the media, as here.
List<int> _movie(int timescale, int duration) => [
  ..._box('ftyp', [...'mp42'.codeUnits, 0, 0, 0, 0]),
  ..._box('free', const []),
  ..._box('mdat', List.filled(4096, 7)),
  ..._box('moov', [
    ..._box('mvhd', _movieHeader(timescale, duration)),
    ..._box('trak', List.filled(16, 0)),
  ]),
];

void main() {
  const name = 'abcdefghijk-1234567890123456';
  late Directory root;
  late Directory pictures;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mits-thumbnails-');
    pictures = Directory(p.join(root.path, 'pictures'));
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  OfflineItem item(String file) => OfflineItem(
    id: file.substring(0, 11),
    title: 'A saved video',
    sourceUrl: 'https://www.youtube.com/watch?v=${file.substring(0, 11)}',
    filePath: p.join(root.path, '$file.mp4'),
    bytes: 100,
    createdAt: DateTime.utc(2026),
  );

  Future<File> video(List<int> bytes) =>
      File(p.join(root.path, '$name.mp4')).writeAsBytes(bytes);

  OfflineThumbnails thumbnails(_Frames frames) => OfflineThumbnails(
    directoryProvider: () async => pictures,
    framesFactory: () => frames,
  );

  group('readMp4Duration', () {
    test('reads the movie header when the movie follows the media', () async {
      final file = await video(_movie(30000, 59059));
      expect(await readMp4Duration(file), const Duration(milliseconds: 1968));
    });

    test('reads 64-bit box sizes and version 1 movie headers', () async {
      final movie = _box('mvhd', _movieHeader(90000, 90000 * 754, version: 1));
      final file = await video([
        ..._box('ftyp', 'isom'.codeUnits),
        ...(ByteData(4)..setUint32(0, 1)).buffer.asUint8List(),
        ...'moov'.codeUnits,
        ...(ByteData(8)..setUint64(0, movie.length + 16)).buffer.asUint8List(),
        ...movie,
      ]);
      expect(await readMp4Duration(file), const Duration(seconds: 754));
    });

    test('rejects unknown, implausible and malformed movies', () async {
      for (final bytes in [
        <int>[],
        'not a movie at all'.codeUnits,
        _movie(30000, 0xffffffff),
        _movie(0, 59059),
        _movie(1, 86400),
        // The movie box claims more bytes than the file holds.
        _movie(30000, 59059).sublist(0, 4200),
      ]) {
        expect(await readMp4Duration(await video(bytes)), isNull);
      }
    });
  });

  test(
    'takes a detailed picture a quarter of the way in and keeps it',
    () async {
      final file = await video(_movie(1000, 120000));
      final frames = _Frames([_jpeg(4096)]);
      final service = thumbnails(frames);
      final picture = await service.create(item(name), file);
      expect(picture, hasLength(4096));
      expect(frames.positions, [const Duration(seconds: 30)]);
      expect(frames.disposals, 1);
      expect(await service.stored(item(name)), picture);
      expect(pictures.listSync().map((entry) => p.basename(entry.path)), [
        '$name.jpg',
      ]);
    },
  );

  test('tries later scenes when a frame is nearly blank', () async {
    final file = await video(_movie(1000, 120000));
    var frames = _Frames([_jpeg(900), _jpeg(1500), _jpeg(1200)]);
    expect(await thumbnails(frames).create(item(name), file), hasLength(1500));
    expect(frames.positions, const [
      Duration(seconds: 30),
      Duration(seconds: 60),
      Duration(seconds: 90),
    ]);
    frames = _Frames([_jpeg(900), _jpeg(5000), _jpeg(6000)]);
    expect(await thumbnails(frames).create(item(name), file), hasLength(5000));
    expect(frames.positions, const [
      Duration(seconds: 30),
      Duration(seconds: 60),
    ]);
  });

  test('a replaced session or invalid picture stores nothing', () async {
    final file = await video(_movie(1000, 120000));
    for (final result in [null, Uint8List.fromList('not a jpeg'.codeUnits)]) {
      final frames = _Frames([result]);
      expect(await thumbnails(frames).create(item(name), file), isNull);
      expect(frames.positions, [const Duration(seconds: 30)]);
      expect(frames.disposals, 1);
    }
    expect(pictures.existsSync(), isFalse);
  });

  test('an unreadable movie header still tries an early scene', () async {
    final file = await video('no movie header'.codeUnits);
    final frames = _Frames([_jpeg(4096)]);
    expect(await thumbnails(frames).create(item(name), file), isNotNull);
    expect(frames.positions, [const Duration(seconds: 10)]);
  });

  test('files outside the saved video naming are never decoded', () async {
    var sessions = 0;
    final service = OfflineThumbnails(
      directoryProvider: () async => pictures,
      framesFactory: () {
        sessions++;
        return _Frames([_jpeg(4096)]);
      },
    );
    final imported = item('imported-video');
    expect(await service.create(imported, File(imported.filePath)), isNull);
    expect(await service.stored(imported), isNull);
    expect(sessions, 0);
  });

  test('damaged or oversized stored pictures are ignored', () async {
    final service = thumbnails(_Frames([]));
    final stored = File(p.join((await pictures.create()).path, '$name.jpg'));
    await stored.writeAsBytes('not a picture'.codeUnits);
    expect(await service.stored(item(name)), isNull);
    await stored.writeAsBytes(_jpeg(OfflineThumbnails.maximumBytes + 1));
    expect(await service.stored(item(name)), isNull);
    await stored.writeAsBytes(_jpeg(2048));
    expect(await service.stored(item(name)), hasLength(2048));
  });

  test('removes pictures only for videos no longer saved', () async {
    const deleted = 'lmnopqrstuv-1234567890123457';
    const linked = 'zyxwvutsrqp-1234567890123458';
    await pictures.create();
    for (final file in [
      '$name.jpg',
      '$deleted.jpg',
      '$deleted.jpg.tmp',
      'notes.txt',
    ]) {
      await File(p.join(pictures.path, file)).writeAsBytes([1]);
    }
    final outside = await File(
      p.join(root.path, 'outside.jpg'),
    ).writeAsBytes([1]);
    await Link(p.join(pictures.path, '$linked.jpg')).create(outside.path);
    await thumbnails(_Frames([])).removeUnused([item(name)]);
    expect(pictures.listSync().map((entry) => p.basename(entry.path)).toSet(), {
      '$name.jpg',
      'notes.txt',
      '$linked.jpg',
    });
    expect(outside.existsSync(), isTrue);
  });

  test('a linked picture directory is never read or written', () async {
    final elsewhere = await Directory(p.join(root.path, 'elsewhere')).create();
    await File(p.join(elsewhere.path, '$name.jpg')).writeAsBytes(_jpeg(2048));
    await Link(pictures.path).create(elsewhere.path);
    final file = await video(_movie(1000, 120000));
    final service = thumbnails(_Frames([_jpeg(4096)]));
    expect(await service.stored(item(name)), isNull);
    expect(await service.create(item(name), file), hasLength(4096));
    await service.removeUnused(const []);
    expect(elsewhere.listSync().map((entry) => p.basename(entry.path)), [
      '$name.jpg',
    ]);
    expect(await File(p.join(elsewhere.path, '$name.jpg')).length(), 2048);
  });
}

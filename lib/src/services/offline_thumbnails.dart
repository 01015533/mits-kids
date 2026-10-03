import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/offline_item.dart';
import 'seek_preview_frames.dart';

/// Pictures for the child's Offline list, taken from each saved local video.
/// No network, remote thumbnails or new permissions are used. The pictures are
/// only a cache: Android may clear them, and they are made again from the video.
class OfflineThumbnails {
  OfflineThumbnails({
    Future<Directory> Function()? directoryProvider,
    SeekPreviewFrames Function()? framesFactory,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _framesFactory = framesFactory ?? AndroidSeekPreviewFrames.new;

  static const maximumBytes = 128 * 1024;
  // A near-uniform 320×180 frame, such as a fade to black, is about 1 KiB.
  static const _detailedBytes = 2048;
  static final _savedVideo = RegExp(r'^[a-zA-Z0-9_-]{11}-[0-9]{16,20}$');
  static final _storedPicture = RegExp(
    r'^([a-zA-Z0-9_-]{11}-[0-9]{16,20})\.jpg(\.tmp)?$',
  );
  final Future<Directory> Function() _directoryProvider;
  final SeekPreviewFrames Function() _framesFactory;

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'offline-thumbnails'),
  );

  // Every save, including a restore, has its own file name; reuse it.
  static String? _name(OfflineItem item) {
    final name = p.basenameWithoutExtension(item.filePath);
    return p.extension(item.filePath) == '.mp4' && _savedVideo.hasMatch(name)
        ? name
        : null;
  }

  static bool isJpeg(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes.length <= maximumBytes &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[bytes.length - 2] == 0xff &&
      bytes.last == 0xd9;

  Future<Directory?> _directory({bool create = false}) async {
    final directory = await _directoryProvider();
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound && create) {
      return directory.create(recursive: true);
    }
    return type == FileSystemEntityType.directory ? directory : null;
  }

  /// A picture kept from an earlier visit, or null when it must be made.
  Future<Uint8List?> stored(OfflineItem item) async {
    final name = _name(item);
    if (name == null) return null;
    try {
      final directory = await _directory();
      if (directory == null) return null;
      final file = File(p.join(directory.path, '$name.jpg'));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final input = await file.open();
      try {
        final bytes = await input.read(maximumBytes + 1);
        return isJpeg(bytes) ? bytes : null;
      } finally {
        await input.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Takes a picture about a quarter of the way into the saved video, trying
  /// later scenes only when that frame is nearly blank. Each picture uses a
  /// new preview session and sends one request at a time.
  Future<Uint8List?> create(OfflineItem item, File video) async {
    final name = _name(item);
    if (name == null) return null;
    Duration? length;
    try {
      length = await readMp4Duration(video);
    } catch (_) {
      // An unreadable header still allows an early scene below.
    }
    final positions = length == null
        ? const [Duration(seconds: 10)]
        : [
            for (final quarter in const [1, 2, 3]) length * (quarter / 4),
          ];
    Uint8List? best;
    final frames = _framesFactory();
    try {
      for (final position in positions) {
        final bytes = (await frames.frame(video, position: position))?.bytes;
        // A newer session, such as the player's, may have replaced this one.
        if (bytes == null || !isJpeg(bytes)) break;
        if (best == null || bytes.length > best.length) best = bytes;
        if (bytes.length >= _detailedBytes) break;
      }
    } catch (_) {
      // Unsupported or damaged media leaves the list's placeholder in place.
    } finally {
      try {
        await frames.dispose();
      } catch (_) {
        // Native deadlines and session checks bound the decoder independently.
      }
    }
    if (best != null) await _store(name, best);
    return best;
  }

  Future<void> _store(String name, Uint8List bytes) async {
    try {
      final directory = await _directory(create: true);
      if (directory == null) return;
      final target = File(p.join(directory.path, '$name.jpg'));
      final pending = File('${target.path}.tmp');
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(target.path);
    } catch (_) {
      // The picture is still shown now; a later visit makes it again.
    }
  }

  /// Deletes pictures whose saved video is no longer in the library.
  Future<void> removeUnused(Iterable<OfflineItem> records) async {
    try {
      final directory = await _directory();
      if (directory == null) return;
      final keep = records.map(_name).whereType<String>().toSet();
      await for (final entity in directory.list(followLinks: false)) {
        final match = _storedPicture.firstMatch(p.basename(entity.path));
        if (entity is File && match != null && !keep.contains(match[1])) {
          await entity.delete();
        }
      }
    } catch (_) {
      // Unused pictures are only a cache; a later visit tries again.
    }
  }
}

/// The movie duration from an MP4's `moov`/`mvhd` box headers. Media is never
/// decoded here. Returns null for an unexpected or implausible structure.
Future<Duration?> readMp4Duration(File file) async {
  final input = await file.open();
  try {
    final movie = await _findBox(input, 0, await input.length(), 'moov');
    if (movie == null) return null;
    final header = await _findBox(input, movie.$1, movie.$2, 'mvhd');
    if (header == null) return null;
    await input.setPosition(header.$1);
    final body = ByteData.sublistView(
      await input.read(math.min(32, header.$2 - header.$1)),
    );
    final int timescale;
    final int duration;
    if (body.lengthInBytes >= 20 && body.getUint8(0) == 0) {
      timescale = body.getUint32(12);
      duration = body.getUint32(16);
      if (duration == 0xffffffff) return null;
    } else if (body.lengthInBytes >= 32 && body.getUint8(0) == 1) {
      timescale = body.getUint32(20);
      // All bits set means unknown; it reads as negative here.
      duration = body.getUint64(24);
    } else {
      return null;
    }
    if (timescale <= 0 || duration <= 0 || duration ~/ timescale >= 86400) {
      return null;
    }
    return Duration(milliseconds: duration * 1000 ~/ timescale);
  } finally {
    await input.close();
  }
}

/// The payload range of the first [type] box between [start] and [end].
Future<(int, int)?> _findBox(
  RandomAccessFile input,
  int start,
  int end,
  String type,
) async {
  var offset = start;
  for (var boxes = 0; boxes < 4096 && offset + 8 <= end; boxes++) {
    await input.setPosition(offset);
    final header = await input.read(16);
    if (header.length < 8) return null;
    final view = ByteData.sublistView(header);
    var size = view.getUint32(0);
    var payload = offset + 8;
    if (size == 1) {
      if (header.length < 16) return null;
      size = view.getUint64(8);
      payload = offset + 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < payload - offset || size > end - offset) return null;
    if (String.fromCharCodes(header, 4, 8) == type) {
      return (payload, offset + size);
    }
    offset += size;
  }
  return null;
}

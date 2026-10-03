import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/seek_preview_frames.dart';

/// Emits one seek on an intentional release. Playback and authorization stay
/// with the owning player; this widget only requests scene thumbnails.
class SeekPreviewTimeline extends StatefulWidget {
  const SeekPreviewTimeline({
    required this.file,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onChangeEnd,
    this.onChangeStart,
    this.onChangeCancel,
    this.frames,
    this.debounce = const Duration(milliseconds: 120),
    super.key,
  });

  final File file;
  final Duration position;
  final Duration duration;
  final bool enabled;
  final ValueChanged<Duration>? onChangeStart;
  final ValueChanged<Duration> onChangeEnd;
  final VoidCallback? onChangeCancel;
  final SeekPreviewFrames? frames;
  final Duration debounce;

  @override
  State<SeekPreviewTimeline> createState() => _SeekPreviewTimelineState();
}

class _SeekPreviewTimelineState extends State<SeekPreviewTimeline> {
  final _overlay = OverlayPortalController();
  final _track = GlobalKey();
  final _pointers = <int>{};
  late SeekPreviewFrames _frames;
  Timer? _debounce;
  Duration? _target;
  Duration? _queued;
  SeekPreviewFrame? _frame;
  bool _unavailable = false;
  bool _requestBusy = false;
  bool _cancelSent = false;
  bool _disposed = false;
  int _generation = 0;

  bool get _enabled => widget.enabled && widget.duration > Duration.zero;

  @override
  void initState() {
    super.initState();
    _frames = widget.frames ?? AndroidSeekPreviewFrames();
  }

  @override
  void didUpdateWidget(SeekPreviewTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final differentFrames = !identical(widget.frames, oldWidget.frames);
    if (!_enabled ||
        widget.file.path != oldWidget.file.path ||
        widget.duration != oldWidget.duration ||
        differentFrames) {
      final wasDragging = _target != null;
      _clear(duringBuild: true);
      if (wasDragging) {
        // didUpdateWidget runs during the parent's build. A cancellation may
        // update parent state, so notify after this frame if still cancelled.
        final generation = _generation;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation && _target == null) {
            widget.onChangeCancel?.call();
          }
        });
      }
    }
    if (differentFrames) {
      if (oldWidget.frames == null) unawaited(_frames.dispose());
      _frames = widget.frames ?? AndroidSeekPreviewFrames();
    }
  }

  Duration _position(double value) => Duration(
    milliseconds: value.round().clamp(0, widget.duration.inMilliseconds),
  );

  void _begin(double value) {
    if (!_enabled || _pointers.length > 1) return;
    final target = _position(value);
    _target = target;
    widget.onChangeStart?.call(target);
    if (!_enabled || !mounted) return;
    _update(value);
    _overlay.show();
  }

  void _update(double value) {
    if (!_enabled || _target == null) return;
    final target = _position(value);
    _generation++;
    _debounce?.cancel();
    _queued = null;
    _cancelActiveRequest();
    setState(() {
      _target = target;
      _frame = null;
      _unavailable = false;
    });
    _debounce = Timer(widget.debounce, () {
      if (!mounted || !_enabled || _target != target) return;
      _queued = target;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (_requestBusy || _queued == null || !_enabled || _target == null) return;
    final target = _queued!;
    final file = widget.file;
    final frames = _frames;
    final generation = _generation;
    _queued = null;
    _requestBusy = true;
    _cancelSent = false;
    SeekPreviewFrame? frame;
    try {
      frame = await frames.frame(file, position: target);
    } catch (_) {
      // Injected implementations can also fail. The timeline remains usable.
    } finally {
      _requestBusy = false;
      _cancelSent = false;
    }
    if (_disposed || !mounted) return;
    if (generation == _generation && _enabled && _target == target) {
      setState(() {
        _frame = frame;
        _unavailable = frame == null;
      });
    }
    if (_queued != null) unawaited(_drain());
  }

  void _finish(double value) {
    if (!_enabled || _target == null || _pointers.length > 1) return;
    final target = _position(value);
    setState(_clear);
    widget.onChangeEnd(target);
  }

  void _cancelActiveRequest() {
    if (_requestBusy && !_cancelSent) {
      _cancelSent = true;
      unawaited(_frames.cancel().catchError((Object _) {}));
    }
  }

  void _clear({bool duringBuild = false}) {
    _generation++;
    _debounce?.cancel();
    _queued = null;
    _target = null;
    _frame = null;
    _unavailable = false;
    _cancelActiveRequest();
    if (duringBuild) {
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation && _target == null) {
          _overlay.hide();
        }
      });
    } else {
      _overlay.hide();
    }
  }

  void _cancel() {
    if (_target == null) return;
    setState(_clear);
    widget.onChangeCancel?.call();
  }

  String _time(Duration position) {
    final hours = position.inHours;
    final minutes = (hours > 0 ? position.inMinutes % 60 : position.inMinutes)
        .toString()
        .padLeft(2, '0');
    final seconds = (position.inSeconds % 60).toString().padLeft(2, '0');
    return '${hours > 0 ? '$hours:' : ''}$minutes:$seconds';
  }

  Widget _preview(BuildContext context) {
    final box = _track.currentContext?.findRenderObject() as RenderBox?;
    final target = _target;
    if (box == null || !box.attached || target == null) {
      return const SizedBox.shrink();
    }
    final media = MediaQuery.of(context);
    final width = math.min(200.0, math.max(80.0, media.size.width - 24));
    final imageHeight = width * 9 / 16;
    final labelHeight = media.textScaler.scale(14) * 1.4 + 16;
    final previewHeight = imageHeight + labelHeight;
    final origin = box.localToGlobal(Offset.zero);
    final ratio = target.inMilliseconds / widget.duration.inMilliseconds;
    final thumbX = origin.dx + 24 + ratio * math.max(0, box.size.width - 48);
    final left = (thumbX - width / 2).clamp(
      12.0,
      media.size.width - width - 12,
    );
    final top = (origin.dy - previewHeight - 8).clamp(
      media.padding.top + 4,
      math.max(
        media.padding.top + 4,
        media.size.height - previewHeight - media.padding.bottom - 4,
      ),
    );
    final frame = _frame;
    final timestamp = _time(target);
    return Positioned(
      left: left,
      top: top.toDouble(),
      width: width,
      child: IgnorePointer(
        child: Material(
          key: const ValueKey('seek-scene-preview'),
          color: Theme.of(context).colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          elevation: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: imageHeight,
                width: width,
                child: frame == null
                    ? _fallback(context)
                    : Image.memory(
                        frame.bytes,
                        key: ValueKey(_generation),
                        fit: BoxFit.contain,
                        gaplessPlayback: false,
                        semanticLabel:
                            'Scene preview at ${_time(frame.position)}',
                        errorBuilder: (_, _, _) =>
                            _fallback(context, unavailable: true),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  timestamp,
                  key: const ValueKey('seek-preview-time'),
                  semanticsLabel: 'Seek to $timestamp',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onInverseSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context, {bool unavailable = false}) => Padding(
    padding: const EdgeInsets.all(8),
    child: Center(
      child: Text(
        unavailable || _unavailable
            ? 'Preview unavailable'
            : 'Loading preview…',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onInverseSurface,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final maximum = math.max(1, widget.duration.inMilliseconds).toDouble();
    final value = (_target ?? widget.position).inMilliseconds.toDouble().clamp(
      0,
      maximum,
    );
    return OverlayPortal(
      controller: _overlay,
      overlayChildBuilder: _preview,
      child: Listener(
        key: _track,
        onPointerDown: (event) {
          _pointers.add(event.pointer);
          if (_pointers.length > 1) _cancel();
        },
        onPointerUp: (event) => _pointers.remove(event.pointer),
        onPointerCancel: (event) {
          _pointers.remove(event.pointer);
          _cancel();
        },
        child: Slider(
          key: const ValueKey('playback-seek-track'),
          value: value.toDouble(),
          min: 0,
          max: maximum,
          semanticFormatterCallback: (value) =>
              'Seek to ${_time(_position(value))}',
          onChangeStart: _enabled ? _begin : null,
          onChanged: _enabled ? _update : null,
          onChangeEnd: _enabled ? _finish : null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _generation++;
    _cancelActiveRequest();
    if (widget.frames == null) unawaited(_frames.dispose());
    super.dispose();
  }
}

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;

/// Decode a BMP and return a small PNG thumbnail (or null on failure).
/// Top-level so it can run inside [Isolate.run].
Uint8List? makeBmpThumb(Uint8List bmpBytes, {int maxSide = 56}) {
  final decoded = img.decodeBmp(bmpBytes);
  if (decoded == null) return null;
  final w = decoded.width;
  final h = decoded.height;
  if (w < 1 || h < 1) return null;
  final tw = w >= h ? maxSide : (maxSide * w / h).round().clamp(1, maxSide);
  final th = h >= w ? maxSide : (maxSide * h / w).round().clamp(1, maxSide);
  final resized = img.copyResize(
    decoded,
    width: tw,
    height: th,
    // nearest is much cheaper than average for tiny previews
    interpolation: img.Interpolation.nearest,
  );
  return Uint8List.fromList(img.encodePng(resized, level: 0));
}

class _ThumbJob {
  final String path;
  final Future<Uint8List> Function() loadBytes;
  _ThumbJob(this.path, this.loadBytes);
}

/// Background thumbnail queue — keeps decode/resize off the UI isolate (desktop)
/// and serializes work so the UI stays responsive.
class ThumbLoader {
  ThumbLoader({
    required this.onUpdate,
    required this.isPaused,
  });

  final void Function(Map<String, Uint8List?> batch) onUpdate;
  final bool Function() isPaused;

  final Queue<_ThumbJob> _queue = Queue<_ThumbJob>();
  final Set<String> _queuedOrDone = {};
  bool _pumping = false;
  bool _disposed = false;
  final Map<String, Uint8List?> _pendingUi = {};
  Timer? _flushTimer;

  void enqueue(String path, Future<Uint8List> Function() loadBytes) {
    if (_disposed || _queuedOrDone.contains(path)) return;
    _queuedOrDone.add(path);
    _queue.add(_ThumbJob(path, loadBytes));
    _pump();
  }

  void enqueueMany(Iterable<(String path, Future<Uint8List> Function() loadBytes)> jobs) {
    for (final j in jobs) {
      enqueue(j.$1, j.$2);
    }
  }

  void clear() {
    _queue.clear();
    _queuedOrDone.clear();
    _pendingUi.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void dispose() {
    _disposed = true;
    clear();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        while (!_disposed && isPaused()) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        if (_disposed || _queue.isEmpty) break;

        final job = _queue.removeFirst();
        try {
          final bytes = await job.loadBytes();
          final thumb = await _decodeOffUi(bytes);
          _scheduleUi(job.path, thumb);
        } catch (_) {
          _scheduleUi(job.path, null);
        }
        // Let the event loop paint between jobs.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _pumping = false;
      if (!_disposed && _queue.isNotEmpty) {
        // Restart if something was enqueued while we were finishing.
        unawaited(_pump());
      }
    }
  }

  Future<Uint8List?> _decodeOffUi(Uint8List bytes) async {
    final side = kIsWeb ? 40 : 56;
    if (kIsWeb) {
      // Isolates aren't available on dart2js; yield then decode.
      await Future<void>.delayed(Duration.zero);
      return makeBmpThumb(bytes, maxSide: side);
    }
    return Isolate.run(() => makeBmpThumb(bytes, maxSide: side));
  }

  void _scheduleUi(String path, Uint8List? png) {
    if (_disposed) return;
    _pendingUi[path] = png;
    _flushTimer ??= Timer(const Duration(milliseconds: 64), _flushUi);
  }

  void _flushUi() {
    _flushTimer = null;
    if (_disposed || _pendingUi.isEmpty) return;
    final batch = Map<String, Uint8List?>.from(_pendingUi);
    _pendingUi.clear();
    onUpdate(batch);
  }
}

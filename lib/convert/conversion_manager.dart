import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/conversion_options.dart';
import 'convert_core.dart';
import 'worker.dart';

class FileTask {
  final String? inputPath;
  final String? outputPath;
  final Uint8List? inputBytes;
  final String outputName;
  final bool returnBytes;

  const FileTask({
    this.inputPath,
    this.outputPath,
    this.inputBytes,
    required this.outputName,
    this.returnBytes = false,
  });
}

abstract class ConversionEvent {}

class FileStarted extends ConversionEvent {
  final int index;
  FileStarted(this.index);
}

class FileProgress extends ConversionEvent {
  final int index;
  final String phase;
  final double pct;
  FileProgress(this.index, this.phase, this.pct);
}

class FileFinished extends ConversionEvent {
  final int index;
  final bool ok;
  final String? error;
  final int elapsedMs;
  final Uint8List? outputBytes;
  FileFinished(
    this.index,
    this.ok,
    this.error,
    this.elapsedMs, {
    this.outputBytes,
  });
}

class AllFinished extends ConversionEvent {
  final int successCount;
  final int failCount;
  AllFinished(this.successCount, this.failCount);
}

/// Desktop: isolate pool. Web: sequential in-memory conversion.
class ConversionManager {
  bool _cancelled = false;
  final List<Isolate> _isolates = [];
  final List<SendPort> _idleWorkers = [];
  ReceivePort? _mainReceivePort;
  StreamSubscription? _sub;

  void cancel() => _cancelled = true;

  Future<void> dispose() async {
    _sub?.cancel();
    for (final sp in _idleWorkers) {
      sp.send(const WorkerStop());
    }
    for (final iso in _isolates) {
      iso.kill(priority: Isolate.immediate);
    }
    _mainReceivePort?.close();
    _isolates.clear();
    _idleWorkers.clear();
  }

  Future<void> run({
    required List<FileTask> files,
    required ConversionOptions options,
    required void Function(ConversionEvent event) onEvent,
  }) async {
    _cancelled = false;
    if (files.isEmpty) {
      onEvent(AllFinished(0, 0));
      return;
    }

    if (kIsWeb) {
      await _runWeb(files: files, options: options, onEvent: onEvent);
    } else {
      await _runDesktop(files: files, options: options, onEvent: onEvent);
    }
  }

  Future<void> _runWeb({
    required List<FileTask> files,
    required ConversionOptions options,
    required void Function(ConversionEvent event) onEvent,
  }) async {
    var successCount = 0;
    var failCount = 0;
    var lastUiMs = 0;
    for (var i = 0; i < files.length; i++) {
      if (_cancelled) break;
      final f = files[i];
      onEvent(FileStarted(i));
      final sw = Stopwatch()..start();
      try {
        final bmp = f.inputBytes;
        if (bmp == null) throw Exception('Missing file bytes');
        final tiff = await convertBmpToTiffBytes(
          bmpBytes: bmp,
          compression: options.compression,
          pixelOrder: options.pixelOrder,
          imagePyramid: options.imagePyramid,
          jpegQuality: options.jpegQuality,
          onProgress: (phase, pct) {
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - lastUiMs < 80 && pct < 0.999) return;
            lastUiMs = now;
            onEvent(FileProgress(i, phase, pct));
          },
        );
        successCount++;
        onEvent(FileFinished(
          i,
          true,
          null,
          sw.elapsedMilliseconds,
          outputBytes: f.returnBytes ? tiff : null,
        ));
      } catch (e) {
        failCount++;
        onEvent(FileFinished(i, false, e.toString(), sw.elapsedMilliseconds));
      }
      // One yield per file is enough for the overall progress bar.
      await Future<void>.delayed(Duration.zero);
    }
    onEvent(AllFinished(successCount, failCount));
  }

  Future<void> _runDesktop({
    required List<FileTask> files,
    required ConversionOptions options,
    required void Function(ConversionEvent event) onEvent,
  }) async {
    final threadCount = options.threadCount.clamp(1, files.length);
    final mainReceivePort = ReceivePort();
    _mainReceivePort = mainReceivePort;

    final taskWorker = <int, SendPort>{};
    var nextIndex = 0;
    var completed = 0;
    var successCount = 0;
    var failCount = 0;
    final workersReady = <SendPort>[];
    final completer = Completer<void>();

    void dispatchNext(SendPort worker) {
      if (_cancelled) {
        if (workersReady.length == threadCount && taskWorker.isEmpty && !completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      if (nextIndex >= files.length) {
        _idleWorkers.add(worker);
        return;
      }
      final idx = nextIndex++;
      final f = files[idx];
      taskWorker[idx] = worker;
      onEvent(FileStarted(idx));
      worker.send(ConvertTask(
        id: idx,
        inputPath: f.inputPath,
        outputPath: f.outputPath,
        inputBytes: f.inputBytes,
        returnBytes: f.returnBytes,
        compression: options.compression,
        pixelOrder: options.pixelOrder,
        imagePyramid: options.imagePyramid,
        jpegQuality: options.jpegQuality,
      ));
    }

    _sub = mainReceivePort.listen((message) {
      if (message is WorkerReady) {
        workersReady.add(message.sendPort);
        dispatchNext(message.sendPort);
      } else if (message is ConvertProgress) {
        onEvent(FileProgress(message.id, message.phase, message.pct));
      } else if (message is ConvertResult) {
        final worker = taskWorker.remove(message.id);
        completed++;
        if (message.ok) {
          successCount++;
        } else {
          failCount++;
        }
        onEvent(FileFinished(
          message.id,
          message.ok,
          message.error,
          message.elapsedMs,
          outputBytes: message.outputBytes,
        ));
        if (completed >= files.length) {
          if (!completer.isCompleted) completer.complete();
          return;
        }
        if (worker != null) dispatchNext(worker);
      }
    });

    for (var i = 0; i < threadCount; i++) {
      final iso = await Isolate.spawn(workerMain, mainReceivePort.sendPort);
      _isolates.add(iso);
    }

    await completer.future;
    onEvent(AllFinished(successCount, failCount));
  }
}

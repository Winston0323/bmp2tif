import 'dart:isolate';
import 'dart:typed_data';

import '../platform/fs.dart' as fs;
import 'convert_core.dart';
import '../tiff/tiff_writer.dart';

/// Message sent from main isolate -> worker isolate to request a conversion.
class ConvertTask {
  final int id;
  final String? inputPath;
  final String? outputPath;
  final Uint8List? inputBytes;
  final bool returnBytes;
  final TiffCompression compression;
  final PixelOrder pixelOrder;
  final bool imagePyramid;
  final int jpegQuality;

  const ConvertTask({
    required this.id,
    this.inputPath,
    this.outputPath,
    this.inputBytes,
    this.returnBytes = false,
    required this.compression,
    required this.pixelOrder,
    required this.imagePyramid,
    required this.jpegQuality,
  });
}

/// Sent from worker -> main to report progress of the in-flight task.
class ConvertProgress {
  final int id;
  final String phase; // 'decode' | 'pyramid' | 'encode' | 'write'
  final double pct; // 0..1
  const ConvertProgress(this.id, this.phase, this.pct);
}

/// Sent from worker -> main when a task finishes (success or failure).
class ConvertResult {
  final int id;
  final bool ok;
  final String? error;
  final int? outputByteCount;
  final Uint8List? outputBytes;
  final int elapsedMs;
  const ConvertResult(
    this.id,
    this.ok,
    this.error,
    this.outputByteCount,
    this.elapsedMs, {
    this.outputBytes,
  });
}

/// First message sent worker -> main: the worker's SendPort, so main can
/// dispatch tasks to it.
class WorkerReady {
  final SendPort sendPort;
  const WorkerReady(this.sendPort);
}

/// Sent main -> worker to tell it to shut down.
class WorkerStop {
  const WorkerStop();
}

void workerMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(WorkerReady(receivePort.sendPort));

  receivePort.listen((message) async {
    if (message is WorkerStop) {
      receivePort.close();
      return;
    }
    if (message is ConvertTask) {
      final sw = Stopwatch()..start();
      try {
        final tiff = await _convertOne(message, mainSendPort);
        mainSendPort.send(ConvertResult(
          message.id,
          true,
          null,
          tiff.length,
          sw.elapsedMilliseconds,
          outputBytes: message.returnBytes ? tiff : null,
        ));
      } catch (e) {
        mainSendPort.send(ConvertResult(
          message.id,
          false,
          e.toString(),
          null,
          sw.elapsedMilliseconds,
        ));
      }
    }
  });
}

Future<Uint8List> _convertOne(ConvertTask task, SendPort reportTo) async {
  final bmpBytes = task.inputBytes ??
      (task.inputPath != null
          ? await fs.readFileBytes(task.inputPath!)
          : throw ArgumentError('ConvertTask needs inputBytes or inputPath'));

  final tiffBytes = await convertBmpToTiffBytes(
    bmpBytes: bmpBytes,
    compression: task.compression,
    pixelOrder: task.pixelOrder,
    imagePyramid: task.imagePyramid,
    jpegQuality: task.jpegQuality,
  );

  if (task.outputPath != null && task.outputPath!.isNotEmpty) {
    await fs.writeFileBytes(task.outputPath!, tiffBytes);
  }
  return tiffBytes;
}

// Integration test for the isolate-based ConversionManager (the actual code
// path used by the GUI). Run with: dart run tool/test_manager.dart
import 'dart:io';

import '../lib/convert/conversion_manager.dart';
import '../lib/models/conversion_options.dart';
import '../lib/tiff/tiff_writer.dart';

Future<void> main() async {
  final assetsDir = Directory('test_assets');
  final outDir = Directory('test_output_manager');
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync();

  final bmpFiles = assetsDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.bmp'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final tasks = bmpFiles
      .map((f) => FileTask(
            inputPath: f.path,
            outputPath: 'test_output_manager/${f.uri.pathSegments.last.replaceAll('.bmp', '.tif')}',
          ))
      .toList();

  print('Converting ${tasks.length} file(s) with 3 worker threads...');

  final manager = ConversionManager();
  final startedIdx = <int>{};
  final progressEvents = <int>[];
  final finishedResults = <FileFinished>[];
  var doneCalled = false;

  await manager.run(
    files: tasks,
    options: const ConversionOptions(
      compression: TiffCompression.lzw,
      pixelOrder: PixelOrder.interleaved,
      imagePyramid: true,
      jpegQuality: 90,
      threadCount: 3,
    ),
    onEvent: (event) {
      if (event is FileStarted) {
        startedIdx.add(event.index);
        print('  started #${event.index}: ${tasks[event.index].inputPath}');
      } else if (event is FileProgress) {
        progressEvents.add(event.index);
      } else if (event is FileFinished) {
        finishedResults.add(event);
        print('  finished #${event.index}: ok=${event.ok} error=${event.error} (${event.elapsedMs}ms)');
      } else if (event is AllFinished) {
        doneCalled = true;
        print('AllFinished: success=${event.successCount} fail=${event.failCount}');
      }
    },
  );
  await manager.dispose();

  var failures = 0;

  if (!doneCalled) {
    print('FAIL: AllFinished event never fired');
    failures++;
  }
  if (startedIdx.length != tasks.length) {
    print('FAIL: not all files were started (${startedIdx.length}/${tasks.length})');
    failures++;
  }
  if (finishedResults.length != tasks.length) {
    print('FAIL: not all files finished (${finishedResults.length}/${tasks.length})');
    failures++;
  }
  if (progressEvents.isEmpty) {
    print('FAIL: no progress events received at all');
    failures++;
  }

  // bad.bmp should fail; the two real BMPs should succeed and produce
  // non-empty, multi-page (pyramid) TIFF files.
  for (final r in finishedResults) {
    final task = tasks[r.index];
    final isBad = task.inputPath.contains('bad.bmp');
    if (isBad && r.ok) {
      print('FAIL: expected bad.bmp to fail conversion, but it succeeded');
      failures++;
    }
    if (!isBad && !r.ok) {
      print('FAIL: expected ${task.inputPath} to succeed, got error: ${r.error}');
      failures++;
    }
    if (!isBad && r.ok) {
      final outFile = File(task.outputPath);
      if (!outFile.existsSync() || outFile.lengthSync() == 0) {
        print('FAIL: output file missing/empty for ${task.inputPath}');
        failures++;
      }
    }
  }

  print('---');
  print('Failures: $failures');
  exit(failures > 0 ? 1 : 0);
}

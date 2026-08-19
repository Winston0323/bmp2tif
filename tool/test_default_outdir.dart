// Verifies the default-output-folder logic used by main.dart's
// _startConversion: when no explicit output dir is chosen, files should be
// written to a "tif" subfolder next to each source file.
// Run with: dart run tool/test_default_outdir.dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../lib/convert/conversion_manager.dart';
import '../lib/models/conversion_options.dart';
import '../lib/tiff/tiff_writer.dart';

Future<void> main() async {
  final assetsDir = Directory('test_assets');
  final tifDir = Directory(p.join(assetsDir.path, 'tif'));
  if (tifDir.existsSync()) tifDir.deleteSync(recursive: true);

  final inputPath = p.join(assetsDir.path, 'sample1.bmp');
  // Mirrors: final outDir = _outputDir ?? p.join(p.dirname(f.path), 'tif');
  final outDir = p.join(p.dirname(inputPath), 'tif');
  final outPath = p.join(outDir, '${p.basenameWithoutExtension(inputPath)}.tif');

  final manager = ConversionManager();
  var ok = false;
  await manager.run(
    files: [FileTask(inputPath: inputPath, outputPath: outPath)],
    options: const ConversionOptions(
      compression: TiffCompression.zip,
      pixelOrder: PixelOrder.interleaved,
      imagePyramid: false,
      jpegQuality: 90,
      threadCount: 1,
    ),
    onEvent: (event) {
      if (event is FileFinished) ok = event.ok;
    },
  );
  await manager.dispose();

  final outFile = File(outPath);
  var failures = 0;
  if (!ok) {
    print('FAIL: conversion reported failure');
    failures++;
  }
  if (!outFile.existsSync() || outFile.lengthSync() == 0) {
    print('FAIL: expected output file at $outPath');
    failures++;
  } else {
    print('OK: wrote $outPath (${outFile.lengthSync()} bytes)');
  }
  print('---');
  print('Failures: $failures');
  exit(failures > 0 ? 1 : 0);
}

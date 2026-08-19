// Standalone self-test for the BMP -> TIFF conversion pipeline.
// Run with: dart run tool/self_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../lib/tiff/tiff_writer.dart';

Uint8List _jpegEncode(int width, int height, Uint8List rgba) {
  final frame = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(frame, quality: 90);
}

Future<void> main() async {
  final assetsDir = Directory('test_assets');
  final outDir = Directory('test_output');
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync();

  final bmpFiles = assetsDir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.bmp')).toList();

  if (bmpFiles.isEmpty) {
    stderr.writeln('No BMP files found in test_assets/');
    exit(1);
  }

  var failures = 0;
  var total = 0;

  for (final bmpFile in bmpFiles) {
    final baseName = bmpFile.uri.pathSegments.last.replaceAll('.bmp', '');
    final bytes = bmpFile.readAsBytesSync();
    final decoded = img.decodeBmp(bytes);
    if (decoded == null) {
      stderr.writeln('FAIL decode: ${bmpFile.path}');
      failures++;
      continue;
    }
    final srcRgba = decoded.getBytes(order: img.ChannelOrder.rgba);
    print('Loaded ${bmpFile.path}: ${decoded.width}x${decoded.height}');

    for (final compression in TiffCompression.values) {
      for (final pixelOrder in PixelOrder.values) {
        if (compression == TiffCompression.jpeg && pixelOrder == PixelOrder.perChannel) {
          continue; // JPEG path ignores pixel order, skip duplicate.
        }
        for (final pyramid in [false, true]) {
          total++;
          final label = '${compression.name}_${pixelOrder.name}_pyr$pyramid';
          try {
            final pages = <TiffPage>[
              TiffPage(width: decoded.width, height: decoded.height, rgba: srcRgba),
            ];
            if (pyramid) {
              var current = decoded;
              while (current.width >= 64 && current.height >= 64) {
                final newW = current.width ~/ 2;
                final newH = current.height ~/ 2;
                if (newW < 1 || newH < 1) break;
                current = img.copyResize(current, width: newW, height: newH, interpolation: img.Interpolation.cubic);
                pages.add(TiffPage(width: current.width, height: current.height, rgba: current.getBytes(order: img.ChannelOrder.rgba)));
              }
            }

            final tiffBytes = encodeTiff(
              pages: pages,
              compression: compression,
              pixelOrder: pixelOrder,
              jpegEncoder: _jpegEncode,
            );

            final outPath = 'test_output/${baseName}_$label.tif';
            File(outPath).writeAsBytesSync(tiffBytes);

            // Verify round-trip: re-decode with package:image and compare basic properties.
            final redecoded = img.decodeTiff(tiffBytes);
            if (redecoded == null) {
              throw Exception('re-decode returned null');
            }
            if (redecoded.width != decoded.width || redecoded.height != decoded.height) {
              throw Exception('size mismatch: got ${redecoded.width}x${redecoded.height}');
            }

            if (compression == TiffCompression.none) {
              final redRgba = redecoded.getBytes(order: img.ChannelOrder.rgba);
              if (redRgba.length != srcRgba.length) {
                throw Exception('pixel byte length mismatch');
              }
              var mismatches = 0;
              for (var i = 0; i < srcRgba.length; i += 4) {
                if (srcRgba[i] != redRgba[i] || srcRgba[i + 1] != redRgba[i + 1] || srcRgba[i + 2] != redRgba[i + 2]) {
                  mismatches++;
                }
              }
              if (mismatches > 0) {
                throw Exception('$mismatches pixel mismatches out of ${srcRgba.length ~/ 4}');
              }
            }

            final pageCount = pyramid ? pages.length : 1;
            print('  OK  $label -> $outPath (${tiffBytes.length} bytes, expected $pageCount page(s))');
          } catch (e) {
            print('  FAIL $label: $e');
            failures++;
          }
        }
      }
    }
  }

  print('---');
  print('Total: $total, Failures: $failures');
  if (failures > 0) exit(1);
}

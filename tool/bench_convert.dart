// Benchmarks the actual per-file conversion pipeline (decode -> pyramid ->
// encode -> write) for a realistic image size, to find out whether the
// "UI unresponsive after clicking Start" complaint is caused by isolate
// startup (measured elsewhere to be ~15ms, not the cause) or by the sheer
// CPU cost of the first file(s) before any meaningful progress is visible.
//
// Run with: dart compile exe tool/bench_convert.dart -o build/bench_convert.exe
//           build/bench_convert.exe
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../lib/tiff/tiff_writer.dart';

Uint8List makeBmp(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, (x * 3) & 0xFF, (y * 5) & 0xFF, ((x + y) * 7) & 0xFF);
    }
  }
  return Uint8List.fromList(img.encodeBmp(image));
}

void bench(String label, void Function() f) {
  final sw = Stopwatch()..start();
  f();
  stdout.writeln('  $label: ${sw.elapsedMilliseconds}ms');
}

void main() {
  for (final size in [(1024, 768), (4000, 3000)]) {
    final (w, h) = size;
    stdout.writeln('=== ${w}x$h ===');
    late Uint8List bmpBytes;
    bench('encode source BMP', () => bmpBytes = makeBmp(w, h));

    late img.Image decoded;
    bench('decodeBmp', () => decoded = img.decodeBmp(bmpBytes)!);

    late Uint8List rgba;
    bench('getBytes(rgba)', () => rgba = decoded.getBytes(order: img.ChannelOrder.rgba));

    final pages = [TiffPage(width: decoded.width, height: decoded.height, rgba: rgba)];

    for (final comp in TiffCompression.values) {
      bench('encodeTiff [$comp, interleaved, no pyramid]', () {
        encodeTiff(
          pages: pages,
          compression: comp,
          pixelOrder: PixelOrder.interleaved,
          jpegEncoder: (w, h, rgba) {
            final frame = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
            return img.encodeJpg(frame, quality: 90);
          },
        );
      });
    }

    late img.Image resized;
    bench('pyramid copyResize (1 level, cubic)', () {
      resized = img.copyResize(decoded, width: decoded.width ~/ 2, height: decoded.height ~/ 2, interpolation: img.Interpolation.cubic);
    });
    stdout.writeln('  (resized to ${resized.width}x${resized.height})');
    bench('pyramid copyResize (1 level, average)', () {
      resized = img.copyResize(decoded, width: decoded.width ~/ 2, height: decoded.height ~/ 2, interpolation: img.Interpolation.average);
    });
    stdout.writeln('  (resized to ${resized.width}x${resized.height})');
  }
}

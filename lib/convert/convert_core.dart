import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../tiff/tiff_writer.dart';

/// In-memory BMP → TIFF conversion (web + desktop). No filesystem access.
Future<Uint8List> convertBmpToTiffBytes({
  required Uint8List bmpBytes,
  required TiffCompression compression,
  required PixelOrder pixelOrder,
  required bool imagePyramid,
  required int jpegQuality,
  void Function(String phase, double pct)? onProgress,
}) async {
  void progress(String phase, double pct) => onProgress?.call(phase, pct);

  progress('decode', 0);
  final decoded = img.decodeBmp(bmpBytes);
  if (decoded == null) {
    throw Exception('Unable to decode BMP (corrupt or unsupported)');
  }
  progress('decode', 1);

  final pages = <TiffPage>[
    TiffPage(
      width: decoded.width,
      height: decoded.height,
      rgba: decoded.getBytes(order: img.ChannelOrder.rgba),
    ),
  ];

  if (imagePyramid) {
    var current = decoded;
    var level = 0;
    while (current.width >= 64 && current.height >= 64) {
      final newW = current.width ~/ 2;
      final newH = current.height ~/ 2;
      if (newW < 1 || newH < 1) break;
      current = img.copyResize(
        current,
        width: newW,
        height: newH,
        interpolation: img.Interpolation.average,
      );
      pages.add(TiffPage(
        width: current.width,
        height: current.height,
        rgba: current.getBytes(order: img.ChannelOrder.rgba),
      ));
      level++;
      progress('pyramid', (level / 8).clamp(0, 0.9));
      await Future<void>.delayed(Duration.zero);
    }
  }

  Uint8List jpegEncode(int width, int height, Uint8List rgba) {
    final frame = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return img.encodeJpg(frame, quality: jpegQuality);
  }

  progress('encode', 0);
  final tiffBytes = await encodeTiff(
    pages: pages,
    compression: compression,
    pixelOrder: pixelOrder,
    jpegEncoder: jpegEncode,
    onProgress: (pct) => progress('encode', pct),
  );
  progress('write', 1);
  return tiffBytes;
}

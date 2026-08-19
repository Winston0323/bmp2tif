import '../tiff/tiff_writer.dart';

class ConversionOptions {
  final TiffCompression compression;
  final PixelOrder pixelOrder;
  final bool imagePyramid;
  final int jpegQuality; // 1-100, used only when compression == jpeg
  final int threadCount;

  const ConversionOptions({
    required this.compression,
    required this.pixelOrder,
    required this.imagePyramid,
    required this.jpegQuality,
    required this.threadCount,
  });

  ConversionOptions copyWith({
    TiffCompression? compression,
    PixelOrder? pixelOrder,
    bool? imagePyramid,
    int? jpegQuality,
    int? threadCount,
  }) {
    return ConversionOptions(
      compression: compression ?? this.compression,
      pixelOrder: pixelOrder ?? this.pixelOrder,
      imagePyramid: imagePyramid ?? this.imagePyramid,
      jpegQuality: jpegQuality ?? this.jpegQuality,
      threadCount: threadCount ?? this.threadCount,
    );
  }
}

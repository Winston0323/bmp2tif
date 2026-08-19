import 'dart:typed_data';

import '../platform/deflate.dart' as deflate;

import 'lzw.dart';

/// Compression modes, matching the original desktop/web BMP→TIFF tools.
enum TiffCompression { none, lzw, zip, jpeg }

/// Pixel sample arrangement (TIFF PlanarConfiguration).
enum PixelOrder { interleaved, perChannel }

/// A single page of pixel data to encode (RGBA8888, row-major, no padding).
class TiffPage {
  final int width;
  final int height;
  final Uint8List rgba;

  const TiffPage({required this.width, required this.height, required this.rgba});
}

void _putLE(Uint8List buf, int off, int val, int bytes) {
  for (var i = 0; i < bytes; i++) {
    buf[off + i] = (val >> (i * 8)) & 0xFF;
  }
}

/// Drop alpha — TIFF RGB is 3 bytes/pixel (25% less data to compress).
Uint8List rgbaToRgb(Uint8List rgba) {
  final n = rgba.length ~/ 4;
  final out = Uint8List(n * 3);
  var si = 0;
  var di = 0;
  for (var i = 0; i < n; i++) {
    out[di++] = rgba[si++];
    out[di++] = rgba[si++];
    out[di++] = rgba[si++];
    si++; // skip A
  }
  return out;
}

/// Encodes a JPEG-compressed RGB image using a minimal baseline encoder.
typedef JpegEncoderFn = Uint8List Function(int width, int height, Uint8List rgba);

class _RawCompressed {
  final int width;
  final int height;
  final List<Uint8List> strips;
  final int compTag;
  final bool planar;
  final int samples;

  _RawCompressed(
    this.width,
    this.height,
    this.strips,
    this.compTag,
    this.planar,
    this.samples,
  );
}

Future<_RawCompressed> _compressRawPage(
  TiffPage page,
  TiffCompression compression,
  PixelOrder pixelOrder,
) async {
  final planar = pixelOrder == PixelOrder.perChannel;
  final totalPx = page.width * page.height;
  const samples = 3;

  late final List<Uint8List> planes;
  if (planar) {
    final r = Uint8List(totalPx);
    final g = Uint8List(totalPx);
    final b = Uint8List(totalPx);
    final src = page.rgba;
    for (var i = 0; i < totalPx; i++) {
      final o = i * 4;
      r[i] = src[o];
      g[i] = src[o + 1];
      b[i] = src[o + 2];
    }
    planes = [r, g, b];
  } else {
    planes = [rgbaToRgb(page.rgba)];
  }

  var compTag = 1;
  Future<Uint8List> compressOne(Uint8List bytes) async {
    switch (compression) {
      case TiffCompression.zip:
        compTag = 8;
        return deflate.zlibDeflate(bytes);
      case TiffCompression.lzw:
        compTag = 5;
        return lzwEncode(bytes);
      case TiffCompression.none:
      case TiffCompression.jpeg:
        compTag = 1;
        return bytes;
    }
  }

  final strips = <Uint8List>[];
  for (final p in planes) {
    strips.add(await compressOne(p));
  }
  return _RawCompressed(page.width, page.height, strips, compTag, planar, samples);
}

class _RawLayout {
  late final int tagCount;
  late final int localDataOff;
  late final int stripCount;
  late final bool inlineStrips;
  late final List<int> stripOffsetsLocal;
  late final List<int> stripByteCounts;
  late final int bpsOff;
  late final int stripOffOff;
  late final int stripCntOff;
  late final int xrOff;
  late final int yrOff;
  late final int totalLength;
  late final int samples;

  _RawLayout(_RawCompressed r) {
    samples = r.samples;
    // No ExtraSamples when writing RGB-only.
    tagCount = 12;
    localDataOff = 2 + tagCount * 12 + 4;
    stripCount = r.strips.length;
    inlineStrips = stripCount == 1;
    final totalImageBytes = r.strips.fold<int>(0, (s, d) => s + d.length);

    stripOffsetsLocal = [];
    var off = localDataOff;
    for (final s in r.strips) {
      stripOffsetsLocal.add(off);
      off += s.length;
    }
    stripByteCounts = r.strips.map((s) => s.length).toList(growable: false);

    var overflow = localDataOff + totalImageBytes;
    bpsOff = overflow;
    overflow += samples * 2;
    stripOffOff = overflow;
    if (!inlineStrips) overflow += stripCount * 4;
    stripCntOff = overflow;
    if (!inlineStrips) overflow += stripCount * 4;
    xrOff = overflow;
    overflow += 8;
    yrOff = overflow;
    overflow += 8;
    totalLength = overflow;
  }
}

Uint8List _writeRawBlock(_RawCompressed r, _RawLayout l, int baseOffset, int nextIfdAbsOrZero) {
  final buf = Uint8List(l.totalLength);

  var pos = 0;
  _putLE(buf, pos, l.tagCount, 2);
  pos += 2;

  final inlineStripOff = baseOffset + l.stripOffsetsLocal[0];

  final tags = <List<int>>[
    [256, 4, 1, r.width],
    [257, 4, 1, r.height],
    [258, 3, r.samples, baseOffset + l.bpsOff],
    [259, 3, 1, r.compTag],
    [262, 3, 1, 2], // PhotometricInterpretation = RGB
    [273, 4, l.stripCount, l.inlineStrips ? inlineStripOff : baseOffset + l.stripOffOff],
    [277, 3, 1, r.samples],
    [278, 4, 1, r.height],
    [279, 4, l.stripCount, l.inlineStrips ? l.stripByteCounts[0] : baseOffset + l.stripCntOff],
    [282, 5, 1, baseOffset + l.xrOff],
    [283, 5, 1, baseOffset + l.yrOff],
    [284, 3, 1, r.planar ? 2 : 1],
  ];

  for (final t in tags) {
    final tag = t[0], type = t[1], count = t[2], value = t[3];
    _putLE(buf, pos, tag, 2);
    _putLE(buf, pos + 2, type, 2);
    _putLE(buf, pos + 4, count, 4);
    if (type == 3 && count == 1 && value < 0x10000) {
      _putLE(buf, pos + 8, value, 2);
      _putLE(buf, pos + 10, 0, 2);
    } else {
      _putLE(buf, pos + 8, value, 4);
    }
    pos += 12;
  }

  _putLE(buf, pos, nextIfdAbsOrZero, 4);

  var off = l.localDataOff;
  for (final s in r.strips) {
    buf.setRange(off, off + s.length, s);
    off += s.length;
  }

  for (var i = 0; i < r.samples; i++) {
    _putLE(buf, l.bpsOff + i * 2, 8, 2);
  }
  if (!l.inlineStrips) {
    for (var i = 0; i < l.stripCount; i++) {
      _putLE(buf, l.stripOffOff + i * 4, baseOffset + l.stripOffsetsLocal[i], 4);
    }
    for (var i = 0; i < l.stripCount; i++) {
      _putLE(buf, l.stripCntOff + i * 4, l.stripByteCounts[i], 4);
    }
  }
  _putLE(buf, l.xrOff, 72, 4);
  _putLE(buf, l.xrOff + 4, 1, 4);
  _putLE(buf, l.yrOff, 72, 4);
  _putLE(buf, l.yrOff + 4, 1, 4);

  return buf;
}

class _JpegLayout {
  final int tagCount = 13;
  late final int localDataOff;
  late final int bpsOff;
  late final int xrOff;
  late final int yrOff;
  late final int totalLength;

  _JpegLayout(int jpegLen) {
    localDataOff = 2 + tagCount * 12 + 4;
    var overflow = localDataOff + jpegLen;
    bpsOff = overflow;
    overflow += 6;
    xrOff = overflow;
    overflow += 8;
    yrOff = overflow;
    overflow += 8;
    totalLength = overflow;
  }
}

Uint8List _writeJpegBlock(
  int width,
  int height,
  Uint8List jpegData,
  _JpegLayout l,
  int baseOffset,
  int nextIfdAbsOrZero,
) {
  final buf = Uint8List(l.totalLength);
  var pos = 0;
  _putLE(buf, pos, l.tagCount, 2);
  pos += 2;

  final tags = <List<int>>[
    [256, 4, 1, width],
    [257, 4, 1, height],
    [258, 3, 3, baseOffset + l.bpsOff],
    [259, 3, 1, 7],
    [262, 3, 1, 6],
    [273, 4, 1, baseOffset + l.localDataOff],
    [277, 3, 1, 3],
    [278, 4, 1, height],
    [279, 4, 1, jpegData.length],
    [282, 5, 1, baseOffset + l.xrOff],
    [283, 5, 1, baseOffset + l.yrOff],
    [284, 3, 1, 1],
    [296, 3, 1, 2],
  ];

  for (final t in tags) {
    final tag = t[0], type = t[1], count = t[2], value = t[3];
    _putLE(buf, pos, tag, 2);
    _putLE(buf, pos + 2, type, 2);
    _putLE(buf, pos + 4, count, 4);
    if (type == 3 && count == 1 && value < 0x10000) {
      _putLE(buf, pos + 8, value, 2);
      _putLE(buf, pos + 10, 0, 2);
    } else {
      _putLE(buf, pos + 8, value, 4);
    }
    pos += 12;
  }

  _putLE(buf, pos, nextIfdAbsOrZero, 4);

  buf.setRange(l.localDataOff, l.localDataOff + jpegData.length, jpegData);
  _putLE(buf, l.bpsOff, 8, 2);
  _putLE(buf, l.bpsOff + 2, 8, 2);
  _putLE(buf, l.bpsOff + 4, 8, 2);
  _putLE(buf, l.xrOff, 72, 4);
  _putLE(buf, l.xrOff + 4, 1, 4);
  _putLE(buf, l.yrOff, 72, 4);
  _putLE(buf, l.yrOff + 4, 1, 4);

  return buf;
}

/// Encodes one or more pages into a single (possibly multi-page) TIFF file.
Future<Uint8List> encodeTiff({
  required List<TiffPage> pages,
  required TiffCompression compression,
  required PixelOrder pixelOrder,
  required JpegEncoderFn jpegEncoder,
  void Function(double pct)? onProgress,
}) async {
  assert(pages.isNotEmpty);

  onProgress?.call(0);
  final blocks = <Uint8List>[];
  const headerLen = 8;
  var cumulativeOffset = headerLen;

  final layouts = <Object>[];
  final rawResults = <_RawCompressed?>[];
  final jpegResults = <Uint8List?>[];

  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    if (compression == TiffCompression.jpeg) {
      final jpegBytes = jpegEncoder(page.width, page.height, page.rgba);
      jpegResults.add(jpegBytes);
      rawResults.add(null);
      layouts.add(_JpegLayout(jpegBytes.length));
    } else {
      final raw = await _compressRawPage(page, compression, pixelOrder);
      rawResults.add(raw);
      jpegResults.add(null);
      layouts.add(_RawLayout(raw));
    }
    onProgress?.call((p + 1) / pages.length * 0.85);
  }

  final baseOffsets = <int>[];
  for (var p = 0; p < pages.length; p++) {
    baseOffsets.add(cumulativeOffset);
    final layout = layouts[p];
    final len = layout is _RawLayout ? layout.totalLength : (layout as _JpegLayout).totalLength;
    cumulativeOffset += len;
  }

  for (var p = 0; p < pages.length; p++) {
    final nextIfd = p == pages.length - 1 ? 0 : baseOffsets[p + 1];
    final layout = layouts[p];
    if (layout is _RawLayout) {
      blocks.add(_writeRawBlock(rawResults[p]!, layout, baseOffsets[p], nextIfd));
    } else {
      final jl = layout as _JpegLayout;
      blocks.add(_writeJpegBlock(pages[p].width, pages[p].height, jpegResults[p]!, jl, baseOffsets[p], nextIfd));
    }
  }
  onProgress?.call(0.95);

  final header = Uint8List(headerLen);
  header[0] = 0x49;
  header[1] = 0x49;
  _putLE(header, 2, 42, 2);
  _putLE(header, 4, headerLen, 4);

  final out = BytesBuilder(copy: false);
  out.add(header);
  for (final b in blocks) {
    out.add(b);
  }
  onProgress?.call(1);
  return out.toBytes();
}

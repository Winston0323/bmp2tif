import 'dart:typed_data';

/// TIFF-spec compliant LZW encoder (MSB-first bit packing, variable code width).
///
/// Ported from the BMP→TIFF web tool's `lzwEncode` (index.html), which is the
/// canonical implementation used by this project.
///
/// The dictionary is a flat, direct-indexed table (keyed by `prefix*256+byte`,
/// which fits in a fixed [0, 2^20) range since `prefix` never exceeds 4093)
/// rather than a `Map<int,int>`. This avoids hashing/boxing overhead on every
/// single byte, which made this the dominant cost of the whole conversion for
/// large images (multiple seconds for a 12MP frame). A monotonically
/// increasing epoch counter is used to "clear" the table in O(1) instead of
/// reallocating/clearing the underlying arrays on every dictionary reset.
Uint8List lzwEncode(Uint8List data) {
  const clearCode = 256;
  const eoiCode = 257;
  const codeFirst = 258;
  const bitsMin = 9;
  // libtiff resets the table when free_ent reaches CODE_MAX-1 (4095-1=4094),
  // and bumps the code width only *after* free_ent exceeds the current
  // maxcode (i.e. one code later than a naive/GIF-style LZW encoder).
  const tableFullAt = 4094;
  // Max key = (tableFullAt - 1) * 256 + 255 = 1_048_063, so 2^20 entries
  // comfortably covers every possible (prefix, byte) pair.
  const tableSize = 1 << 20;
  final dataLen = data.length;

  final codeOf = Uint16List(tableSize);
  final epochOf = Uint32List(tableSize);
  var epoch = 1;

  int freeEnt = codeFirst;
  int nbits = bitsMin;
  int maxcode = (1 << bitsMin) - 1;

  final out = BytesBuilder(copy: false);
  int bitBuffer = 0;
  int bitCount = 0;

  void emit(int code) {
    bitBuffer = (bitBuffer << nbits) | code;
    bitCount += nbits;
    while (bitCount >= 8) {
      bitCount -= 8;
      out.addByte((bitBuffer >> bitCount) & 0xFF);
    }
    bitBuffer &= (1 << bitCount) - 1;
  }

  emit(clearCode);

  if (dataLen > 0) {
    int ent = data[0];
    for (int i = 1; i < dataLen; i++) {
      final c = data[i];
      final key = ent * 256 + c;
      if (epochOf[key] == epoch) {
        ent = codeOf[key];
        continue;
      }
      emit(ent);
      ent = c;
      epochOf[key] = epoch;
      codeOf[key] = freeEnt;
      freeEnt++;
      if (freeEnt == tableFullAt) {
        epoch++;
        emit(clearCode);
        freeEnt = codeFirst;
        nbits = bitsMin;
        maxcode = (1 << bitsMin) - 1;
      } else if (freeEnt > maxcode) {
        nbits++;
        maxcode = (1 << nbits) - 1;
      }
    }
    emit(ent);
  }
  emit(eoiCode);

  if (bitCount > 0) {
    out.addByte((bitBuffer << (8 - bitCount)) & 0xFF);
  }

  return out.toBytes();
}

import 'dart:typed_data';

import 'package:archive/archive.dart';

Future<Uint8List> zlibDeflate(Uint8List data) async {
  final encoder = ZLibEncoder();
  return Uint8List.fromList(encoder.encode(data, level: DeflateLevel.bestSpeed));
}

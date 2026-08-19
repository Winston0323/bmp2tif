import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Native browser zlib deflate — vastly faster than pure-Dart ZLibEncoder on web.
Future<Uint8List> zlibDeflate(Uint8List data) async {
  final cs = web.CompressionStream('deflate');
  final writer = cs.writable.getWriter();
  await writer.write(data.toJS).toDart;
  await writer.close().toDart;

  // Collect the compressed stream via Response — simpler than manual reader typing.
  final response = web.Response(cs.readable);
  final buffer = await response.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Triggers a browser download of [bytes] as [filename].
void downloadBytes(Uint8List bytes, String filename) {
  final data = bytes.toJS;
  final blob = web.Blob([data].toJS);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = filename;
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

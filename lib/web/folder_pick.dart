import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class WebFolderBmp {
  final String relativePath;
  final String name;
  final Uint8List bytes;
  const WebFolderBmp({
    required this.relativePath,
    required this.name,
    required this.bytes,
  });
}

class WebFolderPickResult {
  final String folderName;
  final List<WebFolderBmp> files;
  const WebFolderPickResult({required this.folderName, required this.files});
}

/// Opens a browser folder picker (webkitdirectory) and returns BMP files with bytes.
Future<WebFolderPickResult?> pickWebFolderBmps() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true;
  input.setAttribute('webkitdirectory', '');
  input.setAttribute('directory', '');

  final completer = Completer<WebFolderPickResult?>();

  void finish(WebFolderPickResult? result) {
    if (!completer.isCompleted) completer.complete(result);
    input.remove();
  }

  input.onchange = (web.Event event) {
    final list = input.files;
    if (list == null || list.length == 0) {
      finish(null);
      return;
    }
    () async {
      String? folderName;
      final bmps = <WebFolderBmp>[];
      for (var i = 0; i < list.length; i++) {
        final file = list.item(i);
        if (file == null) continue;
        final rel = file.webkitRelativePath;
        final name = file.name;
        if (folderName == null && rel.isNotEmpty) {
          final slash = rel.indexOf('/');
          folderName = slash > 0 ? rel.substring(0, slash) : rel;
        }
        if (!name.toLowerCase().endsWith('.bmp')) continue;
        final jsBuf = await file.arrayBuffer().toDart;
        final bytes = Uint8List.view(jsBuf.toDart);
        bmps.add(WebFolderBmp(
          relativePath: rel.isNotEmpty ? rel : name,
          name: name,
          bytes: bytes,
        ));
      }

      bmps.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      finish(WebFolderPickResult(
        folderName: folderName ?? 'folder',
        files: bmps,
      ));
    }();
  }.toJS;

  input.oncancel = (web.Event event) {
    finish(null);
  }.toJS;

  web.document.body!.append(input);
  input.click();
  return completer.future;
}

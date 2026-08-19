import 'dart:typed_data';

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

Future<WebFolderPickResult?> pickWebFolderBmps() async {
  throw UnsupportedError('Web folder pick is only available in the browser');
}

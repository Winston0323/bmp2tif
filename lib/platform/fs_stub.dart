import 'dart:typed_data';

Future<Uint8List> readFileBytes(String path) async {
  throw UnsupportedError('Filesystem read is not available on web');
}

Future<void> writeFileBytes(String path, Uint8List bytes) async {
  throw UnsupportedError('Filesystem write is not available on web');
}

int processorCount() => 2;

Future<List<String>> listBmpFilesRecursive(String dir) async => const [];

int fileLengthSync(String path) => 0;

Future<void> deleteFile(String path) async {}

bool fileExistsSync(String path) => false;

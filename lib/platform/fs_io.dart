import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();

Future<void> writeFileBytes(String path, Uint8List bytes) async {
  final out = File(path);
  await out.parent.create(recursive: true);
  await out.writeAsBytes(bytes, flush: true);
}

int processorCount() {
  final hw = Platform.numberOfProcessors;
  return hw < 1 ? 1 : hw;
}

Future<List<String>> listBmpFilesRecursive(String dir) async {
  final found = <String>[];
  await for (final entity in Directory(dir).list(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.toLowerCase().endsWith('.bmp')) {
      found.add(entity.path);
    }
  }
  found.sort();
  return found;
}

int fileLengthSync(String path) => File(path).lengthSync();

Future<void> deleteFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}

bool fileExistsSync(String path) => File(path).existsSync();

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../platform/fs.dart' as fs;

/// In-memory zip of name → bytes. Uses store (no deflate) for speed —
/// TIFF/BMP payloads are large and re-compressing them is usually wasted work.
Uint8List zipBytes({required Map<String, Uint8List> files}) {
  if (files.isEmpty) {
    throw Exception('No files to zip');
  }
  final archive = Archive();
  for (final entry in files.entries) {
    final file = ArchiveFile.bytes(entry.key, entry.value);
    file.compression = CompressionType.none;
    archive.addFile(file);
  }
  final encoded = ZipEncoder().encode(archive, level: DeflateLevel.none);
  if (encoded.isEmpty) {
    throw Exception('ZIP encoder produced empty output');
  }
  return Uint8List.fromList(encoded);
}

/// Zips [filePaths] into [zipPath] using each file's basename as the entry name.
/// Returns the number of files written into the archive.
Future<int> zipFiles({
  required List<String> filePaths,
  required String zipPath,
  void Function(int done, int total, String phase)? onProgress,
}) async {
  final entries = <String, Uint8List>{};
  final total = filePaths.length;
  for (var i = 0; i < filePaths.length; i++) {
    final path = filePaths[i];
    try {
      final bytes = await fs.readFileBytes(path);
      // Avoid basename collisions when multiple folders contribute same name.
      var name = p.basename(path);
      if (entries.containsKey(name)) {
        name = '${p.basenameWithoutExtension(path)}_$i${p.extension(path)}';
      }
      entries[name] = bytes;
    } catch (_) {
      // skip missing
    }
    onProgress?.call(i + 1, total, 'add');
    // Yield occasionally so the progress bar can paint without killing throughput.
    if (i % 4 == 3) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  if (entries.isEmpty) {
    throw Exception('No files found to zip');
  }

  onProgress?.call(total, total, 'encode');
  await Future<void>.delayed(Duration.zero);

  final encoded = zipBytes(files: entries);
  onProgress?.call(total, total, 'write');
  await fs.writeFileBytes(zipPath, encoded);
  return entries.length;
}

/// Default zip path inside [folder]: `Folder/FolderName_bmp.zip`.
String defaultBmpZipPath(String folder) {
  final name = p.basename(folder);
  return p.join(folder, '${name}_bmp.zip');
}

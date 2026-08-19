import 'dart:typed_data';

enum FileStatus { queued, running, done, error }

class FileEntry {
  String path;
  String name;
  final int size;
  Uint8List? bytes;
  Uint8List? outputBytes;
  FileStatus status;
  String phase;
  double pct;
  String? error;
  int? elapsedMs;

  FileEntry({
    required this.path,
    required this.name,
    required this.size,
    this.bytes,
  })  : status = FileStatus.queued,
        phase = '',
        pct = 0;
}

/// Web stub — rename-on-disk is desktop only.
String sanitizePrefix(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '').trim();
  return cleaned;
}

int compareBasenamesNatural(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

class RenamePair {
  final String from;
  final String to;
  const RenamePair(this.from, this.to);
}

class RenameResult {
  final List<RenamePair> renamed;
  final List<RenamePair> renamedFolders;
  final List<String> errors;
  const RenameResult({
    required this.renamed,
    this.renamedFolders = const [],
    required this.errors,
  });
  int get successCount => renamed.length;
  int get failCount => errors.length;
}

RenameResult renameImagesOrdered({
  required List<String> paths,
  required String prefix,
  bool renameFolders = true,
}) {
  throw UnsupportedError('Rename on disk is not available on web');
}

List<String> listImagesInDir(String dir) => const [];

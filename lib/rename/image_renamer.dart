import 'dart:io';

import 'package:path/path.dart' as p;

/// Common image extensions recognized by the renamer (lowercase, no dot).
const imageExtensions = {
  'bmp',
  'jpg',
  'jpeg',
  'png',
  'tif',
  'tiff',
  'gif',
  'webp',
};

bool isImagePath(String path) {
  final ext = p.extension(path).toLowerCase();
  if (ext.isEmpty) return false;
  return imageExtensions.contains(ext.substring(1));
}

/// One successful rename: [from] -> [to] (absolute paths).
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

/// Zero-pads [index] (1-based) so labels line up for [total] files.
String formatOrderIndex(int index, int total) {
  final width = total < 1000 ? 3 : total.toString().length;
  return index.toString().padLeft(width, '0');
}

/// Natural (numeric-aware) basename compare: img2 before img10.
/// Ordering only — the rename index itself is always a sequential file count.
int compareBasenamesNatural(String pathA, String pathB) {
  final a = p.basename(pathA);
  final b = p.basename(pathB);
  final ra = RegExp(r'\d+|\D+').allMatches(a);
  final rb = RegExp(r'\d+|\D+').allMatches(b);
  final ia = ra.iterator;
  final ib = rb.iterator;
  while (true) {
    final ha = ia.moveNext();
    final hb = ib.moveNext();
    if (!ha && !hb) return a.toLowerCase().compareTo(b.toLowerCase());
    if (!ha) return -1;
    if (!hb) return 1;
    final sa = ia.current.group(0)!;
    final sb = ib.current.group(0)!;
    final na = int.tryParse(sa);
    final nb = int.tryParse(sb);
    if (na != null && nb != null) {
      final c = na.compareTo(nb);
      if (c != 0) return c;
      // same numeric value: shorter digit run first (e.g. "2" before "02")
      final len = sa.length.compareTo(sb.length);
      if (len != 0) return len;
    } else {
      final c = sa.toLowerCase().compareTo(sb.toLowerCase());
      if (c != 0) return c;
    }
  }
}

void sortImagePaths(List<String> paths) {
  paths.sort(compareBasenamesNatural);
}

/// Sanitizes a user-supplied prefix for use in filenames / folder names.
/// Strips path separators and other illegal Windows filename characters.
String sanitizePrefix(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  s = s.replaceAll(RegExp(r'\s+'), '_');
  // Windows does not allow trailing dots/spaces in folder names.
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  return s;
}

/// Lists image files directly under [dir] (non-recursive), sorted naturally.
List<String> listImagesInDir(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return [];
  final files = d
      .listSync(followLinks: false)
      .whereType<File>()
      .map((f) => f.path)
      .where(isImagePath)
      .toList();
  sortImagePaths(files);
  return files;
}

/// Picks a free sibling folder name based on [prefix].
/// If [prefix] is free, uses it; otherwise `prefix_2`, `prefix_3`, ...
String _uniqueSiblingDir(String parent, String prefix) {
  var candidate = p.join(parent, prefix);
  if (!Directory(candidate).existsSync() && !File(candidate).existsSync()) {
    return candidate;
  }
  for (var n = 2; n < 10000; n++) {
    candidate = p.join(parent, '${prefix}_$n');
    if (!Directory(candidate).existsSync() && !File(candidate).existsSync()) {
      return candidate;
    }
  }
  return p.join(parent, '${prefix}_${DateTime.now().microsecondsSinceEpoch}');
}

/// Renames [dir] to the sanitized [prefix] (as a sibling under the same parent).
/// Returns a [RenamePair] if renamed, or null if already named that way / skipped.
/// Throws nothing; appends to [errors] on failure.
RenamePair? renameFolderToPrefix({
  required String dir,
  required String prefix,
  List<String>? errors,
}) {
  final cleanPrefix = sanitizePrefix(prefix);
  if (cleanPrefix.isEmpty) {
    errors?.add('Folder rename skipped: prefix is empty');
    return null;
  }

  final normalized = p.normalize(dir);
  final parent = p.dirname(normalized);
  final currentName = p.basename(normalized);

  if (currentName.toLowerCase() == cleanPrefix.toLowerCase()) {
    return null; // already has the desired name
  }

  final dest = _uniqueSiblingDir(parent, cleanPrefix);
  try {
    Directory(normalized).renameSync(dest);
    return RenamePair(normalized, dest);
  } catch (e) {
    errors?.add('Folder ${p.basename(normalized)} -> ${p.basename(dest)}: $e');
    return null;
  }
}

/// After folders move, rewrite any file path that lived under an old folder.
String remapPathAfterFolderRenames(String path, List<RenamePair> folderRenames) {
  var result = p.normalize(path);
  for (final folder in folderRenames) {
    final fromNorm = p.normalize(folder.from);
    if (result == fromNorm) {
      result = folder.to;
      continue;
    }
    final relative = p.relative(result, from: fromNorm);
    if (!relative.startsWith('..') && relative != '.') {
      result = p.join(folder.to, relative);
    }
  }
  return result;
}

/// Renames images to `prefix_001.ext`, `prefix_002.ext`, ...
///
/// Files are grouped by parent folder. Within each folder they are sorted by
/// name (natural order), then numbered **1..N by file count in that folder** —
/// never by parsing digits out of the old filename.
///
/// Uses a two-pass rename via unique temp names so files never overwrite each
/// other when the destination name already exists in the same folder.
RenameResult renameImagesOrdered({
  required List<String> paths,
  required String prefix,
  bool renameFolders = true,
}) {
  final cleanPrefix = sanitizePrefix(prefix);
  if (cleanPrefix.isEmpty) {
    return const RenameResult(renamed: [], errors: ['Prefix is empty']);
  }
  if (paths.isEmpty) {
    return const RenameResult(renamed: [], errors: ['No images to rename']);
  }

  // Group by parent directory, then sort each group naturally by name.
  final byDir = <String, List<String>>{};
  for (final path in paths) {
    final dir = p.normalize(p.dirname(path));
    byDir.putIfAbsent(dir, () => []).add(path);
  }
  for (final group in byDir.values) {
    sortImagePaths(group);
  }

  // Flatten in stable directory order so logging/results are predictable.
  final dirs = byDir.keys.toList()..sort();
  final ordered = <String>[];
  for (final dir in dirs) {
    ordered.addAll(byDir[dir]!);
  }

  final total = ordered.length;
  final errors = <String>[];
  final tempPaths = <String?>[];
  final stamp = DateTime.now().microsecondsSinceEpoch;

  // Pass 1: move everything to unique temp names in the same directory.
  for (var i = 0; i < total; i++) {
    final from = ordered[i];
    final dir = p.dirname(from);
    final ext = p.extension(from);
    final temp = p.join(dir, '__bmp2tif_rename_${stamp}_$i$ext');
    try {
      File(from).renameSync(temp);
      tempPaths.add(temp);
    } catch (e) {
      errors.add('${p.basename(from)}: $e');
      tempPaths.add(null);
    }
  }

  // Pass 2: assign sequential indices per folder by file count (1..N),
  // not by anything read from the old name.
  final renamed = <RenamePair>[];
  final perDirCount = <String, int>{};
  final perDirTotal = <String, int>{
    for (final e in byDir.entries) e.key: e.value.length,
  };

  for (var i = 0; i < total; i++) {
    final temp = tempPaths[i];
    if (temp == null) continue;
    final dir = p.normalize(p.dirname(temp));
    final ext = p.extension(temp);
    final seq = (perDirCount[dir] ?? 0) + 1;
    perDirCount[dir] = seq;
    final folderTotal = perDirTotal[dir] ?? total;
    final index = formatOrderIndex(seq, folderTotal);
    var dest = p.join(dir, '${cleanPrefix}_$index$ext');

    // If somehow still occupied, append a suffix rather than fail silently.
    if (File(dest).existsSync()) {
      dest = p.join(dir, '${cleanPrefix}_${index}_$stamp$ext');
    }

    try {
      File(temp).renameSync(dest);
      renamed.add(RenamePair(ordered[i], dest));
    } catch (e) {
      errors.add('${p.basename(ordered[i])} -> ${p.basename(dest)}: $e');
      // Best effort: try to restore original name from temp.
      try {
        File(temp).renameSync(ordered[i]);
      } catch (_) {}
    }
  }

  // Pass 3: rename each unique parent folder to the prefix.
  final renamedFolders = <RenamePair>[];
  if (renameFolders && renamed.isNotEmpty) {
    final folderDirs = renamed.map((r) => p.normalize(p.dirname(r.to))).toSet().toList()
      ..sort();
    for (final dir in folderDirs) {
      final pair = renameFolderToPrefix(dir: dir, prefix: cleanPrefix, errors: errors);
      if (pair != null) {
        renamedFolders.add(pair);
      }
    }

    if (renamedFolders.isNotEmpty) {
      for (var i = 0; i < renamed.length; i++) {
        final pair = renamed[i];
        final newTo = remapPathAfterFolderRenames(pair.to, renamedFolders);
        if (newTo != pair.to) {
          renamed[i] = RenamePair(pair.from, newTo);
        }
      }
    }
  }

  return RenameResult(renamed: renamed, renamedFolders: renamedFolders, errors: errors);
}

/// Convenience: list + sort + rename all images in [dir], then rename [dir]
/// itself to the prefix.
RenameResult renameImagesInDirectory({
  required String dir,
  required String prefix,
  bool renameFolders = true,
}) {
  return renameImagesOrdered(
    paths: listImagesInDir(dir),
    prefix: prefix,
    renameFolders: renameFolders,
  );
}

// Test sequential numbering by file count + natural sort.
// Run: dart run tool/test_rename.dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../lib/rename/image_renamer.dart';

Future<void> main() async {
  final root = Directory('test_rename_assets');
  if (root.existsSync()) root.deleteSync(recursive: true);
  root.createSync();

  final dir = Directory(p.join(root.path, 'photos_dump'));
  dir.createSync();

  // Lexicographic order would be: img10, img2, img9 — wrong.
  // Natural order + sequential count should be: img2->001, img9->002, img10->003.
  File(p.join(dir.path, 'img10.bmp')).writeAsBytesSync([1]);
  File(p.join(dir.path, 'img2.bmp')).writeAsBytesSync([1]);
  File(p.join(dir.path, 'img9.bmp')).writeAsBytesSync([1]);
  File(p.join(dir.path, 'notes.txt')).writeAsBytesSync([1]);

  var failures = 0;

  final result = renameImagesInDirectory(dir: dir.path, prefix: 'shot', renameFolders: false);
  if (result.successCount != 3) {
    print('FAIL: expected 3 renames, got ${result.successCount}');
    failures++;
  }

  final byFrom = {for (final r in result.renamed) p.basename(r.from): p.basename(r.to)};
  final expected = {
    'img2.bmp': 'shot_001.bmp',
    'img9.bmp': 'shot_002.bmp',
    'img10.bmp': 'shot_003.bmp',
  };
  for (final e in expected.entries) {
    if (byFrom[e.key] != e.value) {
      print('FAIL: ${e.key} -> ${byFrom[e.key]}, expected ${e.value}');
      failures++;
    } else {
      print('OK: ${e.key} -> ${e.value}');
    }
  }

  // Digits in old names must NOT become the new index (img10 must not become *_010).
  for (final r in result.renamed) {
    final to = p.basename(r.to);
    if (to.contains('_010') || to.contains('_009') || to.contains('_0020')) {
      print('FAIL: looked like index came from old name digits: $to');
      failures++;
    }
  }

  root.deleteSync(recursive: true);
  print('---');
  print('Failures: $failures');
  exit(failures > 0 ? 1 : 0);
}

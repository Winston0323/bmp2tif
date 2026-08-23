import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'convert/conversion_manager.dart';
import 'convert/thumb.dart';
import 'convert/zip_bmps.dart';
import 'models/conversion_options.dart';
import 'models/file_entry.dart';
import 'platform/download.dart';
import 'platform/env.dart';
import 'platform/folder_pick.dart';
import 'platform/fs.dart' as fs;
import 'platform/permissions.dart';
import 'rename/rename.dart';
import 'theme/app_theme.dart';
import 'tiff/tiff_writer.dart';

void main() {
  runApp(const Bmp2TifApp());
}

class Bmp2TifApp extends StatelessWidget {
  const Bmp2TifApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BMP to TIFF Converter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      // Phones only: keep text comfortably readable (at least 1.1x, capped at
      // 1.35x). System font scale is still honoured. Desktop/web untouched.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        if (!isMobile) return child;
        final systemScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(systemScale.clamp(1.1, 1.35).toDouble()),
          ),
          child: child,
        );
      },
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<FileEntry> _files = [];
  final Map<String, FileEntry> _byPath = {};

  TiffCompression _compression = TiffCompression.zip;
  PixelOrder _pixelOrder = PixelOrder.interleaved;
  bool _pyramid = false;
  double _jpegQuality = 90;
  // Leave at least one logical core free by default so the UI thread isn't
  // starved while worker isolates are doing CPU-heavy encode/resize work.
  late int _threads = () {
    final hw = fs.processorCount();
    if (hw <= 1) return 1;
    return (hw - 1).clamp(1, 4);
  }();
  int get _maxThreads => fs.processorCount().clamp(1, 32);

  String? _outputDir;
  /// True after the user picks an output path with Change (stops auto updates from prefix).
  bool _outputPathCustom = false;
  /// When true, write TIFFs into `<input>/<prefix>_tif`. When false, write into the input folder.
  bool _independentOutputFolder = false;
  /// Set when input came from a folder pick / folder drop (enables Zip BMPs).
  String? _inputFolder;
  bool _zipBmpsAfterConvert = false;
  bool _isConverting = false;
  bool _isRenaming = false;
  bool _dragOver = false;
  /// `converting` | `archiving` | `deleting` while a job is running.
  String? _jobPhase;

  // Rename: independent of convert. Triggered only by Rename Only.
  bool _renameImages = true;
  bool _renameFolderToo = true;
  late final TextEditingController _renamePrefixCtrl = TextEditingController(
    text: _defaultRenamePrefix(),
  );
  late final TextEditingController _outputDirCtrl = TextEditingController();
  String _panelStatus = '';
  bool _panelStatusError = false;

  ConversionManager? _manager;
  int _total = 0;
  int _completed = 0;
  int _successCount = 0;
  int _failCount = 0;

  late final ThumbLoader _thumbs = ThumbLoader(
    isPaused: () => _busy,
    onUpdate: (batch) {
      if (!mounted) return;
      var changed = false;
      for (final e in batch.entries) {
        final file = _byPath[e.key];
        if (file == null) continue;
        file.thumbPng = e.value;
        changed = true;
      }
      if (changed) setState(() {});
    },
  );

  bool get _busy => _isConverting || _isRenaming;
  bool get _canStart => _files.isNotEmpty && !_busy;
  bool get _canRenameNow {
    if (kIsWeb || _busy) return false;
    if (sanitizePrefix(_renamePrefixCtrl.text).isEmpty) return false;
    if (!_renameImages && !_renameFolderToo) return false;
    if (_renameFolderToo && _inputFolder == null && _files.isEmpty) return false;
    if (_renameImages && _files.isEmpty && _inputFolder == null) return false;
    return _inputFolder != null || _files.isNotEmpty;
  }

  String get _typedOutputDir => _outputDirCtrl.text.trim();

  bool get _outputFolderExists {
    if (kIsWeb) return false;
    final path = _typedOutputDir;
    return path.isNotEmpty && fs.directoryExistsSync(path);
  }

  bool get _outputFolderNeedsCreate {
    if (kIsWeb) return false;
    final path = _typedOutputDir;
    return path.isNotEmpty && !fs.directoryExistsSync(path);
  }

  void _setPanelStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _panelStatus = message;
      _panelStatusError = error;
    });
  }

  void _writeOutputCtrl(String? dir) {
    final text = dir ?? '';
    if (_outputDirCtrl.text == text) return;
    _outputDirCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _setOutputDir(String? dir, {required bool custom}) {
    final cleaned = (dir == null || dir.trim().isEmpty) ? null : dir.trim();
    _outputDir = cleaned;
    _outputPathCustom = custom;
    _writeOutputCtrl(cleaned);
  }

  static String _defaultRenamePrefix() {
    final n = DateTime.now();
    final y = n.year.toString().padLeft(4, '0');
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<bool> _ensureAndroidStorage({required String why}) async {
    if (!isAndroid) return true;
    final ok = await ensureStorageAccess();
    if (!ok) {
      _showMessage('Storage permission required to $why. Enable "All files access" for BMP to TIFF.');
    }
    return ok;
  }

  Future<void> _pickFiles() async {
    if (!await _ensureAndroidStorage(why: 'read BMP files')) return;
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['bmp'],
      withData: kIsWeb,
      dialogTitle: 'Select BMP files',
    );
    if (result == null) return;
    setState(() {
      _applyInputFolder(null);
      _zipBmpsAfterConvert = false;
    });
    if (kIsWeb) {
      _addWebFiles(result.files);
    } else {
      _addPaths(result.paths.whereType<String>().toList());
    }
  }

  Future<void> _pickFolder() async {
    if (kIsWeb) {
      final picked = await pickWebFolderBmps();
      if (picked == null) return;
      setState(() {
        _files.clear();
        _byPath.clear();
        // Synthetic folder id so UI can show folder mode on web.
        _applyInputFolder(picked.folderName);
      });
      _addWebFolderFiles(picked);
      if (picked.files.isEmpty) {
        _appendLog('No BMP files found in ${picked.folderName}');
      } else {
        _appendLog('Loaded ${picked.files.length} BMP(s) from ${picked.folderName}');
      }
      return;
    }
    if (!await _ensureAndroidStorage(why: 'open folders')) return;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Select a folder containing BMP files');
    if (dir == null) return;
    final found = await fs.listBmpFilesRecursive(dir);
    setState(() {
      _files.clear();
      _byPath.clear();
      _applyInputFolder(dir);
    });
    _addPaths(found);
    if (found.isEmpty) {
      _appendLog('No BMP files found in $dir');
      _showMessage('No BMP files found in that folder');
    }
  }

  Future<void> _pickOutputDir() async {
    if (!await _ensureAndroidStorage(why: 'choose an output folder')) return;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Select output folder');
    if (dir == null) return;
    setState(() => _setOutputDir(dir, custom: true));
  }

  Future<void> _showOutputFolder() async {
    if (kIsWeb) return;
    var path = _typedOutputDir;
    if (path.isEmpty) {
      _setPanelStatus('Set an output folder first', error: true);
      return;
    }
    if (!fs.directoryExistsSync(path)) {
      if (!await _ensureOutputFolder()) return;
      path = _typedOutputDir;
    }
    try {
      await fs.openDirectory(path);
    } catch (e) {
      _setPanelStatus('Could not open folder: $e', error: true);
    }
  }

  String _defaultOutputFolderName() {
    final prefix = sanitizePrefix(_renamePrefixCtrl.text);
    return prefix.isEmpty ? 'tif' : '${prefix}_tif';
  }

  String _autoOutputDirFor(String inputFolder) {
    if (_independentOutputFolder) {
      return p.join(inputFolder, _defaultOutputFolderName());
    }
    return inputFolder;
  }

  /// Folder input sets the output path. File-only input clears it.
  void _applyInputFolder(String? dir) {
    _inputFolder = dir;
    _setOutputDir(dir == null ? null : _autoOutputDirFor(dir), custom: false);
  }

  void _syncAutoOutputDir() {
    if (_outputPathCustom || _inputFolder == null) return;
    _setOutputDir(_autoOutputDirFor(_inputFolder!), custom: false);
  }

  void _addPaths(List<String> paths) {
    final added = <FileEntry>[];
    for (final path in paths) {
      if (!path.toLowerCase().endsWith('.bmp')) continue;
      if (_byPath.containsKey(path)) continue;
      int size;
      try {
        size = fs.fileLengthSync(path);
      } catch (_) {
        continue;
      }
      final entry = FileEntry(path: path, name: p.basename(path), size: size);
      _byPath[path] = entry;
      _files.add(entry);
      added.add(entry);
    }
    if (added.isNotEmpty) {
      setState(() {});
      _enqueueThumbs(added);
    }
  }

  void _addWebFiles(List<PlatformFile> files) {
    final added = <FileEntry>[];
    for (final f in files) {
      final name = f.name;
      if (!name.toLowerCase().endsWith('.bmp')) continue;
      final bytes = f.bytes;
      if (bytes == null) continue;
      final key = 'web://${_files.length}_$name';
      if (_byPath.containsKey(key)) continue;
      final entry = FileEntry(
        path: key,
        name: name,
        size: bytes.length,
        bytes: bytes,
      );
      _byPath[key] = entry;
      _files.add(entry);
      added.add(entry);
    }
    if (added.isNotEmpty) {
      setState(() {});
      _enqueueThumbs(added);
    }
  }

  void _addWebFolderFiles(WebFolderPickResult picked) {
    final added = <FileEntry>[];
    for (final f in picked.files) {
      final key = 'web://${picked.folderName}/${f.relativePath}';
      if (_byPath.containsKey(key)) continue;
      final entry = FileEntry(
        path: key,
        name: f.name,
        size: f.bytes.length,
        bytes: f.bytes,
      );
      _byPath[key] = entry;
      _files.add(entry);
      added.add(entry);
    }
    if (added.isNotEmpty) {
      setState(() {});
      _enqueueThumbs(added);
    }
  }

  void _enqueueThumbs(List<FileEntry> entries) {
    for (final e in entries) {
      if (e.thumbPng != null) continue;
      final path = e.path;
      final cached = e.bytes;
      _thumbs.enqueue(path, () async {
        if (cached != null) return cached;
        return fs.readFileBytes(path);
      });
    }
  }

  Future<void> _onDragDone(DropDoneDetails details) async {
    if (kIsWeb) {
      // Prefer file picker on web; drop may not include bytes.
      return;
    }
    final paths = <String>[];
    String? droppedFolder;
    Future<void> walk(dynamic item) async {
      if (item is DropItemDirectory) {
        droppedFolder ??= item.path;
        for (final child in item.children) {
          await walk(child);
        }
        if (item.children.isEmpty) {
          paths.addAll(await fs.listBmpFilesRecursive(item.path));
        }
      } else {
        paths.add(item.path as String);
      }
    }

    for (final f in details.files) {
      await walk(f);
    }

    if (droppedFolder != null) {
      setState(() {
        _files.clear();
        _byPath.clear();
        _applyInputFolder(droppedFolder);
      });
    } else {
      setState(() {
        _applyInputFolder(null);
        _zipBmpsAfterConvert = false;
      });
    }
    _addPaths(paths);
  }

  void _removeFile(int index) {
    final e = _files[index];
    _byPath.remove(e.path);
    setState(() {
      _files.removeAt(index);
      if (_files.isEmpty) {
        _applyInputFolder(null);
        _zipBmpsAfterConvert = false;
      }
    });
  }

  void _clearFiles() {
    _thumbs.clear();
    setState(() {
      _files.clear();
      _byPath.clear();
      _applyInputFolder(null);
      _zipBmpsAfterConvert = false;
    });
  }

  void _appendLog(String line) {
    debugPrint(line);
  }

  /// Renames images/folder from the Input panel selection.
  Future<bool> _renameListedFiles() async {
    final prefix = _renamePrefixCtrl.text;
    if (sanitizePrefix(prefix).isEmpty) {
      _appendLog('Rename skipped: prefix is empty');
      _setPanelStatus('Enter a name prefix first', error: true);
      return false;
    }
    if (!_renameImages && !_renameFolderToo) {
      _appendLog('Rename skipped: no target selected');
      _setPanelStatus('Select Images and/or Folder as the rename target', error: true);
      return false;
    }
    if (_inputFolder == null && _files.isEmpty) {
      _setPanelStatus('Pick BMP files or a folder in Input first', error: true);
      return false;
    }
    if (_renameFolderToo && _inputFolder == null && !_renameImages) {
      _setPanelStatus('Pick a folder to rename, or also check Images', error: true);
      return false;
    }

    if (!await _ensureAndroidStorage(why: 'rename files')) return false;

    final folder = _inputFolder;
    final List<String> paths;
    if (_renameImages) {
      if (folder != null && !kIsWeb) {
        paths = listImagesInDir(folder, recursive: true);
      } else {
        final sorted = List<FileEntry>.from(_files)
          ..sort((a, b) => compareBasenamesNatural(a.path, b.path));
        paths = sorted.map((e) => e.path).toList();
      }
    } else {
      paths = const [];
    }

    if (_renameImages && paths.isEmpty) {
      _setPanelStatus('No images found to rename', error: true);
      return false;
    }
    if (folder != null && !kIsWeb && !fs.directoryExistsSync(folder)) {
      _setPanelStatus('Folder not found: $folder', error: true);
      return false;
    }

    setState(() => _isRenaming = true);
    _appendLog('Renaming with prefix "${sanitizePrefix(prefix)}_"...');
    if (_renameImages) {
      _appendLog('  Images: ${paths.length} file(s)${folder != null ? " (recursive)" : ""}');
    }
    if (_renameFolderToo) {
      _appendLog('  Folder: ${folder ?? "(parent folders)"}');
    }

    late final RenameResult result;
    try {
      result = await Future(() => renameImagesOrdered(
            paths: paths,
            prefix: prefix,
            renameFiles: _renameImages,
            renameFolders: _renameFolderToo,
            rootFolder: folder,
          ));
      _applyRenameResult(result, renamedFrom: folder);
    } catch (e) {
      _appendLog('  FAIL  $e');
      _setPanelStatus('Rename failed: $e', error: true);
      return false;
    } finally {
      if (mounted && _isRenaming) setState(() => _isRenaming = false);
    }

    for (final pair in result.renamed) {
      _appendLog('  ${p.basename(pair.from)} -> ${p.basename(pair.to)}');
    }
    for (final pair in result.renamedFolders) {
      _appendLog('  folder ${p.basename(pair.from)} -> ${p.basename(pair.to)}');
    }
    for (final err in result.errors) {
      _appendLog('  FAIL  $err');
    }
    _appendLog('Rename done: ${result.successCount} file(s), '
        '${result.renamedFolders.length} folder(s), ${result.failCount} failed');

    final parts = <String>[];
    if (result.successCount > 0) parts.add('${result.successCount} file(s)');
    if (result.renamedFolders.isNotEmpty) {
      parts.add('${result.renamedFolders.length} folder(s)');
    }
    if (result.failCount > 0) {
      _setPanelStatus('Rename finished with ${result.failCount} error(s)'
          '${parts.isEmpty ? "" : ": ${parts.join(", ")}"}', error: true);
    } else if (parts.isEmpty) {
      _setPanelStatus(result.errors.isEmpty ? 'Nothing to rename' : result.errors.first, error: true);
    } else {
      _setPanelStatus('Renamed ${parts.join(" and ")}');
    }

    return result.failCount == 0 || result.successCount > 0 || result.renamedFolders.isNotEmpty;
  }

  void _applyRenameResult(RenameResult result, {String? renamedFrom}) {
    final pathMap = <String, String>{
      for (final pair in result.renamed) pair.from: pair.to,
    };
    final newFiles = <FileEntry>[];
    final newByPath = <String, FileEntry>{};
    for (final e in _files) {
      var newPath = pathMap[e.path] ?? e.path;
      if (result.renamedFolders.isNotEmpty) {
        newPath = remapPathAfterFolderRenames(newPath, result.renamedFolders);
      }
      e.path = newPath;
      e.name = p.basename(newPath);
      newFiles.add(e);
      newByPath[newPath] = e;
    }
    String? renamedTo;
    if (renamedFrom != null) {
      for (final pair in result.renamedFolders) {
        if (p.normalize(pair.from) == p.normalize(renamedFrom)) {
          renamedTo = pair.to;
          break;
        }
      }
    }
    setState(() {
      _files
        ..clear()
        ..addAll(newFiles);
      _byPath
        ..clear()
        ..addAll(newByPath);
      if (renamedTo != null &&
          _inputFolder != null &&
          renamedFrom != null &&
          p.normalize(_inputFolder!) == p.normalize(renamedFrom)) {
        final oldInput = _inputFolder!;
        _inputFolder = renamedTo;
        final autoOld = _autoOutputDirFor(oldInput);
        if (!_outputPathCustom &&
            _outputDir != null &&
            p.normalize(_outputDir!) == p.normalize(autoOld)) {
          _setOutputDir(_autoOutputDirFor(renamedTo), custom: false);
        }
      }
    });
  }

  Future<void> _renameNow() async {
    if (!_canRenameNow) return;
    if (!await _ensureOutputFolder()) return;
    await _renameListedFiles();
  }

  /// Creates the typed output folder if it does not exist yet.
  /// Returns false only when a path was given and creation failed.
  Future<bool> _ensureOutputFolder() async {
    if (kIsWeb) return true;
    final path = _typedOutputDir;
    if (path.isEmpty) return true;
    _outputDir = path;
    _outputPathCustom = true;
    if (fs.directoryExistsSync(path)) return true;
    try {
      await fs.createDirectory(path);
      if (mounted) {
        setState(() {
          _outputDir = path;
          _panelStatus = 'Created folder';
          _panelStatusError = false;
        });
      }
      return true;
    } catch (e) {
      _setPanelStatus('Could not create folder: $e', error: true);
      return false;
    }
  }

  Future<void> _startConversion() async {
    if (_files.isEmpty || _busy) return;

    if (!await _ensureAndroidStorage(why: 'convert and save TIFF files')) return;
    if (!await _ensureOutputFolder()) return;

    final shouldZipBmps = !kIsWeb && _zipBmpsAfterConvert && _inputFolder != null;
    final bmpPathsForZip = shouldZipBmps ? _files.map((f) => f.path).toList() : const <String>[];
    final zipFolder = _inputFolder;
    final downloadResults = kIsWeb;

    final tasks = <FileTask>[];
    for (final f in _files) {
      f.status = FileStatus.queued;
      f.phase = '';
      f.pct = 0;
      f.error = null;
      f.outputBytes = null;
      final outName = '${p.basenameWithoutExtension(f.name)}.tif';
      if (kIsWeb) {
        tasks.add(FileTask(
          inputBytes: f.bytes,
          outputName: outName,
          returnBytes: true,
        ));
      } else {
        final outDir = _outputDir ??
            (_independentOutputFolder
                ? p.join(p.dirname(f.path), _defaultOutputFolderName())
                : p.dirname(f.path));
        final outPath = p.join(outDir, outName);
        tasks.add(FileTask(
          inputPath: f.path,
          outputPath: outPath,
          outputName: outName,
        ));
      }
    }

    setState(() {
      _isConverting = true;
      _jobPhase = 'converting';
      _total = _files.length;
      _completed = 0;
      _successCount = 0;
      _failCount = 0;
    });
    _appendLog('Starting conversion of $_total file(s) '
        '(threads: ${kIsWeb ? 1 : _threads}, compression: ${_compressionLabel(_compression)}, '
        'pixel order: ${_pixelOrder == PixelOrder.interleaved ? "Interleaved" : "Per-Channel"}, '
        'pyramid: ${_pyramid ? "on" : "off"}'
        '${shouldZipBmps ? ", zip BMPs: on" : ""}'
        '${downloadResults ? ", web download: on" : ""})');

    final manager = ConversionManager();
    _manager = manager;

    final options = ConversionOptions(
      compression: _compression,
      pixelOrder: _pixelOrder,
      imagePyramid: _pyramid,
      jpegQuality: _jpegQuality.round(),
      threadCount: kIsWeb ? 1 : _threads,
    );

    final outputs = <String, Uint8List>{};
    var successCount = 0;
    await manager.run(
      files: tasks,
      options: options,
      onEvent: (event) {
        if (!mounted) return;
        if (event is FileStarted) {
          setState(() {
            final e = _files[event.index];
            e.status = FileStatus.running;
            e.phase = 'Converting';
          });
        } else if (event is FileProgress) {
          // Skip per-file progress updates — overall bar is enough and keeps convert fast.
        } else if (event is FileFinished) {
          setState(() {
            _completed++;
            final e = _files[event.index];
            e.status = event.ok ? FileStatus.done : FileStatus.error;
            e.pct = event.ok ? 1 : e.pct;
            e.phase = event.ok ? 'Converted' : 'Failed';
            e.error = event.error;
            e.elapsedMs = event.elapsedMs;
            e.outputBytes = event.outputBytes;
          });
          final name = _files[event.index].name;
          if (event.ok) {
            if (event.outputBytes != null) {
              outputs[tasks[event.index].outputName] = event.outputBytes!;
            }
            _appendLog('[$_completed/$_total] OK  $name (${event.elapsedMs} ms)');
          } else {
            _appendLog('[$_completed/$_total] FAIL  $name: ${event.error}');
          }
        } else if (event is AllFinished) {
          successCount = event.successCount;
          setState(() {
            _successCount = event.successCount;
            _failCount = event.failCount;
          });
          _appendLog('-' * 40);
          _appendLog('Done! Success: ${event.successCount}, Failed: ${event.failCount}');
        }
      },
    );
    await manager.dispose();
    _manager = null;

    if (downloadResults && outputs.isNotEmpty && mounted) {
      setState(() {
        _jobPhase = 'archiving';
        _total = 1;
        _completed = 0;
      });
      try {
        final zipName = '${sanitizePrefix(_renamePrefixCtrl.text).isEmpty ? "tif" : sanitizePrefix(_renamePrefixCtrl.text)}_tif.zip';
        final zipped = zipBytes(files: outputs);
        downloadBytes(zipped, zipName);
        _appendLog('Download ready: $zipName (${outputs.length} TIFF(s))');
        setState(() => _completed = 1);
      } catch (e) {
        _appendLog('Download zip FAIL: $e');
        for (final e in outputs.entries) {
          downloadBytes(e.value, e.key);
        }
      }
    }

    if (shouldZipBmps && zipFolder != null && successCount > 0 && mounted) {
      await _zipSourceBmps(bmpPathsForZip, zipFolder);
    }

    if (mounted) {
      setState(() {
        _isConverting = false;
        _jobPhase = null;
      });
    }
  }

  Future<void> _zipSourceBmps(List<String> bmpPaths, String folder) async {
    final zipPath = defaultBmpZipPath(folder);
    _appendLog('Zipping ${bmpPaths.length} BMP(s) -> $zipPath');
    setState(() {
      _jobPhase = 'archiving';
      _total = bmpPaths.length;
      _completed = 0;
    });
    try {
      final count = await zipFiles(
        filePaths: bmpPaths,
        zipPath: zipPath,
        onProgress: (done, total, phase) {
          if (!mounted) return;
          setState(() {
            _completed = done;
            _total = total;
          });
        },
      );
      _appendLog('ZIP OK: $count file(s) -> $zipPath');

      if (!mounted) return;
      setState(() {
        _jobPhase = 'deleting';
        _total = bmpPaths.length;
        _completed = 0;
      });

      var deleted = 0;
      for (var i = 0; i < bmpPaths.length; i++) {
        final path = bmpPaths[i];
        try {
          await fs.deleteFile(path);
          deleted++;
        } catch (e) {
          _appendLog('  DELETE FAIL  ${p.basename(path)}: $e');
        }
        if (!mounted) return;
        setState(() => _completed = i + 1);
        await Future<void>.delayed(Duration.zero);
      }
      _appendLog('Deleted $deleted BMP(s) after archive');

      if (mounted) {
        setState(() {
          for (final path in bmpPaths) {
            _byPath.remove(path);
            _files.removeWhere((e) => e.path == path);
          }
        });
      }
    } catch (e) {
      _appendLog('ZIP FAIL: $e');
    }
  }

  void _cancelConversion() {
    _manager?.cancel();
    _appendLog('Cancelling... (will stop after the current file finishes)');
  }

  String _compressionLabel(TiffCompression c) {
    switch (c) {
      case TiffCompression.none:
        return 'None';
      case TiffCompression.lzw:
        return 'LZW';
      case TiffCompression.zip:
        return 'ZIP/Deflate';
      case TiffCompression.jpeg:
        return 'JPEG';
    }
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1048576).toStringAsFixed(1)} MB';
  }

  @override
  void dispose() {
    _thumbs.dispose();
    _manager?.dispose();
    _renamePrefixCtrl.dispose();
    _outputDirCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalSize = _files.fold<int>(0, (s, f) => s + f.size);
    final overallPct = _total == 0 ? 0.0 : _completed / _total;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: AppTheme.scaffoldBackdrop(),
        child: SafeArea(
          child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'BMP \u2192 TIFF',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isMobile
                              ? 'Pick BMP files or a folder, set options, then convert.'
                              : 'Select BMP files, set options, then convert. Rename and ZIP are optional.',
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Main: Files + Settings (side-by-side on wide, stacked on phone)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Phones: stack all panels at natural height inside a single
                    // page-level scroll. Text stays full size (no scale-down),
                    // no panel grows an inner scrollbar, and the header plus
                    // action bar stay pinned above/below.
                    if (isMobile) {
                      final filesHeight = MediaQuery.sizeOf(context).height * 0.45;
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildInputPanel(totalSize),
                            const SizedBox(height: 10),
                            _buildOptionsPanel(),
                            const SizedBox(height: 10),
                            _buildRenamePanel(),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: filesHeight,
                              child: _buildFilesPanel(totalSize),
                            ),
                            const SizedBox(height: 10),
                            _buildOutputPanel(),
                          ],
                        ),
                      );
                    }
                    final narrow = constraints.maxWidth < 720;
                    final left = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _buildInputPanel(totalSize)),
                        const SizedBox(height: 10),
                        Expanded(child: _buildOptionsPanel()),
                        if (!kIsWeb) ...[
                          const SizedBox(height: 10),
                          Expanded(child: _buildRenamePanel()),
                        ],
                      ],
                    );
                    final right = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _buildFilesPanel(totalSize)),
                        const SizedBox(height: 10),
                        _buildOutputPanel(),
                      ],
                    );
                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 6, child: left),
                          const SizedBox(height: 10),
                          Expanded(flex: 5, child: right),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 4, child: left),
                        const SizedBox(width: 12),
                        Expanded(flex: 6, child: right),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),

              // Action bar: start + progress (full width)
              _buildActionBar(overallPct),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionBar(double overallPct) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _canStart ? _startConversion : null,
                  icon: Icon(_busy ? Icons.hourglass_top : Icons.play_arrow, size: 20),
                  label: Text(_jobPhase == 'archiving'
                          ? 'Archiving BMPs...'
                          : _jobPhase == 'deleting'
                              ? 'Deleting BMPs...'
                              : _isConverting
                                  ? 'Converting...'
                                  : 'Start conversion'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (_isConverting && _jobPhase == 'converting') ...[
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _cancelConversion,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
          if (_isConverting || _total > 0) ...[
            const SizedBox(height: 10),
            _buildOverallProgress(overallPct),
          ],
        ],
      ),
    );
  }

  /// Shrinks panel content to fit the available slot. Does not scroll or upscale.
  /// Mobile uses natural panel heights inside a page-level scroll, so no scaling.
  Widget _fitPanel(Widget child) {
    if (isMobile) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: constraints.maxWidth,
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildOptionsPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      alignment: Alignment.topLeft,
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: _fitPanel(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Convert', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _radioGroup<TiffCompression>(
            label: 'Compression',
            value: _compression,
            items: const {
              TiffCompression.zip: 'ZIP',
              TiffCompression.lzw: 'LZW',
              TiffCompression.none: 'None',
              TiffCompression.jpeg: 'JPEG',
            },
            onChanged: _busy ? null : (v) => setState(() => _compression = v!),
          ),
          const SizedBox(height: 4),
          _radioGroup<PixelOrder>(
            label: 'Pixel order',
            value: _pixelOrder,
            items: const {
              PixelOrder.interleaved: 'Interleaved',
              PixelOrder.perChannel: 'Per-channel',
            },
            onChanged: _busy || _compression == TiffCompression.jpeg
                ? null
                : (v) => setState(() => _pixelOrder = v!),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Checkbox(
                value: _pyramid,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: _busy ? null : (v) => setState(() => _pyramid = v ?? false),
              ),
              const SizedBox(width: 4),
              const Text('Image pyramid', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
            ],
          ),
          if (_compression == TiffCompression.jpeg) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                const Text('JPEG quality', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: _jpegQuality,
                    min: 10,
                    max: 100,
                    divisions: 90,
                    label: _jpegQuality.round().toString(),
                    onChanged: _busy ? null : (v) => setState(() => _jpegQuality = v),
                  ),
                ),
                SizedBox(
                  width: 34,
                  child: Text('${_jpegQuality.round()}', style: const TextStyle(color: AppTheme.accent, fontSize: 13)),
                ),
              ],
            ),
          ],
          if (!kIsWeb)
            Row(
              children: [
                const Text('Worker threads', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: _threads.toDouble(),
                    min: 1,
                    max: _maxThreads.toDouble(),
                    divisions: _maxThreads > 1 ? _maxThreads - 1 : 1,
                    label: '$_threads',
                    onChanged: _busy ? null : (v) => setState(() => _threads = v.round()),
                  ),
                ),
                SizedBox(
                  width: 34,
                  child: Text('$_threads', style: const TextStyle(color: AppTheme.accent, fontSize: 13)),
                ),
              ],
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildOutputPanel() {
    final zipEnabled = !_busy && _inputFolder != null;

    // Shared by desktop (inline row) and mobile (stacked) layouts below.
    final dirField = TextField(
      controller: _outputDirCtrl,
      enabled: !_busy,
      onChanged: (v) {
        _outputPathCustom = true;
        _outputDir = v.trim().isEmpty ? null : v.trim();
        setState(() {});
      },
      decoration: InputDecoration(
        isDense: true,
        labelText: 'Output folder',
        hintText: isMobile ? 'Choose or type a folder path' : r'C:\Photos\out',
        suffix: _outputPathSuffix(),
      ),
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
    );
    final dirButtons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton(
          onPressed: _busy ? null : _pickOutputDir,
          child: const Text('Change'),
        ),
        OutlinedButton.icon(
          onPressed: _busy || kIsWeb || _typedOutputDir.isEmpty
              ? null
              : _showOutputFolder,
          icon: const Icon(Icons.folder_open, size: 16),
          label: const Text('Show folder'),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('Output', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              Expanded(
                child: _panelStatus.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        _panelStatus,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _panelStatusError ? AppTheme.danger : AppTheme.success,
                          fontSize: 12,
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (kIsWeb) ...[
            const Text(
              'Converted TIFFs download as a single ZIP after conversion.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _renamePrefixCtrl,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Download prefix',
                hintText: '20260805',
              ),
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            ),
          ] else ...[
            if (isMobile) ...[
              dirField,
              const SizedBox(height: 8),
              dirButtons,
            ] else
              Row(
                children: [
                  Expanded(child: dirField),
                  const SizedBox(width: 8),
                  dirButtons,
                ],
              ),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _independentOutputFolder,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                              _independentOutputFolder = v ?? false;
                              _outputPathCustom = false;
                              _syncAutoOutputDir();
                            }),
                  ),
                  const Text(
                    'Independent folder',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
              Opacity(
                opacity: zipEnabled ? 1 : 0.45,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _zipBmpsAfterConvert,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: zipEnabled
                          ? (v) => setState(() => _zipBmpsAfterConvert = v ?? false)
                          : null,
                    ),
                    const Text(
                      'Archive BMPs',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          ],
        ],
      ),
    );
  }

  Widget _buildRenamePanel() {
    final previewPrefix = sanitizePrefix(_renamePrefixCtrl.text);
    final preview = previewPrefix.isEmpty
        ? 'prefix_001.ext'
        : (_renameFolderToo ? '$previewPrefix/${previewPrefix}_001.ext' : '${previewPrefix}_001.ext');

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      alignment: Alignment.topLeft,
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: _fitPanel(
        Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Rename', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _renamePrefixCtrl,
            enabled: !_busy,
            onChanged: (_) => setState(() => _syncAutoOutputDir()),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Name prefix',
              hintText: '20260805',
            ),
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              const Text(
                'Rename target:',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Checkbox(
                value: _renameImages,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: _busy ? null : (v) => setState(() => _renameImages = v ?? false),
              ),
              const Text('Images', style: TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
              Checkbox(
                value: _renameFolderToo,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: _busy ? null : (v) => setState(() => _renameFolderToo = v ?? false),
              ),
              const Text('Folder', style: TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            preview,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _canRenameNow ? _renameNow : null,
              icon: Icon(_isRenaming ? Icons.hourglass_top : Icons.drive_file_rename_outline, size: 18),
              label: Text(_isRenaming ? 'Renaming...' : 'Rename Only'),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget? _outputPathSuffix() {
    if (kIsWeb) return null;
    if (_outputFolderExists) {
      return const Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle, color: AppTheme.success, size: 18),
      );
    }
    if (_outputFolderNeedsCreate) {
      const yellow = Color(0xFFFFE14D);
      const outline = Color(0xFF3D3200);
      return GestureDetector(
        onTap: _busy ? null : () { _ensureOutputFolder(); },
        child: Opacity(
          opacity: _busy ? 0.5 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: yellow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                Text(
                  'create',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 1.4
                      ..color = outline,
                  ),
                ),
                const Text(
                  'create',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    color: Colors.transparent,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return null;
  }

  Widget _radioGroup<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?>? onChanged,
  }) {
    final disabled = onChanged == null;
    return RadioGroup<T>(
      groupValue: value,
      onChanged: onChanged ?? (_) {},
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 0,
        runSpacing: 0,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              label,
              softWrap: false,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          ...items.entries.map((e) {
            return InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onChanged == null ? null : () => onChanged(e.key),
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Radio<T>(
                      value: e.key,
                      enabled: !disabled,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                    ),
                    Text(
                      e.value,
                      style: TextStyle(
                        color: disabled ? AppTheme.textMuted : AppTheme.textPrimary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildOverallProgress(double pct) {
    final label = switch (_jobPhase) {
      'archiving' => 'Archiving $_completed/$_total',
      'deleting' => 'Deleting $_completed/$_total',
      _ => 'Completed $_completed/$_total  (success $_successCount, failed $_failCount)',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 10,
            backgroundColor: AppTheme.border,
            valueColor: const AlwaysStoppedAnimation(AppTheme.accentSoft),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                label,
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${(pct * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInputPanel(int totalSize) {
    final hasInput = _inputFolder != null || _files.isNotEmpty;
    final summary = _inputFolder != null
        ? _inputFolder!
        : (_files.isEmpty
            ? 'No files or folder selected'
            : '${_files.length} BMP file(s)${totalSize > 0 ? ", ${_fmtSize(totalSize)}" : ""}');

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      alignment: Alignment.topLeft,
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: _fitPanel(
        Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Input', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.surfaceInput,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasInput ? AppTheme.textPrimary : AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFiles,
                icon: const Icon(Icons.insert_drive_file_outlined, size: 16),
                label: const Text('BMP files'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: const Text('Folder'),
              ),
              if (hasInput)
                OutlinedButton(
                  onPressed: _busy ? null : _clearFiles,
                  child: const Text('Clear'),
                ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildFilesPanel(int totalSize) {
    final panel = Container(
        decoration: BoxDecoration(
          color: _dragOver ? AppTheme.accent.withValues(alpha: 0.08) : AppTheme.panel.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _dragOver ? AppTheme.accent : AppTheme.border,
            width: _dragOver ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
              child: Row(
                children: [
                  const Text('Files', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _inputFolder != null
                          ? '${_files.length} in ${p.basename(_inputFolder!)}'
                          : '${_files.length} file(s)${totalSize > 0 ? ", ${_fmtSize(totalSize)}" : ""}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _files.isEmpty
                  ? InkWell(
                      onTap: _busy ? null : _pickFolder,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isMobile ? Icons.folder_open : Icons.download,
                                size: 28,
                                color: AppTheme.accent,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                isMobile
                                    ? 'Use Input above to add BMP files or a folder'
                                    : 'Drop BMP files / folder here',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                isMobile
                                    ? 'or tap here to pick a folder'
                                    : 'or use Input above',
                                style: const TextStyle(color: AppTheme.textDim, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _files.length,
                      itemBuilder: (context, index) => _fileRow(index),
                    ),
            ),
          ],
        ),
      );

    if (isMobile) return panel;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragOver = true),
      onDragExited: (_) => setState(() => _dragOver = false),
      onDragDone: (details) {
        setState(() => _dragOver = false);
        _onDragDone(details);
      },
      child: panel,
    );
  }

  Widget _fileRow(int index) {
    final f = _files[index];
    final Color statusColor;
    final String statusText;
    final IconData statusIcon;
    switch (f.status) {
      case FileStatus.queued:
        statusColor = AppTheme.textMuted;
        statusText = _busy ? 'Waiting' : 'Ready';
        statusIcon = Icons.schedule;
        break;
      case FileStatus.running:
        statusColor = AppTheme.accent;
        statusText = 'Converting';
        statusIcon = Icons.hourglass_top;
        break;
      case FileStatus.done:
        statusColor = AppTheme.success;
        statusText = 'Converted';
        statusIcon = Icons.check_circle;
        break;
      case FileStatus.error:
        statusColor = AppTheme.danger;
        statusText = 'Failed';
        statusIcon = Icons.error_outline;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: AppTheme.panelElevated.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 48,
                height: 48,
                child: f.thumbPng != null
                    ? Image.memory(
                        f.thumbPng!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    : ColoredBox(
                        color: AppTheme.surfaceInput,
                        child: Icon(
                          Icons.image_outlined,
                          size: 22,
                          color: AppTheme.textDim,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fmtSize(f.size),
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(statusIcon, size: 16, color: statusColor),
            const SizedBox(width: 4),
            Text(
              statusText,
              style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w500),
            ),
            if (f.status == FileStatus.error && f.error != null)
              Tooltip(
                message: f.error!,
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.info_outline, size: 14, color: AppTheme.textMuted),
                ),
              ),
            if (!_busy)
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => _removeFile(index),
                icon: const Icon(Icons.close, size: 16, color: AppTheme.danger),
              ),
          ],
        ),
      ),
    );
  }
}

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
import 'platform/folder_pick.dart';
import 'platform/fs.dart' as fs;
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

  // Rename: optional step before BMP->TIFF.
  bool _renameBeforeConvert = true;
  bool _renameFolderToo = true;
  late final TextEditingController _renamePrefixCtrl = TextEditingController(
    text: _defaultRenamePrefix(),
  );

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

  static String _defaultRenamePrefix() {
    final n = DateTime.now();
    final y = n.year.toString().padLeft(4, '0');
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  Future<void> _pickFiles() async {
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
    }
  }

  Future<void> _pickOutputDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Select output folder');
    if (dir == null) return;
    setState(() {
      _outputDir = dir;
      _outputPathCustom = true;
    });
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
    _outputPathCustom = false;
    _outputDir = dir == null ? null : _autoOutputDirFor(dir);
  }

  void _syncAutoOutputDir() {
    if (_outputPathCustom || _inputFolder == null) return;
    _outputDir = _autoOutputDirFor(_inputFolder!);
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

  /// Renames files currently in the list (sorted by name) to prefix_index.
  /// Returns false if rename failed hard (empty prefix / nothing to do).
  Future<bool> _renameListedFiles() async {
    final prefix = _renamePrefixCtrl.text;
    if (sanitizePrefix(prefix).isEmpty) {
      _appendLog('Rename skipped: prefix is empty');
      return false;
    }

    final sorted = List<FileEntry>.from(_files)
      ..sort((a, b) => compareBasenamesNatural(a.path, b.path));
    final paths = sorted.map((e) => e.path).toList();

    setState(() => _isRenaming = true);
    _appendLog('Renaming ${paths.length} file(s) with prefix "${sanitizePrefix(prefix)}_"...');
    if (_renameFolderToo) {
      _appendLog('Also renaming parent folder(s) to "${sanitizePrefix(prefix)}"');
    }

    final result = await Future(() => renameImagesOrdered(
          paths: paths,
          prefix: prefix,
          renameFolders: _renameFolderToo,
        ));

    // Rebuild list + path map from rename results / leftovers.
    final pathMap = <String, String>{
      for (final pair in result.renamed) pair.from: pair.to,
    };
    final newFiles = <FileEntry>[];
    final newByPath = <String, FileEntry>{};
    for (final e in sorted) {
      final newPath = pathMap[e.path] ?? e.path;
      e.path = newPath;
      e.name = p.basename(newPath);
      newFiles.add(e);
      newByPath[newPath] = e;
    }
    setState(() {
      _files
        ..clear()
        ..addAll(newFiles);
      _byPath
        ..clear()
        ..addAll(newByPath);
      if (_inputFolder != null) {
        for (final pair in result.renamedFolders) {
          if (p.normalize(pair.from) == p.normalize(_inputFolder!)) {
            final oldInput = _inputFolder!;
            _inputFolder = pair.to;
            // Keep auto output under the renamed folder.
            final autoOld = _autoOutputDirFor(oldInput);
            if (!_outputPathCustom &&
                _outputDir != null &&
                p.normalize(_outputDir!) == p.normalize(autoOld)) {
              _outputDir = _autoOutputDirFor(pair.to);
            }
            break;
          }
        }
      }
      _isRenaming = false;
    });

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
    return result.failCount == 0 || result.successCount > 0;
  }

  Future<void> _startConversion() async {
    if (_files.isEmpty || _busy) return;

    if (!kIsWeb && _renameBeforeConvert) {
      final ok = await _renameListedFiles();
      if (!ok) return;
    }

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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'BMP \u2192 TIFF',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Select BMP files, set options, then convert. Rename and ZIP are optional.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                  if (_inputFolder != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppTheme.panel,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Text(
                        'Folder: ${p.basename(_inputFolder!)}',
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // Main: Files (left) + Settings (right)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: _buildFilesPanel(totalSize)),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildOptionsPanel(),
                            const SizedBox(height: 10),
                            _buildOutputPanel(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Action bar: start + progress (full width)
              _buildActionBar(overallPct),
            ],
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
                  label: Text(_isRenaming
                      ? 'Renaming...'
                      : _jobPhase == 'archiving'
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

  Widget _buildOptionsPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
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
                  width: 28,
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
                  width: 28,
                  child: Text('$_threads', style: const TextStyle(color: AppTheme.accent, fontSize: 13)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildOutputPanel() {
    final previewPrefix = sanitizePrefix(_renamePrefixCtrl.text);
    final preview = previewPrefix.isEmpty
        ? 'prefix_001.ext'
        : (_renameFolderToo ? '$previewPrefix/${previewPrefix}_001.ext' : '${previewPrefix}_001.ext');
    final zipEnabled = !_busy && _inputFolder != null;

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
          const Text('Output', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
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
          Row(
            children: [
              const Text(
                'Output folder:',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceInput,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Text(
                    _outputDir ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _outputDir == null ? AppTheme.textMuted : AppTheme.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy ? null : _pickOutputDir,
                child: const Text('Change'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
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
              const SizedBox(width: 4),
              const Text(
                'Independent folder',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _independentOutputFolder
                      ? '→ ${_defaultOutputFolderName()}'
                      : '→ same as input folder',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
          Row(
            children: [
              const Text(
                'Rename Target:',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Checkbox(
                value: _renameBeforeConvert,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: _busy ? null : (v) => setState(() => _renameBeforeConvert = v ?? false),
              ),
              const Text('Images', style: TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
              const SizedBox(width: 8),
              Checkbox(
                value: _renameFolderToo,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: _busy ? null : (v) => setState(() => _renameFolderToo = v ?? false),
              ),
              const Text('Folder', style: TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  preview,
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Opacity(
            opacity: zipEnabled ? 1 : 0.45,
            child: Row(
              children: [
                Checkbox(
                  value: _zipBmpsAfterConvert,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: zipEnabled
                      ? (v) => setState(() => _zipBmpsAfterConvert = v ?? false)
                      : null,
                ),
                const SizedBox(width: 4),
                const Text(
                  'Archive BMPs',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
          ],
        ],
      ),
    );
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

  Widget _buildFilesPanel(int totalSize) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragOver = true),
      onDragExited: (_) => setState(() => _dragOver = false),
      onDragDone: (details) {
        setState(() => _dragOver = false);
        _onDragDone(details);
      },
      child: Container(
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
                  IconButton(
                    tooltip: 'Add files',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: _busy ? null : _pickFiles,
                    icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Add folder',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: _busy ? null : _pickFolder,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                  ),
                  const SizedBox(width: 4),
                  OutlinedButton(
                    onPressed: _busy || _files.isEmpty ? null : _clearFiles,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: const Text('Clear files'),
                  ),
                ],
              ),
            ),
            if (_inputFolder != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Text(
                  _inputFolder!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.textDim, fontSize: 10),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: _files.isEmpty
                  ? InkWell(
                      onTap: _busy ? null : _pickFolder,
                      child: const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.download, size: 28, color: AppTheme.accent),
                              SizedBox(height: 8),
                              Text(
                                'Drop BMP files / folder here',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'or use the buttons above',
                                style: TextStyle(color: AppTheme.textDim, fontSize: 11),
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
      ),
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

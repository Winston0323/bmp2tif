// Benchmarks isolate pool startup cost (the real workerMain from the app),
// both sequential (current behavior) and parallel spawn, so we can see
// exactly where the "start conversion" UI delay comes from.
//
// Run with the SAME artifact type the app ships as, e.g.:
//   dart compile exe tool/bench_spawn.dart -o build/bench_spawn.exe
//   build/bench_spawn.exe
import 'dart:io';
import 'dart:isolate';

import '../lib/convert/worker.dart';

Future<int> spawnSequential(int n) async {
  final sw = Stopwatch()..start();
  final rp = ReceivePort();
  final isolates = <Isolate>[];
  var readyCount = 0;
  final firstReadyMs = <int>[];
  final sub = rp.listen((m) {
    if (m is WorkerReady) {
      readyCount++;
      firstReadyMs.add(sw.elapsedMilliseconds);
    }
  });
  for (var i = 0; i < n; i++) {
    isolates.add(await Isolate.spawn(workerMain, rp.sendPort));
  }
  while (readyCount < n) {
    await Future.delayed(const Duration(milliseconds: 1));
  }
  final total = sw.elapsedMilliseconds;
  print('  sequential spawn($n): total=${total}ms readyTimes=$firstReadyMs');
  await sub.cancel();
  rp.close();
  for (final iso in isolates) {
    iso.kill(priority: Isolate.immediate);
  }
  return total;
}

Future<int> spawnParallel(int n) async {
  final sw = Stopwatch()..start();
  final rp = ReceivePort();
  var readyCount = 0;
  final firstReadyMs = <int>[];
  final sub = rp.listen((m) {
    if (m is WorkerReady) {
      readyCount++;
      firstReadyMs.add(sw.elapsedMilliseconds);
    }
  });
  final isolates = await Future.wait(List.generate(n, (_) => Isolate.spawn(workerMain, rp.sendPort)));
  while (readyCount < n) {
    await Future.delayed(const Duration(milliseconds: 1));
  }
  final total = sw.elapsedMilliseconds;
  print('  parallel   spawn($n): total=${total}ms readyTimes=$firstReadyMs');
  await sub.cancel();
  rp.close();
  for (final iso in isolates) {
    iso.kill(priority: Isolate.immediate);
  }
  return total;
}

Future<void> main() async {
  print('mode: ${const bool.fromEnvironment('dart.vm.product') ? "AOT/release" : "JIT/debug"}');
  for (final n in [1, 2, 4, 8]) {
    await spawnSequential(n);
    await spawnParallel(n);
  }
  exit(0);
}

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import '../models/folder_info.dart';

class ScanParams {
  final String path;
  final SendPort sendPort;
  final String? userProfilePath;
  ScanParams(this.path, this.sendPort, {this.userProfilePath});
}

Future<int> _scanDirectoryRecursive(
    Directory dir, SendPort sendPort, int sizeThreshold, String? userProfilePath) async {
  int totalSize = 0;
  try {
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (entity is File) {
        totalSize += await entity.length();
      } else if (entity is Directory) {
        totalSize += await _scanDirectoryRecursive(entity, sendPort, sizeThreshold, userProfilePath);
      }
    }
  } catch (e) {
    sendPort.send({'type': 'error', 'message': 'Cannot access ${dir.path}'});

  }

  if (totalSize > sizeThreshold && dir.path != userProfilePath) {
    sendPort.send({'type': 'result', 'path': dir.path, 'size': totalSize});
  }
  return totalSize;
}

Future<void> scanFoldersIsolate(ScanParams params) async {
  final path = params.path;
  final sendPort = params.sendPort;
  final userProfilePath = params.userProfilePath;
  const sizeThreshold = 500 * 1024 * 1024;

  final root = Directory(path);
  if (!await root.exists()) {
    sendPort.send({'type': 'error', 'message': 'Directory not found: $path'});
    return;
  }

  final List<Directory> topLevelDirsToScan = [];
  final topLevelExclusions = {
    r'C:\Windows',
    r'$Recycle.Bin',
    r'C:\Users',
  }.map((p) => p.toLowerCase()).toSet();

  try {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory) {
        if (!topLevelExclusions.contains(entity.path.toLowerCase())) {
          topLevelDirsToScan.add(entity);
        }
      }
    }
    if (userProfilePath != null && Directory(userProfilePath).existsSync()) {
      if (!topLevelDirsToScan.any((dir) => dir.path == userProfilePath)) {
        topLevelDirsToScan.add(Directory(userProfilePath));
      }
    }
  } catch (e) {
    sendPort.send({'type': 'error', 'message': 'Cannot access drive: $path'});
    return;
  }

  int completedDirs = 0;
  for (final dir in topLevelDirsToScan) {
    await _scanDirectoryRecursive(dir, sendPort, sizeThreshold, userProfilePath);
    completedDirs++;
    final progress = topLevelDirsToScan.isNotEmpty
        ? (completedDirs * 100) ~/ topLevelDirsToScan.length
        : 100;
    sendPort.send({'type': 'progress', 'value': progress});
  }
  sendPort.send({'type': 'complete'});
}

class DiskScannerService {
  Isolate? _mainScanIsolate;
  final ReceivePort _mainReceivePort = ReceivePort();

  Stream<Map<String, dynamic>> get scanEventsStream =>
      _mainReceivePort.asBroadcastStream().map((event) => event as Map<String, dynamic>);

  Future<void> startScan(String drivePath) async {
    stopScan();
    final userProfilePath = Platform.environment['USERPROFILE'];

    _mainScanIsolate = await Isolate.spawn(
        scanFoldersIsolate, ScanParams(drivePath, _mainReceivePort.sendPort, userProfilePath: userProfilePath));
  }

  Future<List<FolderInfo>> scanSubdirectory(String path) async {
    final completer = Completer<List<FolderInfo>>();
    final receivePort = ReceivePort();

    final isolate = await Isolate.spawn(
        scanFoldersIsolate, ScanParams(path, receivePort.sendPort, userProfilePath: null));

    final subResults = <FolderInfo>[];
    receivePort.listen((message) {
      final event = message as Map<String, dynamic>;
      if (event['type'] == 'result') {
        subResults.add(FolderInfo(path: event['path'], sizeInBytes: event['size']));
      } else if (event['type'] == 'complete' || event['type'] == 'error') {
        isolate.kill();
        receivePort.close();
        subResults.sort((a, b) => b.sizeInBytes.compareTo(a.sizeInBytes));
        completer.complete(subResults);
      }
    });

    return completer.future;
  }

  void stopScan() {
    _mainScanIsolate?.kill(priority: Isolate.immediate);
    _mainScanIsolate = null;
  }
}
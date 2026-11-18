import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// One file inside a folder chosen for upload.
class LocalFile {
  final String rel; // path inside the folder, with '/' separators
  final int size;
  final Stream<Uint8List> Function() open;
  LocalFile(this.rel, this.size, this.open);
}

/// A folder picked on this device, ready to be uploaded.
class LocalFolder {
  final String name;
  final List<String> dirs; // every sub-folder (relative), including empty ones
  final List<LocalFile> files;
  LocalFolder(this.name, this.dirs, this.files);

  int get totalBytes => files.fold(0, (a, f) => a + f.size);

  static const _ch = MethodChannel('phoenicx_ssh/keepalive');

  /// Shows the system folder picker. Returns null if the user cancels.
  static Future<LocalFolder?> pick() async {
    final uri = await FilePicker.pickDirectory(dialogTitle: 'Choose a folder to upload');
    if (uri == null) return null;
    if (Platform.isAndroid && uri.scheme == 'content') return _fromAndroid(uri);
    final path = uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
    return fromDirectory(Directory(path));
  }

  /// Desktop (and tests): read the folder straight from disk.
  static Future<LocalFolder> fromDirectory(Directory dir) async {
    final root = dir.absolute.path;
    final name = root.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).last;
    final dirs = <String>[];
    final files = <LocalFile>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      final rel = e.path.substring(root.length).replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
      if (rel.isEmpty) continue;
      if (e is Directory) {
        dirs.add(rel);
      } else if (e is File) {
        final f = e;
        int size;
        try {
          size = await f.length();
        } catch (_) {
          continue; // locked or vanished
        }
        files.add(LocalFile(rel, size, () => f.openRead().map((c) => c is Uint8List ? c : Uint8List.fromList(c))));
      }
    }
    return LocalFolder(name, dirs, files);
  }

  static Future<LocalFolder> _fromAndroid(Uri tree) async {
    final r = Map<String, dynamic>.from(await _ch.invokeMethod('listTree', {'uri': tree.toString()}) as Map);
    final files = <LocalFile>[];
    for (final raw in (r['files'] as List)) {
      final m = Map<String, dynamic>.from(raw as Map);
      final uri = m['uri'] as String;
      files.add(LocalFile(m['path'] as String, (m['size'] as num).toInt(), () => _androidStream(uri)));
    }
    return LocalFolder(
      r['name'] as String? ?? 'folder',
      [for (final d in (r['dirs'] as List)) d as String],
      files,
    );
  }

  /// Reads a content:// file in 256 KB chunks (no copy, no big memory use).
  static Stream<Uint8List> _androidStream(String uri) async* {
    final h = await _ch.invokeMethod<int>('openRead', {'uri': uri});
    try {
      while (true) {
        final chunk = await _ch.invokeMethod<Uint8List>('read', {'h': h, 'n': 262144});
        if (chunk == null) break;
        yield chunk;
      }
    } finally {
      await _ch.invokeMethod('closeRead', {'h': h});
    }
  }
}

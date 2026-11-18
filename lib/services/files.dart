import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'local_folder.dart';
import 'session.dart';

/// One entry in a remote folder.
class RemoteEntry {
  final String name;
  final String path;
  final bool isDir;
  final bool isLink;
  final int size;
  final DateTime? modified;
  final int mode; // permission bits, e.g. 0x1a4 (= 0644)

  RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.isLink,
    required this.size,
    required this.modified,
    required this.mode,
  });

  String get perms => (mode & 0x1ff).toRadixString(8).padLeft(3, '0');
  bool get hidden => name.startsWith('.');
}

enum TransferState { running, done, failed, cancelled }

class Transfer extends ChangeNotifier {
  final String name;
  final bool upload;
  final String remotePath;
  int total;
  int done = 0;
  TransferState state = TransferState.running;
  String? error;
  String? detail; // folder uploads: "12 of 340 files · current/file.txt"
  bool isFolder = false;
  String? savedTo; // downloads: where the file ended up
  String? localPath; // downloads on desktop: full path to open
  final _started = DateTime.now();
  DateTime _lastTick = DateTime.now();
  int _lastBytes = 0;
  double speed = 0; // bytes/s
  Future<void> Function()? _cancel;

  Transfer({required this.name, required this.upload, required this.remotePath, required this.total});

  double get progress => total <= 0 ? (state == TransferState.done ? 1 : 0) : (done / total).clamp(0, 1).toDouble();
  bool get active => state == TransferState.running;
  Duration get elapsed => DateTime.now().difference(_started);

  void _progress(int bytes) {
    done = bytes;
    final now = DateTime.now();
    final ms = now.difference(_lastTick).inMilliseconds;
    if (ms >= 250) {
      speed = (bytes - _lastBytes) * 1000 / ms;
      _lastBytes = bytes;
      _lastTick = now;
      notifyListeners();
    }
  }

  void _finish(TransferState s, [String? err]) {
    if (state != TransferState.running) return;
    state = s;
    error = err;
    if (s == TransferState.done && total > 0) done = total;
    notifyListeners();
  }

  Future<void> cancel() async {
    if (!active) return;
    final c = _cancel;
    _finish(TransferState.cancelled);
    try {
      await c?.call();
    } catch (_) {}
  }
}

/// SFTP file browser + transfers for one SSH tab. Uses the tab's existing
/// connection, so nothing has to be installed on the server.
class FileService extends ChangeNotifier {
  final SshTab tab;
  FileService(this.tab);

  SftpClient? _sftp;
  SSHClient? _sftpFor;
  Future<SftpClient>? _opening;

  String? cwd;
  String? home;
  final List<Transfer> transfers = [];

  static const _ch = MethodChannel('phoenicx_ssh/keepalive');

  Future<SftpClient> _client() async {
    final c = tab.client;
    if (c == null || tab.status != TabStatus.connected) {
      throw const FileError('Not connected. Wait for the session to reconnect.');
    }
    if (_sftp != null && identical(_sftpFor, c)) return _sftp!;
    if (_opening != null && identical(_sftpFor, c)) return _opening!;
    _sftpFor = c;
    _sftp = null;
    final f = c.sftp().then((s) {
      _sftp = s;
      return s;
    }).catchError((Object e) {
      _sftpFor = null;
      throw FileError.from(e, 'Could not start SFTP on this server. Is the SFTP subsystem enabled in sshd?');
    });
    _opening = f;
    try {
      return await f;
    } finally {
      _opening = null;
    }
  }

  Future<String> homeDir() async {
    if (home != null) return home!;
    final s = await _client();
    home = await s.absolute('.');
    return home!;
  }

  static String join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  static String parent(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final p = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  static String baseName(String path) {
    final p = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    return p.substring(p.lastIndexOf('/') + 1);
  }

  Future<List<RemoteEntry>> list(String dir) async {
    final s = await _client();
    try {
      final names = await s.listdir(dir);
      final out = <RemoteEntry>[];
      for (final n in names) {
        if (n.filename == '.' || n.filename == '..') continue;
        var a = n.attr;
        final path = join(dir, n.filename);
        var isDir = a.isDirectory;
        final link = a.isSymbolicLink;
        if (link) {
          try {
            a = await s.stat(path); // follow the link to see if it's a folder
            isDir = a.isDirectory;
          } catch (_) {}
        }
        out.add(RemoteEntry(
          name: n.filename,
          path: path,
          isDir: isDir,
          isLink: link,
          size: a.size ?? 0,
          modified: a.modifyTime == null ? null : DateTime.fromMillisecondsSinceEpoch(a.modifyTime! * 1000),
          mode: a.mode?.value ?? 0,
        ));
      }
      out.sort((x, y) {
        if (x.isDir != y.isDir) return x.isDir ? -1 : 1;
        return x.name.toLowerCase().compareTo(y.name.toLowerCase());
      });
      cwd = dir;
      return out;
    } catch (e) {
      throw FileError.from(e, 'Could not open $dir');
    }
  }

  Future<void> mkdir(String path) async {
    try {
      await (await _client()).mkdir(path);
    } catch (e) {
      throw FileError.from(e, 'Could not create the folder');
    }
  }

  Future<void> rename(String from, String to) async {
    try {
      await (await _client()).rename(from, to);
    } catch (e) {
      throw FileError.from(e, 'Could not rename');
    }
  }

  Future<void> chmod(String path, int perms) async {
    try {
      await (await _client()).setStat(path, SftpFileAttrs(mode: SftpFileMode.value(perms & 0xfff)));
    } catch (e) {
      throw FileError.from(e, 'Could not change permissions');
    }
  }

  Future<void> delete(RemoteEntry e) async {
    final s = await _client();
    try {
      if (e.isDir && !e.isLink) {
        await _rmTree(s, e.path);
      } else {
        await s.remove(e.path);
      }
    } catch (err) {
      throw FileError.from(err, 'Could not delete ${e.name}');
    }
  }

  Future<void> _rmTree(SftpClient s, String dir) async {
    for (final n in await s.listdir(dir)) {
      if (n.filename == '.' || n.filename == '..') continue;
      final p = join(dir, n.filename);
      if (n.attr.isDirectory) {
        await _rmTree(s, p);
      } else {
        await s.remove(p);
      }
    }
    await s.rmdir(dir);
  }

  /// Small text files only (for the built-in editor).
  Future<String> readText(String path) async {
    final s = await _client();
    final f = await s.open(path);
    try {
      final bytes = await f.readBytes(length: maxEditBytes);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await f.close();
    }
  }

  Future<void> writeText(String path, String text) async {
    final s = await _client();
    try {
      final f = await s.open(path,
          mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
      try {
        await f.writeBytes(Uint8List.fromList(utf8.encode(text)));
      } finally {
        await f.close();
      }
    } catch (e) {
      throw FileError.from(e, 'Could not save the file');
    }
  }

  static const maxEditBytes = 1024 * 1024;

  // ----------------------------------------------------------------- uploads

  Transfer upload({
    required String name,
    required String remoteDir,
    required int size,
    required Stream<Uint8List> Function() open,
  }) {
    final t = Transfer(name: name, upload: true, remotePath: join(remoteDir, name), total: size);
    _add(t);
    () async {
      SftpFile? f;
      try {
        final s = await _client();
        f = await s.open(t.remotePath,
            mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
        final w = f.write(open(), onProgress: t._progress);
        t._cancel = () async => w.abort();
        await w.done;
        t._finish(TransferState.done);
      } catch (e) {
        t._finish(TransferState.failed, FileError.from(e, 'Upload failed').message);
      } finally {
        try {
          await f?.close();
        } catch (_) {}
        notifyListeners();
      }
    }();
    return t;
  }

  /// True if [path] exists on the server and is a folder.
  Future<bool> isDir(String path) async {
    try {
      return (await (await _client()).stat(path)).isDirectory;
    } catch (_) {
      return false;
    }
  }

  /// Uploads a whole folder (with all sub-folders) into [remoteDir].
  /// Shown as ONE transfer with overall progress. Existing files with the
  /// same name are replaced; other files on the server are left alone.
  Transfer uploadFolder(LocalFolder folder, String remoteDir) {
    final base = join(remoteDir, folder.name);
    final t = Transfer(name: '${folder.name}/', upload: true, remotePath: base, total: folder.totalBytes)
      ..isFolder = true
      ..detail = '${folder.files.length} files';
    _add(t);
    () async {
      var cancelled = false;
      SftpFileWriter? current;
      t._cancel = () async {
        cancelled = true;
        current?.abort();
      };
      try {
        final s = await _client();
        Future<void> ensureDir(String p) async {
          try {
            await s.mkdir(p);
          } catch (e) {
            // Fine if it already exists.
            try {
              if ((await s.stat(p)).isDirectory) return;
            } catch (_) {}
            throw FileError.from(e, 'Could not create folder $p');
          }
        }

        await ensureDir(base);
        final dirs = [...folder.dirs]..sort((a, b) => '/'.allMatches(a).length.compareTo('/'.allMatches(b).length));
        for (final d in dirs) {
          if (cancelled) return;
          await ensureDir(join(base, d));
        }
        var doneBytes = 0;
        var n = 0;
        for (final f in folder.files) {
          if (cancelled) return;
          n++;
          t.detail = '$n of ${folder.files.length} files · ${f.rel}';
          final remote = join(base, f.rel);
          final sf = await s.open(remote,
              mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
          try {
            final start = doneBytes;
            current = sf.write(f.open(), onProgress: (b) => t._progress(start + b));
            await current!.done;
          } catch (e) {
            if (cancelled) return;
            throw FileError.from(e, 'Upload failed at ${f.rel}');
          } finally {
            current = null;
            try {
              await sf.close();
            } catch (_) {}
          }
          doneBytes += f.size;
          t._progress(doneBytes);
        }
        t.detail = '${folder.files.length} files';
        t._finish(TransferState.done);
      } catch (e) {
        t._finish(TransferState.failed, FileError.from(e, 'Upload failed').message);
      } finally {
        notifyListeners();
      }
    }();
    return t;
  }

  // --------------------------------------------------------------- downloads

  Transfer download(RemoteEntry e) {
    final t = Transfer(name: e.name, upload: false, remotePath: e.path, total: e.size);
    _add(t);
    () async {
      SftpFile? f;
      File? tmp;
      IOSink? sink;
      try {
        final s = await _client();
        tmp = await _tempTarget(e.name);
        sink = tmp.openWrite();
        f = await s.open(e.path);
        if (t.total <= 0) {
          try {
            t.total = (await f.stat()).size ?? 0;
          } catch (_) {}
        }
        final done = Completer<void>();
        final sub = f.read(onProgress: t._progress).listen(
              sink.add,
              onError: (Object err) {
                if (!done.isCompleted) done.completeError(err);
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
              cancelOnError: true,
            );
        t._cancel = () async {
          await sub.cancel();
          if (!done.isCompleted) done.complete();
        };
        await done.future;
        await sink.flush();
        await sink.close();
        sink = null;
        if (t.state == TransferState.cancelled) {
          await tmp.delete();
          return;
        }
        await _deliver(t, tmp);
        tmp = null;
        t._finish(TransferState.done);
      } catch (err) {
        t._finish(TransferState.failed, FileError.from(err, 'Download failed').message);
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
        try {
          await f?.close();
        } catch (_) {}
        if (tmp != null && t.state != TransferState.done) {
          try {
            await tmp.delete();
          } catch (_) {}
        }
        notifyListeners();
      }
    }();
    return t;
  }

  /// Folders are packed on the server with tar, downloaded, then the archive
  /// on the server is removed.
  Future<Transfer> downloadFolder(RemoteEntry dir) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final archive = '/tmp/phoenicx-$stamp-${_safe(dir.name)}.tar.gz';
    final cmd = "tar -czf ${_q(archive)} -C ${_q(parent(dir.path))} ${_q(dir.name)} 2>&1; echo \"@@RC \$?\"";
    final out = await tab.run(cmd);
    if (!out.contains('@@RC 0')) {
      throw FileError('Could not pack the folder: ${out.replaceAll(RegExp(r'@@RC \d+'), '').trim()}');
    }
    final s = await _client();
    final st = await s.stat(archive);
    final entry = RemoteEntry(
      name: '${dir.name}.tar.gz',
      path: archive,
      isDir: false,
      isLink: false,
      size: st.size ?? 0,
      modified: null,
      mode: 0,
    );
    final t = download(entry);
    void cleanup() {
      if (t.active) return;
      t.removeListener(cleanup);
      s.remove(archive).catchError((_) {});
    }

    t.addListener(cleanup);
    return t;
  }

  static String _safe(String n) => n.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<File> _tempTarget(String name) async {
    if (Platform.isAndroid) {
      final d = await getTemporaryDirectory();
      final dir = Directory('${d.path}/downloads');
      await dir.create(recursive: true);
      return File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}_${_safe(name)}');
    }
    // Desktop: write straight next to the final file, then rename.
    final dir = await downloadsDir();
    return File('${dir.path}${Platform.pathSeparator}.${_safe(name)}.part${DateTime.now().millisecondsSinceEpoch}');
  }

  /// Tests point downloads at a temp folder.
  @visibleForTesting
  static Directory? downloadsOverride;

  static Future<Directory> downloadsDir() async {
    Directory? d = downloadsOverride;
    if (d != null) {
      await d.create(recursive: true);
      return d;
    }
    try {
      d = await getDownloadsDirectory();
    } catch (_) {}
    d ??= await getApplicationDocumentsDirectory();
    await d.create(recursive: true);
    return d;
  }

  Future<void> _deliver(Transfer t, File tmp) async {
    if (Platform.isAndroid) {
      final shown = await _ch.invokeMethod<String>('saveToDownloads', {
        'path': tmp.path,
        'name': t.name,
        'mime': _mime(t.name),
      });
      await tmp.delete();
      t.savedTo = shown ?? 'Download/Phoenicx SSH/${t.name}';
      return;
    }
    final dir = tmp.parent.path;
    var dest = File('$dir${Platform.pathSeparator}${t.name}');
    var n = 1;
    while (await dest.exists()) {
      final dot = t.name.lastIndexOf('.');
      final alt = dot > 0 ? '${t.name.substring(0, dot)} ($n)${t.name.substring(dot)}' : '${t.name} ($n)';
      dest = File('$dir${Platform.pathSeparator}$alt');
      n++;
    }
    await tmp.rename(dest.path);
    t.localPath = dest.path;
    t.savedTo = dest.path;
  }

  static String _mime(String name) {
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
    const m = {
      'txt': 'text/plain', 'log': 'text/plain', 'conf': 'text/plain', 'yml': 'text/plain', 'yaml': 'text/plain',
      'json': 'application/json', 'xml': 'text/xml', 'html': 'text/html', 'csv': 'text/csv',
      'sh': 'text/x-shellscript', 'py': 'text/x-python', 'md': 'text/markdown',
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp',
      'mp4': 'video/mp4', 'mkv': 'video/x-matroska', 'mp3': 'audio/mpeg', 'pdf': 'application/pdf',
      'zip': 'application/zip', 'gz': 'application/gzip', 'tgz': 'application/gzip', 'apk': 'application/vnd.android.package-archive',
    };
    return m[ext] ?? 'application/octet-stream';
  }

  void _add(Transfer t) {
    transfers.insert(0, t);
    t.addListener(notifyListeners);
    notifyListeners();
  }

  void clearFinished() {
    transfers.removeWhere((t) {
      if (t.active) return false;
      t.removeListener(notifyListeners);
      return true;
    });
    notifyListeners();
  }

  int get activeCount => transfers.where((t) => t.active).length;

  /// Called when the SSH connection is replaced or closed.
  void connectionChanged() {
    _sftp = null;
    _sftpFor = null;
    for (final t in transfers) {
      if (t.active) t._finish(TransferState.failed, 'Connection lost');
    }
    notifyListeners();
  }
}

class FileError implements Exception {
  final String message;
  const FileError(this.message);

  factory FileError.from(Object e, String what) {
    if (e is FileError) return e;
    var m = e.toString();
    if (e is SftpStatusError) {
      final low = e.message.toLowerCase();
      if (e.code == SftpStatusCode.permissionDenied || low.contains('permission')) {
        return FileError('$what: permission denied. Your user is not allowed to change this.');
      }
      if (e.code == SftpStatusCode.noSuchFile || low.contains('no such file')) {
        return FileError('$what: it no longer exists.');
      }
      m = e.message;
    }
    return FileError('$what: $m');
  }

  @override
  String toString() => message;
}

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/files.dart';
import '../services/local_folder.dart';
import '../services/session.dart';
import '../theme.dart';

/// Opens the SFTP file browser for [tab]. Wide screens get a large panel on
/// the right; phones get a tall bottom sheet. Transfers keep running when the
/// panel is closed.
Future<void> showFiles(BuildContext context, SshTab tab, {required bool wide}) {
  final panel = FilesPanel(tab: tab);
  if (wide) {
    final size = MediaQuery.sizeOf(context);
    return showDialog(
      context: context,
      barrierColor: Colors.black26,
      builder: (_) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 92, right: 14),
          child: SizedBox(
            width: (size.width * 0.55).clamp(520.0, 780.0).toDouble(),
            height: (size.height - 130).clamp(360.0, 820.0).toDouble(),
            child: Material(
              color: PX.card,
              elevation: 12,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: PX.cardLine),
              ),
              clipBehavior: Clip.antiAlias,
              child: panel,
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: PX.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (c) => SizedBox(height: MediaQuery.sizeOf(c).height * 0.9, child: panel),
  );
}

class FilesPanel extends StatefulWidget {
  final SshTab tab;
  const FilesPanel({super.key, required this.tab});

  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel> {
  FileService get fs => widget.tab.files;

  String? _dir;
  List<RemoteEntry> _items = [];
  bool _loading = true;
  String? _error;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    fs.addListener(_onFs);
    _start();
  }

  @override
  void dispose() {
    fs.removeListener(_onFs);
    super.dispose();
  }

  void _onFs() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    try {
      final env = Platform.environment;
      final start = env['PHOENICX_SELFTEST_FILES_PATH'] ?? fs.cwd ?? await fs.homeDir();
      await _open(start);
      _selfTestActions(env);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Automated screenshot tests only (environment variables set by the test).
  Future<void> _selfTestActions(Map<String, String> env) async {
    final up = env['PHOENICX_SELFTEST_UPLOAD_DIR'];
    if (up != null && _dir != null) {
      final t = fs.uploadFolder(await LocalFolder.fromDirectory(Directory(up)), _dir!);
      while (t.active) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      await _refresh();
    }
    final dl = env['PHOENICX_SELFTEST_DOWNLOAD'];
    if (dl != null) {
      final e = _items.where((e) => e.name == dl).firstOrNull;
      if (e != null) _download(e);
    }
    final ed = env['PHOENICX_SELFTEST_EDIT'];
    if (ed != null) {
      final e = _items.where((e) => e.name == ed).firstOrNull;
      if (e != null) _edit(e);
    }
  }

  Future<void> _open(String dir) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await fs.list(dir);
      if (!mounted) return;
      setState(() {
        _dir = dir;
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
        _dir ??= dir;
      });
    }
  }

  Future<void> _refresh() async {
    if (_dir != null) await _open(_dir!);
  }

  void _snack(String m) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) _snack(e.toString());
    }
  }

  // ---------------------------------------------------------------- actions

  Future<void> _upload() async {
    final dir = _dir;
    if (dir == null) return;
    final picked = await FilePicker.pickFiles(dialogTitle: 'Choose files to upload');
    if (picked.isEmpty) return;
    final existing = _items.map((e) => e.name).toSet();
    final clash = picked.where((f) => existing.contains(f.name)).map((f) => f.name).toList();
    var replace = true;
    if (clash.isNotEmpty) {
      if (!mounted) return;
      final r = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(clash.length == 1 ? 'Replace ${clash.first}?' : 'Replace ${clash.length} files?'),
          content: Text(clash.length == 1
              ? 'A file with this name is already in $dir.'
              : 'These are already in $dir:\n${clash.take(6).join('\n')}${clash.length > 6 ? '\n…' : ''}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Skip those')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Replace')),
          ],
        ),
      );
      if (r == null) return;
      replace = r;
    }
    var n = 0;
    for (final f in picked) {
      if (!replace && existing.contains(f.name)) continue;
      final size = await f.length() ?? 0;
      final t = fs.upload(name: f.name, remoteDir: dir, size: size, open: f.readAsByteStream);
      n++;
      void done() {
        if (t.active) return;
        t.removeListener(done);
        if (mounted && _dir == dir) _refresh();
      }

      t.addListener(done);
    }
    if (n > 0) _snack(n == 1 ? 'Uploading ${picked.first.name}' : 'Uploading $n files');
  }

  Future<void> _uploadFolder() async {
    final dir = _dir;
    if (dir == null) return;
    LocalFolder? folder;
    try {
      folder = await LocalFolder.pick();
    } catch (e) {
      _snack('Could not read that folder: $e');
      return;
    }
    if (folder == null || !mounted) return;
    if (folder.files.isEmpty && folder.dirs.isEmpty) {
      _snack('${folder.name} is empty');
    }
    final exists = _items.any((e) => e.name == folder!.name);
    if (exists) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${folder!.name} already exists'),
          content: Text('A folder with this name is already in $dir. '
              'Files with the same name inside it will be replaced; other files are kept.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Upload and replace')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final t = fs.uploadFolder(folder, dir);
    _snack('Uploading ${folder.name} · ${folder.files.length} files, ${fmtBytes(folder.totalBytes)}');
    _refresh();
    void done() {
      if (t.active) return;
      t.removeListener(done);
      if (mounted && _dir == dir) _refresh();
    }

    t.addListener(done);
  }

  Future<void> _download(RemoteEntry e) async {
    if (e.isDir) {
      _snack('Packing ${e.name} on the server…');
      await _guard(() async => fs.downloadFolder(e));
    } else {
      fs.download(e);
    }
  }

  Future<void> _newFolder() async {
    final name = await _askText(title: 'New folder', label: 'Folder name', action: 'Create');
    if (name == null || name.isEmpty || _dir == null) return;
    await _guard(() async {
      await fs.mkdir(FileService.join(_dir!, name));
      await _refresh();
    });
  }

  Future<void> _rename(RemoteEntry e) async {
    final name = await _askText(title: 'Rename', label: 'New name', initial: e.name, action: 'Rename');
    if (name == null || name.isEmpty || name == e.name) return;
    await _guard(() async {
      await fs.rename(e.path, FileService.join(FileService.parent(e.path), name));
      await _refresh();
    });
  }

  Future<void> _delete(RemoteEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${e.name}?'),
        content: Text(e.isDir && !e.isLink
            ? 'The folder and everything inside it is deleted from the server. This can\'t be undone.'
            : 'The file is deleted from the server. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PX.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      await fs.delete(e);
      await _refresh();
    });
  }

  Future<void> _perms(RemoteEntry e) async {
    final v = await showDialog<int>(context: context, builder: (_) => _PermsDialog(entry: e));
    if (v == null) return;
    await _guard(() async {
      await fs.chmod(e.path, v);
      await _refresh();
    });
  }

  Future<void> _edit(RemoteEntry e) async {
    if (e.size > FileService.maxEditBytes) {
      _snack('Too big to edit here (over 1 MB). Download it instead.');
      return;
    }
    String text;
    try {
      text = await fs.readText(e.path);
    } catch (err) {
      _snack(err.toString());
      return;
    }
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _EditorPage(fs: fs, entry: e, text: text),
    ));
    if (saved == true) _refresh();
  }

  void _copyPath(RemoteEntry e) {
    Clipboard.setData(ClipboardData(text: e.path));
    _snack('Path copied');
  }

  void _pastePath(RemoteEntry e) {
    final p = e.path.contains(' ') ? "'${e.path}'" : e.path;
    widget.tab.terminal.paste(p);
    Navigator.of(context).maybePop();
  }

  Future<void> _goTo() async {
    final p = await _askText(title: 'Go to folder', label: 'Path', initial: _dir ?? '/', action: 'Open');
    if (p == null || p.isEmpty) return;
    _open(p);
  }

  Future<String?> _askText({required String title, required String label, String initial = '', required String action}) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(c, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: Text(action)),
        ],
      ),
    );
  }

  void _actions(RemoteEntry e, [Offset? at]) async {
    final items = <(String, IconData, String)>[
      ('download', Icons.download_rounded, e.isDir ? 'Download as .tar.gz' : 'Download'),
      if (!e.isDir) ('edit', Icons.edit_note_rounded, 'Edit'),
      ('rename', Icons.drive_file_rename_outline_rounded, 'Rename'),
      ('perms', Icons.lock_outline_rounded, 'Permissions (${e.perms})'),
      ('copy', Icons.link_rounded, 'Copy path'),
      ('paste', Icons.terminal_rounded, 'Paste path into terminal'),
      ('delete', Icons.delete_outline_rounded, 'Delete'),
    ];
    String? v;
    if (at != null) {
      v = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
        items: [
          for (final i in items)
            PopupMenuItem(
              value: i.$1,
              child: Row(children: [
                Icon(i.$2, size: 18, color: i.$1 == 'delete' ? PX.red : PX.soft),
                const SizedBox(width: 10),
                Text(i.$3, style: TextStyle(color: i.$1 == 'delete' ? PX.red : null)),
              ]),
            ),
        ],
      );
    } else {
      v = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: PX.card,
        builder: (c) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: Icon(e.isDir ? Icons.folder_rounded : _iconFor(e.name), color: e.isDir ? PX.accent2 : PX.soft),
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(e.isDir ? 'Folder' : fmtBytes(e.size)),
            ),
            const Divider(height: 1),
            for (final i in items)
              ListTile(
                dense: true,
                leading: Icon(i.$2, color: i.$1 == 'delete' ? PX.red : PX.soft),
                title: Text(i.$3, style: TextStyle(color: i.$1 == 'delete' ? PX.red : null)),
                onTap: () => Navigator.pop(c, i.$1),
              ),
          ]),
        ),
      );
    }
    switch (v) {
      case 'download':
        _download(e);
      case 'edit':
        _edit(e);
      case 'rename':
        _rename(e);
      case 'perms':
        _perms(e);
      case 'copy':
        _copyPath(e);
      case 'paste':
        _pastePath(e);
      case 'delete':
        _delete(e);
    }
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final shown = _showHidden ? _items : _items.where((e) => !e.hidden).toList();
    return Column(children: [
      _header(),
      _pathBar(),
      const Divider(height: 1),
      Expanded(child: _body(shown)),
      _transfers(),
    ]);
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 4),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: const LinearGradient(colors: PX.gMem),
            ),
            child: const Icon(Icons.folder_copy_rounded, color: Colors.white, size: 19),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Files', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          PopupMenuButton<String>(
            tooltip: 'Upload files or a folder',
            enabled: _dir != null,
            position: PopupMenuPosition.under,
            onSelected: (v) => v == 'folder' ? _uploadFolder() : _upload(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'files',
                child: Row(children: [
                  Icon(Icons.upload_file_rounded, size: 20, color: PX.neonBlue),
                  SizedBox(width: 10),
                  Text('Upload files'),
                ]),
              ),
              PopupMenuItem(
                value: 'folder',
                child: Row(children: [
                  Icon(Icons.drive_folder_upload_rounded, size: 20, color: PX.accent2),
                  SizedBox(width: 10),
                  Text('Upload a folder'),
                ]),
              ),
            ],
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _dir == null ? PX.cardLine : PX.neonBlue,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.upload_rounded, size: 18, color: Colors.white),
                SizedBox(width: 6),
                Text('Upload', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                Icon(Icons.arrow_drop_down_rounded, size: 20, color: Colors.white),
              ]),
            ),
          ),
          IconButton(
            tooltip: 'New folder',
            onPressed: _dir == null ? null : _newFolder,
            icon: const Icon(Icons.create_new_folder_outlined, color: PX.accent2),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded, color: PX.soft),
            onSelected: (v) {
              switch (v) {
                case 'hidden':
                  setState(() => _showHidden = !_showHidden);
                case 'goto':
                  _goTo();
                case 'home':
                  fs.homeDir().then(_open);
                case 'root':
                  _open('/');
                case 'refresh':
                  _refresh();
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'hidden', checked: _showHidden, child: const Text('Show hidden files')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'goto', child: Text('Go to folder…')),
              const PopupMenuItem(value: 'home', child: Text('Home folder')),
              const PopupMenuItem(value: 'root', child: Text('Root  /')),
              const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
            ],
          ),
        ]),
      );

  Widget _pathBar() {
    final dir = _dir ?? '';
    final parts = dir.split('/').where((p) => p.isNotEmpty).toList();
    final crumbs = <Widget>[
      _crumb('/', '/'),
    ];
    var acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc = '$acc/${parts[i]}';
      final target = acc;
      if (i > 0) crumbs.add(const Text('/', style: TextStyle(color: PX.muted, fontSize: 12.5)));
      crumbs.add(_crumb(parts[i], target, last: i == parts.length - 1));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(children: [
        IconButton(
          tooltip: 'Up one folder',
          visualDensity: VisualDensity.compact,
          onPressed: dir.isEmpty || dir == '/' ? null : () => _open(FileService.parent(dir)),
          icon: const Icon(Icons.arrow_upward_rounded, size: 20),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(children: crumbs),
          ),
        ),
        IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          onPressed: _refresh,
          icon: const Icon(Icons.refresh_rounded, size: 20, color: PX.soft),
        ),
      ]),
    );
  }

  Widget _crumb(String label, String path, {bool last = false}) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _open(path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: last ? PX.text : PX.muted,
                fontWeight: last ? FontWeight.w700 : FontWeight.w400,
              )),
        ),
      );

  Widget _body(List<RemoteEntry> shown) {
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, color: PX.red, size: 32),
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: PX.soft)),
            const SizedBox(height: 14),
            Wrap(spacing: 8, children: [
              OutlinedButton(onPressed: _refresh, child: const Text('Try again')),
              if (_dir != null && _dir != '/')
                OutlinedButton(onPressed: () => _open(FileService.parent(_dir!)), child: const Text('Go up')),
            ]),
          ]),
        ),
      );
    }
    if (shown.isEmpty) {
      return const Center(child: Text('This folder is empty', style: TextStyle(color: PX.muted)));
    }
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _refresh,
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: shown.length,
          itemBuilder: (c, i) => _row(shown[i]),
        ),
      ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
    ]);
  }

  Widget _row(RemoteEntry e) {
    final date = e.modified == null ? '' : _date(e.modified!);
    return GestureDetector(
      onSecondaryTapDown: (d) => _actions(e, d.globalPosition),
      child: InkWell(
        onTap: () => e.isDir ? _open(e.path) : _actions(e),
        onLongPress: () => _actions(e),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 4, 7),
          child: Row(children: [
            Icon(
              e.isDir ? Icons.folder_rounded : _iconFor(e.name),
              size: 22,
              color: e.isDir ? PX.accent2 : PX.soft.withValues(alpha: 0.75),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: e.hidden ? PX.muted : PX.text,
                          fontWeight: e.isDir ? FontWeight.w600 : FontWeight.w400,
                        )),
                  ),
                  if (e.isLink) const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.link_rounded, size: 14, color: PX.muted),
                  ),
                ]),
                const SizedBox(height: 2),
                Text(
                  [if (!e.isDir) fmtBytes(e.size), if (date.isNotEmpty) date, e.perms].join('  ·  '),
                  style: const TextStyle(fontSize: 11.5, color: PX.muted),
                ),
              ]),
            ),
            if (!e.isDir)
              IconButton(
                tooltip: 'Download',
                visualDensity: VisualDensity.compact,
                onPressed: () => _download(e),
                icon: const Icon(Icons.download_rounded, size: 20, color: PX.mint),
              ),
            Builder(
              builder: (bc) => IconButton(
                tooltip: 'Actions',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final box = bc.findRenderObject() as RenderBox?;
                  final pos = box?.localToGlobal(box.size.bottomLeft(Offset.zero));
                  _actions(e, Layout.wide(context) ? pos : null);
                },
                icon: const Icon(Icons.more_vert_rounded, size: 20, color: PX.muted),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _transfers() {
    final list = fs.transfers;
    if (list.isEmpty) return const SizedBox.shrink();
    final finished = list.where((t) => !t.active).length;
    return Container(
      constraints: const BoxConstraints(maxHeight: 210),
      decoration: const BoxDecoration(
        color: PX.panelTop,
        border: Border(top: BorderSide(color: PX.cardLine)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
          child: Row(children: [
            Text(
              fs.activeCount > 0 ? 'Transfers · ${fs.activeCount} running' : 'Transfers',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: PX.soft),
            ),
            const Spacer(),
            if (finished > 0)
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: fs.clearFinished,
                child: const Text('Clear finished', style: TextStyle(fontSize: 12)),
              ),
          ]),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 6),
            children: [for (final t in list) _transferRow(t)],
          ),
        ),
      ]),
    );
  }

  Widget _transferRow(Transfer t) {
    final color = switch (t.state) {
      TransferState.done => PX.mint,
      TransferState.failed => PX.red,
      TransferState.cancelled => PX.muted,
      TransferState.running => t.upload ? PX.neonBlue : PX.mint,
    };
    final status = switch (t.state) {
      TransferState.running =>
        '${(t.progress * 100).toStringAsFixed(0)}%  ·  ${fmtBytes(t.done)} of ${fmtBytes(t.total)}  ·  ${fmtBytes(t.speed)}/s'
            '${t.detail != null ? '\n${t.detail}' : ''}',
      TransferState.done => t.isFolder
          ? 'Uploaded ${t.detail ?? ''} to ${FileService.parent(t.remotePath)}'
          : t.upload
              ? 'Uploaded to ${FileService.parent(t.remotePath)}'
              : 'Saved to ${t.savedTo ?? 'Downloads'}',
      TransferState.failed => t.error ?? 'Failed',
      TransferState.cancelled => 'Cancelled',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      child: Row(children: [
        Icon(t.isFolder ? Icons.drive_folder_upload_rounded : (t.upload ? Icons.upload_rounded : Icons.download_rounded),
            size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: t.active && t.total <= 0 ? null : t.progress,
                minHeight: 4,
                color: color,
                backgroundColor: PX.cardLine,
              ),
            ),
            const SizedBox(height: 3),
            Text(status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: t.state == TransferState.failed ? PX.red : PX.muted)),
          ]),
        ),
        if (t.active)
          IconButton(
            tooltip: 'Cancel',
            visualDensity: VisualDensity.compact,
            onPressed: t.cancel,
            icon: const Icon(Icons.close_rounded, size: 18, color: PX.muted),
          )
        else if (t.localPath != null)
          IconButton(
            tooltip: 'Show in folder',
            visualDensity: VisualDensity.compact,
            onPressed: () => _showInFolder(t.localPath!),
            icon: const Icon(Icons.folder_open_rounded, size: 18, color: PX.accent2),
          ),
      ]),
    );
  }

  void _showInFolder(String path) {
    if (Platform.isWindows) {
      Process.run('explorer.exe', ['/select,', path]);
    } else {
      launchUrl(Uri.file(File(path).parent.path));
    }
  }

  static String _date(DateTime d) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final now = DateTime.now();
    final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (d.year == now.year) return '${d.day} ${m[d.month - 1]} $hm';
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  static IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
    switch (ext) {
      case 'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'svg':
        return Icons.image_outlined;
      case 'mp4' || 'mkv' || 'avi' || 'mov' || 'webm':
        return Icons.movie_outlined;
      case 'mp3' || 'flac' || 'wav' || 'm4a':
        return Icons.audiotrack_outlined;
      case 'zip' || 'gz' || 'tgz' || 'tar' || 'xz' || 'bz2' || '7z' || 'rar':
        return Icons.archive_outlined;
      case 'sh' || 'py' || 'js' || 'ts' || 'dart' || 'go' || 'rs' || 'c' || 'cpp' || 'java' || 'php' || 'rb':
        return Icons.code_rounded;
      case 'yml' || 'yaml' || 'json' || 'conf' || 'cfg' || 'ini' || 'toml' || 'env' || 'xml':
        return Icons.settings_applications_outlined;
      case 'log' || 'txt' || 'md':
        return Icons.description_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

/// rwx grid for owner / group / others.
class _PermsDialog extends StatefulWidget {
  final RemoteEntry entry;
  const _PermsDialog({required this.entry});

  @override
  State<_PermsDialog> createState() => _PermsDialogState();
}

class _PermsDialogState extends State<_PermsDialog> {
  late int v = widget.entry.mode & 0x1ff;

  @override
  Widget build(BuildContext context) {
    const who = ['Owner', 'Group', 'Others'];
    const what = ['Read', 'Write', 'Run'];
    return AlertDialog(
      title: Text('Permissions · ${widget.entry.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: const {0: IntrinsicColumnWidth()},
          children: [
            TableRow(children: [
              const SizedBox(),
              for (final w in what)
                Center(child: Text(w, style: const TextStyle(fontSize: 12, color: PX.muted))),
            ]),
            for (var r = 0; r < 3; r++)
              TableRow(children: [
                Padding(padding: const EdgeInsets.only(right: 12), child: Text(who[r])),
                for (var c = 0; c < 3; c++)
                  Checkbox(
                    value: v & (1 << (8 - (r * 3 + c))) != 0,
                    onChanged: (on) => setState(() {
                      final bit = 1 << (8 - (r * 3 + c));
                      v = on == true ? v | bit : v & ~bit;
                    }),
                  ),
              ]),
          ],
        ),
        const SizedBox(height: 8),
        Text('chmod ${v.toRadixString(8).padLeft(3, '0')}',
            style: const TextStyle(fontFamily: 'monospace', color: PX.accent2)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (widget.entry.mode & 0xe00) | v),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Simple full-screen editor for small text files.
class _EditorPage extends StatefulWidget {
  final FileService fs;
  final RemoteEntry entry;
  final String text;
  const _EditorPage({required this.fs, required this.entry, required this.text});

  @override
  State<_EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<_EditorPage> {
  late final ctl = TextEditingController(text: widget.text);
  bool _saving = false;
  bool _dirty = false;

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.fs.writeText(widget.entry.path, ctl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
      setState(() => _dirty = false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits haven\'t been saved to the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
        ],
      ),
    );
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.pop(context, false);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (!_saving) _save();
          },
        },
        child: Scaffold(
          backgroundColor: PX.bg,
          appBar: AppBar(
            backgroundColor: PX.card,
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.entry.name, style: const TextStyle(fontSize: 15)),
              Text(widget.entry.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: PX.muted)),
            ]),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_rounded, size: 18),
                  label: Text(_dirty ? 'Save' : 'Saved'),
                ),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(10),
            child: TextField(
              controller: ctl,
              maxLines: null,
              expands: true,
              autofocus: true,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              onChanged: (_) {
                if (!_dirty) setState(() => _dirty = true);
              },
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
              decoration: const InputDecoration(
                border: InputBorder.none,
                filled: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

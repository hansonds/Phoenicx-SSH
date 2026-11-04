import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/backup.dart';
import '../services/session.dart';
import '../services/store.dart';
import '../theme.dart';
import 'host_editor.dart';
import 'settings_page.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({super.key});

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  String _query = '';

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _edit([HostConfig? h]) async {
    final r = await Navigator.push<EditorResult>(
      context,
      MaterialPageRoute(builder: (_) => HostEditor(host: h)),
    );
    if (r != null && r.connect) Sessions.I.open(r.host);
  }

  Future<void> _delete(HostConfig h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${h.title}?'),
        content: const Text('The saved login details (and key) for this host will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await Store.I.remove(h.id);
  }

  // ------------------------------------------------------------ export

  Future<void> _export() async {
    final hosts = Store.I.hosts.value;
    if (hosts.isEmpty) {
      _snack('There are no hosts to export yet.');
      return;
    }
    final opts = await showDialog<(bool, String)>(
      context: context,
      builder: (_) => const _ExportDialog(),
    );
    if (opts == null) return;
    try {
      final bytes = await buildBackup(hosts, password: opts.$2, includeSecrets: opts.$1);
      final d = DateTime.now();
      final name =
          'phoenicx-ssh-backup-${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}.json';
      final uri = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'Save backup',
      );
      if (uri != null) _snack('Backup saved (${hosts.length} hosts).');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  // ------------------------------------------------------------ import

  Future<void> _import() async {
    final f = await FilePicker.pickFile(dialogTitle: 'Choose a Phoenicx SSH backup (.json)');
    if (f == null) return;
    try {
      final bytes = await f.readAsBytes();
      List<HostConfig>? list;
      if (backupIsEncrypted(bytes)) {
        String? error;
        while (list == null) {
          if (!mounted) return;
          final pw = await _askPassword(error);
          if (pw == null) return;
          try {
            list = await readBackup(bytes, password: pw);
          } on WrongPassword {
            error = 'Wrong password, try again.';
          }
        }
      } else {
        list = await readBackup(bytes);
      }
      await _merge(list);
    } catch (e) {
      _snack('Import failed: $e');
    }
  }

  Future<void> _importPutty() async {
    try {
      final list = await importPuttySessions();
      if (list.isEmpty) {
        _snack('No saved PuTTY SSH sessions were found.');
        return;
      }
      await _merge(list, byAddress: true);
    } catch (e) {
      _snack('Could not read PuTTY sessions: $e');
    }
  }

  Future<void> _merge(List<HostConfig> incoming, {bool byAddress = false}) async {
    if (incoming.isEmpty) {
      _snack('The file has no hosts in it.');
      return;
    }
    final current = [...Store.I.hosts.value];
    var added = 0, updated = 0;
    for (final h in incoming) {
      final i = current.indexWhere((x) => byAddress
          ? (x.host == h.host && x.port == h.port && x.username == h.username)
          : x.id == h.id);
      if (i >= 0) {
        if (byAddress) continue;
        // Keep existing secrets if the backup was made without them.
        if (h.privateKey.isEmpty) h.privateKey = current[i].privateKey;
        if (h.password.isEmpty) h.password = current[i].password;
        if (h.passphrase.isEmpty) h.passphrase = current[i].passphrase;
        current[i] = h;
        updated++;
      } else {
        current.add(h);
        added++;
      }
    }
    Store.I.hosts.value = current;
    await Store.I.saveHosts();
    _snack('Imported: $added new${updated > 0 ? ', $updated updated' : ''}.');
  }

  Future<String?> _askPassword(String? error) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Backup password'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: true,
          onSubmitted: (v) => Navigator.pop(c, v),
          decoration: InputDecoration(hintText: 'Password', errorText: error),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Unlock')),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Image.asset('assets/logo.png', width: 28, height: 28),
          ),
          const SizedBox(width: 10),
          const Text('Phoenicx SSH', style: TextStyle(fontWeight: FontWeight.w700)),
        ]),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Backup',
            icon: const Icon(Icons.import_export),
            onSelected: (v) {
              if (v == 'import') _import();
              if (v == 'export') _export();
              if (v == 'putty') _importPutty();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.upload_file), title: Text('Export backup'), dense: true)),
              const PopupMenuItem(value: 'import', child: ListTile(leading: Icon(Icons.download), title: Text('Import backup'), dense: true)),
              if (Platform.isWindows)
                const PopupMenuItem(value: 'putty', child: ListTile(leading: Icon(Icons.terminal), title: Text('Import from PuTTY'), dense: true)),
            ],
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('New host'),
      ),
      body: ValueListenableBuilder<List<HostConfig>>(
        valueListenable: Store.I.hosts,
        builder: (context, hosts, _) {
          if (hosts.isEmpty) return _empty();
          final q = _query.toLowerCase();
          final list = hosts
              .where((h) => q.isEmpty ||
                  h.title.toLowerCase().contains(q) ||
                  h.address.toLowerCase().contains(q))
              .toList()
            ..sort((a, b) {
              final c = b.lastUsed.compareTo(a.lastUsed);
              return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
            });
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                children: [
                  if (hosts.length > 5)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search hosts',
                        ),
                      ),
                    ),
                  for (final h in list) _hostCard(h),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset('assets/logo.png', width: 84, height: 84),
            ),
            const SizedBox(height: 18),
            const Text('No servers yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'Add your Oracle instance with its IP, username and the private key you downloaded.',
              textAlign: TextAlign.center,
              style: TextStyle(color: PX.muted),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Add a server')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
              TextButton.icon(onPressed: _import, icon: const Icon(Icons.download), label: const Text('Import backup')),
              if (Platform.isWindows)
                TextButton.icon(onPressed: _importPutty, icon: const Icon(Icons.terminal), label: const Text('Import from PuTTY')),
            ]),
          ]),
        ),
      );

  Widget _hostCard(HostConfig h) {
    final color = PX.tags[h.color.clamp(0, PX.tags.length - 1).toInt()];
    final open = Sessions.I.tabs.where((t) => t.host.id == h.id).length;
    return Card(
      color: PX.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Sessions.I.open(h),
        child: IntrinsicHeight(
          child: Row(children: [
            Container(width: 4, color: color),
            const SizedBox(width: 12),
            Icon(h.auth == AuthType.key ? Icons.dns_rounded : Icons.dns_outlined, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(h.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    if (open > 0) _badge('$open open', PX.green),
                    if (h.useTmux) _badge('tmux', PX.accent2),
                  ]),
                  const SizedBox(height: 2),
                  Text(h.address, style: const TextStyle(fontSize: 12.5, color: PX.muted)),
                ]),
              ),
            ),
            IconButton(
              tooltip: 'Connect',
              icon: const Icon(Icons.play_arrow_rounded, color: PX.accent),
              onPressed: () => Sessions.I.open(h),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') _edit(h);
                if (v == 'dup') {
                  final c = h.copy(newIdentity: true)..name = '${h.title} (copy)';
                  await Store.I.upsert(c);
                }
                if (v == 'del') _delete(h);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'dup', child: Text('Duplicate')),
                PopupMenuItem(value: 'del', child: Text('Delete')),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Widget _badge(String t, Color c) => Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(t, style: TextStyle(fontSize: 10.5, color: c, fontWeight: FontWeight.w600)),
      );
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _secrets = true;
  final _p1 = TextEditingController(), _p2 = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export backup'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _secrets,
            onChanged: (v) => setState(() => _secrets = v),
            title: const Text('Include passwords and private keys'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _p1,
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Backup password (recommended)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _p2,
            obscureText: true,
            decoration: InputDecoration(hintText: 'Repeat password', errorText: _err),
          ),
          const SizedBox(height: 10),
          Text(
            _p1.text.isEmpty && _secrets
                ? 'Without a password, your keys are saved as plain text in the file.'
                : 'The file is encrypted (AES-256). You need this password to import it.',
            style: const TextStyle(fontSize: 12, color: PX.muted),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_p1.text != _p2.text) {
              setState(() => _err = 'Passwords do not match');
              return;
            }
            Navigator.pop(context, (_secrets, _p1.text));
          },
          child: const Text('Export'),
        ),
      ],
    );
  }
}

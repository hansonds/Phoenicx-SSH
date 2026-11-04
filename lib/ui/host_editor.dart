import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/keys.dart';
import '../services/store.dart';
import '../theme.dart';

/// Returns the saved host, or null. If the user pressed "Save & connect",
/// the result is wrapped in [EditorResult] with connect = true.
class EditorResult {
  final HostConfig host;
  final bool connect;
  EditorResult(this.host, this.connect);
}

class HostEditor extends StatefulWidget {
  final HostConfig? host;
  const HostEditor({super.key, this.host});

  @override
  State<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends State<HostEditor> {
  late final HostConfig h;
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _host, _port, _user, _pass, _phrase, _startup;
  bool _showPass = false;
  String? _keyInfo;

  @override
  void initState() {
    super.initState();
    h = widget.host?.copy() ?? HostConfig();
    _name = TextEditingController(text: h.name);
    _host = TextEditingController(text: h.host);
    _port = TextEditingController(text: '${h.port}');
    _user = TextEditingController(text: h.username);
    _pass = TextEditingController(text: h.password);
    _phrase = TextEditingController(text: h.passphrase);
    _startup = TextEditingController(text: h.startupCommand);
    if (h.privateKey.isNotEmpty) _keyInfo = describeKey(h.privateKey);
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _user, _pass, _phrase, _startup]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickKey() async {
    final f = await FilePicker.pickFile(dialogTitle: 'Choose your private key (.key, .pem, .ppk, id_rsa)');
    if (f == null) return;
    try {
      final bytes = await f.readAsBytes();
      if (bytes.length > 64 * 1024) throw Exception('File is too big to be a key');
      final text = utf8.decode(bytes, allowMalformed: true);
      setState(() {
        h.privateKey = text;
        h.keyName = f.name;
        _keyInfo = describeKey(text);
      });
    } catch (e) {
      _snack('Could not read the file: $e');
    }
  }

  Future<void> _pasteKey() async {
    final ctl = TextEditingController(text: h.privateKey);
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Paste private key'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctl,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            decoration: const InputDecoration(hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Use key')),
        ],
      ),
    );
    if (r == null) return;
    setState(() {
      h.privateKey = r.trim();
      h.keyName = 'pasted key';
      _keyInfo = describeKey(h.privateKey);
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save(bool connect) async {
    if (!_form.currentState!.validate()) return;
    var hostText = _host.text.trim();
    var user = _user.text.trim();
    // Accept "user@host" typed into the host field.
    if (hostText.contains('@')) {
      final i = hostText.lastIndexOf('@');
      user = hostText.substring(0, i);
      hostText = hostText.substring(i + 1);
    }
    h
      ..name = _name.text.trim()
      ..host = hostText
      ..port = int.tryParse(_port.text.trim()) ?? 22
      ..username = user
      ..password = _pass.text
      ..passphrase = _phrase.text
      ..startupCommand = _startup.text.trim();
    if (h.auth == AuthType.key && h.privateKey.isEmpty) {
      _snack('Load your private key file first.');
      return;
    }
    if (h.auth == AuthType.key) {
      try {
        loadKeyPairs(h.privateKey, h.passphrase);
      } on KeyFormatError catch (e) {
        _snack(e.message);
        return;
      } catch (e) {
        _snack('$e');
        return;
      }
    }
    await Store.I.upsert(h);
    if (mounted) Navigator.pop(context, EditorResult(h, connect));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.host == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'New host' : 'Edit host'),
        actions: [
          TextButton(onPressed: () => _save(false), child: const Text('Save')),
          const SizedBox(width: 6),
        ],
      ),
      body: Form(
        key: _form,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _label('Name'),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(hintText: 'e.g. Oracle Mumbai'),
                ),
                const SizedBox(height: 14),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    flex: 3,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _label('Host / IP address'),
                      TextFormField(
                        controller: _host,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(hintText: '129.154.x.x'),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                      ),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 90,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _label('Port'),
                      TextFormField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          final p = int.tryParse((v ?? '').trim());
                          return (p == null || p < 1 || p > 65535) ? 'Invalid' : null;
                        },
                      ),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                _label('Username'),
                TextFormField(
                  controller: _user,
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'ubuntu (Ubuntu) or opc (Oracle Linux)'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty && !_host.text.contains('@') ? 'Required' : null,
                ),
                const SizedBox(height: 18),
                _label('Login with'),
                SegmentedButton<AuthType>(
                  segments: const [
                    ButtonSegment(value: AuthType.key, label: Text('Private key'), icon: Icon(Icons.key)),
                    ButtonSegment(value: AuthType.password, label: Text('Password'), icon: Icon(Icons.password)),
                  ],
                  selected: {h.auth},
                  onSelectionChanged: (s) => setState(() => h.auth = s.first),
                ),
                const SizedBox(height: 12),
                if (h.auth == AuthType.password)
                  TextFormField(
                    controller: _pass,
                    obscureText: !_showPass,
                    decoration: InputDecoration(
                      hintText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showPass = !_showPass),
                      ),
                    ),
                  )
                else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: PX.surface2,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(children: [
                      Icon(Icons.vpn_key, color: h.privateKey.isEmpty ? PX.muted : PX.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(h.privateKey.isEmpty ? 'No key loaded' : h.keyName,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            _keyInfo ?? 'Oracle .key, OpenSSH, .pem or PuTTY .ppk',
                            style: const TextStyle(fontSize: 12, color: PX.muted),
                          ),
                        ]),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    FilledButton.tonalIcon(
                      onPressed: _pickKey,
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Load key file'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _pasteKey,
                      icon: const Icon(Icons.content_paste, size: 18),
                      label: const Text('Paste key'),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _phrase,
                    obscureText: true,
                    decoration: const InputDecoration(hintText: 'Key passphrase (only if the key has one)'),
                  ),
                ],
                const SizedBox(height: 22),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: h.useTmux,
                  onChanged: (v) => setState(() => h.useTmux = v),
                  title: const Text('Keep remote session alive with tmux'),
                  subtitle: const Text(
                    'Programs keep running on the server even if your connection drops; '
                    'the app re-attaches to the same screen when it reconnects.',
                    style: TextStyle(fontSize: 12, color: PX.muted),
                  ),
                ),
                const SizedBox(height: 8),
                _label('Run after login (optional)'),
                TextFormField(
                  controller: _startup,
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'e.g. cd /home/ubuntu && docker ps'),
                ),
                const SizedBox(height: 16),
                _label('Colour'),
                Wrap(spacing: 10, children: [
                  for (var i = 0; i < PX.tags.length; i++)
                    GestureDetector(
                      onTap: () => setState(() => h.color = i),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: PX.tags[i],
                          shape: BoxShape.circle,
                          border: Border.all(color: h.color == i ? Colors.white : Colors.transparent, width: 2),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () => _save(true),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Save & connect'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 12.5, color: PX.muted, fontWeight: FontWeight.w600)),
      );
}

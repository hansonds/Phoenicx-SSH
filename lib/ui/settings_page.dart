import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/keepalive.dart';
import '../services/session.dart';
import '../services/store.dart';
import '../theme.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final s = Store.I.settings;

  Future<void> _save() async {
    await Store.I.saveSettings();
    for (final t in Sessions.I.tabs) {
      t.applySettings();
    }
    setState(() {});
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 11.5, letterSpacing: 1, color: PX.accent2, fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 30),
            children: [
              _section('Terminal'),
              ListTile(
                title: const Text('Font size'),
                subtitle: Slider(
                  value: s.fontSize,
                  min: 8,
                  max: 28,
                  divisions: 20,
                  label: s.fontSize.toStringAsFixed(0),
                  onChanged: (v) => setState(() => s.fontSize = v),
                  onChangeEnd: (_) => _save(),
                ),
                trailing: Text(s.fontSize.toStringAsFixed(0)),
              ),
              ListTile(
                title: const Text('Scrollback lines'),
                subtitle: const Text('Applies to new tabs', style: TextStyle(color: PX.muted, fontSize: 12)),
                trailing: DropdownButton<int>(
                  value: s.scrollback,
                  items: const [1000, 5000, 10000, 20000]
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: (v) {
                    s.scrollback = v ?? 5000;
                    _save();
                  },
                ),
              ),
              if (Platform.isWindows)
                SwitchListTile(
                  value: s.rightClickPaste,
                  onChanged: (v) {
                    s.rightClickPaste = v;
                    _save();
                  },
                  title: const Text('Select to copy, right-click to paste (like PuTTY)'),
                ),
              if (Platform.isWindows)
                SwitchListTile(
                  value: s.ctrlVPaste,
                  onChanged: (v) {
                    s.ctrlVPaste = v;
                    _save();
                  },
                  title: const Text('Ctrl+V pastes'),
                  subtitle: const Text(
                    'Turn off to send Ctrl+V to the server instead (e.g. page down in nano). '
                    'Ctrl+Shift+V always pastes.',
                    style: TextStyle(color: PX.muted, fontSize: 12),
                  ),
                ),
              _section('Connection'),
              SwitchListTile(
                value: s.autoReconnect,
                onChanged: (v) {
                  s.autoReconnect = v;
                  _save();
                },
                title: const Text('Reconnect automatically'),
                subtitle: const Text(
                  'If the network drops, keep retrying until you close the tab yourself.',
                  style: TextStyle(color: PX.muted, fontSize: 12),
                ),
              ),
              if (Platform.isAndroid) ...[
                SwitchListTile(
                  value: s.keepCpuAwake,
                  onChanged: (v) async {
                    s.keepCpuAwake = v;
                    await _save();
                    await SessionKeeper.refresh();
                  },
                  title: const Text('Keep connections alive with screen off'),
                  subtitle: const Text(
                    'Holds a light wake lock while sessions are open. Most reliable; uses a little more battery.',
                    style: TextStyle(color: PX.muted, fontSize: 12),
                  ),
                ),
                ListTile(
                  title: const Text('Allow running in background'),
                  subtitle: const Text(
                    'Recommended on Samsung: stops battery saver from closing your sessions.',
                    style: TextStyle(color: PX.muted, fontSize: 12),
                  ),
                  trailing: const Icon(Icons.battery_saver_outlined),
                  onTap: SessionKeeper.requestBatteryExemption,
                ),
              ],
              _section('Server monitor'),
              ListTile(
                title: const Text('Update every'),
                subtitle: const Text('Longer = even less load on the server',
                    style: TextStyle(color: PX.muted, fontSize: 12)),
                trailing: DropdownButton<int>(
                  value: s.monitorSeconds,
                  items: const [2, 3, 5, 10, 30]
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v sec')))
                      .toList(),
                  onChanged: (v) {
                    s.monitorSeconds = v ?? 3;
                    _save();
                  },
                ),
              ),
              SwitchListTile(
                value: s.backgroundMonitor,
                onChanged: (v) {
                  s.backgroundMonitor = v;
                  _save();
                },
                title: const Text('Monitor while panel is hidden'),
                subtitle: const Text(
                  'Shows CPU/RAM in the tab bar and keeps graph history. Turn off for zero background polling.',
                  style: TextStyle(color: PX.muted, fontSize: 12),
                ),
              ),
              _section('Known hosts'),
              ListTile(
                title: Text('${s.knownHosts.length} trusted host keys'),
                trailing: TextButton(
                  onPressed: s.knownHosts.isEmpty
                      ? null
                      : () {
                          s.knownHosts.clear();
                          _save();
                        },
                  child: const Text('Forget all'),
                ),
              ),
              _section('About'),
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/logo.png', width: 40, height: 40),
                ),
                title: const Text('Phoenicx SSH'),
                subtitle: const Text('Version $appVersion\nMade by Hanson', style: TextStyle(color: PX.muted)),
                isThreeLine: true,
              ),
              ListTile(
                leading: const Icon(Icons.language, color: PX.accent),
                title: const Text('phoenicx.org'),
                onTap: () => launchUrl(Uri.parse('https://phoenicx.org'), mode: LaunchMode.externalApplication),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

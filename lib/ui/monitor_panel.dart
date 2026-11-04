import 'package:flutter/material.dart';

import '../services/monitor.dart';
import '../services/session.dart';
import '../theme.dart';
import 'charts.dart';

class MonitorPanel extends StatefulWidget {
  final SshTab tab;
  const MonitorPanel({super.key, required this.tab});

  @override
  State<MonitorPanel> createState() => _MonitorPanelState();
}

class _MonitorPanelState extends State<MonitorPanel> {
  int _view = 0; // 0 processes, 1 docker, 2 net per app
  bool _byMem = false;
  bool _grouped = true;

  SshTab get tab => widget.tab;

  @override
  void dispose() {
    tab.nethogs.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PX.surface,
      child: AnimatedBuilder(
        animation: Listenable.merge([tab, tab.monitor, tab.nethogs]),
        builder: (context, _) {
          final m = tab.monitor;
          if (tab.status != TabStatus.connected) {
            return const _Empty(icon: Icons.cloud_off, text: 'Not connected');
          }
          if (!m.hasData) {
            return _Empty(
              icon: Icons.monitor_heart_outlined,
              text: m.error ?? 'Collecting server stats...',
              busy: m.error == null,
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            children: [
              _header(m),
              const SizedBox(height: 10),
              _cpuCard(m),
              _memCard(m),
              _netCard(m),
              _diskCard(m),
              const SizedBox(height: 6),
              _segments(),
              const SizedBox(height: 8),
              if (_view == 0) ..._processes(m),
              if (_view == 1) ..._docker(m),
              if (_view == 2) ..._netApps(),
            ],
          );
        },
      ),
    );
  }

  Widget _header(MonitorService m) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _chip(Icons.memory, '${m.cores} cores'),
        _chip(Icons.timer_outlined, 'up ${fmtDuration(m.uptime)}'),
        _chip(Icons.speed, 'load ${m.load.map((e) => e.toStringAsFixed(2)).join('  ')}'),
      ],
    );
  }

  Widget _chip(IconData i, String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: PX.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 13, color: PX.muted),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 11.5, color: PX.muted)),
        ]),
      );

  Widget _card({required String title, required String value, String? sub, required Widget child, Color color = PX.accent}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: PX.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PX.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(title, style: const TextStyle(fontSize: 12, color: PX.muted, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
          if (sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(sub, style: const TextStyle(fontSize: 11, color: PX.muted)),
            ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _cpuCard(MonitorService m) => _card(
        title: 'CPU',
        value: '${m.cpu.toStringAsFixed(1)}%',
        sub: m.steal >= 1 ? 'steal ${m.steal.toStringAsFixed(1)}% (host is busy)' : null,
        child: LiveChart(series: [Series(m.cpuHist.data, PX.accent)], maxY: 100),
      );

  Widget _memCard(MonitorService m) => _card(
        title: 'Memory',
        value: '${m.memPerc.toStringAsFixed(0)}%',
        color: PX.blue,
        sub: '${fmtBytes(m.memUsed)} of ${fmtBytes(m.memTotal)}'
            '${m.swapTotal > 0 ? '   swap ${fmtBytes(m.swapUsed)} / ${fmtBytes(m.swapTotal)}' : ''}',
        child: LiveChart(series: [Series(m.memHist.data, PX.blue)], maxY: 100),
      );

  Widget _netCard(MonitorService m) => _card(
        title: 'Network',
        value: '',
        color: PX.green,
        sub: null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.south, size: 14, color: PX.green),
              Text(' ${fmtRate(m.rxRate)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 14),
              const Icon(Icons.north, size: 14, color: PX.purple),
              Text(' ${fmtRate(m.txRate)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            LiveChart(series: [Series(m.rxHist.data, PX.green), Series(m.txHist.data, PX.purple)]),
            if (m.ifaceRates.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  m.ifaceRates.entries
                      .map((e) => '${e.key}: ↓${fmtRate(e.value.$1)} ↑${fmtRate(e.value.$2)}')
                      .join('\n'),
                  style: const TextStyle(fontSize: 11, color: PX.muted),
                ),
              ),
          ],
        ),
      );

  Widget _diskCard(MonitorService m) => _card(
        title: 'Disk  /',
        value: '${m.diskPerc.toStringAsFixed(0)}%',
        color: PX.yellow,
        sub: '${fmtBytes(m.diskUsed)} of ${fmtBytes(m.diskTotal)}',
        child: UsageBar(percent: m.diskPerc, color: m.diskPerc > 90 ? PX.red : PX.yellow),
      );

  Widget _segments() {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12),
      ),
      segments: const [
        ButtonSegment(value: 0, label: Text('Processes'), icon: Icon(Icons.apps, size: 16)),
        ButtonSegment(value: 1, label: Text('Docker'), icon: Icon(Icons.inventory_2_outlined, size: 16)),
        ButtonSegment(value: 2, label: Text('Net / app'), icon: Icon(Icons.swap_vert, size: 16)),
      ],
      selected: {_view},
      onSelectionChanged: (s) {
        setState(() => _view = s.first);
        if (_view == 2) {
          final c = tab.client;
          if (c != null && !tab.nethogs.running) tab.nethogs.start(c);
        } else {
          tab.nethogs.stop();
        }
      },
    );
  }

  List<Widget> _processes(MonitorService m) {
    final list = m.topProcesses(byMemory: _byMem, grouped: _grouped);
    return [
      Row(children: [
        _toggle('CPU', !_byMem, () => setState(() => _byMem = false)),
        const SizedBox(width: 6),
        _toggle('RAM', _byMem, () => setState(() => _byMem = true)),
        const Spacer(),
        _toggle(_grouped ? 'Grouped by app' : 'Each process', _grouped,
            () => setState(() => _grouped = !_grouped)),
      ]),
      const SizedBox(height: 6),
      if (list.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Reading processes...', style: TextStyle(color: PX.muted)),
        ),
      for (final p in list) _procRow(p, m),
    ];
  }

  Widget _toggle(String label, bool on, VoidCallback tap) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: on ? PX.accent.withValues(alpha: 0.18) : PX.surface2,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: on ? PX.accent : Colors.transparent),
          ),
          child: Text(label, style: TextStyle(fontSize: 11.5, color: on ? PX.accent2 : PX.muted)),
        ),
      );

  Widget _procRow(ProcInfo p, MonitorService m) {
    final memPerc = m.memTotal == 0 ? 0.0 : p.rss / m.memTotal * 100;
    return InkWell(
      onTap: _grouped ? null : () => _procMenu(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                p.count > 1 ? '${p.name}  ×${p.count}' : p.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              if (!_grouped)
                Text('PID ${p.pid}', style: const TextStyle(fontSize: 10.5, color: PX.muted)),
            ]),
          ),
          Expanded(
            flex: 3,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${p.cpu.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 3),
              UsageBar(percent: p.cpu / m.cores, color: PX.accent),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmtBytes(p.rss), style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 3),
              UsageBar(percent: memPerc, color: PX.blue),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _procMenu(ProcInfo p) async {
    final sig = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text('${p.name} (PID ${p.pid})'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'TERM'),
            child: const Text('End process (kill)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'KILL'),
            child: const Text('Force kill (kill -9)', style: TextStyle(color: PX.red)),
          ),
        ],
      ),
    );
    if (sig == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await tab.run('kill -$sig ${p.pid} 2>&1 || sudo -n kill -$sig ${p.pid} 2>&1');
      messenger.showSnackBar(SnackBar(content: Text('Sent SIG$sig to ${p.name}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not kill: $e')));
    }
  }

  List<Widget> _docker(MonitorService m) {
    if (!m.dockerSeen) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Reading containers... (needs Docker; uses sudo if your user is not in the docker group)',
            style: TextStyle(color: PX.muted, fontSize: 12.5),
          ),
        ),
      ];
    }
    if (m.containers.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Text('No running containers found.', style: TextStyle(color: PX.muted)),
        ),
      ];
    }
    final list = [...m.containers]..sort((a, b) => b.cpuValue.compareTo(a.cpuValue));
    return [
      for (final c in list)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: PX.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: PX.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.inventory_2_outlined, size: 15, color: PX.accent2),
              const SizedBox(width: 6),
              Expanded(
                child: Text(c.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              Text('CPU ${c.cpu}', style: const TextStyle(fontSize: 12)),
            ]),
            const SizedBox(height: 4),
            Text('RAM ${c.mem} (${c.memPerc})',
                style: const TextStyle(fontSize: 11.5, color: PX.muted)),
            Text('Net ${c.net}    Disk ${c.block}',
                style: const TextStyle(fontSize: 11.5, color: PX.muted)),
          ]),
        ),
      const Text('Updates every few cycles to keep server load low.',
          style: TextStyle(fontSize: 10.5, color: PX.muted)),
    ];
  }

  List<Widget> _netApps() {
    final n = tab.nethogs;
    if (n.problem == 'notfound') {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Per-app network usage needs the small "nethogs" tool on the server.',
            style: TextStyle(color: PX.muted, fontSize: 12.5),
          ),
        ),
        FilledButton.icon(
          onPressed: () => tab.send('sudo apt install -y nethogs || sudo dnf install -y nethogs\r'),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Install it in the terminal'),
        ),
        TextButton(
          onPressed: () {
            final c = tab.client;
            if (c != null) n.start(c);
          },
          child: const Text('Check again'),
        ),
      ];
    }
    if (n.problem == 'sudo') {
      return const [
        Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'nethogs needs root. Your user needs passwordless sudo (the default ubuntu/opc users on Oracle have it).',
            style: TextStyle(color: PX.muted, fontSize: 12.5),
          ),
        ),
      ];
    }
    if (n.problem == 'error') {
      return const [Text('Could not start nethogs.', style: TextStyle(color: PX.muted))];
    }
    if (n.apps.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Text('Measuring traffic per app...', style: TextStyle(color: PX.muted)),
        ),
      ];
    }
    return [
      for (final a in n.apps.take(30))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                if (a.pid > 0) Text('PID ${a.pid}', style: const TextStyle(fontSize: 10.5, color: PX.muted)),
              ]),
            ),
            const Icon(Icons.south, size: 12, color: PX.green),
            SizedBox(width: 78, child: Text(fmtRate(a.recvKBs * 1024), style: const TextStyle(fontSize: 12))),
            const Icon(Icons.north, size: 12, color: PX.purple),
            SizedBox(width: 78, child: Text(fmtRate(a.sentKBs * 1024), style: const TextStyle(fontSize: 12))),
          ]),
        ),
    ];
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool busy;
  const _Empty({required this.icon, required this.text, this.busy = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (busy)
            const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(icon, size: 36, color: PX.muted),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: PX.muted)),
        ]),
      ),
    );
  }
}

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

  void _setView(int v) {
    setState(() => _view = v);
    if (v == 2) {
      _enterNetView();
    } else {
      tab.nethogs.stop();
    }
  }

  Future<void> _enterNetView() async {
    final c = tab.client;
    if (c == null) return;
    final tool = tab.nethogsTool;
    if (tool.state == ToolState.unknown || tool.state == ToolState.notInstalled) {
      await tool.check(c);
    }
    if (!mounted || _view != 2) return;
    if (tool.isInstalled && !tab.nethogs.running) tab.nethogs.start(c);
  }

  Future<void> _toolAction(String action) async {
    final c = tab.client;
    if (c == null) return;
    if (action == 'uninstall') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Uninstall nethogs?'),
          content: const Text('It is removed from the server. The per-app network view stops working until you install it again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Uninstall')),
          ],
        ),
      );
      if (ok != true) return;
      tab.nethogs.stop();
    }
    final tool = tab.nethogsTool;
    final ok = await tool.run(c, action);
    if (!mounted) return;
    final msg = ok
        ? switch (action) {
            'install' => 'nethogs installed',
            'upgrade' => 'nethogs updated',
            _ => 'nethogs removed',
          }
        : 'Failed: ${tool.lastError ?? 'unknown error'}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    if (ok && _view == 2 && tool.isInstalled) {
      final c2 = tab.client;
      if (c2 != null) tab.nethogs.start(c2);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PX.surface,
      child: AnimatedBuilder(
        animation: Listenable.merge([tab, tab.monitor, tab.nethogs, tab.nethogsTool]),
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
          return LayoutBuilder(builder: (context, box) {
            final twoCol = box.maxWidth >= 760;
            final left = [_cpuCard(m), _memCard(m)];
            final right = [_netCard(m), _diskCard(m)];
            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
              children: [
                _header(m),
                const SizedBox(height: 10),
                _gauges(m),
                const SizedBox(height: 10),
                if (twoCol)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(children: left)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(children: right)),
                  ])
                else ...[...left, ...right],
                const SizedBox(height: 6),
                _segments(),
                const SizedBox(height: 10),
                if (_view == 0) ..._processes(m),
                if (_view == 1) ..._docker(m),
                if (_view == 2) ..._netApps(),
              ],
            );
          });
        },
      ),
    );
  }

  // ------------------------------------------------------------ overview

  Widget _header(MonitorService m) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _box(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.dns_rounded, size: 18, color: PX.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(m.hostname.isEmpty ? tab.host.host : m.hostname,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          if (tab.monitor.running)
            const Tooltip(
              message: 'Live',
              child: Icon(Icons.circle, size: 9, color: PX.green),
            ),
        ]),
        if (m.os.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 26),
            child: Text('${m.os} · ${m.kernel} · ${m.arch}',
                style: const TextStyle(fontSize: 11.5, color: PX.muted)),
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _chip(Icons.memory, '${m.cores} cores'),
          _chip(Icons.timer_outlined, 'up ${fmtDuration(m.uptime)}'),
          _chip(Icons.speed, 'load ${m.load.map((e) => e.toStringAsFixed(2)).join(' · ')}'),
        ]),
      ]),
    );
  }

  Widget _gauges(MonitorService m) {
    final root = m.rootDisk;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      decoration: _box(),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        RingGauge(percent: m.cpu, label: 'CPU', sub: '${m.cores} cores', color: PX.accent),
        RingGauge(percent: m.memPerc, label: 'RAM', sub: fmtBytes(m.memTotal, digits: 0), color: PX.blue),
        if (m.swapTotal > 0)
          RingGauge(percent: m.swapPerc, label: 'Swap', sub: fmtBytes(m.swapTotal, digits: 0), color: PX.purple),
        if (root != null)
          RingGauge(percent: root.perc, label: 'Disk', sub: fmtBytes(root.total, digits: 0), color: PX.yellow),
      ]),
    );
  }

  BoxDecoration _box() => BoxDecoration(
        color: PX.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PX.line),
      );

  Widget _chip(IconData i, String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: PX.surface2, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 13, color: PX.muted),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 11.5, color: PX.muted)),
        ]),
      );

  Widget _card({required String title, String value = '', required List<Widget> children, Color color = PX.accent}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: _box(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(title, style: const TextStyle(fontSize: 12.5, color: PX.muted, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }

  Widget _legend(List<(String, String, Color)> items) => Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          for (final i in items)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: i.$3, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 4),
              Text('${i.$1} ', style: const TextStyle(fontSize: 11, color: PX.muted)),
              Text(i.$2, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
        ],
      );

  Widget _cpuCard(MonitorService m) => _card(
        title: 'CPU',
        value: '${m.cpu.toStringAsFixed(1)}%',
        children: [
          LiveChart(series: [Series(m.cpuHist.data, PX.accent)], maxY: 100, height: 80, topLabel: (_) => '100%'),
          const SizedBox(height: 8),
          _legend([
            ('user', '${m.cpuUser.toStringAsFixed(1)}%', PX.accent),
            ('system', '${m.cpuSystem.toStringAsFixed(1)}%', PX.accent2),
            ('io wait', '${m.cpuIowait.toStringAsFixed(1)}%', PX.blue),
            ('steal', '${m.steal.toStringAsFixed(1)}%', PX.red),
          ]),
          if (m.coreUsage.length > 1) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (var i = 0; i < m.coreUsage.length; i++)
                SizedBox(
                  width: 70,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('core $i  ${m.coreUsage[i].toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 10, color: PX.muted)),
                    const SizedBox(height: 2),
                    UsageBar(percent: m.coreUsage[i], color: PX.accent),
                  ]),
                ),
            ]),
          ],
          if (m.steal >= 5)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('High steal: the cloud host is busy and your instance is waiting for CPU.',
                  style: TextStyle(fontSize: 11, color: PX.yellow)),
            ),
        ],
      );

  Widget _memCard(MonitorService m) {
    final t = m.memTotal == 0 ? 1 : m.memTotal;
    final room = t - m.memUsed < 0 ? 0 : t - m.memUsed;
    final cache = m.memCache.clamp(0, room).toInt();
    return _card(
      title: 'Memory',
      value: '${fmtBytes(m.memUsed)} / ${fmtBytes(m.memTotal)}',
      color: PX.blue,
      children: [
        LiveChart(series: [Series(m.memHist.data, PX.blue)], maxY: 100, height: 70, topLabel: (_) => '100%'),
        const SizedBox(height: 8),
        StackedBar(parts: [(m.memUsed / t, PX.blue), (cache / t, PX.blue.withValues(alpha: 0.4))]),
        const SizedBox(height: 6),
        _legend([
          ('used', fmtBytes(m.memUsed), PX.blue),
          ('cache', fmtBytes(cache), PX.blue.withValues(alpha: 0.4)),
          ('free', fmtBytes(m.memFree), PX.surface2),
        ]),
        if (m.swapTotal > 0) ...[
          const SizedBox(height: 8),
          Text('Swap ${fmtBytes(m.swapUsed)} of ${fmtBytes(m.swapTotal)}',
              style: const TextStyle(fontSize: 11, color: PX.muted)),
          const SizedBox(height: 3),
          UsageBar(percent: m.swapPerc, color: PX.purple),
        ],
      ],
    );
  }

  Widget _netCard(MonitorService m) => _card(
        title: 'Network',
        color: PX.green,
        children: [
          Row(children: [
            const Icon(Icons.south, size: 15, color: PX.green),
            Text(' ${fmtRate(m.rxRate)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(width: 16),
            const Icon(Icons.north, size: 15, color: PX.purple),
            Text(' ${fmtRate(m.txRate)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          LiveChart(
            series: [Series(m.rxHist.data, PX.green), Series(m.txHist.data, PX.purple)],
            height: 80,
            topLabel: (t) => fmtRate(t),
          ),
          const SizedBox(height: 8),
          _legend([
            ('received since boot', fmtBytes(m.rxTotal), PX.green),
            ('sent', fmtBytes(m.txTotal), PX.purple),
          ]),
          if (m.ifaceRates.length > 1) ...[
            const SizedBox(height: 6),
            for (final e in m.ifaceRates.entries)
              Text('${e.key}   ↓${fmtRate(e.value.$1)}   ↑${fmtRate(e.value.$2)}',
                  style: const TextStyle(fontSize: 11, color: PX.muted)),
          ],
        ],
      );

  Widget _diskCard(MonitorService m) => _card(
        title: 'Disks',
        color: PX.yellow,
        children: [
          Row(children: [
            const Text('read ', style: TextStyle(fontSize: 11, color: PX.muted)),
            Text(fmtRate(m.diskRead), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(width: 14),
            const Text('write ', style: TextStyle(fontSize: 11, color: PX.muted)),
            Text(fmtRate(m.diskWrite), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 6),
          LiveChart(
            series: [Series(m.readHist.data, PX.yellow), Series(m.writeHist.data, PX.red)],
            height: 50,
            topLabel: (t) => fmtRate(t),
          ),
          const SizedBox(height: 10),
          for (final d in m.disks)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(d.mount,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                  Text('${fmtBytes(d.used)} / ${fmtBytes(d.total)}  ${d.perc.toStringAsFixed(0)}%',
                      style: const TextStyle(fontSize: 11, color: PX.muted)),
                ]),
                const SizedBox(height: 3),
                UsageBar(percent: d.perc, color: d.perc > 90 ? PX.red : PX.yellow),
              ]),
            ),
        ],
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
      onSelectionChanged: (s) => _setView(s.first),
    );
  }

  // ------------------------------------------------------------ processes

  List<Widget> _processes(MonitorService m) {
    if (!m.processesSeen) {
      return const [_Note('Reading processes...', busy: true)];
    }
    final list = m.topProcesses(byMemory: _byMem, grouped: _grouped);
    return [
      Row(children: [
        _toggle('By CPU', !_byMem, () => setState(() => _byMem = false)),
        const SizedBox(width: 6),
        _toggle('By RAM', _byMem, () => setState(() => _byMem = true)),
        const Spacer(),
        _toggle(_grouped ? 'Grouped by app' : 'Each process', _grouped,
            () => setState(() => _grouped = !_grouped)),
      ]),
      const SizedBox(height: 6),
      Row(children: const [
        Expanded(flex: 5, child: Text('NAME', style: TextStyle(fontSize: 10, color: PX.muted, letterSpacing: 1))),
        Expanded(flex: 3, child: Text('CPU', textAlign: TextAlign.end, style: TextStyle(fontSize: 10, color: PX.muted, letterSpacing: 1))),
        SizedBox(width: 12),
        Expanded(flex: 3, child: Text('RAM', textAlign: TextAlign.end, style: TextStyle(fontSize: 10, color: PX.muted, letterSpacing: 1))),
      ]),
      const Divider(height: 10),
      if (list.isEmpty) const _Note('No processes found.'),
      for (final p in list) _procRow(p, m),
      if (!_grouped)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Tap a process to end it.', style: TextStyle(fontSize: 10.5, color: PX.muted)),
        ),
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
              Text(p.count > 1 ? '${p.name}  ×${p.count}' : p.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              if (!_grouped) Text('PID ${p.pid}', style: const TextStyle(fontSize: 10.5, color: PX.muted)),
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
          SimpleDialogOption(onPressed: () => Navigator.pop(c, 'TERM'), child: const Text('End process (kill)')),
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
      await tab.run('kill -$sig ${p.pid} 2>/dev/null || sudo -n kill -$sig ${p.pid}');
      messenger.showSnackBar(SnackBar(content: Text('Sent SIG$sig to ${p.name}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not kill: $e')));
    }
  }

  // ------------------------------------------------------------ docker

  List<Widget> _docker(MonitorService m) {
    switch (m.docker) {
      case DockerState.unknown:
        return const [_Note('Reading containers...', busy: true)];
      case DockerState.notInstalled:
        return const [_Note('Docker is not installed on this server.')];
      case DockerState.noPermission:
        return const [
          _Note('No permission to read Docker. Add your user to the docker group '
              '(sudo usermod -aG docker \$USER, then reconnect) or allow passwordless sudo.'),
        ];
      case DockerState.ok:
        break;
    }
    if (m.containers.isEmpty) return const [_Note('No running containers.')];
    final list = [...m.containers]..sort((a, b) => b.cpuValue.compareTo(a.cpuValue));
    return [
      for (final c in list)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: _box(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.inventory_2_outlined, size: 15, color: PX.accent2),
              const SizedBox(width: 6),
              Expanded(
                child: Text(c.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              Text('CPU ${c.cpu}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            UsageBar(percent: c.cpuValue, color: PX.accent),
            const SizedBox(height: 6),
            Text('RAM ${c.mem} (${c.memPerc})', style: const TextStyle(fontSize: 11.5, color: PX.muted)),
            Text('Net ${c.net}    Disk ${c.block}', style: const TextStyle(fontSize: 11.5, color: PX.muted)),
          ]),
        ),
      const Text('Container stats refresh every few updates to keep server load low.',
          style: TextStyle(fontSize: 10.5, color: PX.muted)),
    ];
  }

  // ------------------------------------------------------------ net per app

  List<Widget> _netApps() {
    final tool = tab.nethogsTool;
    final n = tab.nethogs;
    final out = <Widget>[_toolCard(tool)];
    if (!tool.isInstalled) return out;
    out.add(const SizedBox(height: 10));
    if (n.problem == 'sudo') {
      out.add(const _Note('nethogs needs root. Your user needs passwordless sudo '
          '(the default ubuntu/opc users on Oracle have it).'));
      return out;
    }
    if (n.problem != null) {
      out.add(_Note('nethogs stopped: ${n.problem}'));
      out.add(Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            final c = tab.client;
            if (c != null) n.start(c);
          },
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Restart'),
        ),
      ));
      return out;
    }
    if (!n.gotFirstSample) {
      out.add(const _Note('Measuring traffic per app...', busy: true));
      return out;
    }
    if (n.apps.isEmpty) {
      out.add(const _Note('No network traffic right now.'));
      return out;
    }
    out.add(Row(children: const [
      Expanded(child: Text('APP', style: TextStyle(fontSize: 10, color: PX.muted, letterSpacing: 1))),
      SizedBox(width: 90, child: Text('DOWN', style: TextStyle(fontSize: 10, color: PX.muted, letterSpacing: 1))),
      SizedBox(width: 84, child: Text('UP', style: TextStyle(fontSize: 10, color: PX.muted, letterSpacing: 1))),
    ]));
    out.add(const Divider(height: 10));
    for (final a in n.apps.take(30)) {
      out.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              if (a.pid > 0) Text('PID ${a.pid}', style: const TextStyle(fontSize: 10.5, color: PX.muted)),
            ]),
          ),
          const Icon(Icons.south, size: 12, color: PX.green),
          SizedBox(width: 78, child: Text(' ${fmtRate(a.recvKBs * 1024)}', style: const TextStyle(fontSize: 12))),
          const Icon(Icons.north, size: 12, color: PX.purple),
          SizedBox(width: 72, child: Text(' ${fmtRate(a.sentKBs * 1024)}', style: const TextStyle(fontSize: 12))),
        ]),
      ));
    }
    return out;
  }

  Widget _toolCard(ServerTool tool) {
    final busy = tool.state == ToolState.busy || tool.state == ToolState.checking;
    String title;
    String sub;
    final actions = <Widget>[];
    switch (tool.state) {
      case ToolState.unknown:
      case ToolState.checking:
        title = 'Checking nethogs...';
        sub = 'Looking for the tool on the server.';
      case ToolState.notInstalled:
        title = 'nethogs is not installed';
        sub = 'This small tool shows how much network each app uses. '
            '${tool.candidate.isNotEmpty ? 'Version ${tool.candidate} is available.' : ''}';
        actions.add(FilledButton.icon(
          onPressed: () => _toolAction('install'),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Install'),
        ));
      case ToolState.updateAvailable:
        title = 'nethogs ${tool.installed}';
        sub = 'Update available: ${tool.candidate}';
        actions.add(FilledButton.icon(
          onPressed: () => _toolAction('upgrade'),
          icon: const Icon(Icons.system_update_alt, size: 18),
          label: const Text('Upgrade'),
        ));
        actions.add(TextButton(onPressed: () => _toolAction('uninstall'), child: const Text('Uninstall')));
      case ToolState.installed:
        title = 'nethogs ${tool.installed}';
        sub = 'Installed · up to date';
        actions.add(TextButton(onPressed: () => _toolAction('uninstall'), child: const Text('Uninstall')));
      case ToolState.busy:
        title = 'Working...';
        sub = tool.log.isEmpty ? 'Talking to the package manager' : tool.log.last;
      case ToolState.unsupported:
        title = 'Package manager not found';
        sub = 'Install nethogs on the server yourself to see per-app traffic.';
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _box(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            tool.isInstalled ? Icons.check_circle : Icons.extension_outlined,
            size: 18,
            color: tool.state == ToolState.installed
                ? PX.green
                : tool.state == ToolState.updateAvailable
                    ? PX.yellow
                    : PX.muted,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          if (busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          if (!busy && tool.state != ToolState.unknown)
            IconButton(
              tooltip: 'Check again',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () {
                final c = tab.client;
                if (c != null) tool.check(c);
              },
              icon: const Icon(Icons.refresh),
            ),
        ]),
        const SizedBox(height: 4),
        Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: PX.muted)),
        if (tool.lastError != null && !busy) ...[
          const SizedBox(height: 6),
          Text(tool.lastError!, style: const TextStyle(fontSize: 11.5, color: PX.red)),
          if (tool.needsSudoPassword)
            TextButton.icon(
              onPressed: () {
                tab.send('${tool.manualCommand(tool.isInstalled ? 'upgrade' : 'install')}\r');
                tab.setMonitorVisible(false);
              },
              icon: const Icon(Icons.terminal, size: 18),
              label: const Text('Run it in the terminal instead'),
            ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: actions),
        ],
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final bool busy;
  const _Note(this.text, {this.busy = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(children: [
        if (busy) ...[
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
        ],
        Expanded(child: Text(text, style: const TextStyle(color: PX.muted, fontSize: 12.5))),
      ]),
    );
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

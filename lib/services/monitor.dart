import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class ProcInfo {
  final int pid;
  final String name;
  double cpu; // % of one core, like top
  int rss; // bytes
  int count;
  ProcInfo(this.pid, this.name, this.cpu, this.rss, [this.count = 1]);
}

class ContainerInfo {
  final String name, cpu, mem, memPerc, net, block;
  ContainerInfo(this.name, this.cpu, this.mem, this.memPerc, this.net, this.block);
  double get cpuValue => double.tryParse(cpu.replaceAll('%', '')) ?? 0;
}

class NetApp {
  final String name;
  final int pid;
  final double sentKBs, recvKBs;
  NetApp(this.name, this.pid, this.sentKBs, this.recvKBs);
}

class History {
  final int size;
  final List<double> data = [];
  History([this.size = 90]);
  void add(double v) {
    data.add(v);
    if (data.length > size) data.removeAt(0);
  }

  double get last => data.isEmpty ? 0 : data.last;
}

/// Polls the server's CPU, memory, network, disk, processes and Docker
/// containers through ONE long-running shell loop on a separate SSH channel.
/// The loop is just `cat`/`awk` on /proc, so it costs the server almost
/// nothing; processes and containers are only collected while the
/// monitor panel is on screen.
class MonitorService extends ChangeNotifier {
  SSHClient? _client;
  SSHSession? _loop;
  int _gen = 0;
  bool _full = false;
  int _interval = 3;
  bool running = false;
  String? error;

  // latest values
  int cores = 1;
  double cpu = 0, steal = 0;
  int memTotal = 0, memUsed = 0, swapTotal = 0, swapUsed = 0;
  double rxRate = 0, txRate = 0;
  int diskTotal = 0, diskUsed = 0;
  List<double> load = [0, 0, 0];
  Duration uptime = Duration.zero;
  Map<String, (double, double)> ifaceRates = {};
  List<ProcInfo> processes = [];
  List<ContainerInfo> containers = [];
  bool dockerSeen = false;
  bool hasData = false;

  final cpuHist = History(), memHist = History(), rxHist = History(), txHist = History();

  // previous samples
  int? _pTotal, _pIdle, _pSteal;
  double? _pTime;
  Map<String, (int, int)> _pNet = {};
  Map<int, int> _pProc = {};
  int _pageSize = 4096;

  double get memPerc => memTotal == 0 ? 0 : memUsed / memTotal * 100;
  double get diskPerc => diskTotal == 0 ? 0 : diskUsed / diskTotal * 100;

  void attach(SSHClient client, {required bool full, required int interval}) {
    _client = client;
    _full = full;
    _interval = interval;
    _restart();
  }

  void configure({bool? full, int? interval}) {
    final changed = (full != null && full != _full) ||
        (interval != null && interval != _interval);
    if (full != null) _full = full;
    if (interval != null) _interval = interval;
    if (changed && _client != null) _restart();
  }

  void detach() {
    _client = null;
    _stopLoop();
    running = false;
    notifyListeners();
  }

  void _stopLoop() {
    _gen++;
    try {
      _loop?.close();
    } catch (_) {}
    _loop = null;
    _pProc = {};
  }

  Future<void> _restart() async {
    _stopLoop();
    final c = _client;
    if (c == null || c.isClosed) return;
    final gen = _gen;
    try {
      final s = await c.execute(_script(_full, _interval));
      if (gen != _gen) {
        s.close();
        return;
      }
      _loop = s;
      running = true;
      error = null;
      final block = <String>[];
      s.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        if (gen != _gen) return;
        if (line == '@@E') {
          _parse(block);
          block.clear();
        } else {
          block.add(line);
        }
      }, onError: (_) {}, onDone: () {
        if (gen == _gen) {
          running = false;
          notifyListeners();
        }
      });
      s.stderr.listen((_) {});
    } catch (e) {
      running = false;
      error = 'Monitor unavailable: $e';
      notifyListeners();
    }
  }

  static String _script(bool full, int interval) {
    const awkProc =
        r'''awk '{l=$0;i=index(l,"(");j=0;for(k=length(l);k>i;k--)if(substr(l,k,1)==")"){j=k;break};if(j==0)next;nm=substr(l,i+1,j-i-1);n=split(substr(l,j+2),a," ");print $1"\t"nm"\t"(a[12]+a[13])"\t"a[22]}' /proc/[0-9]*/stat 2>/dev/null''';
    const fmt = "'{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}'";
    final fullPart = full
        ? '''
echo "@@P"; $awkProc
if [ \$((i % 4)) -eq 0 ] && command -v docker >/dev/null 2>&1; then
  echo "@@C"; docker stats --no-stream --format $fmt 2>/dev/null || sudo -n docker stats --no-stream --format $fmt 2>/dev/null
fi'''
        : '';
    return '''
PS=\$(getconf PAGESIZE 2>/dev/null || echo 4096); N=\$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1); i=0
while :; do
echo "@@S \$PS \$N"; head -1 /proc/stat
echo "@@M"; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
echo "@@N"; tail -n +3 /proc/net/dev
echo "@@L"; cat /proc/loadavg /proc/uptime
echo "@@D"; df -P -k / 2>/dev/null | tail -1$fullPart
echo "@@E"
i=\$((i+1)); sleep $interval
done
''';
  }

  static bool _virtualIface(String n) =>
      n == 'lo' ||
      n.startsWith('veth') ||
      n.startsWith('docker') ||
      n.startsWith('br-') ||
      n.startsWith('virbr') ||
      n.startsWith('cni') ||
      n.startsWith('flannel') ||
      n.startsWith('tailscale') ||
      n.startsWith('zt');

  void _parse(List<String> lines) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final dt = _pTime == null ? 0.0 : now - _pTime!;
    String section = '';
    int? total, idle, stl;
    final mem = <String, int>{};
    final net = <String, (int, int)>{};
    final procLines = <String>[];
    List<ContainerInfo>? cont;
    final loadLines = <String>[];

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.startsWith('@@')) {
        section = line.substring(2, 3);
        if (section == 'S') {
          final p = line.split(' ');
          if (p.length >= 3) {
            _pageSize = int.tryParse(p[1]) ?? 4096;
            cores = int.tryParse(p[2]) ?? 1;
          }
        }
        if (section == 'C') cont = [];
        continue;
      }
      switch (section) {
        case 'S': {
          if (line.startsWith('cpu ')) {
            final v = line
                .split(RegExp(r'\s+'))
                .skip(1)
                .map((e) => int.tryParse(e) ?? 0)
                .toList();
            if (v.length >= 4) {
              total = v.take(8).fold<int>(0, (a, b) => a + b);
              idle = v[3] + (v.length > 4 ? v[4] : 0);
              stl = v.length > 7 ? v[7] : 0;
            }
          }
        }
        case 'M': {
          final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
          if (m != null) mem[m.group(1)!] = int.parse(m.group(2)!) * 1024;
        }
        case 'N': {
          final c = line.indexOf(':');
          if (c > 0) {
            final name = line.substring(0, c).trim();
            final f = line.substring(c + 1).trim().split(RegExp(r'\s+'));
            if (f.length >= 9) {
              net[name] = (int.tryParse(f[0]) ?? 0, int.tryParse(f[8]) ?? 0);
            }
          }
        }
        case 'L': {
          loadLines.add(line);
        }
        case 'D': {
          final f = line.split(RegExp(r'\s+'));
          if (f.length >= 4) {
            diskTotal = (int.tryParse(f[1]) ?? 0) * 1024;
            diskUsed = (int.tryParse(f[2]) ?? 0) * 1024;
          }
        }
        case 'P': {
          procLines.add(line);
        }
        case 'C': {
          final f = line.split('|');
          if (f.length >= 6) {
            cont!.add(ContainerInfo(f[0], f[1], f[2], f[3], f[4], f[5]));
          }
        }
      }
    }

    // CPU
    if (total != null && idle != null) {
      if (_pTotal != null && total > _pTotal!) {
        final dTotal = total - _pTotal!;
        cpu = (1 - (idle - _pIdle!) / dTotal) * 100;
        steal = ((stl ?? 0) - (_pSteal ?? 0)) / dTotal * 100;
        cpu = cpu.clamp(0.0, 100.0).toDouble();
        cpuHist.add(cpu);
      }
    }

    // Memory
    memTotal = mem['MemTotal'] ?? memTotal;
    if (mem.containsKey('MemAvailable')) memUsed = memTotal - mem['MemAvailable']!;
    swapTotal = mem['SwapTotal'] ?? 0;
    swapUsed = swapTotal - (mem['SwapFree'] ?? swapTotal);
    if (memTotal > 0) memHist.add(memPerc);

    // Network
    if (dt > 0) {
      final rates = <String, (double, double)>{};
      double rx = 0, tx = 0, rxAll = 0, txAll = 0;
      net.forEach((name, v) {
        final p = _pNet[name];
        if (p == null) return;
        final r = ((v.$1 - p.$1) / dt).clamp(0, double.infinity).toDouble();
        final t = ((v.$2 - p.$2) / dt).clamp(0, double.infinity).toDouble();
        if (name != 'lo') {
          rxAll += r;
          txAll += t;
        }
        if (!_virtualIface(name)) {
          rates[name] = (r, t);
          rx += r;
          tx += t;
        }
      });
      if (rates.isEmpty) {
        rx = rxAll;
        tx = txAll;
      }
      ifaceRates = rates;
      rxRate = rx;
      txRate = tx;
      rxHist.add(rx);
      txHist.add(tx);
    }
    _pNet = net;

    // Load & uptime
    if (loadLines.isNotEmpty) {
      final l = loadLines[0].split(' ');
      if (l.length >= 3) load = l.take(3).map((e) => double.tryParse(e) ?? 0).toList();
      if (loadLines.length > 1) {
        final u = double.tryParse(loadLines[1].split(' ').first) ?? 0;
        uptime = Duration(seconds: u.round());
      }
    }

    // Processes
    if (procLines.isNotEmpty && total != null) {
      final elapsedPerCore =
          (_pTotal != null && total > _pTotal!) ? (total - _pTotal!) / cores : 0.0;
      final cur = <int, int>{};
      final list = <ProcInfo>[];
      for (final l in procLines) {
        final f = l.split('\t');
        if (f.length < 4) continue;
        final pid = int.tryParse(f[0]);
        final ticks = int.tryParse(f[2]);
        final rssPages = int.tryParse(f[3]) ?? 0;
        if (pid == null || ticks == null) continue;
        cur[pid] = ticks;
        final prev = _pProc[pid];
        final c = (prev != null && elapsedPerCore > 0)
            ? ((ticks - prev) / elapsedPerCore * 100).clamp(0, 100.0 * cores).toDouble()
            : 0.0;
        list.add(ProcInfo(pid, f[1], c, rssPages * _pageSize));
      }
      _pProc = cur;
      processes = list;
    }

    if (cont != null) {
      containers = cont;
      dockerSeen = true;
    }

    if (total != null) {
      _pTotal = total;
      _pIdle = idle;
      _pSteal = stl;
    }
    _pTime = now;
    hasData = true;
    notifyListeners();
  }

  /// Process list for the UI: sorted, optionally grouped by program name.
  List<ProcInfo> topProcesses({required bool byMemory, required bool grouped, int limit = 40}) {
    var list = processes.where((p) => p.rss > 0 || p.cpu >= 0.5).toList();
    if (grouped) {
      final m = <String, ProcInfo>{};
      for (final p in list) {
        final g = m[p.name];
        if (g == null) {
          m[p.name] = ProcInfo(p.pid, p.name, p.cpu, p.rss);
        } else {
          g.cpu += p.cpu;
          g.rss += p.rss;
          g.count++;
        }
      }
      list = m.values.toList();
    }
    list.sort((a, b) => byMemory ? b.rss.compareTo(a.rss) : b.cpu.compareTo(a.cpu));
    return list.take(limit).toList();
  }

  @override
  void dispose() {
    _stopLoop();
    super.dispose();
  }
}

/// Per-application network usage using `nethogs` (needs passwordless sudo,
/// which the default `ubuntu`/`opc` users on Oracle Cloud have).
class NetHogsService extends ChangeNotifier {
  SSHSession? _s;
  int _gen = 0;
  bool running = false;
  String? problem;
  List<NetApp> apps = [];
  final List<NetApp> _pending = [];

  Future<void> start(SSHClient client) async {
    stop();
    final gen = ++_gen;
    problem = null;
    running = true;
    notifyListeners();
    try {
      final s = await client.execute(
        'command -v nethogs >/dev/null 2>&1 || { echo "@@NOTFOUND"; exit 0; }; '
        'sudo -n nethogs -t -d 2 2>&1',
        pty: const SSHPtyConfig(width: 250, height: 50),
      );
      if (gen != _gen) {
        s.close();
        return;
      }
      _s = s;
      s.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((raw) {
        if (gen != _gen) return;
        final line = raw.replaceAll('\r', '').trim();
        if (line.isEmpty) return;
        if (line == '@@NOTFOUND') {
          problem = 'notfound';
          notifyListeners();
          return;
        }
        if (line.contains('password is required') || line.contains('a terminal is required')) {
          problem = 'sudo';
          notifyListeners();
          return;
        }
        if (line.startsWith('Refreshing')) {
          apps = [..._pending]..sort((a, b) =>
              (b.sentKBs + b.recvKBs).compareTo(a.sentKBs + a.recvKBs));
          _pending.clear();
          notifyListeners();
          return;
        }
        final f = line.split('\t');
        if (f.length == 3) {
          final id = f[0];
          final parts = id.split('/');
          int pid = 0;
          var name = id;
          if (parts.length >= 3) {
            pid = int.tryParse(parts[parts.length - 2]) ?? 0;
            name = parts.sublist(0, parts.length - 2).join('/');
          }
          final short = name.split('/').where((e) => e.isNotEmpty).lastOrNull ?? name;
          _pending.add(NetApp(short.isEmpty ? name : short, pid,
              double.tryParse(f[1]) ?? 0, double.tryParse(f[2]) ?? 0));
        }
      }, onDone: () {
        if (gen == _gen) {
          running = false;
          notifyListeners();
        }
      });
    } catch (e) {
      running = false;
      problem = 'error';
      notifyListeners();
    }
  }

  void stop() {
    _gen++;
    try {
      _s?.close();
    } catch (_) {}
    _s = null;
    running = false;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

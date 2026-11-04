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

class DiskInfo {
  final String device, mount;
  final int total, used;
  DiskInfo(this.device, this.mount, this.total, this.used);
  double get perc => total == 0 ? 0 : used / total * 100;
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

/// Docker state from the last sample.
enum DockerState { unknown, ok, notInstalled, noPermission }

/// Polls the server's CPU, memory, network, disks, processes and Docker
/// containers through ONE long-running shell loop on a separate SSH channel.
/// The loop only reads /proc and /sys, so it costs the server almost nothing.
/// Processes and containers are only collected while the panel is on screen.
class MonitorService extends ChangeNotifier {
  SSHClient? _client;
  SSHSession? _loop;
  int _gen = 0;
  bool _full = false;
  int _interval = 3;
  bool running = false;
  String? error;

  // system info (read once per connection)
  String hostname = '', os = '', kernel = '', arch = '';

  // latest values
  int cores = 1;
  double cpu = 0, cpuUser = 0, cpuSystem = 0, cpuIowait = 0, steal = 0;
  List<double> coreUsage = [];
  int memTotal = 0, memUsed = 0, memCache = 0, memFree = 0;
  int swapTotal = 0, swapUsed = 0;
  double rxRate = 0, txRate = 0;
  int rxTotal = 0, txTotal = 0;
  double diskRead = 0, diskWrite = 0;
  List<DiskInfo> disks = [];
  List<double> load = [0, 0, 0];
  Duration uptime = Duration.zero;
  Map<String, (double, double)> ifaceRates = {};
  List<ProcInfo> processes = [];
  bool processesSeen = false;
  List<ContainerInfo> containers = [];
  DockerState docker = DockerState.unknown;
  bool hasData = false;

  final cpuHist = History(), memHist = History(), rxHist = History(), txHist = History();
  final readHist = History(), writeHist = History();

  // previous samples
  Map<String, List<int>> _pCpu = {};
  double? _pTime;
  Map<String, (int, int)> _pNet = {};
  Map<String, (int, int)> _pIo = {};
  Map<int, int> _pProc = {};
  int? _pProcTotal;
  int _pageSize = 4096;

  double get memPerc => memTotal == 0 ? 0 : memUsed / memTotal * 100;
  double get swapPerc => swapTotal == 0 ? 0 : swapUsed / swapTotal * 100;
  DiskInfo? get rootDisk {
    for (final d in disks) {
      if (d.mount == '/') return d;
    }
    return disks.isEmpty ? null : disks.first;
  }

  void attach(SSHClient client, {required bool full, required int interval}) {
    final fresh = !identical(client, _client);
    _client = client;
    _full = full;
    _interval = interval;
    if (fresh) _readSysInfo(client);
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
    _pProcTotal = null;
  }

  Future<void> _readSysInfo(SSHClient c) async {
    try {
      final r = await c.run(
          'hostname; . /etc/os-release 2>/dev/null; echo "\${PRETTY_NAME:-Linux}"; uname -r; uname -m');
      final l = const LineSplitter().convert(utf8.decode(r, allowMalformed: true));
      if (l.length >= 4) {
        hostname = l[0].trim();
        os = l[1].trim();
        kernel = l[2].trim();
        arch = l[3].trim();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _restart() async {
    _stopLoop();
    final c = _client;
    if (c == null || c.isClosed) return;
    final gen = _gen;
    try {
      final s = await c.execute(buildScript(_full, _interval));
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
          try {
            parse(block);
          } catch (e) {
            debugPrint('monitor parse error: $e');
          }
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

  static const _awkProc =
      r'''awk '{l=$0;i=index(l,"(");j=0;for(k=length(l);k>i;k--)if(substr(l,k,1)==")"){j=k;break};if(j==0)next;nm=substr(l,i+1,j-i-1);n=split(substr(l,j+2),a," ");print $1"\t"nm"\t"(a[12]+a[13])"\t"a[22]}' /proc/[0-9]*/stat 2>/dev/null''';

  static const _fmt = r"'{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}'";

  static const _loopBody = r'''
PS=$(getconf PAGESIZE 2>/dev/null || echo 4096); N=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1); i=0
while :; do
echo "@@S $PS $N"; grep '^cpu' /proc/stat
echo "@@M"; grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SReclaimable|SwapTotal|SwapFree):' /proc/meminfo
echo "@@N"; tail -n +3 /proc/net/dev
echo "@@L"; cat /proc/loadavg /proc/uptime
echo "@@D"; df -P -k -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2
echo "@@I"; for d in /sys/block/*; do n=${d##*/}; case $n in loop*|ram*|zram*|sr*|dm-*|md*|nbd*) continue;; esac; read -r a b c e f g h r < "$d/stat" && echo "$n $c $h"; done
if [ "$FULL" = 1 ]; then
echo "@@P"; __AWK__
if [ $((i % 3)) -eq 0 ]; then
echo "@@C"
if command -v docker >/dev/null 2>&1; then
{ docker stats --no-stream --format __FMT__ 2>/dev/null || sudo -n docker stats --no-stream --format __FMT__ 2>/dev/null || echo "!noperm"; }
else echo "!nodocker"; fi
fi
fi
echo "@@E"
i=$((i+1)); sleep $IV
done
''';

  /// The shell loop sent to the server (public for tests).
  static String buildScript(bool full, int interval) =>
      'FULL=${full ? 1 : 0}; IV=$interval\n' +
      _loopBody.replaceAll('__AWK__', _awkProc).replaceAll('__FMT__', _fmt);

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

  static int _sum(List<int> v, int n) {
    var s = 0;
    for (var i = 0; i < n && i < v.length; i++) {
      s += v[i];
    }
    return s;
  }

  /// Parses one sample block (public for tests).
  void parse(List<String> lines) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final dt = _pTime == null ? 0.0 : now - _pTime!;
    var section = '';
    final cpuLines = <String, List<int>>{};
    final mem = <String, int>{};
    final net = <String, (int, int)>{};
    final io = <String, (int, int)>{};
    final procLines = <String>[];
    final diskList = <DiskInfo>[];
    final loadLines = <String>[];
    List<ContainerInfo>? cont;
    DockerState? dockerState;
    var sawProc = false, sawDisk = false;

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.startsWith('@@')) {
        section = line.length >= 3 ? line.substring(2, 3) : '';
        if (section == 'S') {
          final p = line.split(' ');
          if (p.length >= 3) {
            _pageSize = int.tryParse(p[1]) ?? 4096;
            cores = int.tryParse(p[2]) ?? 1;
          }
        } else if (section == 'C') {
          cont = [];
          dockerState = DockerState.ok;
        } else if (section == 'P') {
          sawProc = true;
        } else if (section == 'D') {
          sawDisk = true;
        }
        continue;
      }
      switch (section) {
        case 'S':
          {
            if (line.startsWith('cpu')) {
              final f = line.split(RegExp(r'\s+'));
              cpuLines[f[0]] = f.skip(1).map((e) => int.tryParse(e) ?? 0).toList();
            }
          }
        case 'M':
          {
            final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
            if (m != null) mem[m.group(1)!] = int.parse(m.group(2)!) * 1024;
          }
        case 'N':
          {
            final c = line.indexOf(':');
            if (c > 0) {
              final name = line.substring(0, c).trim();
              final f = line.substring(c + 1).trim().split(RegExp(r'\s+'));
              if (f.length >= 9) {
                net[name] = (int.tryParse(f[0]) ?? 0, int.tryParse(f[8]) ?? 0);
              }
            }
          }
        case 'L':
          loadLines.add(line);
        case 'D':
          {
            final f = line.split(RegExp(r'\s+'));
            if (f.length >= 6) {
              diskList.add(DiskInfo(f[0], f.sublist(5).join(' '),
                  (int.tryParse(f[1]) ?? 0) * 1024, (int.tryParse(f[2]) ?? 0) * 1024));
            }
          }
        case 'I':
          {
            final f = line.split(' ');
            if (f.length >= 3) {
              io[f[0]] = (int.tryParse(f[1]) ?? 0, int.tryParse(f[2]) ?? 0);
            }
          }
        case 'P':
          procLines.add(line);
        case 'C':
          {
            if (line == '!nodocker') {
              dockerState = DockerState.notInstalled;
            } else if (line == '!noperm') {
              dockerState = DockerState.noPermission;
            } else {
              final f = line.split('|');
              if (f.length >= 6) {
                cont!.add(ContainerInfo(f[0], f[1], f[2], f[3], f[4], f[5]));
              }
            }
          }
      }
    }

    // ---- CPU (fields: user nice system idle iowait irq softirq steal)
    final total = cpuLines['cpu'];
    int? totalJiffies;
    if (total != null && total.length >= 4) {
      totalJiffies = _sum(total, 8);
      final p = _pCpu['cpu'];
      if (p != null) {
        final d = totalJiffies - _sum(p, 8);
        if (d > 0) {
          double part(int i) => total.length > i ? (total[i] - p[i]) / d * 100 : 0.0;
          final idle = part(3) + part(4);
          cpu = (100 - idle).clamp(0.0, 100.0).toDouble();
          cpuUser = part(0) + part(1);
          cpuSystem = part(2) + part(5) + part(6);
          cpuIowait = part(4);
          steal = part(7);
          cpuHist.add(cpu);
        }
      }
      final cores0 = <double>[];
      for (var i = 0; i < 1024; i++) {
        final cur = cpuLines['cpu$i'];
        if (cur == null) break;
        final p = _pCpu['cpu$i'];
        if (p == null) {
          cores0.add(0);
          continue;
        }
        final d = _sum(cur, 8) - _sum(p, 8);
        final idle = (cur[3] - p[3]) + (cur.length > 4 ? cur[4] - p[4] : 0);
        cores0.add(d > 0 ? ((1 - idle / d) * 100).clamp(0.0, 100.0).toDouble() : 0.0);
      }
      coreUsage = cores0;
      _pCpu = cpuLines;
    }

    // ---- Memory
    if (mem.containsKey('MemTotal')) {
      memTotal = mem['MemTotal']!;
      final avail = mem['MemAvailable'] ?? mem['MemFree'] ?? 0;
      memUsed = memTotal - avail;
      memFree = mem['MemFree'] ?? 0;
      memCache = (mem['Buffers'] ?? 0) + (mem['Cached'] ?? 0) + (mem['SReclaimable'] ?? 0);
      swapTotal = mem['SwapTotal'] ?? 0;
      swapUsed = swapTotal - (mem['SwapFree'] ?? swapTotal);
      memHist.add(memPerc);
    }

    // ---- Network
    if (net.isNotEmpty) {
      final rates = <String, (double, double)>{};
      double rx = 0, tx = 0, rxAll = 0, txAll = 0;
      int rt = 0, tt = 0, rtAll = 0, ttAll = 0;
      net.forEach((name, v) {
        if (name != 'lo') {
          rtAll += v.$1;
          ttAll += v.$2;
        }
        if (!_virtualIface(name)) {
          rt += v.$1;
          tt += v.$2;
        }
        final p = _pNet[name];
        if (p == null || dt <= 0) return;
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
      final physical = net.keys.any((n) => !_virtualIface(n));
      rxTotal = physical ? rt : rtAll;
      txTotal = physical ? tt : ttAll;
      if (dt > 0) {
        ifaceRates = rates;
        rxRate = physical ? rx : rxAll;
        txRate = physical ? tx : txAll;
        rxHist.add(rxRate);
        txHist.add(txRate);
      }
      _pNet = net;
    }

    // ---- Disk I/O (sectors of 512 bytes)
    if (io.isNotEmpty) {
      if (dt > 0) {
        double r = 0, w = 0;
        io.forEach((n, v) {
          final p = _pIo[n];
          if (p == null) return;
          r += ((v.$1 - p.$1) * 512 / dt).clamp(0, double.infinity).toDouble();
          w += ((v.$2 - p.$2) * 512 / dt).clamp(0, double.infinity).toDouble();
        });
        diskRead = r;
        diskWrite = w;
        readHist.add(r);
        writeHist.add(w);
      }
      _pIo = io;
    }
    if (sawDisk) disks = diskList;

    // ---- Load & uptime
    if (loadLines.isNotEmpty) {
      final l = loadLines[0].split(' ');
      if (l.length >= 3) load = l.take(3).map((e) => double.tryParse(e) ?? 0).toList();
      if (loadLines.length > 1) {
        final u = double.tryParse(loadLines[1].split(' ').first) ?? 0;
        uptime = Duration(seconds: u.round());
      }
    }

    // ---- Processes
    if (sawProc && totalJiffies != null) {
      final elapsedPerCore = (_pProcTotal != null && totalJiffies > _pProcTotal!)
          ? (totalJiffies - _pProcTotal!) / cores
          : 0.0;
      final cur = <int, int>{};
      final list = <ProcInfo>[];
      for (final l in procLines) {
        final f = l.split('\t');
        if (f.length < 4) continue;
        final pid = int.tryParse(f[0].trim());
        final ticks = int.tryParse(f[2].trim());
        final rssPages = int.tryParse(f[3].trim()) ?? 0;
        if (pid == null || ticks == null) continue;
        cur[pid] = ticks;
        final prev = _pProc[pid];
        final c = (prev != null && elapsedPerCore > 0)
            ? ((ticks - prev) / elapsedPerCore * 100).clamp(0, 100.0 * cores).toDouble()
            : 0.0;
        list.add(ProcInfo(pid, f[1], c, rssPages * _pageSize));
      }
      _pProc = cur;
      _pProcTotal = totalJiffies;
      processes = list;
      processesSeen = true;
    }

    if (dockerState != null) {
      docker = dockerState;
      containers = cont ?? [];
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

// ======================================================================
// Server tools (nethogs): check / install / upgrade / uninstall

enum ToolState { unknown, checking, notInstalled, installed, updateAvailable, busy, unsupported }

class ServerTool extends ChangeNotifier {
  final String package;
  ServerTool(this.package);

  ToolState state = ToolState.unknown;
  String installed = '';
  String candidate = '';
  String manager = '';
  String? lastError;
  final List<String> log = [];
  bool needsSudoPassword = false;

  bool get isInstalled =>
      state == ToolState.installed || state == ToolState.updateAvailable;

  String _checkCmd() => r'''
P=__PKG__
if command -v dpkg-query >/dev/null 2>&1; then
  I=$(dpkg-query -W -f='${Status} ${Version}' $P 2>/dev/null | awk '/install ok installed/{print $4}')
  C=$(apt-cache policy $P 2>/dev/null | awk '/Candidate:/{print $2}')
  echo "apt|$I|$C"
elif command -v rpm >/dev/null 2>&1; then
  I=$(rpm -q --qf '%{VERSION}-%{RELEASE}' $P 2>/dev/null | grep -v 'not installed')
  C=$( (dnf -q repoquery --latest-limit 1 --qf '%{version}-%{release}' $P || yum -q list available $P 2>/dev/null | awk 'NR>1{print $2}') 2>/dev/null | tail -1)
  echo "dnf|$I|${C:-$I}"
else
  echo "none||"
fi
'''.replaceAll('__PKG__', package);

  Future<void> check(SSHClient c) async {
    state = ToolState.checking;
    lastError = null;
    notifyListeners();
    try {
      final out = utf8.decode(await c.run(_checkCmd()), allowMalformed: true).trim();
      final line = out.split('\n').lastWhere((l) => l.contains('|'), orElse: () => 'none||');
      final f = line.split('|');
      manager = f[0];
      installed = f.length > 1 ? f[1].trim() : '';
      candidate = f.length > 2 ? f[2].trim() : '';
      if (manager == 'none') {
        state = ToolState.unsupported;
      } else if (installed.isEmpty) {
        state = ToolState.notInstalled;
      } else if (candidate.isNotEmpty && candidate != '(none)' && candidate != installed) {
        state = ToolState.updateAvailable;
      } else {
        state = ToolState.installed;
      }
    } catch (e) {
      state = ToolState.unknown;
      lastError = '$e';
    }
    notifyListeners();
  }

  String _actionCmd(String action) {
    final apt = manager != 'dnf';
    final pm = apt
        ? 'sudo -n env DEBIAN_FRONTEND=noninteractive apt-get'
        : 'sudo -n \$(command -v dnf || command -v yum)';
    switch (action) {
      case 'install':
        return apt
            ? '$pm update -qq; $pm install -y $package'
            : '$pm install -y $package';
      case 'upgrade':
        return apt
            ? '$pm update -qq; $pm install -y --only-upgrade $package'
            : '$pm upgrade -y $package';
      default:
        return apt ? '$pm remove -y $package' : '$pm remove -y $package';
    }
  }

  /// Runs install / upgrade / uninstall. Returns true on success.
  Future<bool> run(SSHClient c, String action) async {
    state = ToolState.busy;
    log.clear();
    lastError = null;
    needsSudoPassword = false;
    notifyListeners();
    var ok = false;
    try {
      final s = await c.execute('${_actionCmd(action)} 2>&1; echo "@@RC=\$?"');
      await for (final line in s.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
        if (line.startsWith('@@RC=')) {
          ok = line.trim() == '@@RC=0';
          continue;
        }
        if (line.contains('a password is required') || line.contains('a terminal is required')) {
          needsSudoPassword = true;
        }
        log.add(line);
        if (log.length > 200) log.removeAt(0);
        notifyListeners();
      }
    } catch (e) {
      lastError = '$e';
    }
    if (!ok) {
      lastError ??= needsSudoPassword
          ? 'Your user needs passwordless sudo for this.'
          : (log.isNotEmpty ? log.last : 'Failed');
    }
    await check(c);
    return ok;
  }

  /// Command to run by hand in the terminal (when sudo needs a password).
  String manualCommand(String action) {
    final apt = manager != 'dnf';
    switch (action) {
      case 'install':
        return apt ? 'sudo apt update && sudo apt install -y $package' : 'sudo dnf install -y $package';
      case 'upgrade':
        return apt
            ? 'sudo apt update && sudo apt install -y --only-upgrade $package'
            : 'sudo dnf upgrade -y $package';
      default:
        return apt ? 'sudo apt remove -y $package' : 'sudo dnf remove -y $package';
    }
  }

  void reset() {
    state = ToolState.unknown;
    installed = '';
    candidate = '';
    log.clear();
    lastError = null;
    notifyListeners();
  }
}

/// Per-application network usage using `nethogs` (needs passwordless sudo,
/// which the default `ubuntu`/`opc` users on Oracle Cloud have).
class NetHogsService extends ChangeNotifier {
  SSHSession? _s;
  SSHClient? _client;
  int _gen = 0;
  bool running = false;
  bool wanted = false;
  String? problem; // 'sudo' or an error text
  List<NetApp> apps = [];
  bool gotFirstSample = false;
  final List<NetApp> _pending = [];
  final List<String> _tail = [];
  int _restarts = 0;
  Timer? _retry;

  Future<void> start(SSHClient client) async {
    _client = client;
    wanted = true;
    _restarts = 0;
    await _launch();
  }

  Future<void> _launch() async {
    _killSession();
    final client = _client;
    if (client == null || client.isClosed || !wanted) return;
    final gen = ++_gen;
    problem = null;
    running = true;
    _tail.clear();
    notifyListeners();
    try {
      final s = await client.execute(
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
          .listen((raw) => _onLine(gen, raw), onError: (_) {}, onDone: () => _onExit(gen));
    } catch (e) {
      if (gen != _gen) return;
      running = false;
      _scheduleRetry('$e');
    }
  }

  void _onLine(int gen, String raw) {
    if (gen != _gen) return;
    final line = raw.replaceAll('\r', '').trim();
    if (line.isEmpty) return;
    _tail.add(line);
    if (_tail.length > 5) _tail.removeAt(0);
    if (line.contains('password is required') || line.contains('a terminal is required')) {
      problem = 'sudo';
      notifyListeners();
      return;
    }
    if (line.startsWith('Refreshing')) {
      apps = [..._pending]
        ..sort((a, b) => (b.sentKBs + b.recvKBs).compareTo(a.sentKBs + a.recvKBs));
      _pending.clear();
      gotFirstSample = true;
      _restarts = 0;
      notifyListeners();
      return;
    }
    final f = line.split('\t');
    if (f.length == 3) {
      final id = f[0];
      final parts = id.split('/');
      var pid = 0;
      var name = id;
      if (parts.length >= 3) {
        pid = int.tryParse(parts[parts.length - 2]) ?? 0;
        name = parts.sublist(0, parts.length - 2).join('/');
      }
      final short = name.split('/').where((e) => e.isNotEmpty).lastOrNull ?? name;
      _pending.add(NetApp(short.isEmpty ? name : short, pid,
          double.tryParse(f[1]) ?? 0, double.tryParse(f[2]) ?? 0));
    }
  }

  void _onExit(int gen) {
    if (gen != _gen) return;
    running = false;
    _s = null;
    if (problem == 'sudo') {
      notifyListeners();
      return;
    }
    _scheduleRetry(_tail.isEmpty ? 'nethogs stopped' : _tail.last);
  }

  void _scheduleRetry(String why) {
    if (!wanted) return;
    _restarts++;
    if (_restarts > 5) {
      problem = why;
      notifyListeners();
      return;
    }
    notifyListeners();
    _retry?.cancel();
    _retry = Timer(Duration(seconds: 2 * _restarts), _launch);
  }

  void _killSession() {
    _gen++;
    _retry?.cancel();
    try {
      _s?.close();
    } catch (_) {}
    _s = null;
  }

  void stop() {
    wanted = false;
    _killSession();
    running = false;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

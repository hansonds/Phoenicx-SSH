import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models.dart';
import 'keepalive.dart';
import 'keys.dart';
import 'monitor.dart';
import 'store.dart';

enum TabStatus { connecting, connected, reconnecting, ended, failed }

/// One terminal tab = one SSH connection.
///
/// The connection is only ever closed by the user. If the network drops, the
/// server reboots or the phone switches between Wi-Fi and mobile data, the tab
/// reconnects by itself and keeps its scrollback.
class SshTab extends ChangeNotifier {
  final String uid = HostConfig.newId();
  HostConfig host;
  late final Terminal terminal;
  final controller = TerminalController();
  final monitor = MonitorService();
  final nethogs = NetHogsService();
  final nethogsTool = ServerTool('nethogs');

  SSHClient? client;
  SSHSession? _shell;
  TabStatus status = TabStatus.connecting;
  String? message;
  String? remoteTitle;
  int attempt = 0;
  int retryIn = 0;
  DateTime? connectedSince;
  bool monitorVisible = false;

  /// Wide screens: monitor fills the whole tab instead of a side panel.
  bool monitorExpanded = false;
  bool ctrlArmed = false, altArmed = false;

  bool _everConnected = false;
  bool _closedByUser = false;
  int _gen = 0;
  Timer? _retryTimer, _watchdog;
  bool _pinging = false;

  /// Set by the UI: asks the user to trust a new or changed host key.
  static Future<bool> Function(HostConfig host, String fingerprint, String? previous)?
      hostKeyPrompt;

  SshTab(this.host) {
    terminal = Terminal(
      maxLines: Store.I.settings.scrollback,
      platform: Platform.isAndroid
          ? TerminalTargetPlatform.android
          : TerminalTargetPlatform.windows,
    );
    terminal.onOutput = _onInput;
    terminal.onResize = (w, h, pw, ph) {
      try {
        _shell?.resizeTerminal(w, h, pw, ph);
      } catch (_) {}
    };
    terminal.onTitleChange = (t) {
      remoteTitle = t;
      notifyListeners();
    };
  }

  bool get isLive =>
      status == TabStatus.connected ||
      status == TabStatus.connecting ||
      status == TabStatus.reconnecting;

  void _set(TabStatus s, [String? msg]) {
    status = s;
    message = msg;
    notifyListeners();
    Sessions.I.statusChanged();
  }

  // ------------------------------------------------------------- connect

  Future<void> connect() async {
    _retryTimer?.cancel();
    _closedByUser = false;
    final gen = ++_gen;
    _teardown();
    _set(_everConnected ? TabStatus.reconnecting : TabStatus.connecting);
    if (!_everConnected && attempt == 0) {
      terminal.write('\x1b[38;5;208mConnecting to ${host.address} ...\x1b[0m\r\n');
    }
    try {
      final socket = await SSHSocket.connect(host.host.trim(), host.port,
          timeout: const Duration(seconds: 15));
      if (gen != _gen) {
        socket.destroy();
        return;
      }
      final ids = host.auth == AuthType.key
          ? loadKeyPairs(host.privateKey, host.passphrase)
          : null;
      final c = SSHClient(
        socket,
        username: host.username.trim(),
        identities: ids,
        onPasswordRequest:
            host.auth == AuthType.password ? () => host.password : null,
        onUserInfoRequest: host.auth == AuthType.password
            ? (req) => req.prompts.map((_) => host.password).toList()
            : null,
        onVerifyHostKey: _verifyHostKey,
        onUserauthBanner: (b) => terminal.write(b.replaceAll('\n', '\r\n')),
        keepAliveInterval: null, // our own watchdog below also detects dead links
      );
      client = c;
      await c.authenticated.timeout(const Duration(seconds: 30));
      if (gen != _gen) return;

      final pty = SSHPtyConfig(
        width: max(terminal.viewWidth, 1),
        height: max(terminal.viewHeight, 1),
      );
      final SSHSession s = host.useTmux
          ? await c.execute(
              'if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s phoenicx; '
              'else echo "tmux is not installed (sudo apt install tmux) - using a normal shell"; exec \${SHELL:-/bin/bash} -l; fi',
              pty: pty)
          : await c.shell(pty: pty);
      if (gen != _gen) {
        s.close();
        return;
      }
      _shell = s;
      final first = !_everConnected;
      _everConnected = true;
      attempt = 0;
      connectedSince = DateTime.now();
      _set(TabStatus.connected);
      if (Store.I.hosts.value.any((h) => h.id == host.id)) Store.I.touch(host.id);

      s.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write, onError: (_) {});
      s.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write, onError: (_) {});
      s.done.then((_) => _onShellDone(gen), onError: (_) => _onShellDone(gen));
      c.done.then((_) => _onLost(gen), onError: (_) => _onLost(gen));

      if (first && host.startupCommand.trim().isNotEmpty) {
        s.write(Uint8List.fromList(utf8.encode('${host.startupCommand.trim()}\n')));
      }
      _startWatchdog(gen);
      _attachMonitor();
    } catch (e) {
      if (gen != _gen) return;
      _teardown();
      _handleFailure(e);
    }
  }

  void _handleFailure(Object e) {
    String msg;
    var permanent = false;
    if (e is SSHAuthFailError || e is SSHAuthAbortError) {
      msg = host.auth == AuthType.key
          ? 'Login refused. Check the username (Oracle Ubuntu = ubuntu, Oracle Linux = opc) and that this key is in ~/.ssh/authorized_keys.'
          : 'Login refused. Check the username and password.';
      permanent = true;
    } else if (e is KeyFormatError) {
      msg = e.message;
      permanent = true;
    } else if (e is SSHHostkeyError) {
      msg = 'Host key was not trusted.';
      permanent = true;
    } else if (e is TimeoutException) {
      msg = 'Timed out reaching ${host.host}.';
    } else if (e is SocketException) {
      msg = 'Network error: ${e.osError?.message ?? e.message}';
    } else {
      msg = e.toString();
    }

    final retry = !permanent && _everConnected && Store.I.settings.autoReconnect;
    if (retry) {
      _scheduleRetry(msg);
    } else {
      terminal.write('\r\n\x1b[31m$msg\x1b[0m\r\n');
      _set(TabStatus.failed, msg);
    }
  }

  void _scheduleRetry(String reason) {
    const delays = [1, 2, 3, 5, 8, 10, 15, 20, 30];
    final wait = delays[min(attempt, delays.length - 1)];
    attempt++;
    retryIn = wait;
    _set(TabStatus.reconnecting, reason);
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      retryIn--;
      if (retryIn <= 0) {
        t.cancel();
        connect();
      } else {
        notifyListeners();
      }
    });
  }

  void _onShellDone(int gen) {
    Future.delayed(const Duration(milliseconds: 400), () {
      if (gen != _gen || _closedByUser) return;
      final c = client;
      if (c == null || c.isClosed) {
        _onLost(gen);
        return;
      }
      // The shell exited on its own (user typed `exit`, tmux detached...).
      _gen++;
      _teardown();
      terminal.write(
          '\r\n\x1b[38;5;208m[Session ended - press Enter or tap Reconnect]\x1b[0m\r\n');
      _set(TabStatus.ended);
    });
  }

  void _onLost(int gen) {
    if (gen != _gen || _closedByUser) return;
    _gen++;
    _teardown();
    if (Store.I.settings.autoReconnect) {
      terminal.write('\r\n\x1b[33m[Connection lost - reconnecting...]\x1b[0m\r\n');
      _scheduleRetry('Connection lost');
    } else {
      terminal.write('\r\n\x1b[33m[Connection lost - press Enter to reconnect]\x1b[0m\r\n');
      _set(TabStatus.ended, 'Connection lost');
    }
  }

  void _startWatchdog(int gen) {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) => checkAlive(gen));
  }

  /// Sends a keep-alive; if the server does not answer, the link is dead
  /// (common after Wi-Fi/mobile switches) and we reconnect.
  Future<void> checkAlive([int? gen]) async {
    final g = gen ?? _gen;
    final c = client;
    if (c == null || status != TabStatus.connected || _pinging) return;
    _pinging = true;
    try {
      await c.ping().timeout(const Duration(seconds: 12));
    } catch (_) {
      if (g == _gen) _onLost(g);
    } finally {
      _pinging = false;
    }
  }

  void _teardown() {
    _watchdog?.cancel();
    _watchdog = null;
    monitor.detach();
    nethogs.stop();
    nethogsTool.reset();
    final s = _shell, c = client;
    _shell = null;
    client = null;
    try {
      s?.close();
    } catch (_) {}
    try {
      c?.close();
    } catch (_) {}
  }

  Future<bool> _verifyHostKey(String type, Uint8List fp) async {
    final f = 'SHA256:${utf8.decode(fp, allowMalformed: true)}';
    final key = '${host.host.trim()}:${host.port}';
    final known = Store.I.settings.knownHosts[key];
    if (known == f) return true;
    final prompt = hostKeyPrompt;
    final ok = prompt == null ? true : await prompt(host, '$type  $f', known);
    if (ok) {
      Store.I.settings.knownHosts[key] = f;
      await Store.I.saveSettings();
    }
    return ok;
  }

  // ------------------------------------------------------------- input

  void _onInput(String data) {
    if (status == TabStatus.ended || status == TabStatus.failed) {
      if (data.contains('\r')) reconnectNow();
      return;
    }
    final s = _shell;
    if (status != TabStatus.connected || s == null) return;
    var out = data;
    if (ctrlArmed && data.length == 1) {
      final c = data.toLowerCase().codeUnitAt(0);
      if (c >= 97 && c <= 122) {
        out = String.fromCharCode(c - 96);
      } else if (c >= 64 && c <= 95) {
        out = String.fromCharCode(c - 64);
      } else if (c == 32) {
        out = '\x00';
      }
      ctrlArmed = false;
      notifyListeners();
    }
    if (altArmed) {
      out = '\x1b$out';
      altArmed = false;
      notifyListeners();
    }
    try {
      s.write(Uint8List.fromList(utf8.encode(out)));
    } catch (_) {}
  }

  void refresh() => notifyListeners();

  /// Type text into the remote shell (used by buttons like "install nethogs").
  void send(String text) => _onInput(text);

  void reconnectNow() {
    _retryTimer?.cancel();
    if (status == TabStatus.connected) return;
    attempt = 0;
    connect();
  }

  // ------------------------------------------------------------- monitor

  void _attachMonitor() {
    final c = client;
    if (c == null) return;
    final st = Store.I.settings;
    if (st.backgroundMonitor || monitorVisible) {
      monitor.attach(c, full: monitorVisible, interval: st.monitorSeconds);
    }
  }

  void setMonitorExpanded(bool v) {
    monitorExpanded = v;
    if (v) {
      setMonitorVisible(true);
    } else {
      notifyListeners();
    }
  }

  void setMonitorVisible(bool v) {
    if (monitorVisible == v) return;
    monitorVisible = v;
    if (!v) monitorExpanded = false;
    notifyListeners();
    final c = client;
    if (c == null || status != TabStatus.connected) return;
    if (!v && !Store.I.settings.backgroundMonitor) {
      monitor.detach();
      nethogs.stop();
    } else if (!monitor.running) {
      monitor.attach(c, full: v, interval: Store.I.settings.monitorSeconds);
    } else {
      monitor.configure(full: v);
    }
    if (!v) nethogs.stop();
  }

  void applySettings() {
    final c = client;
    if (c == null || status != TabStatus.connected) return;
    final st = Store.I.settings;
    if (!st.backgroundMonitor && !monitorVisible) {
      monitor.detach();
    } else if (!monitor.running) {
      monitor.attach(c, full: monitorVisible, interval: st.monitorSeconds);
    } else {
      monitor.configure(interval: st.monitorSeconds);
    }
  }

  /// Runs a one-off command on the server (for kill etc.). Returns output.
  Future<String> run(String cmd) async {
    final c = client;
    if (c == null) throw StateError('Not connected');
    final r = await c.runWithResult(cmd);
    final out = utf8.decode(r.output, allowMalformed: true).trim();
    if ((r.exitCode ?? 0) != 0) throw Exception(out.isEmpty ? 'exit ${r.exitCode}' : out);
    return out;
  }

  /// Closed by the user: the only way a session ends for good.
  void close() {
    _closedByUser = true;
    _gen++;
    _retryTimer?.cancel();
    _teardown();
    status = TabStatus.ended;
  }

  @override
  void dispose() {
    close();
    monitor.dispose();
    nethogs.dispose();
    nethogsTool.dispose();
    super.dispose();
  }
}

/// All open tabs.
class Sessions extends ChangeNotifier {
  Sessions._();
  static final Sessions I = Sessions._();

  final List<SshTab> tabs = [];

  /// -1 = the host list.
  int selected = -1;

  SshTab open(HostConfig host) {
    final t = SshTab(host.copy());
    tabs.add(t);
    selected = tabs.length - 1;
    notifyListeners();
    t.connect();
    _sync();
    return t;
  }

  void select(int i) {
    selected = i;
    notifyListeners();
  }

  void closeTab(SshTab t) {
    final i = tabs.indexOf(t);
    if (i < 0) return;
    tabs.removeAt(i);
    t.dispose();
    if (tabs.isEmpty) {
      selected = -1;
    } else if (selected > i) {
      selected--;
    } else if (selected >= tabs.length) {
      selected = tabs.length - 1;
    }
    notifyListeners();
    _sync();
  }

  void statusChanged() => _sync();

  int get liveCount => tabs.where((t) => t.isLive).length;

  void _sync() => SessionKeeper.update(liveCount);

  /// Called when the app comes back to the foreground.
  void checkAll() {
    for (final t in tabs) {
      t.checkAlive();
    }
  }

  void closeAll() {
    for (final t in [...tabs]) {
      closeTab(t);
    }
  }
}

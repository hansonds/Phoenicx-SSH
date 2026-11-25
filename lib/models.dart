import 'dart:io';
import 'dart:math';

enum AuthType { password, key }

/// One saved server.
class HostConfig {
  String id;
  String name;
  String host;
  int port;
  String username;
  AuthType auth;
  String password;

  /// Full text of the private key (OpenSSH, PEM, PKCS#8 or PuTTY .ppk).
  String privateKey;
  String keyName;
  String passphrase;
  int color;

  /// Wrap the shell in tmux so the remote session survives network drops.
  bool useTmux;
  String startupCommand;
  int lastUsed;

  HostConfig({
    String? id,
    this.name = '',
    this.host = '',
    this.port = 22,
    this.username = 'ubuntu',
    this.auth = AuthType.key,
    this.password = '',
    this.privateKey = '',
    this.keyName = '',
    this.passphrase = '',
    this.color = 0,
    this.useTmux = false,
    this.startupCommand = '',
    this.lastUsed = 0,
  }) : id = id ?? newId();

  String get title => name.trim().isEmpty ? host : name.trim();
  String get address => port == 22 ? '$username@$host' : '$username@$host:$port';

  static String newId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
  }

  HostConfig copy({bool newIdentity = false}) =>
      HostConfig.fromJson(toJson())..id = newIdentity ? newId() : id;

  Map<String, dynamic> toJson({bool secrets = true}) => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'auth': auth.name,
        if (secrets) 'password': password,
        if (secrets) 'privateKey': privateKey,
        'keyName': keyName,
        if (secrets) 'passphrase': passphrase,
        'color': color,
        'useTmux': useTmux,
        'startupCommand': startupCommand,
        'lastUsed': lastUsed,
      };

  factory HostConfig.fromJson(Map<String, dynamic> j) => HostConfig(
        id: (j['id'] as String?) ?? newId(),
        name: (j['name'] as String?) ?? '',
        host: (j['host'] as String?) ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        username: (j['username'] as String?) ?? 'ubuntu',
        auth: j['auth'] == 'password' ? AuthType.password : AuthType.key,
        password: (j['password'] as String?) ?? '',
        privateKey: (j['privateKey'] as String?) ?? '',
        keyName: (j['keyName'] as String?) ?? '',
        passphrase: (j['passphrase'] as String?) ?? '',
        color: (j['color'] as num?)?.toInt() ?? 0,
        useTmux: (j['useTmux'] as bool?) ?? false,
        startupCommand: (j['startupCommand'] as String?) ?? '',
        lastUsed: (j['lastUsed'] as num?)?.toInt() ?? 0,
      );
}

/// A saved command for the Commands panel.
class Snippet {
  String name;
  String command;

  /// Press Enter after pasting.
  bool run;
  Snippet(this.name, this.command, {this.run = false});

  Map<String, dynamic> toJson() => {'name': name, 'command': command, 'run': run};
  factory Snippet.fromJson(Map<String, dynamic> j) => Snippet(
        (j['name'] as String?) ?? '',
        (j['command'] as String?) ?? '',
        run: (j['run'] as bool?) ?? false,
      );

  static List<Snippet> defaults() => [
        Snippet('Disk space', 'df -h'),
        Snippet('Memory', 'free -h'),
        Snippet('Live processes', 'htop || top'),
        Snippet('Uptime & load', 'uptime'),
        Snippet('System info', 'uname -a && cat /etc/os-release'),
        Snippet('Folder sizes here', 'du -sh * 2>/dev/null | sort -h'),
        Snippet('List files', 'ls -lah'),
        Snippet('Update packages', 'sudo apt update && sudo apt upgrade -y'),
        Snippet('Clean old packages', 'sudo apt autoremove -y && sudo apt clean'),
        Snippet('Docker: containers', 'docker ps -a'),
        Snippet('Docker: usage', 'docker stats --no-stream'),
        Snippet('Docker: start compose', 'docker compose up -d'),
        Snippet('Docker: logs', 'docker logs -f --tail 100 '),
        Snippet('Docker: clean up', 'docker system prune -f'),
        Snippet('Failed services', 'systemctl --failed'),
        Snippet('Restart a service', 'sudo systemctl restart '),
        Snippet('Service status', 'systemctl status '),
        Snippet('Recent system log', 'journalctl -n 50 --no-pager'),
        Snippet('Open ports', 'sudo ss -tulpn'),
        Snippet('IP addresses', 'ip -br a'),
        Snippet('Public IP', 'curl -s ifconfig.me; echo'),
        Snippet('Ping test', 'ping -c 4 8.8.8.8'),
        Snippet('Reboot server', 'sudo reboot'),
      ];
}

class AppSettings {
  double fontSize;

  /// Phones get their own, smaller default so more fits on screen.
  double fontSizeMobile;
  int scrollback;
  int monitorSeconds;
  bool backgroundMonitor;
  bool autoReconnect;
  bool keepCpuAwake;
  bool rightClickPaste;
  bool ctrlVPaste;

  /// Android: times the app was opened, and whether Google's rating popup
  /// has been requested yet (asked once, after a few launches).
  int launchCount;
  bool reviewAsked;

  /// host:port -> "SHA256:..." fingerprint accepted by the user.
  Map<String, String> knownHosts;

  /// Saved commands (null until the user edits the list = defaults).
  List<Snippet>? _snippets;
  List<Snippet> get snippets => _snippets ??= Snippet.defaults();
  set snippets(List<Snippet> v) => _snippets = v;

  AppSettings({
    this.fontSize = 14,
    this.fontSizeMobile = 10.5,
    this.scrollback = 5000,
    this.monitorSeconds = 3,
    this.backgroundMonitor = true,
    this.autoReconnect = true,
    this.keepCpuAwake = true,
    this.rightClickPaste = true,
    this.ctrlVPaste = true,
    this.launchCount = 0,
    this.reviewAsked = false,
    Map<String, String>? knownHosts,
    List<Snippet>? snippets,
  })  : knownHosts = knownHosts ?? {},
        _snippets = snippets;

  double get terminalFontSize => Platform.isAndroid ? fontSizeMobile : fontSize;
  set terminalFontSize(double v) {
    if (Platform.isAndroid) {
      fontSizeMobile = v;
    } else {
      fontSize = v;
    }
  }

  Map<String, dynamic> toJson() => {
        'fontSize': fontSize,
        'fontSizeMobile': fontSizeMobile,
        'scrollback': scrollback,
        'monitorSeconds': monitorSeconds,
        'backgroundMonitor': backgroundMonitor,
        'autoReconnect': autoReconnect,
        'keepCpuAwake': keepCpuAwake,
        'rightClickPaste': rightClickPaste,
        'ctrlVPaste': ctrlVPaste,
        'launchCount': launchCount,
        'reviewAsked': reviewAsked,
        'knownHosts': knownHosts,
        'snippets': snippets.map((e) => e.toJson()).toList(),
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        fontSize: (j['fontSize'] as num?)?.toDouble() ?? 14,
        fontSizeMobile: (j['fontSizeMobile'] as num?)?.toDouble() ?? 10.5,
        scrollback: (j['scrollback'] as num?)?.toInt() ?? 5000,
        monitorSeconds: (j['monitorSeconds'] as num?)?.toInt() ?? 3,
        backgroundMonitor: (j['backgroundMonitor'] as bool?) ?? true,
        autoReconnect: (j['autoReconnect'] as bool?) ?? true,
        keepCpuAwake: (j['keepCpuAwake'] as bool?) ?? true,
        rightClickPaste: (j['rightClickPaste'] as bool?) ?? true,
        ctrlVPaste: (j['ctrlVPaste'] as bool?) ?? true,
        launchCount: (j['launchCount'] as num?)?.toInt() ?? 0,
        reviewAsked: (j['reviewAsked'] as bool?) ?? false,
        knownHosts: ((j['knownHosts'] as Map?) ?? {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        snippets: (j['snippets'] as List?)
            ?.whereType<Map>()
            .map((e) => Snippet.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

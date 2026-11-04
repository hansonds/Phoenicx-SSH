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

class AppSettings {
  double fontSize;
  int scrollback;
  int monitorSeconds;
  bool backgroundMonitor;
  bool autoReconnect;
  bool keepCpuAwake;
  bool rightClickPaste;

  /// host:port -> "SHA256:..." fingerprint accepted by the user.
  Map<String, String> knownHosts;

  AppSettings({
    this.fontSize = 14,
    this.scrollback = 5000,
    this.monitorSeconds = 3,
    this.backgroundMonitor = true,
    this.autoReconnect = true,
    this.keepCpuAwake = true,
    this.rightClickPaste = true,
    Map<String, String>? knownHosts,
  }) : knownHosts = knownHosts ?? {};

  Map<String, dynamic> toJson() => {
        'fontSize': fontSize,
        'scrollback': scrollback,
        'monitorSeconds': monitorSeconds,
        'backgroundMonitor': backgroundMonitor,
        'autoReconnect': autoReconnect,
        'keepCpuAwake': keepCpuAwake,
        'rightClickPaste': rightClickPaste,
        'knownHosts': knownHosts,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        fontSize: (j['fontSize'] as num?)?.toDouble() ?? 14,
        scrollback: (j['scrollback'] as num?)?.toInt() ?? 5000,
        monitorSeconds: (j['monitorSeconds'] as num?)?.toInt() ?? 3,
        backgroundMonitor: (j['backgroundMonitor'] as bool?) ?? true,
        autoReconnect: (j['autoReconnect'] as bool?) ?? true,
        keepCpuAwake: (j['keepCpuAwake'] as bool?) ?? true,
        rightClickPaste: (j['rightClickPaste'] as bool?) ?? true,
        knownHosts: ((j['knownHosts'] as Map?) ?? {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
      );
}

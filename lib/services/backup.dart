import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models.dart';
import 'crypto.dart';

const _iterations = 60000;

class WrongPassword implements Exception {}

/// Builds the backup file. With a password, everything (including keys and
/// passwords) is encrypted with AES-256-GCM using a PBKDF2-SHA256 key.
Future<Uint8List> buildBackup(List<HostConfig> hosts,
    {String? password, bool includeSecrets = true}) async {
  final list = hosts.map((h) => h.toJson(secrets: includeSecrets)).toList();
  final Map<String, dynamic> out;
  if (password != null && password.isNotEmpty) {
    final plain = utf8.encode(jsonEncode(list));
    final enc = await Isolate.run(() {
      final salt = randomBytes(16);
      final key = pbkdf2(password, salt, _iterations);
      return [salt, aesGcmEncrypt(key, Uint8List.fromList(plain))];
    });
    out = {
      'app': 'Phoenicx SSH',
      'format': 1,
      'encrypted': true,
      'kdf': 'pbkdf2-sha256',
      'iterations': _iterations,
      'salt': base64Encode(enc[0]),
      'data': base64Encode(enc[1]),
    };
  } else {
    out = {
      'app': 'Phoenicx SSH',
      'format': 1,
      'encrypted': false,
      'hosts': list,
    };
  }
  return Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(out)));
}

bool backupIsEncrypted(Uint8List bytes) {
  try {
    final j = jsonDecode(utf8.decode(bytes));
    return j is Map && j['encrypted'] == true;
  } catch (_) {
    return false;
  }
}

/// Reads a backup made by [buildBackup] (or a plain JSON list of hosts).
Future<List<HostConfig>> readBackup(Uint8List bytes, {String? password}) async {
  dynamic j;
  try {
    j = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw const FormatException('This is not a Phoenicx SSH backup file.');
  }
  List list;
  if (j is List) {
    list = j;
  } else if (j is Map && j['encrypted'] == true) {
    if (password == null || password.isEmpty) throw WrongPassword();
    final salt = base64Decode(j['salt'] as String);
    final data = base64Decode(j['data'] as String);
    final iter = (j['iterations'] as num?)?.toInt() ?? _iterations;
    final plain = await Isolate.run(() {
      try {
        return aesGcmDecrypt(pbkdf2(password, salt, iter), data);
      } catch (_) {
        return null;
      }
    });
    if (plain == null) throw WrongPassword();
    list = jsonDecode(utf8.decode(plain)) as List;
  } else if (j is Map && j['hosts'] is List) {
    list = j['hosts'] as List;
  } else {
    throw const FormatException('This is not a Phoenicx SSH backup file.');
  }
  return list
      .whereType<Map>()
      .map((e) => HostConfig.fromJson(Map<String, dynamic>.from(e)))
      .where((h) => h.host.isNotEmpty)
      .toList();
}

/// Windows: reads the sessions saved in PuTTY (registry) including their
/// .ppk key files, so existing PuTTY setups move over in one click.
Future<List<HostConfig>> importPuttySessions() async {
  if (!Platform.isWindows) return [];
  final r = await Process.run(
      'reg', ['query', r'HKCU\Software\SimonTatham\PuTTY\Sessions', '/s']);
  if (r.exitCode != 0) return [];
  final out = <HostConfig>[];
  String? name;
  Map<String, String> vals = {};

  Future<void> flush() async {
    if (name == null) return;
    final proto = vals['Protocol'] ?? 'ssh';
    var hostName = (vals['HostName'] ?? '').trim();
    if (proto == 'ssh' && hostName.isNotEmpty) {
      var user = (vals['UserName'] ?? '').trim();
      if (hostName.contains('@')) {
        final i = hostName.lastIndexOf('@');
        if (user.isEmpty) user = hostName.substring(0, i);
        hostName = hostName.substring(i + 1);
      }
      final portHex = vals['PortNumber'] ?? '0x16';
      final port = int.tryParse(portHex.replaceFirst('0x', ''), radix: 16) ?? 22;
      final keyPath = (vals['PublicKeyFile'] ?? '').trim();
      final h = HostConfig(
        name: Uri.decodeComponent(name!),
        host: hostName,
        port: port,
        username: user.isEmpty ? 'ubuntu' : user,
        auth: keyPath.isEmpty ? AuthType.password : AuthType.key,
      );
      if (keyPath.isNotEmpty) {
        try {
          h.privateKey = await File(keyPath).readAsString();
          h.keyName = keyPath.split(RegExp(r'[\\/]')).last;
        } catch (_) {
          h.keyName = '(missing) $keyPath';
        }
      }
      out.add(h);
    }
    vals = {};
  }

  final valRe = RegExp(r'^\s+(\S+)\s+(REG_\w+)\s*(.*)$');
  for (final line in const LineSplitter().convert(r.stdout.toString())) {
    if (line.startsWith('HKEY_CURRENT_USER')) {
      await flush();
      final i = line.lastIndexOf(r'\');
      final n = line.substring(i + 1);
      name = n == 'Sessions' ? null : n;
      continue;
    }
    final m = valRe.firstMatch(line);
    if (m != null) vals[m.group(1)!] = m.group(3)!.trim();
  }
  await flush();
  return out;
}

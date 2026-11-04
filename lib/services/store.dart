import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'crypto.dart';

/// Saved hosts (encrypted on disk) and app settings.
///
/// Hosts, passwords and keys live in `hosts.bin`, encrypted with AES-256-GCM.
/// The 32-byte key for that file is kept in the OS secure store
/// (Android Keystore / Windows DPAPI via flutter_secure_storage).
class Store {
  Store._();
  static final Store I = Store._();

  final hosts = ValueNotifier<List<HostConfig>>([]);
  late AppSettings settings;
  final settingsVersion = ValueNotifier<int>(0);

  late Directory _dir;
  Uint8List? _key;

  File get _hostsFile => File('${_dir.path}${Platform.pathSeparator}hosts.bin');
  File get _settingsFile =>
      File('${_dir.path}${Platform.pathSeparator}settings.json');
  File get _fallbackKeyFile =>
      File('${_dir.path}${Platform.pathSeparator}.key');

  Future<void> init() async {
    _dir = await getApplicationSupportDirectory();
    await _dir.create(recursive: true);
    try {
      settings = AppSettings.fromJson(
          jsonDecode(await _settingsFile.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      settings = AppSettings();
    }
    await _loadKey();
    await _loadHosts();
  }

  Future<void> _loadKey() async {
    const storage = FlutterSecureStorage();
    try {
      final v = await storage.read(key: 'phoenicx_master_key');
      if (v != null) {
        _key = base64Decode(v);
        return;
      }
    } catch (_) {}
    // Secure storage unavailable or empty: older install may have a fallback key.
    if (await _fallbackKeyFile.exists()) {
      _key = base64Decode(await _fallbackKeyFile.readAsString());
      return;
    }
    final k = randomBytes(32);
    try {
      await storage.write(key: 'phoenicx_master_key', value: base64Encode(k));
      final check = await storage.read(key: 'phoenicx_master_key');
      if (check == null) throw Exception('not stored');
    } catch (_) {
      await _fallbackKeyFile.writeAsString(base64Encode(k));
    }
    _key = k;
  }

  Future<void> _loadHosts() async {
    try {
      if (!await _hostsFile.exists()) return;
      final plain = aesGcmDecrypt(_key!, await _hostsFile.readAsBytes());
      final list = jsonDecode(utf8.decode(plain)) as List;
      hosts.value = list
          .map((e) => HostConfig.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      debugPrint('Could not read hosts: $e');
    }
  }

  Future<void> saveHosts() async {
    final data = utf8.encode(jsonEncode(hosts.value.map((h) => h.toJson()).toList()));
    final enc = aesGcmEncrypt(_key!, Uint8List.fromList(data));
    final tmp = File('${_hostsFile.path}.tmp');
    await tmp.writeAsBytes(enc, flush: true);
    await tmp.rename(_hostsFile.path);
  }

  Future<void> upsert(HostConfig h) async {
    final list = [...hosts.value];
    final i = list.indexWhere((x) => x.id == h.id);
    if (i >= 0) {
      list[i] = h;
    } else {
      list.add(h);
    }
    hosts.value = list;
    await saveHosts();
  }

  Future<void> remove(String id) async {
    hosts.value = hosts.value.where((h) => h.id != id).toList();
    await saveHosts();
  }

  Future<void> touch(String id) async {
    for (final h in hosts.value) {
      if (h.id == id) h.lastUsed = DateTime.now().millisecondsSinceEpoch;
    }
    hosts.value = [...hosts.value];
    await saveHosts();
  }

  Future<void> saveSettings() async {
    await _settingsFile.writeAsString(jsonEncode(settings.toJson()));
    settingsVersion.value++;
  }
}

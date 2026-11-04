import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// AES-256-GCM. Output = 12-byte nonce + ciphertext + 16-byte tag.
Uint8List aesGcmEncrypt(Uint8List key, Uint8List plain) {
  final iv = randomBytes(12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  final out = cipher.process(plain);
  return Uint8List.fromList([...iv, ...out]);
}

/// Throws if the key is wrong or the data was changed.
Uint8List aesGcmDecrypt(Uint8List key, Uint8List data) {
  if (data.length < 28) throw const FormatException('Data too short');
  final iv = data.sublist(0, 12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  return cipher.process(data.sublist(12));
}

Uint8List pbkdf2(String password, Uint8List salt, int iterations) {
  final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  return d.process(Uint8List.fromList(utf8.encode(password)));
}

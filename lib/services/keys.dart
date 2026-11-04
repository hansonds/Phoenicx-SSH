import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed;
import 'package:pointycastle/export.dart' as pc;

/// Loads a private key in any of the formats people usually have:
///  - OpenSSH (`BEGIN OPENSSH PRIVATE KEY`)
///  - PKCS#1 RSA / SEC1 EC (`BEGIN RSA PRIVATE KEY`, `BEGIN EC PRIVATE KEY`)
///  - PKCS#8 (`BEGIN PRIVATE KEY`) - the `.key` file Oracle Cloud downloads
///  - PuTTY `.ppk` (v2 and v3, without a passphrase)
List<SSHKeyPair> loadKeyPairs(String text, [String? passphrase]) {
  final t = text.trim();
  final pass = (passphrase == null || passphrase.isEmpty) ? null : passphrase;
  if (t.isEmpty) throw const KeyFormatError('No private key has been added.');
  if (t.startsWith('PuTTY-User-Key-File-')) return [_parsePpk(t)];
  if (t.startsWith('ssh-') || t.startsWith('ecdsa-')) {
    throw const KeyFormatError(
        'This is a public key. Choose the private key file instead.');
  }
  if (t.contains('BEGIN ENCRYPTED PRIVATE KEY')) {
    throw const KeyFormatError(
        'Encrypted PKCS#8 keys are not supported. Convert it with: '
        'ssh-keygen -p -f yourkey  (or PuTTYgen > Export OpenSSH key).');
  }
  if (t.contains('BEGIN PRIVATE KEY')) return [_parsePkcs8(_pemBody(t))];
  try {
    return SSHKeyPair.fromPem(t, pass);
  } on UnsupportedError catch (e) {
    throw KeyFormatError(e.message ?? 'Unsupported key format.');
  } catch (e) {
    final s = e.toString().toLowerCase();
    if (s.contains('passphrase') || s.contains('decrypt') || s.contains('encrypted')) {
      throw const KeyFormatError('Wrong or missing key passphrase.');
    }
    throw KeyFormatError('Key could not be read: $e');
  }
}

/// Short description shown in the editor after loading a key.
String describeKey(String text) {
  try {
    final k = loadKeyPairs(text);
    return k.first.name;
  } on KeyFormatError catch (e) {
    if (text.contains('ENCRYPTED') || text.contains('Encryption: aes')) {
      return 'encrypted key (needs passphrase)';
    }
    return e.message;
  } catch (_) {
    if (text.contains('ENCRYPTED') || text.contains('bcrypt')) {
      return 'encrypted key (needs passphrase)';
    }
    return 'unrecognised key';
  }
}

class KeyFormatError implements Exception {
  final String message;
  const KeyFormatError(this.message);
  @override
  String toString() => message;
}

Uint8List _pemBody(String pem) {
  final body = pem
      .split(RegExp(r'\r?\n'))
      .where((l) => l.isNotEmpty && !l.startsWith('-----') && !l.contains(':'))
      .join();
  return base64Decode(body.replaceAll(RegExp(r'\s'), ''));
}

BigInt _big(Uint8List b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

// ---------------------------------------------------------------- DER / PKCS#8

class _Der {
  final Uint8List b;
  int p = 0;
  _Der(this.b);
  bool get more => p < b.length;

  (int, Uint8List) next() {
    final tag = b[p++];
    var len = b[p++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | b[p++];
      }
    }
    final v = Uint8List.sublistView(b, p, p + len);
    p += len;
    return (tag, v);
  }
}

const _oidRsa = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01];
const _oidEd25519 = [0x2B, 0x65, 0x70];
const _oidEc = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];
const _oidP256 = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07];
const _oidP384 = [0x2B, 0x81, 0x04, 0x00, 0x22];
const _oidP521 = [0x2B, 0x81, 0x04, 0x00, 0x23];

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

SSHKeyPair _parsePkcs8(Uint8List der) {
  try {
    final outer = _Der(_Der(der).next().$2);
    outer.next(); // version
    final alg = _Der(outer.next().$2);
    final oid = alg.next().$2;
    Uint8List? param;
    if (alg.more) {
      final pr = alg.next();
      if (pr.$1 == 0x06) param = pr.$2;
    }
    final priv = outer.next().$2;

    if (_eq(oid, _oidRsa)) {
      final s = _Der(_Der(priv).next().$2);
      s.next(); // version
      final n = _big(s.next().$2);
      final e = _big(s.next().$2);
      final d = _big(s.next().$2);
      final p = _big(s.next().$2);
      final q = _big(s.next().$2);
      s.next(); // dp
      s.next(); // dq
      final iqmp = _big(s.next().$2);
      return OpenSSHRsaKeyPair(n, e, d, iqmp, p, q, '');
    }
    if (_eq(oid, _oidEd25519)) {
      final seed = _Der(priv).next().$2;
      return _ed25519FromSeed(Uint8List.fromList(seed));
    }
    if (_eq(oid, _oidEc) && param != null) {
      final curve = _eq(param, _oidP256)
          ? 'nistp256'
          : _eq(param, _oidP384)
              ? 'nistp384'
              : _eq(param, _oidP521)
                  ? 'nistp521'
                  : throw const KeyFormatError('Unsupported EC curve.');
      final s = _Der(_Der(priv).next().$2);
      s.next(); // version
      final d = _big(s.next().$2);
      Uint8List? pub;
      while (s.more) {
        final f = s.next();
        if (f.$1 == 0xA1) {
          final bits = _Der(f.$2).next().$2;
          pub = Uint8List.fromList(bits.sublist(1));
        }
      }
      pub ??= _ecPublic(curve, d);
      return OpenSSHEcdsaKeyPair(curve, pub, d, '');
    }
    throw const KeyFormatError('Unsupported PKCS#8 key type.');
  } on KeyFormatError {
    rethrow;
  } catch (_) {
    throw const KeyFormatError('The PKCS#8 key file looks damaged.');
  }
}

Uint8List _ecPublic(String curve, BigInt d) {
  final pc.ECDomainParameters params = switch (curve) {
    'nistp256' => pc.ECCurve_secp256r1(),
    'nistp384' => pc.ECCurve_secp384r1(),
    _ => pc.ECCurve_secp521r1(),
  };
  final q = params.G * d;
  return q!.getEncoded(false);
}

SSHKeyPair _ed25519FromSeed(Uint8List seed) {
  final sk = ed.SigningKey.fromSeed(seed);
  final full = Uint8List.fromList(sk.asTypedList); // seed + public (64 bytes)
  final pub = Uint8List.fromList(sk.verifyKey.asTypedList);
  return OpenSSHEd25519KeyPair(pub, full, '');
}

// ---------------------------------------------------------------- PuTTY .ppk

class _Wire {
  final Uint8List b;
  int p = 0;
  _Wire(this.b);
  int _u32() {
    final v = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    p += 4;
    return v;
  }

  Uint8List str() {
    final n = _u32();
    final v = Uint8List.sublistView(b, p, p + n);
    p += n;
    return v;
  }

  BigInt mpint() => _big(str());
}

SSHKeyPair _parsePpk(String text) {
  final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trimRight()).toList();
  String? type, enc, comment;
  final pub = StringBuffer(), priv = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final c = l.indexOf(':');
    if (c < 0) continue;
    final k = l.substring(0, c), v = l.substring(c + 1).trim();
    if (k.startsWith('PuTTY-User-Key-File-')) type = v;
    if (k == 'Encryption') enc = v;
    if (k == 'Comment') comment = v;
    if (k == 'Public-Lines' || k == 'Private-Lines') {
      final n = int.parse(v);
      final buf = k == 'Public-Lines' ? pub : priv;
      for (var j = 1; j <= n && i + j < lines.length; j++) {
        buf.write(lines[i + j].trim());
      }
      i += n;
    }
  }
  if (enc != null && enc != 'none') {
    throw const KeyFormatError(
        'This .ppk key has a passphrase. Open it in PuTTYgen, clear the '
        'passphrase (or use Conversions > Export OpenSSH key) and load it again.');
  }
  final pw = _Wire(base64Decode(pub.toString()));
  final sw = _Wire(base64Decode(priv.toString()));
  final cm = comment ?? '';
  try {
    switch (type) {
      case 'ssh-rsa':
        pw.str();
        final e = pw.mpint();
        final n = pw.mpint();
        final d = sw.mpint();
        final p = sw.mpint();
        final q = sw.mpint();
        final iqmp = sw.mpint();
        return OpenSSHRsaKeyPair(n, e, d, iqmp, p, q, cm);
      case 'ssh-ed25519':
        pw.str();
        final seed = sw.str();
        return _ed25519FromSeed(Uint8List.fromList(seed));
      case 'ecdsa-sha2-nistp256':
      case 'ecdsa-sha2-nistp384':
      case 'ecdsa-sha2-nistp521':
        pw.str();
        final curve = utf8.decode(pw.str());
        final q = Uint8List.fromList(pw.str());
        final d = sw.mpint();
        return OpenSSHEcdsaKeyPair(curve, q, d, cm);
    }
  } catch (_) {
    throw const KeyFormatError('The .ppk key file looks damaged.');
  }
  throw KeyFormatError('Unsupported .ppk key type: $type');
}

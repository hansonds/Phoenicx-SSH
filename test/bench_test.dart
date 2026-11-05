// Speed benchmark (run by CI with an artificial network delay). Prints a
// table; picks nothing by itself.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phoenicx_ssh/services/fast_socket.dart';
import 'package:phoenicx_ssh/services/keys.dart';

final env = Platform.environment;
final host = env['SSH_HOST'] ?? '127.0.0.1';
final port = int.tryParse(env['SSH_PORT'] ?? '') ?? 0;
final user = env['SSH_USER'] ?? 'runner';
final keyDir = env['KEY_DIR'] ?? '';

Future<SSHClient> open(SSHAlgorithms algos, {bool fast = true}) async {
  final sock = fast ? await FastSocket.connect(host, port) : await SSHSocket.connect(host, port);
  final c = SSHClient(sock,
      username: user,
      identities: loadKeyPairs(File('$keyDir/id_ed25519').readAsStringSync()),
      algorithms: algos);
  await c.authenticated;
  return c;
}

/// Average time for one keystroke to be echoed back by `cat`.
Future<double> echoLatency(SSHClient c, {int rounds = 30}) async {
  final s = await c.execute('cat');
  final q = StreamIterator(s.stdout);
  final sw = Stopwatch();
  var total = 0;
  for (var i = 0; i < rounds; i++) {
    sw
      ..reset()
      ..start();
    s.write(Uint8List.fromList([65 + i % 26]));
    await q.moveNext();
    total += sw.elapsedMicroseconds;
  }
  s.close();
  return total / rounds / 1000;
}

/// Fast typing: 10 keys 15 ms apart; time until the last one is echoed.
Future<double> burst(SSHClient c) async {
  final s = await c.execute('cat');
  var got = 0;
  final done = Completer<void>();
  s.stdout.listen((d) {
    got += d.length;
    if (got >= 10 && !done.isCompleted) done.complete();
  });
  final sw = Stopwatch()..start();
  for (var i = 0; i < 10; i++) {
    s.write(Uint8List.fromList([97 + i]));
    await Future.delayed(const Duration(milliseconds: 15));
  }
  final typed = sw.elapsedMilliseconds;
  await done.future.timeout(const Duration(seconds: 10));
  final ms = sw.elapsedMilliseconds - typed;
  s.close();
  return ms.toDouble(); // delay after the last key
}

Future<double> throughput(SSHClient c) async {
  final sw = Stopwatch()..start();
  final out = await c.run('head -c 8000000 /dev/zero');
  return out.length / 1048576 / (sw.elapsedMilliseconds / 1000);
}

void main() {
  final skip = port == 0 ? 'SSH_PORT not set' : null;

  final configs = <String, SSHAlgorithms>{
    'aes256-gcm (default)': const SSHAlgorithms(cipher: [SSHCipherType.aes256gcm]),
    'aes128-gcm': const SSHAlgorithms(cipher: [SSHCipherType.aes128gcm]),
    'chacha20-poly1305': const SSHAlgorithms(cipher: [SSHCipherType.chacha20poly1305]),
    'aes128-ctr + sha256-etm':
        const SSHAlgorithms(cipher: [SSHCipherType.aes128ctr], mac: [SSHMacType.hmacSha256Etm]),
    'aes256-ctr + sha256-etm':
        const SSHAlgorithms(cipher: [SSHCipherType.aes256ctr], mac: [SSHMacType.hmacSha256Etm]),
    'aes128-ctr + sha512-etm':
        const SSHAlgorithms(cipher: [SSHCipherType.aes128ctr], mac: [SSHMacType.hmacSha512Etm]),
    'aes128-ctr + sha1':
        const SSHAlgorithms(cipher: [SSHCipherType.aes128ctr], mac: [SSHMacType.hmacSha1]),
  };

  test('benchmark', () async {
    final rows = <String>[];
    for (final e in configs.entries) {
      final c = await open(e.value);
      final mbs = await throughput(c);
      final lat = await echoLatency(c);
      rows.add('${e.key.padRight(26)} ${mbs.toStringAsFixed(1).padLeft(6)} MB/s   '
          'echo ${lat.toStringAsFixed(1)} ms');
      c.close();
    }
    for (final fast in [false, true]) {
      final c = await open(const SSHAlgorithms(), fast: fast);
      final lat = await echoLatency(c);
      final b = await burst(c);
      rows.add('${fast ? 'NODELAY on ' : 'NODELAY off'}   echo ${lat.toStringAsFixed(1)} ms   '
          'fast typing: last key echoed ${b.toStringAsFixed(0)} ms after it was typed');
      c.close();
    }
    // ignore: avoid_print
    print('\n===== BENCHMARK =====\n${rows.join('\n')}\n=====================');
    expect(utf8.encode('ok'), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)), skip: skip);
}

// End-to-end tests against a real SSH server (run by CI, see
// .github/workflows/selftest.yml). Skipped when SSH_PORT is not set.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phoenicx_ssh/models.dart';
import 'package:phoenicx_ssh/services/backup.dart';
import 'package:phoenicx_ssh/services/keys.dart';
import 'package:phoenicx_ssh/services/monitor.dart';
import 'package:phoenicx_ssh/services/session.dart';
import 'package:xterm/xterm.dart';

final env = Platform.environment;
final host = env['SSH_HOST'] ?? '127.0.0.1';
final port = int.tryParse(env['SSH_PORT'] ?? '') ?? 0;
final user = env['SSH_USER'] ?? 'runner';
final keyDir = env['KEY_DIR'] ?? '';

Future<void> waitFor(bool Function() cond, String what, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for: $what');
    await Future.delayed(const Duration(milliseconds: 200));
  }
}

String screen(SshTab t) => t.terminal.buffer.getText();

HostConfig keyHost(String file) => HostConfig(
      name: 'ci',
      host: host,
      port: port,
      username: user,
      auth: AuthType.key,
      privateKey: File('$keyDir/$file').readAsStringSync(),
    );

void main() {
  final skip = port == 0 ? 'SSH_PORT not set' : null;

  group('key formats', () {
    const files = [
      'id_ed25519',
      'id_rsa_pem',
      'id_ecdsa',
      'oracle_pkcs8.key',
      'ec_pkcs8.key',
      'ed25519_pkcs8.key',
      'rsa.ppk',
      'rsa_v2.ppk',
      'ed25519.ppk',
      'ecdsa.ppk',
    ];
    for (final f in files) {
      test('login with $f', () async {
        final keys = loadKeyPairs(File('$keyDir/$f').readAsStringSync());
        final c = SSHClient(await SSHSocket.connect(host, port), username: user, identities: keys);
        final out = utf8.decode(await c.run('echo login-ok'));
        expect(out.trim(), 'login-ok');
        c.close();
      });
    }
  }, skip: skip);

  test('backup round trip with password', () async {
    final h = keyHost('id_ed25519')..password = 'secret';
    final bytes = await buildBackup([h], password: 'pw123');
    expect(backupIsEncrypted(bytes), true);
    await expectLater(readBackup(bytes, password: 'wrong'), throwsA(isA<WrongPassword>()));
    final back = await readBackup(bytes, password: 'pw123');
    expect(back.single.privateKey, h.privateKey);
    expect(back.single.password, 'secret');
  }, skip: skip);

  group('session', () {
    late SshTab tab;

    setUpAll(() async {
      tab = SshTab(keyHost('id_ed25519'));
      tab.terminal.resize(120, 40);
      await tab.connect();
      await waitFor(() => tab.status == TabStatus.connected, 'connected');
    });

    tearDownAll(() => tab.dispose());

    test('typing reaches the shell and output comes back', () async {
      tab.terminal.textInput('echo PHX_\$((40+2))');
      tab.terminal.keyInput(TerminalKey.enter);
      await waitFor(() => screen(tab).contains('PHX_42'), 'echo output');
    });

    test('ctrl+c from the touch keys', () async {
      tab.terminal.textInput('sleep 30');
      tab.terminal.keyInput(TerminalKey.enter);
      await Future.delayed(const Duration(milliseconds: 500));
      tab.ctrlArmed = true;
      tab.terminal.textInput('c');
      tab.terminal.textInput('echo after_ctrl_c\r');
      await waitFor(() => screen(tab).contains('after_ctrl_c'), 'ctrl+c interrupts sleep', seconds: 10);
    });

    test('monitor: cpu, memory, network, disks, processes, docker', () async {
      tab.setMonitorVisible(true);
      final m = tab.monitor;
      await waitFor(() => m.cpuHist.data.length >= 2, 'cpu samples');
      await waitFor(() => m.processesSeen, 'processes');
      await waitFor(() => m.docker != DockerState.unknown, 'docker state', seconds: 40);
      await waitFor(() => m.os.isNotEmpty, 'system info');
      // ignore: avoid_print
      print('host=${m.hostname} os=${m.os} cores=${m.cores} cpu=${m.cpu.toStringAsFixed(1)} '
          'mem=${m.memUsed}/${m.memTotal} disks=${m.disks.map((d) => d.mount).join(',')} '
          'procs=${m.processes.length} docker=${m.docker} containers=${m.containers.map((c) => c.name).join(',')} '
          'rx=${m.rxRate} cores=${m.coreUsage}');
      expect(m.memTotal, greaterThan(0));
      expect(m.disks, isNotEmpty);
      expect(m.coreUsage.length, m.cores);
      final top = m.topProcesses(byMemory: true, grouped: true);
      expect(top, isNotEmpty);
      expect(m.topProcesses(byMemory: false, grouped: false), isNotEmpty);
      expect(m.docker, DockerState.ok);
      expect(m.containers.map((c) => c.name), contains('phx-test'));
    });

    test('nethogs: check, install, measure, uninstall', () async {
      final c = tab.client!;
      final tool = tab.nethogsTool;
      await tool.check(c);
      // ignore: avoid_print
      print('nethogs before: ${tool.state} installed=${tool.installed} candidate=${tool.candidate}');
      if (tool.isInstalled) {
        expect(await tool.run(c, 'uninstall'), true, reason: tool.log.join('\n'));
      }
      expect(tool.state, ToolState.notInstalled);
      expect(await tool.run(c, 'install'), true, reason: tool.log.join('\n'));
      expect(tool.state, ToolState.installed);
      expect(tool.installed, isNotEmpty);

      tab.nethogs.start(c);
      await waitFor(() => tab.nethogs.gotFirstSample || tab.nethogs.problem != null, 'nethogs sample',
          seconds: 40);
      expect(tab.nethogs.problem, isNull);
      // Survives being stopped and started again.
      tab.nethogs.stop();
      tab.nethogs.start(c);
      await Future.delayed(const Duration(seconds: 6));
      expect(tab.nethogs.problem, isNull);
      expect(tab.nethogs.running, true);
      tab.nethogs.stop();

      expect(await tool.run(c, 'uninstall'), true, reason: tool.log.join('\n'));
      expect(tool.state, ToolState.notInstalled);
      expect(await tool.run(c, 'install'), true, reason: tool.log.join('\n'));
    });

    test('reconnects by itself when the connection is killed', () async {
      final before = tab.connectedSince;
      // Kill this user's sshd session processes on the server side.
      await Process.run('sudo', ['pkill', '-f', 'sshd: $user']);
      await waitFor(() => tab.status != TabStatus.connected, 'drop detected', seconds: 40);
      await waitFor(() => tab.status == TabStatus.connected && tab.connectedSince != before, 'reconnected',
          seconds: 60);
      tab.terminal.textInput('echo BACK_\$((1+1))\r');
      await waitFor(() => screen(tab).contains('BACK_2'), 'typing after reconnect');
    });
  }, skip: skip);
}


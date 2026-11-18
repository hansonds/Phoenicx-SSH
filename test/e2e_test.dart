// End-to-end tests against a real SSH server (run by CI, see
// .github/workflows/selftest.yml). Skipped when SSH_PORT is not set.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phoenicx_ssh/models.dart';
import 'package:phoenicx_ssh/services/backup.dart';
import 'package:phoenicx_ssh/services/files.dart';
import 'package:phoenicx_ssh/services/local_folder.dart';
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

  test('pasted Windows line endings become single Enters', () {
    expect(SshTab.normalizeNewlines('ls\r\npwd\r\n'), 'ls\rpwd\r');
    expect(SshTab.normalizeNewlines('a\nb'), 'a\rb');
    expect(SshTab.normalizeNewlines('\x1b[200~x\r\ny\x1b[201~'), '\x1b[200~x\ry\x1b[201~');
  });

  test('backup round trip with password', () async {
    final h = keyHost('id_ed25519')..password = 'secret';
    final bytes = await buildBackup([h], password: 'pw123');
    expect(backupIsEncrypted(bytes), true);
    await expectLater(readBackup(bytes, password: 'wrong'), throwsA(isA<WrongPassword>()));
    final back = await readBackup(bytes, password: 'pw123');
    expect(back.single.privateKey, h.privateKey);
    expect(back.single.password, 'secret');

    // Saved commands travel with the backup (encrypted and plain).
    final cmds = [Snippet('Disk', 'df -h'), Snippet('Hi', 'echo hi', run: true)];
    for (final pw in ['pw123', '']) {
      final b2 = await buildBackup([h], password: pw, snippets: cmds);
      final full = await readBackupFull(b2, password: pw);
      expect(full.$1.single.host, h.host);
      expect(full.$2!.map((e) => e.command), ['df -h', 'echo hi']);
      expect(full.$2![1].run, true);
    }
    // Settings keep the user's order.
    final st = AppSettings()..snippets = [cmds[1], cmds[0]];
    final st2 = AppSettings.fromJson(st.toJson());
    expect(st2.snippets.map((e) => e.name), ['Hi', 'Disk']);
    expect(AppSettings().snippets, isNotEmpty);
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

    test('multi-line paste runs each command once, no blank lines', () async {
      tab.terminal.paste('echo P_\$((5+5))\r\necho Q_\$((6+6))\r\n');
      // bash holds a multi-line paste until Enter (safety feature, same as PuTTY).
      await Future.delayed(const Duration(milliseconds: 300));
      tab.terminal.keyInput(TerminalKey.enter);
      await waitFor(() => screen(tab).contains('Q_12'), 'pasted commands ran');
      await Future.delayed(const Duration(milliseconds: 800));
      final lines = screen(tab).split('\n').map((l) => l.trimRight()).toList();
      final start = lines.indexWhere((l) => l.contains('echo P_'));
      expect(start, greaterThanOrEqualTo(0));
      // ignore: avoid_print
      print('after paste:\n${lines.sublist(start).where((l) => l.isNotEmpty).join('\n')}');
      // Only the final, current prompt may be empty - no blank prompts in between.
      final bare = lines.sublist(start).where((l) => l.endsWith('\$') && l.contains('@')).length;
      expect(bare, 1);
    });

    test('saved command: paste only, and paste + run', () async {
      // Same steps as tapping a command in the Commands panel.
      tab.terminal.paste('echo SNIP_\$((3*3))');
      await Future.delayed(const Duration(milliseconds: 500));
      expect(screen(tab).contains('SNIP_9'), false, reason: 'paste-only must not run');
      tab.terminal.keyInput(TerminalKey.enter);
      await waitFor(() => screen(tab).contains('SNIP_9'), 'pasted command ran after Enter');
      tab.terminal.paste('echo RUN_\$((4*4))');
      tab.send('\r');
      await waitFor(() => screen(tab).contains('RUN_16'), 'run-straight-away command');
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

    test('files: browse, upload, download, edit, rename, chmod, folder, delete', () async {
      final fs = tab.files;
      final dl = await Directory.systemTemp.createTemp('phx_dl');
      FileService.downloadsOverride = dl;
      final home = await fs.homeDir();
      expect(home, startsWith('/'));
      final base = FileService.join(home, 'phx_files_test');
      await Process.run('rm', ['-rf', base]);
      await fs.mkdir(base);
      expect((await fs.list(home)).any((e) => e.name == 'phx_files_test' && e.isDir), true);

      // Upload 3 MB in chunks and check the bytes on the server.
      final data = Uint8List.fromList(List.generate(3 * 1024 * 1024, (i) => (i * 31 + 7) & 0xff));
      Stream<Uint8List> chunks() async* {
        for (var o = 0; o < data.length; o += 100000) {
          yield Uint8List.sublistView(data, o, (o + 100000).clamp(0, data.length));
        }
      }

      final up = fs.upload(name: 'big.bin', remoteDir: base, size: data.length, open: chunks);
      await waitFor(() => !up.active, 'upload finished', seconds: 60);
      expect(up.state, TransferState.done, reason: up.error);
      expect(File('$base/big.bin').readAsBytesSync(), data);

      // Download it back.
      final listed = await fs.list(base);
      final big = listed.firstWhere((e) => e.name == 'big.bin');
      expect(big.size, data.length);
      final down = fs.download(big);
      await waitFor(() => !down.active, 'download finished', seconds: 60);
      expect(down.state, TransferState.done, reason: down.error);
      expect(File(down.localPath!).readAsBytesSync(), data);

      // A second download of the same name must not overwrite the first.
      final down2 = fs.download(big);
      await waitFor(() => !down2.active, 'second download', seconds: 60);
      expect(down2.localPath, isNot(down.localPath));
      expect(down2.localPath, contains('big (1).bin'));

      // Edit a text file.
      await fs.writeText('$base/note.txt', 'hello\nworld\n');
      expect(await fs.readText('$base/note.txt'), 'hello\nworld\n');
      expect(File('$base/note.txt').readAsStringSync(), 'hello\nworld\n');

      // Rename + chmod.
      await fs.rename('$base/note.txt', '$base/renamed.txt');
      await fs.chmod('$base/renamed.txt', 0x1ed); // 0755
      final r = (await fs.list(base)).firstWhere((e) => e.name == 'renamed.txt');
      expect(r.perms, '755');

      // Folder download as .tar.gz.
      await fs.mkdir('$base/sub');
      await fs.writeText('$base/sub/inside.txt', 'INSIDE_OK');
      final sub = (await fs.list(base)).firstWhere((e) => e.name == 'sub');
      final tar = await fs.downloadFolder(sub);
      await waitFor(() => !tar.active, 'folder download', seconds: 60);
      expect(tar.state, TransferState.done, reason: tar.error);
      final x = await Process.run('tar', ['-xzOf', tar.localPath!, 'sub/inside.txt']);
      expect(x.stdout.toString(), 'INSIDE_OK');

      // Cancel a slow upload.
      Stream<Uint8List> slow() async* {
        for (var i = 0; i < 200; i++) {
          await Future.delayed(const Duration(milliseconds: 50));
          yield Uint8List(64 * 1024);
        }
      }

      final c = fs.upload(name: 'slow.bin', remoteDir: base, size: 200 * 64 * 1024, open: slow);
      await Future.delayed(const Duration(milliseconds: 600));
      await c.cancel();
      expect(c.state, TransferState.cancelled);

      // Upload a whole folder: nested folders, an empty folder, a file with spaces.
      final src = await Directory.systemTemp.createTemp('phx_up');
      final proj = Directory('${src.path}/my project')..createSync();
      File('${proj.path}/readme.txt').writeAsStringSync('top level');
      Directory('${proj.path}/src/lib/deep').createSync(recursive: true);
      File('${proj.path}/src/main.py').writeAsStringSync('print("hi")');
      File('${proj.path}/src/lib/deep/data file.bin').writeAsBytesSync(data.sublist(0, 1024 * 1024));
      Directory('${proj.path}/empty').createSync();
      final lf = await LocalFolder.fromDirectory(proj);
      expect(lf.name, 'my project');
      expect(lf.files.length, 3);
      expect(lf.dirs.toSet(), {'src', 'src/lib', 'src/lib/deep', 'empty'});
      final fu = fs.uploadFolder(lf, base);
      expect(fu.isFolder, true);
      await waitFor(() => !fu.active, 'folder upload', seconds: 60);
      expect(fu.state, TransferState.done, reason: fu.error);
      expect(fu.done, lf.totalBytes);
      expect(File('$base/my project/readme.txt').readAsStringSync(), 'top level');
      expect(File('$base/my project/src/main.py').readAsStringSync(), 'print("hi")');
      expect(File('$base/my project/src/lib/deep/data file.bin').readAsBytesSync(), data.sublist(0, 1024 * 1024));
      expect(Directory('$base/my project/empty').existsSync(), true);
      expect(await fs.isDir('$base/my project'), true);

      // Upload again into the existing folder: replaces same-name files, keeps others.
      File('$base/my project/server-only.txt').writeAsStringSync('keep me');
      File('${proj.path}/readme.txt').writeAsStringSync('updated');
      final fu2 = fs.uploadFolder(await LocalFolder.fromDirectory(proj), base);
      await waitFor(() => !fu2.active, 'folder re-upload', seconds: 60);
      expect(fu2.state, TransferState.done, reason: fu2.error);
      expect(File('$base/my project/readme.txt').readAsStringSync(), 'updated');
      expect(File('$base/my project/server-only.txt').readAsStringSync(), 'keep me');

      // Cancel a folder upload part-way.
      final many = Directory('${src.path}/many')..createSync();
      for (var i = 0; i < 120; i++) {
        File('${many.path}/f$i.bin').writeAsBytesSync(data.sublist(0, 512 * 1024));
      }
      final fu3 = fs.uploadFolder(await LocalFolder.fromDirectory(many), base);
      await waitFor(() => fu3.done > 0, 'folder upload started', seconds: 30);
      await fu3.cancel();
      expect(fu3.state, TransferState.cancelled);
      await Future.delayed(const Duration(milliseconds: 500));
      final sent = Directory('$base/many').listSync().length;
      expect(sent, lessThan(120), reason: 'cancel should stop the folder upload');
      await src.delete(recursive: true);

      // Delete the whole test folder (recursive).
      final folder = (await fs.list(home)).firstWhere((e) => e.name == 'phx_files_test');
      await fs.delete(folder);
      expect(Directory(base).existsSync(), false);

      // Errors are readable.
      await expectLater(fs.list('/root'), throwsA(isA<FileError>()));
      FileService.downloadsOverride = null;
      await dl.delete(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('reconnects by itself when the connection is killed', () async {
      final before = tab.connectedSince;
      // Kill this user's sshd session processes on the server side.
      await Process.run('sudo', ['pkill', '-f', 'sshd(-session)?: $user']);
      await waitFor(() => tab.status != TabStatus.connected, 'drop detected', seconds: 40);
      await waitFor(() => tab.status == TabStatus.connected && tab.connectedSince != before, 'reconnected',
          seconds: 60);
      tab.terminal.textInput('echo BACK_\$((1+1))\r');
      await waitFor(() => screen(tab).contains('BACK_2'), 'typing after reconnect');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: skip);
}


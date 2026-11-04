import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'models.dart';
import 'services/session.dart';
import 'services/store.dart';
import 'theme.dart';
import 'ui/home_screen.dart';

final navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.I.init();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Phoenicx SSH',
        size: Size(1280, 780),
        minimumSize: Size(560, 400),
        center: true,
        backgroundColor: PX.bg,
      ),
      () async {
        await windowManager.setPreventClose(true);
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  SshTab.hostKeyPrompt = _hostKeyPrompt;
  runApp(const PhoenicxSshApp());
  _selfTest();
}

/// Used only by the automated build tests: when PHOENICX_SELFTEST is set,
/// open a session to that server straight away (user:password@host:port).
void _selfTest() {
  final spec = Platform.environment['PHOENICX_SELFTEST'];
  if (spec == null || spec.isEmpty) return;
  final m = RegExp(r'^([^:]+):([^@]*)@([^:]+):(\d+)$').firstMatch(spec);
  if (m == null) return;
  SshTab.hostKeyPrompt = null;
  final monitorAfter = int.tryParse(Platform.environment['PHOENICX_SELFTEST_MONITOR'] ?? '');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final t = Sessions.I.open(HostConfig(
      name: 'Self test',
      host: m.group(3)!,
      port: int.parse(m.group(4)!),
      username: m.group(1)!,
      auth: AuthType.password,
      password: m.group(2)!,
    ));
    if (monitorAfter != null) {
      Future.delayed(Duration(seconds: monitorAfter), () => t.setMonitorExpanded(true));
    }
  });
}

class PhoenicxSshApp extends StatelessWidget {
  const PhoenicxSshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phoenicx SSH',
      navigatorKey: navKey,
      debugShowCheckedModeBanner: false,
      theme: PX.theme(),
      darkTheme: PX.theme(),
      themeMode: ThemeMode.dark,
      home: const HomeScreen(),
    );
  }
}

Future<bool> _hostKeyPrompt(HostConfig host, String fingerprint, String? previous) async {
  final ctx = navKey.currentContext;
  if (ctx == null) return previous == null;
  final changed = previous != null;
  final ok = await showDialog<bool>(
    context: ctx,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      icon: Icon(changed ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
          color: changed ? PX.red : PX.accent),
      title: Text(changed ? 'Host key has CHANGED' : 'New server'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(changed
              ? '${host.host} is presenting a different key than before. This happens if the instance was '
                  'recreated or reinstalled - or if someone is intercepting the connection.'
              : 'First connection to ${host.host}. Trust this server key?'),
          const SizedBox(height: 12),
          SelectableText(fingerprint, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          if (changed) ...[
            const SizedBox(height: 8),
            Text('Previously: $previous', style: const TextStyle(fontSize: 11, color: PX.muted)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(changed ? 'Trust new key' : 'Trust & connect')),
      ],
    ),
  );
  return ok == true;
}

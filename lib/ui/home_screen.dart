import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models.dart';
import '../services/keepalive.dart';
import '../services/session.dart';
import '../services/store.dart';
import '../theme.dart';
import 'hosts_page.dart';
import 'terminal_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, WindowListener {
  final _sessions = Sessions.I;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SessionKeeper.requestNotificationPermission();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sessions.checkAll();
  }

  @override
  void onWindowClose() async {
    final live = _sessions.liveCount;
    if (live > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Close Phoenicx SSH?'),
          content: Text('$live SSH session${live == 1 ? ' is' : 's are'} still open. Closing the app disconnects ${live == 1 ? 'it' : 'them'}.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Disconnect & close')),
          ],
        ),
      );
      if (ok != true) return;
    }
    _sessions.closeAll();
    await windowManager.destroy();
  }

  Future<void> _closeTab(SshTab t) async {
    if (t.status == TabStatus.connected || t.status == TabStatus.reconnecting) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Disconnect ${t.host.title}?'),
          content: const Text('This ends the SSH session.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Disconnect')),
          ],
        ),
      );
      if (ok != true) return;
    }
    _sessions.closeTab(t);
  }

  Future<void> _newTabMenu(BuildContext anchor) async {
    final hosts = [...Store.I.hosts.value]..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    if (hosts.isEmpty) {
      _sessions.select(-1);
      return;
    }
    final box = anchor.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(0, box.size.height));
    final picked = await showMenu<HostConfig?>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        for (final h in hosts.take(12))
          PopupMenuItem(
            value: h,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.dns_rounded, color: PX.tags[h.color.clamp(0, PX.tags.length - 1).toInt()]),
              title: Text(h.title),
              subtitle: Text(h.address, style: const TextStyle(fontSize: 11)),
            ),
          ),
        const PopupMenuItem(value: null, child: ListTile(dense: true, leading: Icon(Icons.list), title: Text('All hosts...'))),
      ],
    );
    if (picked != null) {
      _sessions.open(picked);
    } else {
      _sessions.select(-1);
    }
  }

  Future<void> _tabMenu(SshTab t, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: const [
        PopupMenuItem(value: 'dup', child: Text('Duplicate session')),
        PopupMenuItem(value: 'rec', child: Text('Reconnect')),
        PopupMenuItem(value: 'close', child: Text('Close')),
      ],
    );
    if (v == 'dup') _sessions.open(t.host);
    if (v == 'rec') {
      t.reconnectNow();
    }
    if (v == 'close') _closeTab(t);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _sessions,
      builder: (context, _) {
        final sel = _sessions.selected;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_sessions.selected >= 0) {
              _sessions.select(-1);
            } else {
              SessionKeeper.moveToBack();
            }
          },
          child: Scaffold(
            body: SafeArea(
              bottom: false,
              child: Column(children: [
                if (_sessions.tabs.isNotEmpty) _tabStrip(),
                Expanded(
                  child: IndexedStack(
                    index: sel + 1,
                    children: [
                      HostsPage(),
                      for (var i = 0; i < _sessions.tabs.length; i++)
                        TerminalPage(
                          key: ValueKey(_sessions.tabs[i].uid),
                          tab: _sessions.tabs[i],
                          active: i == sel,
                        ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _tabStrip() {
    return Container(
      height: 42,
      decoration: const BoxDecoration(
        color: PX.bg,
        border: Border(bottom: BorderSide(color: PX.line)),
      ),
      child: Row(children: [
        _homeTab(),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (var i = 0; i < _sessions.tabs.length; i++) _tab(i),
              Builder(
                builder: (c) => IconButton(
                  tooltip: 'New session',
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: () => _newTabMenu(c),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _homeTab() {
    final on = _sessions.selected == -1;
    return InkWell(
      onTap: () => _sessions.select(-1),
      child: Container(
        width: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: on ? PX.accent : Colors.transparent, width: 2)),
        ),
        child: Icon(Icons.dns_outlined, size: 20, color: on ? PX.accent : PX.muted),
      ),
    );
  }

  Widget _tab(int i) {
    final t = _sessions.tabs[i];
    final on = i == _sessions.selected;
    final color = PX.tags[t.host.color.clamp(0, PX.tags.length - 1).toInt()];
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) => GestureDetector(
        onSecondaryTapDown: (d) => _tabMenu(t, d.globalPosition),
        onLongPressStart: (d) => _tabMenu(t, d.globalPosition),
        child: InkWell(
          onTap: () => _sessions.select(i),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.only(left: 12, right: 2),
            decoration: BoxDecoration(
              color: on ? PX.surface : Colors.transparent,
              border: Border(
                bottom: BorderSide(color: on ? color : Colors.transparent, width: 2),
                right: const BorderSide(color: PX.line),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              statusDot(t.status),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  t.host.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: on ? PX.text : PX.muted, fontWeight: on ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: () => _closeTab(t),
                icon: const Icon(Icons.close),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

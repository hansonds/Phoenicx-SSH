import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/debug_log.dart';
import '../services/session.dart';
import '../services/store.dart';
import '../theme.dart';
import 'monitor_panel.dart';

class TerminalPage extends StatefulWidget {
  final SshTab tab;
  final bool active;
  const TerminalPage({super.key, required this.tab, required this.active});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _focus = FocusNode();
  SshTab get tab => widget.tab;
  bool get _touch => Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    if (widget.active) _grabFocus();
  }

  @override
  void didUpdateWidget(covariant TerminalPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _grabFocus();
  }

  /// Explicitly request focus (not just autofocus) so the keyboard input
  /// connection is opened and typing reaches the terminal.
  void _grabFocus() {
    if (_touch) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Windows: like PuTTY, finishing a mouse selection copies it right away
  /// (no pop-up menu). The highlight stays until you click elsewhere.
  String? _lastAutoCopied;
  void _onPointerUp(PointerUpEvent e) {
    if (_touch) return;
    Future.delayed(const Duration(milliseconds: 60), () async {
      if (!mounted) return;
      final sel = tab.controller.selection;
      if (sel == null || sel.isCollapsed) {
        _lastAutoCopied = null;
        return;
      }
      final text = tab.terminal.buffer.getText(sel).trimRight();
      if (text.isEmpty || text == _lastAutoCopied) return;
      _lastAutoCopied = text;
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Copied - right-click to paste'),
            duration: Duration(milliseconds: 900),
            behavior: SnackBarBehavior.floating,
            width: 260,
          ));
      }
    });
  }

  /// Desktop shortcuts like Windows Terminal: Ctrl+C copies when text is
  /// selected (otherwise it is sent as normal Ctrl+C), Ctrl+V pastes.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent e) {
    if (DebugLog.on) {
      final k = HardwareKeyboard.instance;
      DebugLog.log('key ${e.runtimeType} ${e.logicalKey.debugName} phys=${e.physicalKey.debugName} '
          'ctrl=${k.isControlPressed} shift=${k.isShiftPressed} alt=${k.isAltPressed} '
          'char=${e.character?.codeUnits}');
    }
    if (_touch || e is! KeyDownEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    if (!hw.isControlPressed || hw.isShiftPressed || hw.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyC) {
      final sel = tab.controller.selection;
      if (sel != null && !sel.isCollapsed) {
        _copy();
        return KeyEventResult.handled;
      }
    } else if (e.logicalKey == LogicalKeyboardKey.keyV && Store.I.settings.ctrlVPaste) {
      _paste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _copy() async {
    final sel = tab.controller.selection;
    if (sel == null) return;
    final text = tab.terminal.buffer.getText(sel);
    await Clipboard.setData(ClipboardData(text: text));
    tab.controller.clearSelection();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied'), duration: Duration(milliseconds: 900)),
      );
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    tab.terminal.paste(text);
    _grabFocus();
  }

  void _fontSize(double delta) {
    final s = Store.I.settings;
    s.fontSize = (s.fontSize + delta).clamp(8.0, 32.0).toDouble();
    Store.I.saveSettings();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: tab,
      builder: (context, _) {
        final wide = Layout.wide(context);
        final showMonitor = tab.monitorVisible;
        final term = _terminalArea();
        Widget body;
        if (wide && showMonitor && tab.monitorExpanded) {
          body = MonitorPanel(tab: tab);
        } else if (wide) {
          body = Row(children: [
            Expanded(child: term),
            if (showMonitor) ...[
              const VerticalDivider(width: 1),
              SizedBox(width: 440, child: MonitorPanel(tab: tab)),
            ],
          ]);
        } else {
          body = showMonitor ? MonitorPanel(tab: tab) : term;
        }
        return Column(children: [
          _toolbar(wide),
          const Divider(height: 1),
          Expanded(child: body),
          if (_touch && !(showMonitor && (!wide || tab.monitorExpanded)))
            _ExtraKeys(tab: tab, onPaste: _paste),
        ]);
      },
    );
  }

  Widget _terminalArea() {
    final settings = Store.I.settings;
    return Stack(children: [
      Positioned.fill(
        child: Container(
          color: PX.terminal.background,
          child: Listener(
           onPointerUp: _onPointerUp,
           child: TerminalView(
            tab.terminal,
            controller: tab.controller,
            focusNode: _focus,
            autofocus: false,
            enableSuggestions: false,
            // The copy/paste pop-up is for touch screens only.
            showToolbar: _touch,
            theme: PX.terminal,
            textStyle: TerminalStyle(fontSize: settings.fontSize),
            padding: const EdgeInsets.all(6),
            keyboardType: TextInputType.visiblePassword,
            deleteDetection: _touch,
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
                  CopySelectionTextIntent.copy,
              SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
                  PasteTextIntent(SelectionChangedCause.keyboard),
              SingleActivator(LogicalKeyboardKey.insert, shift: true):
                  PasteTextIntent(SelectionChangedCause.keyboard),
            },
            onKeyEvent: _onKeyEvent,
            onSecondaryTapDown: (details, offset) async {
              // PuTTY style: selecting copies, right-click pastes.
              if (!settings.rightClickPaste) return;
              await _paste();
            },
           ),
          ),
        ),
      ),
      if (tab.status != TabStatus.connected) Positioned(left: 0, right: 0, bottom: 0, child: _statusBanner()),
    ]);
  }

  Widget _statusBanner() {
    final s = tab.status;
    String text;
    IconData icon;
    Color color;
    switch (s) {
      case TabStatus.connecting:
        text = 'Connecting to ${tab.host.address}...';
        icon = Icons.sync;
        color = PX.accent2;
      case TabStatus.reconnecting:
        text = tab.retryIn > 0
            ? '${tab.message ?? 'Disconnected'} - retrying in ${tab.retryIn}s (attempt ${tab.attempt})'
            : 'Reconnecting...';
        icon = Icons.sync_problem;
        color = PX.yellow;
      case TabStatus.failed:
        text = tab.message ?? 'Could not connect';
        icon = Icons.error_outline;
        color = PX.red;
      case TabStatus.ended:
        text = tab.message ?? 'Session ended';
        icon = Icons.power_settings_new;
        color = PX.muted;
      case TabStatus.connected:
        return const SizedBox.shrink();
    }
    return Material(
      color: PX.surface.withValues(alpha: 0.96),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
          if (s != TabStatus.connecting)
            TextButton.icon(
              onPressed: tab.reconnectNow,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(s == TabStatus.reconnecting ? 'Now' : 'Reconnect'),
            ),
        ]),
      ),
    );
  }

  Widget _toolbar(bool wide) {
    final m = tab.monitor;
    final connected = tab.status == TabStatus.connected;
    return Container(
      height: 40,
      color: PX.bg,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        _dot(tab.status),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            tab.remoteTitle?.isNotEmpty == true ? tab.remoteTitle! : tab.host.address,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: PX.muted),
          ),
        ),
        if (connected)
          AnimatedBuilder(
            animation: m,
            builder: (context, _) => !m.hasData
                ? const SizedBox.shrink()
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    _mini('CPU', m.cpu, PX.accent),
                    _mini('RAM', m.memPerc, PX.blue),
                    if (wide) _netMini(m.rxRate, m.txRate),
                  ]),
          ),
        if (!_touch || wide) ...[
          _iconBtn(Icons.text_decrease, 'Smaller text', () => _fontSize(-1)),
          _iconBtn(Icons.text_increase, 'Bigger text', () => _fontSize(1)),
        ],
        _iconBtn(Icons.content_copy, 'Copy selection', _copy),
        _iconBtn(Icons.content_paste, 'Paste', _paste),
        if (_touch && !wide)
          _iconBtn(Icons.keyboard, 'Keyboard', () {
            tab.setMonitorVisible(false);
            _focus.requestFocus();
            SystemChannels.textInput.invokeMethod('TextInput.show');
          }),
        if (wide && tab.monitorVisible)
          _iconBtn(
            tab.monitorExpanded ? Icons.close_fullscreen : Icons.open_in_full,
            tab.monitorExpanded ? 'Back to terminal + monitor' : 'Full-screen monitor',
            () {
              tab.setMonitorExpanded(!tab.monitorExpanded);
              _grabFocus();
            },
          ),
        _iconBtn(
          tab.monitorVisible ? Icons.terminal : Icons.monitor_heart_outlined,
          tab.monitorVisible ? (wide ? 'Hide monitor' : 'Show terminal') : 'Server monitor',
          () {
            tab.setMonitorVisible(!tab.monitorVisible);
            _grabFocus();
          },
          highlight: tab.monitorVisible && wide,
        ),
      ]),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap, {bool highlight = false}) =>
      IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        iconSize: 19,
        color: highlight ? PX.accent : PX.text,
        onPressed: onTap,
        icon: Icon(icon),
      );

  Widget _mini(String label, double v, Color c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$label ', style: const TextStyle(color: PX.muted)),
            TextSpan(text: '${v.toStringAsFixed(0)}%', style: TextStyle(color: c, fontWeight: FontWeight.w700)),
          ]),
          style: const TextStyle(fontSize: 11.5),
        ),
      );

  Widget _netMini(double rx, double tx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text('↓${fmtRate(rx)} ↑${fmtRate(tx)}',
            style: const TextStyle(fontSize: 11.5, color: PX.muted)),
      );
}

Widget _dot(TabStatus s) {
  final c = switch (s) {
    TabStatus.connected => PX.green,
    TabStatus.connecting || TabStatus.reconnecting => PX.yellow,
    TabStatus.failed => PX.red,
    TabStatus.ended => PX.muted,
  };
  return Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
}

Widget statusDot(TabStatus s) => _dot(s);

/// The row of keys phones don't have: Esc, Tab, Ctrl, Alt, arrows...
class _ExtraKeys extends StatelessWidget {
  final SshTab tab;
  final VoidCallback onPaste;
  const _ExtraKeys({required this.tab, required this.onPaste});

  void _key(TerminalKey k) {
    final ctrl = tab.ctrlArmed, alt = tab.altArmed;
    tab.ctrlArmed = false;
    tab.altArmed = false;
    tab.terminal.keyInput(k, ctrl: ctrl, alt: alt);
    tab.refresh();
    HapticFeedback.selectionClick();
  }

  void _text(String s) {
    tab.terminal.textInput(s);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    Widget k(String label, VoidCallback onTap, {bool on = false, double w = 46}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: on ? PX.accent : PX.surface2,
            borderRadius: BorderRadius.circular(7),
            child: InkWell(
              borderRadius: BorderRadius.circular(7),
              onTap: onTap,
              child: SizedBox(
                width: w,
                height: 36,
                child: Center(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: on ? Colors.black : PX.text)),
                ),
              ),
            ),
          ),
        );

    return Container(
      color: PX.bg,
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            k('ESC', () => _key(TerminalKey.escape)),
            k('TAB', () => _key(TerminalKey.tab)),
            k('CTRL', () {
              tab.ctrlArmed = !tab.ctrlArmed;
              tab.refresh();
            }, on: tab.ctrlArmed),
            k('ALT', () {
              tab.altArmed = !tab.altArmed;
              tab.refresh();
            }, on: tab.altArmed),
            k('←', () => _key(TerminalKey.arrowLeft), w: 40),
            k('↑', () => _key(TerminalKey.arrowUp), w: 40),
            k('↓', () => _key(TerminalKey.arrowDown), w: 40),
            k('→', () => _key(TerminalKey.arrowRight), w: 40),
            k('^C', () => _text('\x03'), w: 40),
            k('|', () => _text('|'), w: 36),
            k('/', () => _text('/'), w: 36),
            k('-', () => _text('-'), w: 36),
            k('~', () => _text('~'), w: 36),
            k('HOME', () => _key(TerminalKey.home), w: 52),
            k('END', () => _key(TerminalKey.end)),
            k('PGUP', () => _key(TerminalKey.pageUp), w: 52),
            k('PGDN', () => _key(TerminalKey.pageDown), w: 52),
            k('F1', () => _key(TerminalKey.f1), w: 38),
            k('F2', () => _key(TerminalKey.f2), w: 38),
            k('F10', () => _key(TerminalKey.f10), w: 42),
            k('PASTE', onPaste, w: 58),
          ]),
        ),
      ),
    );
  }
}

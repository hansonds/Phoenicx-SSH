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

  double get _fs => Store.I.settings.terminalFontSize;

  void _setFontSize(double v, {bool save = true}) {
    Store.I.settings.terminalFontSize = v.clamp(6.0, 32.0).toDouble();
    if (save) Store.I.saveSettings();
    setState(() {});
  }

  void _fontSize(double delta) => _setFontSize(_fs + delta);

  // ---- Pinch to zoom (Android). Uses a raw Listener so it never fights the
  // terminal's own scroll / selection gestures.
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDist, _pinchStartSize;

  void _ptrDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      final p = _pointers.values.toList();
      _pinchStartDist = (p[0] - p[1]).distance;
      _pinchStartSize = _fs;
    }
  }

  void _ptrMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && _pinchStartDist != null && _pinchStartDist! > 20) {
      final p = _pointers.values.toList();
      final scale = (p[0] - p[1]).distance / _pinchStartDist!;
      final target = (_pinchStartSize! * scale * 2).roundToDouble() / 2; // 0.5 steps
      if ((target - _fs).abs() >= 0.5) _setFontSize(target, save: false);
    }
  }

  void _ptrEnd(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _pinchStartDist != null) {
      _pinchStartDist = null;
      Store.I.saveSettings();
    }
  }

  void _selectAll() {
    final b = tab.terminal.buffer;
    tab.controller.setSelection(
      b.createAnchor(0, 0),
      b.createAnchor(tab.terminal.viewWidth, b.height - 1),
    );
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: tab.terminal.buffer.getText().trimRight()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Whole screen copied'), duration: Duration(milliseconds: 900)),
      );
    }
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
           onPointerUp: (e) {
             _onPointerUp(e);
             _ptrEnd(e);
           },
           onPointerDown: _touch ? _ptrDown : null,
           onPointerMove: _touch ? _ptrMove : null,
           onPointerCancel: _ptrEnd,
           child: TerminalView(
            tab.terminal,
            controller: tab.controller,
            focusNode: _focus,
            autofocus: false,
            enableSuggestions: false,
            // The library's pop-up dims the whole app; we show our own bar.
            showToolbar: false,
            theme: PX.terminal,
            textStyle: TerminalStyle(fontSize: _fs),
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
      if (_touch)
        Positioned(
          top: 8,
          right: 8,
          child: AnimatedBuilder(
            animation: tab.controller,
            builder: (context, _) =>
                tab.controller.selection == null ? const SizedBox.shrink() : _selectionBar(),
          ),
        ),
    ]);
  }

  /// Small floating bar shown while text is selected on a touch screen.
  Widget _selectionBar() {
    Widget b(IconData i, String label, VoidCallback onTap) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(i, size: 18, color: PX.accent2),
              const SizedBox(width: 5),
              Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          ),
        );
    return Material(
      color: PX.surface2,
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b(Icons.content_copy, 'Copy', _copy),
        b(Icons.select_all, 'All', _selectAll),
        b(Icons.content_paste, 'Paste', () {
          tab.controller.clearSelection();
          _paste();
        }),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: 'Clear selection',
          onPressed: tab.controller.clearSelection,
          icon: const Icon(Icons.close),
        ),
      ]),
    );
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
        PopupMenuButton<String>(
          tooltip: 'More',
          iconSize: 19,
          padding: EdgeInsets.zero,
          onSelected: (v) {
            switch (v) {
              case 'smaller':
                _fontSize(-1);
              case 'bigger':
                _fontSize(1);
              case 'selectall':
                _selectAll();
              case 'copyall':
                _copyAll();
              case 'clear':
                tab.send('\x0c');
              case 'reconnect':
                tab.reconnectNow();
              case 'dup':
                Sessions.I.open(tab.host);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'smaller', child: Text('Smaller text  (or pinch)')),
            const PopupMenuItem(value: 'bigger', child: Text('Bigger text  (or pinch)')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'selectall', child: Text('Select all')),
            const PopupMenuItem(value: 'copyall', child: Text('Copy whole screen')),
            const PopupMenuItem(value: 'clear', child: Text('Clear screen')),
            const PopupMenuItem(value: 'reconnect', child: Text('Reconnect')),
            const PopupMenuItem(value: 'dup', child: Text('Duplicate session')),
          ],
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

/// Keys phones don't have. Row 1: Esc, Tab, Ctrl, Alt, arrows.
/// Row 2 (scrolls): one-tap shortcuts (^C ^X ^O ...), symbols, Home/End,
/// PgUp/PgDn, F1-F12. Long-press CTRL or ALT to lock it on.
class _ExtraKeys extends StatelessWidget {
  final SshTab tab;
  final VoidCallback onPaste;
  const _ExtraKeys({required this.tab, required this.onPaste});

  void _key(TerminalKey k) {
    final ctrl = tab.ctrlArmed, alt = tab.altArmed;
    if (!tab.ctrlLocked) tab.ctrlArmed = false;
    if (!tab.altLocked) tab.altArmed = false;
    tab.terminal.keyInput(k, ctrl: ctrl, alt: alt);
    tab.refresh();
    HapticFeedback.selectionClick();
  }

  void _raw(String s) {
    tab.sendRaw(s);
    HapticFeedback.selectionClick();
  }

  void _text(String s) {
    tab.terminal.textInput(s);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    Widget k(String label, VoidCallback onTap,
            {bool on = false, bool locked = false, VoidCallback? onLong, double? w, Color? fg}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: on ? (locked ? PX.accent2 : PX.accent) : PX.surface2,
            borderRadius: BorderRadius.circular(7),
            child: InkWell(
              borderRadius: BorderRadius.circular(7),
              onTap: onTap,
              onLongPress: onLong,
              child: SizedBox(
                width: w,
                height: 34,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: w == null ? 10 : 0),
                  child: Center(
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: on ? Colors.black : (fg ?? PX.text))),
                  ),
                ),
              ),
            ),
          ),
        );

    Widget mod(String label, bool armed, bool locked, void Function(bool armed, bool locked) set) => k(
          locked ? '$label 🔒' : label,
          () {
            if (locked) {
              set(false, false);
            } else {
              set(!armed, false);
            }
            tab.refresh();
          },
          onLong: () {
            set(true, true);
            tab.refresh();
            HapticFeedback.mediumImpact();
          },
          on: armed,
          locked: locked,
        );

    final row1 = Row(children: [
      Expanded(child: k('ESC', () => _key(TerminalKey.escape))),
      Expanded(child: k('TAB', () => _key(TerminalKey.tab))),
      Expanded(
        flex: 2,
        child: mod('CTRL', tab.ctrlArmed, tab.ctrlLocked, (a, l) {
          tab.ctrlArmed = a;
          tab.ctrlLocked = l;
        }),
      ),
      Expanded(
        child: mod('ALT', tab.altArmed, tab.altLocked, (a, l) {
          tab.altArmed = a;
          tab.altLocked = l;
        }),
      ),
      Expanded(child: k('←', () => _key(TerminalKey.arrowLeft))),
      Expanded(child: k('↑', () => _key(TerminalKey.arrowUp))),
      Expanded(child: k('↓', () => _key(TerminalKey.arrowDown))),
      Expanded(child: k('→', () => _key(TerminalKey.arrowRight))),
    ]);

    const ctrlKeys = ['C', 'D', 'Z', 'X', 'O', 'W', 'K', 'U', 'R', 'L', 'A', 'E'];
    final row2 = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final c in ctrlKeys)
          k('^$c', () => _raw(String.fromCharCode(c.codeUnitAt(0) - 64)), fg: PX.accent2),
        k('|', () => _text('|'), w: 34),
        k('/', () => _text('/'), w: 34),
        k('-', () => _text('-'), w: 34),
        k('~', () => _text('~'), w: 34),
        k('\$', () => _text('\$'), w: 34),
        k('*', () => _text('*'), w: 34),
        k('HOME', () => _key(TerminalKey.home)),
        k('END', () => _key(TerminalKey.end)),
        k('PGUP', () => _key(TerminalKey.pageUp)),
        k('PGDN', () => _key(TerminalKey.pageDown)),
        k('DEL', () => _key(TerminalKey.delete)),
        for (var i = 1; i <= 12; i++)
          k('F$i', () => _key(TerminalKey.values.byName('f$i'))),
        k('PASTE', onPaste),
      ]),
    );

    return Container(
      color: PX.bg,
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          row1,
          const SizedBox(height: 4),
          row2,
        ]),
      ),
    );
  }
}

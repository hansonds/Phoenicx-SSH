import 'package:flutter/material.dart';

import '../models.dart';
import '../services/session.dart';
import '../services/store.dart';
import '../theme.dart';

/// Opens the saved-commands panel. Wide screens get a panel under the
/// toolbar; phones get a bottom sheet.
Future<void> showCommands(BuildContext context, SshTab tab,
    {required bool wide, VoidCallback? afterPaste}) {
  final panel = CommandsPanel(tab: tab, afterPaste: afterPaste);
  if (wide) {
    final h = MediaQuery.sizeOf(context).height;
    return showDialog(
      context: context,
      barrierColor: Colors.black26,
      builder: (_) => Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 92, right: 14),
          child: SizedBox(
            width: 440,
            height: (h - 130).clamp(300.0, 640.0).toDouble(),
            child: Material(
              color: PX.card,
              elevation: 12,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: PX.cardLine),
              ),
              clipBehavior: Clip.antiAlias,
              child: panel,
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: PX.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (c) => SizedBox(height: MediaQuery.sizeOf(c).height * 0.82, child: panel),
  );
}

class CommandsPanel extends StatefulWidget {
  final SshTab tab;
  final VoidCallback? afterPaste;
  const CommandsPanel({super.key, required this.tab, this.afterPaste});

  @override
  State<CommandsPanel> createState() => _CommandsPanelState();
}

class _CommandsPanelState extends State<CommandsPanel> {
  bool _editing = false;
  String _query = '';

  List<Snippet> get _list => Store.I.settings.snippets;

  Future<void> _save() async {
    Store.I.settings.snippets = _list;
    await Store.I.saveSettings();
    if (mounted) setState(() {});
  }

  void _use(Snippet s) {
    final tab = widget.tab;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    if (tab.status != TabStatus.connected) {
      messenger.showSnackBar(const SnackBar(content: Text('Not connected')));
      return;
    }
    tab.terminal.paste(s.command);
    if (s.run) tab.send('\r');
    widget.afterPaste?.call();
  }

  Future<void> _edit([Snippet? s]) async {
    final r = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _EditDialog(snippet: s),
    );
    if (r == null) return;
    if (r.delete && s != null) {
      _list.remove(s);
    } else if (s == null) {
      _list.add(r.snippet!);
    } else {
      s
        ..name = r.snippet!.name
        ..command = r.snippet!.command
        ..run = r.snippet!.run;
    }
    await _save();
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reset commands?'),
        content: const Text('Your list is replaced with the default Linux commands. Commands you added are removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    Store.I.settings.snippets = Snippet.defaults();
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown = _editing
        ? _list
        : _list
            .where((s) => q.isEmpty || s.name.toLowerCase().contains(q) || s.command.toLowerCase().contains(q))
            .toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: const LinearGradient(colors: PX.gBrand),
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Commands', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          IconButton(
            tooltip: 'Add command',
            onPressed: () => _edit(),
            icon: const Icon(Icons.add_rounded, color: PX.accent2),
          ),
          TextButton(
            onPressed: () => setState(() => _editing = !_editing),
            child: Text(_editing ? 'Done' : 'Edit'),
          ),
        ]),
      ),
      if (!_editing)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded, size: 20),
              hintText: 'Search commands',
            ),
          ),
        )
      else
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Drag ≡ to reorder · tap ✎ to change · 🗑 to remove',
              style: TextStyle(fontSize: 12, color: PX.muted)),
        ),
      const Divider(height: 1),
      Expanded(child: _editing ? _editList() : _useList(shown)),
      if (_editing)
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset to default commands'),
          ),
        )
      else
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Text('Tap to paste into the terminal · long-press to edit',
              style: TextStyle(fontSize: 11.5, color: PX.muted)),
        ),
    ]);
  }

  Widget _useList(List<Snippet> shown) {
    if (shown.isEmpty) {
      return const Center(child: Text('No commands', style: TextStyle(color: PX.muted)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: shown.length,
      itemBuilder: (c, i) {
        final s = shown[i];
        return InkWell(
          onTap: () => _use(s),
          onLongPress: () => _edit(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: (s.run ? PX.mint : PX.accent).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(s.run ? Icons.play_arrow_rounded : Icons.keyboard_return_rounded,
                    size: 17, color: s.run ? PX.mint : PX.accent2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(s.command,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: PX.muted)),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _editList() {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _list.length,
      onReorder: (oldI, newI) {
        if (newI > oldI) newI--;
        final s = _list.removeAt(oldI);
        _list.insert(newI, s);
        _save();
      },
      itemBuilder: (c, i) {
        final s = _list[i];
        return Material(
          key: ObjectKey(s),
          color: PX.card,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
            child: Row(children: [
              ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.drag_indicator_rounded, color: PX.muted),
                ),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  Text(s.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: PX.muted)),
                ]),
              ),
              IconButton(
                tooltip: 'Edit',
                onPressed: () => _edit(s),
                icon: const Icon(Icons.edit_rounded, size: 19),
              ),
              IconButton(
                tooltip: 'Delete',
                onPressed: () {
                  _list.remove(s);
                  _save();
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: PX.red),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _EditResult {
  final Snippet? snippet;
  final bool delete;
  _EditResult(this.snippet, {this.delete = false});
}

class _EditDialog extends StatefulWidget {
  final Snippet? snippet;
  const _EditDialog({this.snippet});

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _name = TextEditingController(text: widget.snippet?.name ?? '');
  late final _cmd = TextEditingController(text: widget.snippet?.command ?? '');
  late bool _run = widget.snippet?.run ?? false;

  @override
  void dispose() {
    _name.dispose();
    _cmd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.snippet == null;
    return AlertDialog(
      title: Text(isNew ? 'New command' : 'Edit command'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: isNew,
            decoration: const InputDecoration(hintText: 'Name, e.g. Restart Jellyfin'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _cmd,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(hintText: 'Command, e.g. docker restart jellyfin'),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _run,
            onChanged: (v) => setState(() => _run = v),
            title: const Text('Run straight away'),
            subtitle: const Text('Off = paste only, so you can check or edit it first',
                style: TextStyle(fontSize: 12, color: PX.muted)),
          ),
        ]),
      ),
      actions: [
        if (!isNew)
          TextButton(
            onPressed: () => Navigator.pop(context, _EditResult(null, delete: true)),
            child: const Text('Delete', style: TextStyle(color: PX.red)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final cmd = _cmd.text.trimRight();
            if (cmd.trim().isEmpty) return;
            final name = _name.text.trim().isEmpty ? cmd.trim().split('\n').first : _name.text.trim();
            Navigator.pop(context, _EditResult(Snippet(name, cmd, run: _run)));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

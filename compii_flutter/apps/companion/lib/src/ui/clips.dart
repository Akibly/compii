import 'dart:async';

import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'thread.dart';
import 'tokens.dart';

/// Clipboard history and snippets: what you copied recently, and text you save
/// to reuse. The history is local, off until turned on, and forgettable.
class ClipsPage extends StatefulWidget {
  const ClipsPage({super.key, required this.core, required this.run, this.focusQuery, this.focusSnippets = false});
  final CoreClient core;
  final Run run;

  /// A search the palette handed over: show these matches, in the right tab.
  final String? focusQuery;
  final bool focusSnippets;
  @override
  State<ClipsPage> createState() => _ClipsPageState();
}

enum _Tab { history, snippets }

class _ClipsPageState extends State<ClipsPage> {
  bool _loadFailed = false;
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>>? _clips;
  List<Map<String, dynamic>>? _snippets;
  _Tab _tab = _Tab.history;
  String _query = '';
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _applyFocus();
    _load();
  }

  @override
  void didUpdateWidget(ClipsPage old) {
    super.didUpdateWidget(old);
    if (widget.focusQuery == old.focusQuery && widget.focusSnippets == old.focusSnippets) return;
    if (widget.focusQuery == null) return;
    _debounce?.cancel();
    setState(_applyFocus);
    _load();
  }

  void _applyFocus() {
    final query = widget.focusQuery;
    if (query == null) return;
    _query = query;
    _search.text = query;
    _tab = widget.focusSnippets ? _Tab.snippets : _Tab.history;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  bool get _on => _status?['enabled'] == true;

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
    final status = await widget.core.clipsStatus();
    final clips = _tab == _Tab.history ? await widget.core.clipItems(q: _query) : _clips;
    final snippets = _tab == _Tab.snippets ? await widget.core.snippets(q: _query) : _snippets;
    if (!mounted) return;
    setState(() {
      _status = status;
      _clips = clips;
      _snippets = snippets;
    });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  Future<void> _set(Map<String, Object?> changes) async {
    await widget.run(() => widget.core.setClips(changes));
    await _load();
  }

  void _tabTo(_Tab next) {
    if (next == _tab) return;
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _tab = next;
      _query = '';
    });
    _load();
  }

  Future<void> _turnOn() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remember what you copy?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Compii keeps a list of the text you copy, so “what was that link?” or “the address I copied '
                  'yesterday” is easy to find again.'),
              SizedBox(height: 12),
              Text('· Everything stays on this PC. Nothing is uploaded.\n'
                  '· Copies made in password managers or private windows are never read.\n'
                  '· Older copies delete themselves, and pinned ones stay.\n'
                  '· Turn it off — or forget everything — whenever you like.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Turn on')),
        ],
      ),
    );
    if (ok == true) await _set({'enabled': true});
  }

  Future<void> _copyClip(Map<String, dynamic> clip) async {
    await widget.run(() => widget.core.copyClip(clip['id'] as int));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied — press Ctrl+V wherever you want it.')),
    );
    await _load();
  }

  Future<void> _pin(Map<String, dynamic> clip) async {
    await widget.run(() => widget.core.pinClip(clip['id'] as int, clip['pinned'] != true));
    await _load();
  }

  Future<void> _forgetOne(Map<String, dynamic> clip) async {
    await widget.run(() => widget.core.forgetClip(clip['id'] as int));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Forgotten.')));
    await _load();
  }

  Future<void> _forgetLastHour() async {
    var deleted = 0;
    await widget.run(() async => deleted = await widget.core.forgetClips(hours: 1));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(deleted == 0 ? 'Nothing was copied in the last hour.' : 'Forgot $deleted ${deleted == 1 ? 'copy' : 'copies'}.'),
    ));
    await _load();
  }

  Future<void> _forgetEverything() async {
    final pinned = _status?['pinned'] as int? ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget every copy?'),
        content: Text('This removes the whole clipboard history. It can’t be undone.'
            '${pinned == 0 ? '' : ' Your $pinned pinned ${pinned == 1 ? 'copy stays' : 'copies stay'} until you unpin or forget them.'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget everything'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    var deleted = 0;
    await widget.run(() async => deleted = await widget.core.forgetClips());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(deleted == 0 ? 'There was nothing left to forget.' : 'Forgot $deleted ${deleted == 1 ? 'copy' : 'copies'}.'),
    ));
    await _load();
  }

  Future<void> _openClip(Map<String, dynamic> clip) async {
    Map<String, dynamic>? found;
    await widget.run(() async => found = await widget.core.clipItem(clip['id'] as int));
    if (!mounted || found == null) return;
    final full = found!;
    final action = await showDialog<String>(
      context: context,
      builder: (context) {
        final c = context.c;
        return AlertDialog(
          title: Row(
            children: [
              GlyphTile(glyph: _glyphFor('${full['kind']}'), size: 36, color: _colorFor(c, '${full['kind']}')),
              const SizedBox(width: 10),
              Expanded(child: Text(_kindName('${full['kind']}'))),
            ],
          ),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_source(full)}${'${full['title']}'.trim().isEmpty ? '' : ' · ${full['title']}'} · ${_ago(full['at'])} · '
                  '${full['copies']}× copied',
                  style: context.type.labelMedium?.copyWith(color: c.muted),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: SingleChildScrollView(
                    child: SelectableText('${full['text']}', style: context.type.bodyMedium),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'forget'),
              child: Text('Forget', style: context.type.labelLarge?.copyWith(color: c.danger)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, 'copy'),
              icon: const Glyph(G.copy, size: 16),
              label: const Text('Copy'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (action == 'copy') await _copyClip(clip);
    if (action == 'forget') await _forgetOne(clip);
  }

  Future<void> _copySnippet(Map<String, dynamic> snippet) async {
    await widget.run(() => widget.core.copySnippet('${snippet['id']}'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('“${snippet['name']}” copied — press Ctrl+V wherever you want it.')),
    );
    await _load();
  }

  Future<void> _showSnippet([Map<String, dynamic>? snippet]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SnippetDialog(
        snippet: snippet,
        save: (name, body) async {
          if (snippet == null) {
            await widget.core.saveSnippet(name, body);
          } else {
            await widget.core.editSnippet('${snippet['id']}', name: name, body: body);
          }
        },
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _deleteSnippet(Map<String, dynamic> snippet) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${snippet['name']}”?'),
        content: const Text('The snippet is removed for good. Copies already in the clipboard history are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.run(() => widget.core.deleteSnippet('${snippet['id']}'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted “${snippet['name']}”.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    return PageScaffold(
      glyph: G.clipboard,
      title: 'Clips',
      subtitle: 'Everything you copy, and the bits of text you use again and again — kept on this PC only.',
      children: [
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (st == null && !_loadFailed)
          const SkeletonCards(rows: 3)
        else if (st != null) ...[
          _statusCard(st),
          const SizedBox(height: 16),
          _tabs(st),
          const SizedBox(height: 20),
          if (_tab == _Tab.history) ..._history(st) else ..._snippetsTab(),
        ],
      ],
    );
  }

  Widget _tabs(Map<String, dynamic> st) {
    final items = st['items'] as int? ?? 0;
    final snippets = st['snippets'] as int? ?? 0;
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<_Tab>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: _Tab.history, icon: const Glyph(G.clipboard, size: 16), label: Text('History ($items)')),
          ButtonSegment(value: _Tab.snippets, icon: const Glyph(G.note, size: 16), label: Text('Snippets ($snippets)')),
        ],
        selected: {_tab},
        onSelectionChanged: (v) => _tabTo(v.first),
      ),
    );
  }

  List<Widget> _history(Map<String, dynamic> st) {
    final anyKept = (st['items'] as int? ?? 0) > 0;
    final clips = _clips;
    if (!_on && !anyKept) return [_privacyPanel()];
    return [
      _searchField('Search what you copied: a link, an address, an invoice number…'),
      const SizedBox(height: 12),
      SectionHeader(
        'Recent copies',
        subtitle: clips == null
            ? null
            : _query.isEmpty
                ? '${clips.length} kept · newest first${_on ? '' : ' · history is off, so new copies are not added'}'
                : '${clips.length} found',
        top: 0,
      ),
      _historyList(clips),
      if (_on) ...[
        const SizedBox(height: 26),
        const SectionHeader('How it keeps things', top: 0),
        _settingsCard(st),
      ],
      const SizedBox(height: 24),
      const SectionHeader('Forget', top: 0),
      _forgetCard(st),
    ];
  }

  List<Widget> _snippetsTab() {
    final snippets = _snippets;
    return [
      _searchField('Search snippets'),
      const SizedBox(height: 12),
      SectionHeader(
        'Saved snippets',
        subtitle: 'Text you save deliberately. Copy one with a click — it’s ready to paste.',
        top: 0,
        trailing: FilledButton.icon(
          onPressed: () => _showSnippet(),
          icon: const Glyph(G.plus, size: 16),
          label: const Text('New snippet'),
        ),
      ),
      _snippetList(snippets),
    ];
  }

  Widget _statusCard(Map<String, dynamic> st) {
    final c = context.c;
    final items = st['items'] as int? ?? 0;
    final pinned = st['pinned'] as int? ?? 0;
    final mb = (st['megabytes'] as num?)?.toDouble() ?? 0;
    final days = (st['keep_days'] as num?)?.toDouble() ?? 7;
    return Panel(
      child: Row(
        children: [
          GlyphTile(glyph: G.clipboard, size: 46, color: _on ? c.success : c.muted),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_on ? 'Remembering copies' : 'Clipboard history is off', style: context.type.titleMedium),
                const SizedBox(height: 3),
                Text(
                  _on
                      ? '$items ${items == 1 ? 'copy' : 'copies'} · $pinned pinned · ${mb.toStringAsFixed(1)} MB. '
                          'Kept for ${_days(days)}, all on this PC.'
                      : 'Compii isn’t reading the clipboard. Turn it on and the last few days of copies become '
                          'searchable — the link, the address, the invoice number.'
                          '${items == 0 ? '' : ' What was already kept is still below, and you can forget it here.'}',
                  style: context.type.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          if (_on)
            Switch(value: true, onChanged: (_) => _set({'enabled': false}))
          else
            FilledButton(onPressed: _turnOn, child: const Text('Turn on')),
        ],
      ),
    );
  }

  Widget _searchField(String hint) => TextField(
        controller: _search,
        onChanged: (v) {
          _query = v;
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 350), _load);
        },
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Padding(padding: EdgeInsets.all(13), child: Glyph(G.search, size: 18)),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Glyph(G.close, size: 16),
                  onPressed: () {
                    _search.clear();
                    _query = '';
                    _debounce?.cancel();
                    _load();
                  },
                ),
        ),
      );

  Widget _historyList(List<Map<String, dynamic>>? clips) {
    if (clips == null) {
      return const SkeletonCards(rows: 3);
    }
    if (clips.isEmpty) {
      return EmptyState(
        glyph: G.clipboard,
        title: _query.isNotEmpty ? 'Nothing matches “$_query”' : 'Nothing copied yet',
        body: _query.isNotEmpty
            ? 'Try fewer words, or search for the app it came from.'
            : _on
                ? 'Copy something anywhere on your PC — Ctrl+C as usual — and it will appear here, newest first.'
                : 'Turn clipboard history on and new copies will appear here.',
      );
    }
    return PanelRows(children: [for (final clip in clips) _historyRow(clip)]);
  }

  Widget _historyRow(Map<String, dynamic> clip) {
    final c = context.c;
    final kind = '${clip['kind']}';
    final pinned = clip['pinned'] == true;
    final copies = clip['copies'] as int? ?? 1;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        onTap: () => _openClip(clip),
        leading: GlyphTile(glyph: _glyphFor(kind), size: 34, color: _colorFor(c, kind)),
        title: Text('${clip['preview']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.bodyMedium),
        subtitle: Wrap(
          spacing: 7,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${_source(clip)} · ${_ago(clip['at'])}${copies > 1 ? ' · copied $copies×' : ''}',
              style: context.type.labelMedium,
            ),
            if (pinned) Pill('Pinned', color: c.accent, glyph: G.bookmark),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RowButton(tooltip: 'Copy again', glyph: G.copy, onTap: () => _copyClip(clip)),
            _RowButton(
              tooltip: pinned ? 'Stop keeping this one' : 'Keep this one',
              glyph: G.bookmark,
              color: pinned ? c.accent : null,
              onTap: () => _pin(clip),
            ),
            _RowButton(tooltip: 'Forget this copy', glyph: G.trash, onTap: () => _forgetOne(clip)),
          ],
        ),
      ),
    );
  }

  Widget _snippetList(List<Map<String, dynamic>>? snippets) {
    if (snippets == null) {
      return const SkeletonCards(rows: 3);
    }
    if (snippets.isEmpty) {
      return EmptyState(
        glyph: G.note,
        title: _query.isNotEmpty ? 'Nothing matches “$_query”' : 'No snippets yet',
        body: _query.isNotEmpty
            ? 'Try a different word, or clear the search to see them all.'
            : 'Save text you use again — a signature, your address, a reply you send often — and copy it with one click.',
        action: _query.isNotEmpty ? null : FilledButton.icon(
          onPressed: () => _showSnippet(),
          icon: const Glyph(G.plus, size: 16),
          label: const Text('New snippet'),
        ),
      );
    }
    return PanelRows(children: [for (final snippet in snippets) _snippetRow(snippet)]);
  }

  Widget _snippetRow(Map<String, dynamic> snippet) {
    final c = context.c;
    final uses = snippet['uses'] as int? ?? 0;
    final body = '${snippet['body'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        onTap: () => _showSnippet(snippet),
        leading: GlyphTile(glyph: G.note, size: 34, color: c.accent),
        title: Text('${snippet['name']}', style: context.type.bodyMedium),
        subtitle: Text(
          '$body${uses == 0 ? '' : '  ·  used $uses×'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.type.labelMedium,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RowButton(tooltip: 'Copy this snippet', glyph: G.copy, onTap: () => _copySnippet(snippet)),
            _RowButton(tooltip: 'Edit', glyph: G.edit, onTap: () => _showSnippet(snippet)),
            _RowButton(tooltip: 'Delete', glyph: G.trash, onTap: () => _deleteSnippet(snippet)),
          ],
        ),
      ),
    );
  }

  Widget _settingsCard(Map<String, dynamic> st) {
    final days = (st['keep_days'] as num?)?.toDouble() ?? 7;
    final maxItems = st['max_items'] as int? ?? 500;
    final items = st['items'] as int? ?? 0;
    final pinned = st['pinned'] as int? ?? 0;
    final mb = (st['megabytes'] as num?)?.toDouble() ?? 0;
    final keeps = ({1.0, 3.0, 7.0, 30.0, days}.toList()..sort());
    final sizes = ({100, 250, 500, 1000, maxItems}.toList()..sort());
    return PanelRows(
      children: [
        OptionRow(
          glyph: G.broom,
          title: 'Keep copies for',
          subtitle: '$items ${items == 1 ? 'copy' : 'copies'} · $pinned pinned · ${mb.toStringAsFixed(1)} MB now. '
              'Pinned copies are never pruned.',
          trailing: DropdownButton<double>(
            value: days,
            underline: const SizedBox.shrink(),
            items: [for (final v in keeps) DropdownMenuItem(value: v, child: Text(_days(v)))],
            onChanged: (v) => v == null ? null : _set({'keep_days': v}),
          ),
        ),
        OptionRow(
          glyph: G.bookmark,
          title: 'History size',
          subtitle: 'The newest copies are kept; older ones fall away.',
          trailing: DropdownButton<int>(
            value: maxItems,
            underline: const SizedBox.shrink(),
            items: [for (final v in sizes) DropdownMenuItem(value: v, child: Text('$v copies'))],
            onChanged: (v) => v == null ? null : _set({'max_items': v}),
          ),
        ),
      ],
    );
  }

  Widget _forgetCard(Map<String, dynamic> st) {
    final c = context.c;
    final any = (st['items'] as int? ?? 0) > 0;
    return PanelRows(
      children: [
        OptionRow(
          glyph: G.trash,
          title: 'Forget the last hour',
          subtitle: 'Removes copies from the last 60 minutes. Pinned copies stay.',
          color: c.muted,
          trailing: OutlinedButton(
            onPressed: any ? _forgetLastHour : null,
            child: const Text('Forget hour'),
          ),
        ),
        OptionRow(
          glyph: G.warning,
          title: 'Forget everything',
          subtitle: 'Deletes the whole history. Pinned copies stay until you unpin or forget them.',
          color: c.danger,
          trailing: OutlinedButton(
            onPressed: any ? _forgetEverything : null,
            child: Text('Forget all', style: context.type.labelLarge?.copyWith(color: c.danger)),
          ),
        ),
      ],
    );
  }

  Widget _privacyPanel() {
    final c = context.c;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What it keeps — and what it never does', style: context.type.titleSmall),
          const SizedBox(height: 12),
          for (final (glyph, title, body) in const [
            (G.lock, 'On this PC only', 'Text you copy is kept in a local list. Nothing is uploaded.'),
            (G.password, 'Password managers skipped', 'A copy made while a password manager or private window is in front is never read.'),
            (G.broom, 'Forgets on its own', 'Older copies delete themselves. Pinned ones stay until you unpin them.'),
            (G.eyeOff, 'Off by default', 'Nothing is watched until you turn it on — and the switch is always here.'),
          ]) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 1), child: Glyph(glyph, size: 17, color: c.muted)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: context.type.bodyMedium),
                        Text(body, style: context.type.bodySmall?.copyWith(color: c.muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: _turnOn,
            icon: const Glyph(G.clipboard, size: 16),
            label: const Text('Turn on clipboard history'),
          ),
        ],
      ),
    );
  }
}

class _RowButton extends StatelessWidget {
  const _RowButton({required this.tooltip, required this.glyph, required this.onTap, this.color});
  final String tooltip;
  final GlyphData glyph;
  final VoidCallback onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        icon: Glyph(glyph, size: 17, color: color ?? context.c.muted),
        onPressed: onTap,
      );
}

class _SnippetDialog extends StatefulWidget {
  const _SnippetDialog({this.snippet, required this.save});
  final Map<String, dynamic>? snippet;
  final Future<void> Function(String name, String body) save;
  @override
  State<_SnippetDialog> createState() => _SnippetDialogState();
}

class _SnippetDialogState extends State<_SnippetDialog> {
  late final _name = TextEditingController(text: '${widget.snippet?['name'] ?? ''}');
  late final _body = TextEditingController(text: '${widget.snippet?['body'] ?? ''}');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final body = _body.text.trim();
    if (name.isEmpty || body.isEmpty) {
      setState(() => _error = 'Give it a name and some text.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(name, body);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      title: Text(widget.snippet == null ? 'New snippet' : 'Edit snippet'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Work signature'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 6,
              maxLines: 12,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(labelText: 'Text', hintText: 'Regards,\nSam'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ---- small helpers ------------------------------------------------------------

GlyphData _glyphFor(String kind) => switch (kind) {
  'link' => G.globe,
  'code' => G.keyboard,
  _ => G.clipboard,
};

Color _colorFor(CompiiColors c, String kind) => switch (kind) {
  'link' => c.accent,
  'code' => c.listen,
  _ => c.muted,
};

String _kindName(String kind) => switch (kind) {
  'link' => 'Link',
  'code' => 'Code',
  _ => 'Copied text',
};

String _source(Map<String, dynamic> clip) {
  final app = '${clip['app'] ?? ''}'.replaceAll(RegExp(r'\.exe$', caseSensitive: false), '').trim();
  return app.isEmpty ? 'this PC' : app;
}

String _ago(dynamic at) {
  final seconds = (at as num?)?.toDouble();
  if (seconds == null) return 'just now';
  final then = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  final diff = DateTime.now().difference(then);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 30) return '${diff.inDays} days ago';
  return '${then.day}/${then.month}/${then.year}';
}

String _days(double days) => days == 1 ? '1 day' : '${days.toInt()} days';

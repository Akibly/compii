import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'reader.dart';
import 'thread.dart' show Run;
import 'tokens.dart';
import 'trust.dart';

/// Skills and connectors from Claude, GPT Actions and MCP servers.
/// Everything lands in quarantine: Compii scans it, the user reads the flags,
/// and only then can it be used.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.run});
  final Run run;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  Map<String, dynamic>? _v;
  bool _loadFailed = false;
  final Set<String> _busy = {};
  final Map<String, bool> _local = {};
  final TextEditingController _query = TextEditingController();
  String _kind = '';
  Map<String, dynamic>? _found;
  bool _looking = false;
  final Set<String> _adding = {};
  final Set<String> _staged = {};

  @override
  void initState() {
    super.initState();
    _load();
    _search(); // an empty box means "show me what is there": the registry's first page
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
      final v = await TrustApi.library();
      if (mounted) setState(() => _v = v);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  Future<void> _search({bool fresh = false}) async {
    final words = _query.text.trim();
    if (words.length == 1) {
      _toast('One letter isn’t enough to search. Clear the box to browse, or type one more.');
      return;
    }
    if (_looking) return;
    setState(() => _looking = true);
    try {
      final found = await TrustApi.catalogSearch(words, kind: _kind, refresh: fresh);
      if (mounted) setState(() => _found = found);
    } on CoreError catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  Future<void> _addFromCatalog(Map<String, dynamic> row) async {
    final id = '${row['id']}';
    if (_adding.contains(id)) return;
    setState(() => _adding.add(id));
    try {
      final v = await TrustApi.catalogAdd(row);
      if (mounted) setState(() => _v = v);
      if (mounted) setState(() => _staged.add(id));
      _toast('“${row['name']}” is in the review list. Nothing works until you approve it.');
    } on CoreError catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _adding.remove(id));
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      await TrustApi.openUrl(url);
    } on CoreError catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _do(String id, Future<Map<String, dynamic>> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await widget.run(() async {
        final v = await action();
        if (mounted) setState(() => _v = v);
      });
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _importFolder() async {
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose the folder that contains SKILL.md');
    } catch (e) {
      _toast('The file picker could not open. $e');
      return;
    }
    final folder = dir;
    if (folder == null) return;
    await _do('import', () => TrustApi.libraryImport(path: folder));
  }

  Future<void> _importFiles() async {
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: 'Choose skills or connector files',
        type: FileType.custom,
        allowedExtensions: const ['md', 'zip', 'json', 'yaml', 'yml'],
      );
    } catch (e) {
      _toast('The file picker could not open. $e');
      return;
    }
    if (files.isEmpty) return;
    var ok = 0;
    String? problem;
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      try {
        final v = await TrustApi.libraryImport(path: path);
        if (mounted) setState(() => _v = v);
        ok++;
      } catch (e) {
        problem ??= e is CoreError ? e.message : '$e';
      }
    }
    if (!mounted) return;
    if (problem == null) {
      _toast('$ok ${ok == 1 ? 'item' : 'items'} added to the review list.');
    } else if (ok == 0) {
      _toast(problem);
    } else {
      _toast('$ok imported. ${files.length - ok} skipped: $problem');
    }
  }

  Future<void> _importLink() async {
    final picked = await showDialog<({String url, bool local})>(
      context: context,
      builder: (_) => const _LinkDialog(),
    );
    if (picked == null) return;
    await _do('import', () => TrustApi.libraryImport(url: picked.url, allowPrivate: picked.local));
  }

  Future<void> _approve(Map<String, dynamic> item) async {
    final id = '${item['id']}';
    final danger = [
      for (final f in item['scan'] as List? ?? const [])
        if (f is Map && f['level'] == 'danger') '${f['what']}'
    ];
    var acknowledge = false;
    if (danger.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _DangerDialog(name: '${item['name']}', flags: danger),
      );
      if (ok != true) return;
      acknowledge = true;
    }
    await _do(id, () => TrustApi.libraryApprove(id, acknowledge: acknowledge, allowPrivate: _local[id] ?? false));
  }

  Future<void> _reject(Map<String, dynamic> item) => _do('${item['id']}', () => TrustApi.libraryReject('${item['id']}'));

  Future<void> _toggle(Map<String, dynamic> item) {
    final id = '${item['id']}';
    return _do(id, () => item['status'] == 'approved' ? TrustApi.libraryDisable(id) : TrustApi.libraryEnable(id));
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove “${item['name']}”?'),
        content: const Text('Compii forgets how to use it, deletes the files it copied, and removes any key it '
            'stored. Nothing outside Compii’s own folder is touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    final id = '${item['id']}';
    await _do(id, () => TrustApi.libraryRemove(id));
  }

  Future<void> _setKey(Map<String, dynamic> item) async {
    final id = '${item['id']}';
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _KeyDialog(name: '${item['name']}'),
    );
    if (value == null || value.trim().isEmpty) return;
    await _do(id, () => TrustApi.librarySetKey(id, value.trim()));
  }

  void _read(Map<String, dynamic> item) {
    final skill = Map<String, dynamic>.from(item['skill'] as Map? ?? const {});
    final body = '${skill['body'] ?? ''}'.trim();
    if (body.isEmpty) return;
    final about = '${item['about'] ?? ''}'.trim();
    showAnswerReader(context, text: body, title: '${item['name']}',
        subtitle: about.isEmpty ? 'Imported procedure' : about);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = _v;
    final items = v == null
        ? <Map<String, dynamic>>[]
        : [for (final x in v['items'] as List) Map<String, dynamic>.from(x as Map)];
    final pending = items.where((i) => i['status'] == 'pending').toList();
    final ready = items.where((i) => i['status'] == 'approved' || i['status'] == 'disabled').toList();
    final rejected = items.where((i) => i['status'] == 'rejected').toList();
    return TrustPage(
      title: 'Library',
      subtitle: 'Skills and connectors made for Claude, GPT and other agents. Compii checks them first, and nothing '
          'runs until you say yes.',
      children: [
        TrustCard(child: _intro(context)),
        const SizedBox(height: 12),
        _discover(context),
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (v == null)
          _loadFailed
              ? const SizedBox.shrink()
              : const Padding(padding: EdgeInsets.only(top: 16), child: SkeletonCards(rows: 3))
        else ...[
          if (pending.isNotEmpty) ...[
            SectionHeader('Waiting for review',
                subtitle:
                    '${pending.length} ${pending.length == 1 ? 'thing' : 'things'} Compii hasn’t turned on yet. Read the flags before approving.',
                top: 20),
            for (final it in pending) ...[
              PendingLibraryCard(
                key: ValueKey(it['id']),
                item: it,
                allowPrivate: _local['${it['id']}'] ?? false,
                onAllowPrivate: it['kind'] == 'connector'
                    ? (on) => setState(() => _local['${it['id']}'] = on)
                    : null,
                onApprove: () => _approve(it),
                onReject: () => _reject(it),
                onRead: () => _read(it),
                onKey: () => _setKey(it),
                busy: _busy.contains(it['id']),
              ),
              const SizedBox(height: 12),
            ],
          ],
          if (ready.isNotEmpty) ...[
            SectionHeader('In Compii',
                subtitle: 'These are live. Turn one off any time; its files and key stay until you remove it.',
                top: 20),
            for (final it in ready) ...[
              ReadyLibraryCard(
                key: ValueKey(it['id']),
                item: it,
                busy: _busy.contains(it['id']),
                onToggle: () => _toggle(it),
                onRemove: () => _remove(it),
                onRead: () => _read(it),
                onKey: () => _setKey(it),
                onClearKey: () => _do('${it['id']}', () => TrustApi.libraryClearKey('${it['id']}')),
              ),
              const SizedBox(height: 12),
            ],
          ],
          if (items.isEmpty) _empty(context, v),
          if (rejected.isNotEmpty) ...[
            SectionHeader('Turned down',
                subtitle: 'Compii deleted their files when you said no. Forget them to clear the record.',
                top: 20),
            TrustCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final (i, it) in rejected.indexed) ...[
                    if (i > 0) Divider(height: 1, color: c.border),
                    ListTile(
                      leading: Glyph(G.close, color: c.faint),
                      title: Text('${it['name']}'),
                      subtitle: Text(_formatName('${it['format']}')),
                      trailing: TextButton(
                        onPressed: () => _do('${it['id']}', () => TrustApi.libraryRemove('${it['id']}')),
                        child: const Text('Forget'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          _finePrint(context),
        ],
      ],
    );
  }

  Widget _intro(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdaptiveRow(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GlyphTile(glyph: G.box, size: 44, color: c.accent),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bring the skills you already have', style: context.type.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    'A Claude skill folder or SKILL.md, a .md procedure, a .zip, a GPT Action (OpenAPI .json/.yaml), '
                    'or a link. Compii copies it into its own folder and scans it before anything is usable.',
                    style: context.type.bodySmall?.copyWith(color: c.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            MenuAnchor(
              builder: (context, controller, _) => FilledButton.icon(
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                icon: const Glyph(G.plus, size: 18),
                label: const Text('Import from this PC'),
              ),
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Glyph(G.folder, size: 18),
                  onPressed: _importFolder,
                  child: const Text('Claude skill folder…'),
                ),
                MenuItemButton(
                  leadingIcon: const Glyph(G.file, size: 18),
                  onPressed: _importFiles,
                  child: const Text('Files (.md, .zip, .json, .yaml)…'),
                ),
              ],
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _importLink,
              icon: const Glyph(G.globe, size: 18),
              label: const Text('From a link…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _discover(BuildContext context) {
    final c = context.c;
    final found = _found;
    final rows = found == null
        ? <Map<String, dynamic>>[]
        : [for (final r in found['results'] as List) Map<String, dynamic>.from(r as Map)];
    final problems = found == null
        ? <Map<String, dynamic>>[]
        : [for (final p in found['problems'] as List) Map<String, dynamic>.from(p as Map)];
    final browse = found == null
        ? <Map<String, dynamic>>[]
        : [for (final b in found['browse'] as List) Map<String, dynamic>.from(b as Map)];
    final notes = found == null
        ? <String>[]
        : [for (final n in found['notes'] as List? ?? const []) '$n'];
    final asked = '${found?['query'] ?? ''}'.trim();
    final browsing = found != null && asked.isEmpty;
    return TrustCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveRow(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphTile(glyph: G.search, size: 44, color: c.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Browse what other people published', style: context.type.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      'Below is the official MCP registry’s current page — no search needed. Compii asks for it when '
                      'this page opens and keeps the answer, so from then on it is here at once. Type a word to ask '
                      'both catalogues, the registry and the skills index. Anything you pick lands in the review list '
                      'below, scanned and switched off — a result is never live until you approve it.',
                      style: context.type.bodySmall?.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SegmentedButton<String>(
                style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: '', label: Text('All')),
                  ButtonSegment(value: 'skill', label: Text('Skills')),
                  ButtonSegment(value: 'connector', label: Text('Connectors')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) {
                  setState(() => _kind = s.first);
                  if (_found != null) _search(); // refiltering what is already on screen
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          AdaptiveRow(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(fresh: true),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'calendar, github, pdf, email…',
                    prefixIcon: const Padding(padding: EdgeInsets.all(13), child: Glyph(G.search, size: 18)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _query,
                builder: (context, value, _) => FilledButton.icon(
                  onPressed: _looking ? null : () => _search(fresh: true),
                  icon: _looking
                      ? const SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Glyph(G.search, size: 18),
                  label: Text(value.text.trim().isEmpty
                      ? 'Browse'
                      : found == null
                          ? 'Search'
                          : 'Search again'),
                ),
              ),
            ],
          ),
          if (_looking && found == null) ...[
            const SizedBox(height: 12),
            AdaptiveRow(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Asking the MCP registry for its first page. Its own network is slow sometimes, so this can take '
                    'half a minute.',
                    style: context.type.bodySmall?.copyWith(color: c.muted),
                  ),
                ),
              ],
            ),
          ],
          if (found != null) ...[
            const SizedBox(height: 14),
            for (final p in problems)
              _FlagRow({'level': 'warn', 'what': '${p['catalogue']} didn’t answer: ${p['problem']}'}),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(n, style: context.type.bodySmall?.copyWith(color: c.muted)),
              ),
            if (rows.isEmpty && problems.length < 2 && !(browsing && _kind == 'skill')) ...[
              const SizedBox(height: 2),
              Text(
                browsing
                    ? 'The registry answered, but its first page was empty. Type a word to search, or open one of the '
                        'catalogues listed above and paste the link in.'
                    : 'Neither catalogue knows “$asked”. Try a plainer word, or look in the places below and '
                        'paste the link in.',
                style: context.type.bodySmall?.copyWith(color: c.muted),
              ),
            ],
            if (browsing && browse.isNotEmpty) ...[
              _places(context, browse),
              const SizedBox(height: 12),
            ],
            if (rows.isNotEmpty) ...[
              Text(
                browsing
                    ? '${rows.length} from the MCP registry’s first page · Compii has not fetched any of them yet'
                    : '${rows.length} ${rows.length == 1 ? 'match' : 'matches'} · Compii has not fetched any of them yet',
                style: context.type.labelMedium,
              ),
              const SizedBox(height: 4),
              for (final (i, row) in rows.indexed) ...[
                if (i > 0) Divider(height: 1, color: c.border),
                CatalogResultCard(
                  row: row,
                  busy: _adding.contains('${row['id']}'),
                  staged: _staged.contains('${row['id']}'),
                  onAdd: () => _addFromCatalog(row),
                  onOpen: () => _openUrl('${row['homepage']}'),
                ),
              ],
            ],
            if (!browsing) ...[
              const SizedBox(height: 10),
              _places(context, browse),
            ],
          ],
        ],
      ),
    );
  }

  Widget _places(BuildContext context, List<Map<String, dynamic>> browse) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('More places to look', style: context.type.labelMedium),
            for (final b in browse)
              TextButton.icon(
                onPressed: () => _openUrl('${b['url']}'),
                icon: const Glyph(G.external, size: 15),
                label: Text('${b['name']}'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
          ],
        ),
        if (browse.isNotEmpty)
          Text(
            'Those open in your browser. When you find one you like, copy its SKILL.md folder, link or server '
            'address back to “From a link”.',
            style: context.type.bodySmall?.copyWith(color: c.muted),
          ),
      ],
    );
  }

  Widget _empty(BuildContext context, Map<String, dynamic> v) {
    final c = context.c;
    final formats = Map<String, dynamic>.from(v['formats'] as Map? ?? const {});
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: TrustCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Nothing imported yet', style: context.type.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Compii can read and follow these, and every one is checked before it can do anything. Or search the '
              'catalogues above for something people already published:',
              style: context.type.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final entry in formats.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Glyph(_formatIcon(entry.key), size: 18, color: c.accent),
                    const SizedBox(width: 10),
                    Expanded(child: Text(entry.value, style: context.type.bodyMedium)),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Claude skills keep their reference files next to the procedure. OpenAPI connectors and remote MCP servers '
              'become tools with the same approval rules as everything else.',
              style: context.type.bodySmall?.copyWith(color: c.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _finePrint(BuildContext context) {
    final c = context.c;
    return TrustCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlyphTile(glyph: G.lock, size: 34, color: c.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Imported code is reference only: Compii reads it when a procedure mentions it, and never runs it by '
              'itself. Connector keys live in Windows Credential Manager and are never shown again. Sends, payments '
              'and deletes always ask first, whatever a skill or connector says.',
              style: context.type.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ---- cards -------------------------------------------------------------------

/// One result from a public catalogue: what it is, and whether Compii can take it.
class CatalogResultCard extends StatelessWidget {
  const CatalogResultCard({
    super.key,
    required this.row,
    required this.busy,
    required this.staged,
    this.onAdd,
    this.onOpen,
  });
  final Map<String, dynamic> row;
  final bool busy;
  final bool staged;
  final VoidCallback? onAdd;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isSkill = row['kind'] == 'skill';
    final addable = row['addable'] == true;
    final about = '${row['about'] ?? ''}'.trim();
    final detail = '${row['detail'] ?? ''}'.trim();
    final why = '${row['why'] ?? ''}'.trim();
    final homepage = '${row['homepage'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 11, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Glyph(isSkill ? G.skill : G.globe, size: 19, color: addable ? c.accent : c.faint),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${row['name']}', style: context.type.titleSmall),
                if (about.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(about, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Tag('${row['catalogue']}', c.muted, c.sunken),
                    if (detail.isNotEmpty) _Tag(detail, c.muted, c.sunken),
                    if (row['needs_key'] == true) _Tag('Wants a key', c.warning, c.warningSoft, icon: G.key),
                  ],
                ),
                if (why.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(why, style: context.type.bodySmall?.copyWith(color: c.muted)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (staged)
                _Tag('In the review list', c.success, c.successSoft, icon: G.checkCircle)
              else if (addable)
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onAdd,
                  icon: busy
                      ? const SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Glyph(G.download, size: 17),
                  label: const Text('Add'),
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              if (homepage.isNotEmpty)
                IconButton(
                  tooltip: 'Open its page in your browser',
                  visualDensity: VisualDensity.compact,
                  onPressed: onOpen,
                  icon: const Glyph(G.external, size: 16),
                  color: c.muted,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class PendingLibraryCard extends StatelessWidget {
  const PendingLibraryCard({
    super.key,
    required this.item,
    this.allowPrivate = false,
    this.onAllowPrivate,
    this.onApprove,
    this.onReject,
    this.onRead,
    this.onKey,
    this.busy = false,
  });
  final Map<String, dynamic> item;
  final bool allowPrivate;
  final ValueChanged<bool>? onAllowPrivate;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onRead;
  final VoidCallback? onKey;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final flags = [
      for (final f in item['scan'] as List? ?? const [])
        if (f is Map) Map<String, dynamic>.from(f)
    ];
    final danger = flags.any((f) => f['level'] == 'danger');
    final skill = Map<String, dynamic>.from(item['skill'] as Map? ?? const {});
    final body = '${skill['body'] ?? ''}'.trim();
    final files = [for (final f in item['files'] as List? ?? const []) '$f'];
    final connector = Map<String, dynamic>.from(item['connector'] as Map? ?? const {});
    final tools = [
      for (final t in connector['tools'] as List? ?? const [])
        if (t is Map) '${t['name']}'
    ];
    final isConnector = item['kind'] == 'connector';
    final auth = Map<String, dynamic>.from(connector['auth'] as Map? ?? const {});
    final wantsKey = isConnector &&
        item['has_secret'] != true &&
        const ['bearer', 'basic', 'apiKey'].contains('${auth['scheme'] ?? ''}');
    final wantsLocal = isConnector &&
        flags.any((f) =>
            '${f['what']}'.contains('local network') || '${f['what']}'.toLowerCase().contains('plain http'));
    final host = Uri.tryParse('${connector['url'] ?? ''}')?.host ?? '';
    return TrustCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveRow(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphTile(glyph: _formatIcon('${item['format']}'), size: 40, color: danger ? c.warning : c.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${item['name']}', style: context.type.titleMedium),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _Tag(_formatName('${item['format']}'), c.accent, c.accentSoft),
                        if (tools.isNotEmpty) _Tag('${tools.length} tools', c.muted, c.sunken),
                        if ('${item['source'] ?? ''}'.isNotEmpty)
                          _Tag(_sourceName('${item['source']}'), c.muted, c.sunken),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if ('${item['about'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('${item['about']}', style: context.type.bodySmall),
          ],
          const SizedBox(height: 6),
          for (final flag in flags) _FlagRow(flag),
          if (wantsLocal && onAllowPrivate != null) ...[
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: allowPrivate,
              onChanged: busy ? null : onAllowPrivate,
              title: const Text('Allow this server on my own network'),
              subtitle: Text(
                host.isEmpty
                    ? 'Only turn this on for a server you run yourself.'
                    : '$host is on your own network or the address is not encrypted. Turn this on only if you run that server.',
              ),
            ),
          ],
          if (wantsKey) ...[
            const SizedBox(height: 6),
            AdaptiveRow(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Glyph(G.key, size: 16, color: c.warning),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This one asks for a key before it can answer. Add it now or after you approve — Compii '
                          'keeps it in Windows Credential Manager either way.',
                          style: context.type.bodySmall?.copyWith(color: c.muted),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onKey,
                  icon: const Glyph(G.key, size: 17),
                  label: const Text('Add key'),
                ),
              ],
            ),
          ],
          if (body.isNotEmpty) ...[
            const SizedBox(height: 8),
            AdaptiveRow(
              children: [
                Expanded(
                  child: Text(
                    'Imported procedure · ${body.length} characters${skill['truncated'] == true ? ' (shortened)' : ''}',
                    style: context.type.bodySmall?.copyWith(color: c.muted),
                  ),
                ),
                TextButton.icon(
                  onPressed: onRead,
                  icon: const Glyph(G.doc, size: 17),
                  label: const Text('Read it'),
                ),
              ],
            ),
          ],
          if (files.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Files kept with it', style: context.type.labelMedium),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in files.take(10)) _Tag(f, c.muted, c.sunken),
                if (files.length > 10) _Tag('+ ${files.length - 10} more', c.muted, c.sunken),
              ],
            ),
          ],
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Tools it brings', style: context.type.labelMedium),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in tools.take(8)) _Tag(t, c.muted, c.sunken),
                if (tools.length > 8) _Tag('+ ${tools.length - 8} more', c.muted, c.sunken),
              ],
            ),
            const SizedBox(height: 4),
            Text('Anything that sends, pays or deletes still asks first.',
                style: context.type.bodySmall?.copyWith(color: c.muted)),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                style: danger
                    ? FilledButton.styleFrom(backgroundColor: c.warning, foregroundColor: Colors.black87)
                    : null,
                onPressed: busy ? null : onApprove,
                icon: busy
                    ? const SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Glyph(G.check, size: 18),
                label: Text(danger ? 'Approve anyway' : 'Approve'),
              ),
              OutlinedButton(onPressed: busy ? null : onReject, child: const Text('Turn down')),
            ],
          ),
        ],
      ),
    );
  }
}

class ReadyLibraryCard extends StatelessWidget {
  const ReadyLibraryCard({
    super.key,
    required this.item,
    this.onToggle,
    this.onRemove,
    this.onRead,
    this.onKey,
    this.onClearKey,
    this.busy = false,
  });
  final Map<String, dynamic> item;
  final VoidCallback? onToggle;
  final VoidCallback? onRemove;
  final VoidCallback? onRead;
  final VoidCallback? onKey;
  final VoidCallback? onClearKey;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = item['status'] == 'approved';
    final isConnector = item['kind'] == 'connector';
    final hasKey = item['has_secret'] == true;
    final skill = Map<String, dynamic>.from(item['skill'] as Map? ?? const {});
    final body = '${skill['body'] ?? ''}'.trim();
    final tools = [for (final t in item['tool_names'] as List? ?? const []) '$t'];
    final instruction = '${skill['instruction'] ?? ''}'.trim();
    return TrustCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveRow(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphTile(glyph: _formatIcon('${item['format']}'), size: 40, color: on ? c.accent : c.faint),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${item['name']}', style: context.type.titleMedium),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _Tag(_formatName('${item['format']}'), c.accent, c.accentSoft),
                        _Tag(on ? 'On' : 'Off', on ? c.success : c.muted, c.sunken,
                            icon: on ? G.checkCircle : G.stop),
                        if (isConnector) _Tag(hasKey ? 'Key saved' : 'No key yet', hasKey ? c.success : c.warning,
                            c.sunken, icon: hasKey ? G.key : G.warning),
                        if (tools.isNotEmpty) _Tag('${tools.length} tools', c.muted, c.sunken),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (instruction.isNotEmpty) ...[
            const SizedBox(height: 9),
            Text(instruction, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
          ],
          if (body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Reference files stay in Compii’s library folder. Compii reads them when the procedure calls for it.',
              style: context.type.bodySmall?.copyWith(color: c.muted),
            ),
          ],
          if (isConnector && tools.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Tools in Compii', style: context.type.labelMedium),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in tools.take(8)) _Tag(t, c.muted, c.sunken),
                if (tools.length > 8) _Tag('+ ${tools.length - 8} more', c.muted, c.sunken),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              busy
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: onToggle,
                      icon: Glyph(on ? G.stop : G.play, size: 17),
                      label: Text(on ? 'Turn off' : 'Turn on'),
                    ),
              if (body.isNotEmpty)
                TextButton.icon(onPressed: onRead, icon: const Glyph(G.doc, size: 17), label: const Text('Read')),
              if (isConnector)
                TextButton.icon(
                  onPressed: onKey,
                  icon: const Glyph(G.key, size: 17),
                  label: Text(hasKey ? 'Replace key' : 'Add key'),
                ),
              if (isConnector && hasKey)
                TextButton(onPressed: onClearKey, child: const Text('Remove key')),
              TextButton(
                onPressed: onRemove,
                style: TextButton.styleFrom(foregroundColor: c.danger),
                child: const Text('Remove'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- small pieces ------------------------------------------------------------

class _FlagRow extends StatelessWidget {
  const _FlagRow(this.flag);
  final Map<String, dynamic> flag;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (icon, color) = switch ('${flag['level']}') {
      'danger' => (G.shieldAlert, c.danger),
      'warn' => (G.warning, c.warning),
      _ => (G.checkCircle, c.success),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Glyph(icon, size: 16, color: color)),
          const SizedBox(width: 8),
          Expanded(child: Text('${flag['what']}', style: context.type.bodySmall)),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.fg, this.bg, {this.icon});
  final String text;
  final Color fg;
  final Color bg;
  final GlyphData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: Shapes.pill),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Glyph(icon!, size: 13, color: fg), const SizedBox(width: 4)],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
}

String _formatName(String format) => switch (format) {
      'claude-skill' => 'Claude skill',
      'markdown' => 'Markdown skill',
      'openapi' => 'OpenAPI connector',
      'mcp' => 'MCP server',
      _ => format,
    };

GlyphData _formatIcon(String format) => switch (format) {
      'claude-skill' => G.folder,
      'markdown' => G.doc,
      'openapi' => G.globe,
      'mcp' => G.box,
      _ => G.box,
    };

String _sourceName(String source) {
  final uri = Uri.tryParse(source);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) return uri.host;
  final parts = source.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? source : parts.last;
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog();
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _url = TextEditingController();
  bool _local = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  bool get _ok {
    final u = _url.text.trim();
    return u.startsWith('https://') || u.startsWith('http://');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      title: const Text('Import from a link'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A SKILL.md, a .md or .zip, an OpenAPI spec, or a remote MCP server address.',
                style: context.type.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Link',
                hintText: 'https://…',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _local,
              onChanged: (on) => setState(() => _local = on),
              title: const Text('It’s on my own network or this PC'),
              subtitle: Text(
                _local
                    ? 'Plain http and private addresses are allowed for this import.'
                    : 'Only https addresses are accepted.',
                style: context.type.bodySmall?.copyWith(color: c.muted),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _ok
              ? () => Navigator.pop(context, (url: _url.text.trim(), local: _local))
              : null,
          child: const Text('Import'),
        ),
      ],
    );
  }
}

class _DangerDialog extends StatelessWidget {
  const _DangerDialog({required this.name, required this.flags});
  final String name;
  final List<String> flags;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      icon: Glyph(G.shieldAlert, size: 30, color: c.danger),
      title: Text('“$name” has serious warnings'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Compii’s scan found things that could trick it or reach private data. Only approve if you trust where '
              'this came from and understand what it does.',
              style: context.type.bodySmall,
            ),
            const SizedBox(height: 10),
            for (final f in flags) _FlagRow({'level': 'danger', 'what': f}),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.warning, foregroundColor: Colors.black87),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Approve anyway'),
        ),
      ],
    );
  }
}

class _KeyDialog extends StatefulWidget {
  const _KeyDialog({required this.name});
  final String name;
  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _key = TextEditingController();
  bool _reveal = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Key for ${widget.name}'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Stored only in Windows Credential Manager. Compii never shows it again, and never sends it anywhere '
                'except this connector’s own server.',
                style: context.type.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _key,
                autofocus: true,
                obscureText: !_reveal,
                enableSuggestions: false,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'API key or token',
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: _reveal ? 'Hide' : 'Show',
                    icon: Glyph(_reveal ? G.eyeOff : G.eye, size: 18),
                    onPressed: () => setState(() => _reveal = !_reveal),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _key.text.trim().isEmpty ? null : () => Navigator.pop(context, _key.text),
            child: const Text('Save key'),
          ),
        ],
      );
}

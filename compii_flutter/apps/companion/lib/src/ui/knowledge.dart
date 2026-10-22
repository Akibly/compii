import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'thread.dart' show Run;
import 'tokens.dart';
import 'trust.dart';

/// Knowledge: folders the user chooses, indexed and searched on this PC, so
/// Compii can answer from their own documents and cite the file.
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key, required this.run});
  final Run run;
  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  Map<String, dynamic>? _v;
  bool _loadFailed = false;
  bool _busy = false;
  bool _searching = false;
  String? _searchError;
  List<Map<String, dynamic>>? _hits;
  String _query = '';
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
      final v = await TrustApi.knowledge();
      if (mounted) setState(() => _v = v);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  Future<void> _addFolder() async {
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder Compii can search');
    } catch (e) {
      _toast('The file picker could not open. $e');
      return;
    }
    final folder = dir;
    if (folder == null || !mounted) return;
    setState(() => _busy = true);
    await widget.run(() async {
      final added = await TrustApi.knowledgeAddFolder(folder);
      if (mounted) setState(() => _v = added);
      final v = await TrustApi.knowledgeRefresh(folder);
      if (!mounted) return;
      setState(() => _v = v);
      _toast(_indexedLine(v));
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _refresh([String folder = '']) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.run(() async {
      final v = await TrustApi.knowledgeRefresh(folder);
      if (!mounted) return;
      setState(() => _v = v);
      _toast(_indexedLine(v));
    });
    if (mounted) setState(() => _busy = false);
  }

  String _indexedLine(Map<String, dynamic> v) {
    final last = Map<String, dynamic>.from(v['last'] as Map? ?? const {});
    final indexed = last['indexed'] ?? 0;
    final skipped = last['skipped'] ?? 0;
    final seconds = last['seconds'] ?? 0;
    final head = 'Indexed $indexed ${indexed == 1 ? 'file' : 'files'} in ${seconds}s.';
    return skipped == 0 ? head : '$head $skipped skipped.';
  }

  Future<void> _remove(Map<String, dynamic> folder) async {
    final path = '${folder['path']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove “${folder['name']}”?'),
        content: const Text('Compii deletes everything it indexed from that folder. Your files are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.run(() async {
      final v = await TrustApi.knowledgeRemoveFolder(path);
      if (!mounted) return;
      setState(() {
        _v = v;
        _hits = null;
      });
      if (_search.text.trim().isNotEmpty) _runSearch(_search.text);
    });
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    final q = text.trim();
    setState(() {
      _query = q;
      _searchError = null;
      if (q.isEmpty) _hits = null;
    });
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 280), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searching = true);
    try {
      final hits = await TrustApi.knowledgeSearch(q);
      if (!mounted || _search.text.trim() != q) return;
      setState(() {
        _hits = hits;
        _searchError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _searchError = e is CoreError ? e.message : '$e');
    } finally {
      if (mounted && _search.text.trim() == q) setState(() => _searching = false);
    }
  }

  void _copy(String path) {
    Clipboard.setData(ClipboardData(text: path));
    _toast('File path copied.');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = _v;
    final folders = v == null
        ? <Map<String, dynamic>>[]
        : [for (final f in v['folders'] as List) Map<String, dynamic>.from(f as Map)];
    return TrustPage(
      title: 'Knowledge',
      subtitle: 'Point Compii at your own folders. It searches them on this PC and always cites the file it used.',
      children: [
        TrustCard(child: _intro(context, v)),
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (v == null)
          _loadFailed
              ? const SizedBox.shrink()
              : const Padding(padding: EdgeInsets.only(top: 16), child: SkeletonCards(rows: 2))
        else ...[
          const SizedBox(height: 18),
          SectionHeader('Folders',
              subtitle: folders.isEmpty
                  ? 'None yet. Add the folder you keep notes, contracts or research in.'
                  : '${folders.length} ${folders.length == 1 ? 'folder' : 'folders'}, '
                      '${v['files']} files indexed.'),
          if (folders.isEmpty)
            TrustCard(child: _empty(context))
          else
            for (final f in folders) ...[
              KnowledgeFolderCard(
                key: ValueKey(f['path']),
                folder: f,
                busy: _busy,
                onRefresh: () => _refresh('${f['path']}'),
                onRemove: () => _remove(f),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 18),
          SectionHeader('Search your files',
              subtitle: 'This is the same index Compii uses while you chat. Try a phrase you remember.'),
          TextField(
            controller: _search,
            onChanged: _onQuery,
            decoration: InputDecoration(
              hintText: 'e.g. cancellation deadline, invoice total, what the contract says about renewals',
              prefixIcon: const Padding(padding: EdgeInsets.only(left: 4), child: Glyph(G.search, size: 18)),
              suffixIcon: _searching
                  ? const Padding(padding: EdgeInsets.all(14), child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          onPressed: () {
                            _search.clear();
                            _onQuery('');
                          },
                          icon: const Glyph(G.close, size: 16),
                        ),
            ),
          ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_searchError!, style: context.type.bodySmall?.copyWith(color: c.danger)),
            ),
          if (_hits != null) ...[
            const SizedBox(height: 12),
            if (_hits!.isEmpty)
              TrustCard(
                child: Text('Nothing matches “$_query”. Try fewer words, or refresh a folder if you changed files.',
                    style: context.type.bodySmall),
              )
            else ...[
              Text('${_hits!.length} ${_hits!.length == 1 ? 'passage' : 'passages'} from '
                  '${_hits!.map((h) => h['path']).toSet().length} files',
                  style: context.type.labelMedium),
              const SizedBox(height: 8),
              for (final h in _hits!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: KnowledgeHitCard(hit: h, onCopy: () => _copy('${h['path']}')),
                ),
            ],
          ],
          const SizedBox(height: 20),
          _privacy(context),
        ],
      ],
    );
  }

  Widget _intro(BuildContext context, Map<String, dynamic>? v) {
    final c = context.c;
    final empty = (v?['folders'] as List? ?? const []).isEmpty;
    return Column(
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
                  Text('Ask your own files', style: context.type.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    'Add notes, contracts, PDFs, Word or Excel folders. Compii indexes the words once, then answers '
                    'from them while you chat — with the file path, so you can check every claim.',
                    style: context.type.bodySmall?.copyWith(color: c.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        AdaptiveRow(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _addFolder,
              icon: const Glyph(G.folder, size: 18),
              label: const Text('Add a folder'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _busy || v == null || (v['folders'] as List).isEmpty ? null : () => _refresh(),
              icon: const Glyph(G.sync, size: 17),
              label: const Text('Refresh all'),
            ),
            if (_busy) ...[
              const SizedBox(width: 14),
              const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Indexing — large folders can take a moment.', style: context.type.bodySmall),
              ),
            ] else if (empty)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Text('Nothing leaves this PC.', style: context.type.bodySmall?.copyWith(color: c.faint)),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        Glyph(G.doc, size: 22, color: c.faint),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Text, Markdown, PDF, Word (.docx), Excel (.xlsx), CSV, JSON and code files are supported. '
            'Password stores, private keys and .env files are always skipped.',
            style: context.type.bodySmall?.copyWith(color: c.muted),
          ),
        ),
      ],
    );
  }

  Widget _privacy(BuildContext context) {
    final c = context.c;
    return TrustCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveRow(
            children: [
              Glyph(G.shield, size: 18, color: c.success),
              const SizedBox(width: 8),
              Text('What Compii keeps', style: context.type.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Only the text, in a database in Compii’s own folder on this PC. Files are never copied or uploaded, '
            'and their words are sent to the AI only when a question needs them — the same as any other text you '
            'ask about. Remove a folder to delete its index immediately.',
            style: context.type.bodySmall?.copyWith(color: c.muted),
          ),
        ],
      ),
    );
  }
}

/// One indexed folder: what is inside, when it was refreshed, and its controls.
class KnowledgeFolderCard extends StatelessWidget {
  const KnowledgeFolderCard({
    super.key,
    required this.folder,
    required this.onRefresh,
    required this.onRemove,
    this.busy = false,
  });
  final Map<String, dynamic> folder;
  final VoidCallback onRefresh;
  final VoidCallback onRemove;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final files = folder['files'] as int? ?? 0;
    final chars = folder['chars'] as int? ?? 0;
    final exists = folder['exists'] == true;
    return TrustCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Row(
        children: [
          GlyphTile(glyph: G.folder, size: 38, color: exists ? c.accent : c.faint),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${folder['name']}', style: context.type.titleSmall),
                const SizedBox(height: 2),
                Text(
                  '${folder['path']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.bodySmall?.copyWith(
                    color: c.faint,
                    fontFamily: 'Cascadia Mono',
                    fontFamilyFallback: const ['Consolas'],
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  exists
                      ? '$files ${files == 1 ? 'file' : 'files'} · ${_size(chars)} · ${_ago(folder['updated'])}'
                      : 'This folder is no longer there. Remove it, or plug the drive back in and refresh.',
                  style: context.type.bodySmall?.copyWith(color: exists ? c.muted : c.warning),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: busy ? null : onRefresh,
            icon: const Glyph(G.sync, size: 15),
            label: const Text('Refresh'),
          ),
          IconButton(
            tooltip: 'Remove from Knowledge',
            onPressed: busy ? null : onRemove,
            icon: const Glyph(G.broom, size: 18),
          ),
        ],
      ),
    );
  }

  static String _size(int chars) => chars >= 1000000
      ? '${(chars / 1000000).toStringAsFixed(1)}M characters'
      : chars >= 1000
          ? '${(chars / 1000).round()}k characters'
          : '$chars characters';

  static String _ago(Object? at) {
    final seconds = (at as num?)?.toDouble() ?? 0;
    if (seconds <= 0) return 'not indexed yet';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round()));
    if (d.inMinutes < 1) return 'refreshed just now';
    if (d.inHours < 1) return 'refreshed ${d.inMinutes} min ago';
    if (d.inDays < 1) return 'refreshed ${d.inHours} h ago';
    return 'refreshed ${d.inDays} d ago';
  }
}

/// One passage found in the user's files, with the path it came from.
class KnowledgeHitCard extends StatelessWidget {
  const KnowledgeHitCard({super.key, required this.hit, this.onCopy});
  final Map<String, dynamic> hit;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TrustCard(
      padding: const EdgeInsets.fromLTRB(16, 13, 8, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Glyph(G.doc, size: 17, color: c.faint),
              const SizedBox(width: 8),
              Expanded(child: Text('${hit['title']}', style: context.type.titleSmall)),
              if ((hit['part'] as int? ?? 1) > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Pill('part ${hit['part']}', color: c.muted),
                ),
              IconButton(
                tooltip: 'Copy file path',
                onPressed: onCopy,
                icon: const Glyph(G.clipboard, size: 16),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 25, right: 8, bottom: 6),
            child: Text(
              '${hit['path']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.bodySmall?.copyWith(
                color: c.faint,
                fontFamily: 'Cascadia Mono',
                fontFamilyFallback: const ['Consolas'],
                fontSize: 11.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 25, right: 8),
            child: Text('${hit['excerpt']}', style: context.type.bodySmall),
          ),
        ],
      ),
    );
  }
}

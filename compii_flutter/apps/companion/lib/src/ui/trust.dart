import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'thread.dart' show Run;
import 'tokens.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'teach.dart' show showTeachDialog;

/// Calls to Compii Core on this PC for the brain, safety and skills screens.
/// Uses this PC's token, so key changes, "Always allow" and lifting the kill
/// switch work only here, never from a phone.
class TrustApi {
  static final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  static Future<dynamic> call(String method, String path, [Object? body]) async {
    final String token;
    final HttpClientRequest req;
    try {
      token = (await CoreClient.tokenFile().readAsString()).trim();
      req = await _http.openUrl(method, Uri.parse('http://127.0.0.1:8765$path'));
    } on IOException {
      throw CoreError('Compii Core isn’t reachable right now. It reconnects by itself once Core is running.');
    }
    req.headers.set('X-Compii-Token', token);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      String detail = 'Compii Core couldn’t do that (error ${res.statusCode}).';
      try {
        final d = jsonDecode(text);
        if (d is Map && d['detail'] is String) detail = d['detail'] as String;
      } catch (_) {}
      throw CoreError(detail);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  static Future<Map<String, dynamic>> map(String method, String path, [Object? body]) async =>
      Map<String, dynamic>.from(await call(method, path, body) as Map);

  /// Kill switch: stop everything now; every action asks until lifted on this PC.
  static Future<void> kill() => call('POST', '/killswitch');
  static Future<void> lift() => call('DELETE', '/killswitch');
  static Future<void> alwaysAllow(String approvalId) =>
      call('POST', '/approvals/$approvalId', {'approved': true, 'always': true});
  static Future<Map<String, dynamic>> saveSkill(String taskId, [String name = '', String about = '']) =>
      map('POST', '/tasks/$taskId/skill', {'name': name, 'about': about});
  static Future<Map<String, dynamic>> draftSkill(String taskId) => map('POST', '/tasks/$taskId/skill/draft');

  // Library: imported skills and connectors, reviewed before anything goes live.
  static Future<Map<String, dynamic>> library() => map('GET', '/library');

  /// Public catalogues: the official MCP registry and the skills index.
  static Future<Map<String, dynamic>> catalogSearch(String query, {String kind = ''}) => map(
      'GET',
      '/library/catalog?q=${Uri.encodeQueryComponent(query)}${kind.isEmpty ? '' : '&kind=$kind'}');
  static Future<Map<String, dynamic>> catalogAdd(Map<String, dynamic> entry) =>
      map('POST', '/library/catalog/add', {'entry': entry});
  static Future<Map<String, dynamic>> libraryImport({String path = '', String url = '', bool allowPrivate = false}) =>
      map('POST', '/library/import', {'path': path, 'url': url, 'allow_private': allowPrivate});
  static Future<Map<String, dynamic>> libraryApprove(String id,
          {bool acknowledge = false, bool allowPrivate = false, String name = ''}) =>
      map('POST', '/library/$id/approve',
          {'acknowledge': acknowledge, 'allow_private': allowPrivate, 'name': name});
  static Future<Map<String, dynamic>> libraryReject(String id) => map('POST', '/library/$id/reject');
  static Future<Map<String, dynamic>> libraryEnable(String id) => map('POST', '/library/$id/enable');
  static Future<Map<String, dynamic>> libraryDisable(String id) => map('POST', '/library/$id/disable');
  static Future<Map<String, dynamic>> libraryRemove(String id) => map('DELETE', '/library/$id');
  static Future<Map<String, dynamic>> librarySetKey(String id, String value) =>
      map('POST', '/library/$id/secret', {'value': value});
  static Future<Map<String, dynamic>> libraryClearKey(String id) => map('DELETE', '/library/$id/secret');

  /// Open a link Compii showed the user in their own browser.
  static Future<void> openUrl(String url) => call('POST', '/open_url', {'path': url});

  // Knowledge: the user's own folders, indexed and searched on this PC.
  static Future<Map<String, dynamic>> knowledge() => map('GET', '/knowledge');
  static Future<Map<String, dynamic>> knowledgeAddFolder(String path) =>
      map('POST', '/knowledge/folders', {'path': path});
  static Future<Map<String, dynamic>> knowledgeRemoveFolder(String path) =>
      map('DELETE', '/knowledge/folders?path=${Uri.encodeQueryComponent(path)}');
  static Future<Map<String, dynamic>> knowledgeRefresh([String folder = '']) => map(
      'POST', '/knowledge/refresh${folder.isEmpty ? '' : '?folder=${Uri.encodeQueryComponent(folder)}'}');
  static Future<List<Map<String, dynamic>>> knowledgeSearch(String query) async {
    final v = await map('GET', '/knowledge/search?q=${Uri.encodeQueryComponent(query)}');
    return [for (final r in v['results'] as List) Map<String, dynamic>.from(r as Map)];
  }

  // Research: what this PC can look up outside, and the two switches that guard it.
  static Future<Map<String, dynamic>> research({bool probe = false}) =>
      map('GET', '/research${probe ? '?probe=true' : ''}');
  static Future<Map<String, dynamic>> researchSet({bool? enabled, bool? browserSession}) =>
      map('PUT', '/research', {'enabled': ?enabled, 'browser_session': ?browserSession});

  // Usage: what answering has cost on this PC, counted from what each provider reported.
  static Future<Map<String, dynamic>> usage({int days = 7}) => map('GET', '/usage?days=$days');

  // Teaching by demonstration. Local only: it reads this PC's screen.
  static Future<Map<String, dynamic>> teachStatus() => map('GET', '/teach');
  static Future<Map<String, dynamic>> teachStart([String goal = '']) =>
      map('POST', '/teach/start', {'goal': goal});
  static Future<Map<String, dynamic>> teachStop() => map('POST', '/teach/stop');
  static Future<void> teachCancel() => call('POST', '/teach/cancel');
  static Future<Map<String, dynamic>> teachCheck({List<int>? keep}) =>
      map('POST', '/teach/check', {'keep': ?keep});
  static Future<Map<String, dynamic>> teachSave({
    required String name,
    String about = '',
    Map<String, Object?>? schedule,
    String? botId,
    List<int>? keep,
    List<String>? steps,
  }) =>
      map('POST', '/teach/save', {
        'name': name,
        'about': about,
        'schedule': ?schedule,
        'bot_id': ?botId,
        'keep': ?keep,
        'steps': ?steps,
      });
}

// ---- shared bits ----------------------------------------------------------------

class TrustPage extends StatelessWidget {
  const TrustPage({super.key, required this.title, required this.subtitle, required this.children});
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => PageScaffold(
    glyph: pageGlyph(title),
    title: title,
    subtitle: subtitle,
    children: children,
  );
}

class TrustCard extends StatelessWidget {
  const TrustCard({super.key, required this.child, this.padding = const EdgeInsets.all(18)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Panel(padding: padding, child: child);
}

Widget _chip(BuildContext context, String text, Color fg, Color bg, {GlyphData? icon}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
  decoration: BoxDecoration(color: bg, borderRadius: Shapes.pill),
  child: AdaptiveRow(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) ...[Glyph(icon, size: 14, color: fg), const SizedBox(width: 4)],
      Text(text, style: context.type.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
    ],
  ),
);

String _ago(num? at) {
  if (at == null) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((at * 1000).round()));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

// ---- Brain: which AI thinks, and its keys ------------------------------------------

/// Settings card: Claude, a free local model (Ollama, LM Studio) or another
/// OpenAI-compatible service; write-only keys; a test; an opt-in backup.
class BrainCard extends StatefulWidget {
  const BrainCard({super.key, required this.run});
  final Run run;
  @override
  State<BrainCard> createState() => _BrainCardState();
}

class _BrainCardState extends State<BrainCard> {
  Map<String, dynamic>? _v;
  String _provider = 'claude';
  final _model = TextEditingController();
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _fallback = false;
  String _fallbackProvider = 'claude';
  List<String> _local = [];
  bool? _localRunning;
  bool _loadFailed = false;
  bool _modelsFailed = false;
  bool _testing = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _model.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
      final v = await TrustApi.map('GET', '/brain');
      if (!mounted) return;
      _apply(v);
      await _findLocal();
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  void _apply(Map<String, dynamic> v) {
    final s = Map<String, dynamic>.from(v['settings'] as Map);
    final p = Map<String, dynamic>.from(s['primary'] as Map);
    setState(() {
      _v = v;
      _provider = p['provider'] as String? ?? 'claude';
      final presets = Map<String, dynamic>.from(v['presets'] as Map? ?? {});
      final model = p['model'] as String? ?? '';
      _model.text = model.isNotEmpty ? model : '${(presets[_provider] as Map?)?['model'] ?? ''}';
      _url.text = p['base_url'] as String? ?? '';
      _fallback = s['fallback_enabled'] == true;
      final fb = s['fallback'] as Map?;
      if (fb != null) _fallbackProvider = fb['provider'] as String? ?? 'claude';
      _loadFailed = false;
      _dirty = false;
    });
  }

  Map<String, dynamic> get _presets => Map<String, dynamic>.from(_v?['presets'] as Map? ?? {});
  Map<String, dynamic> _preset(String p) => Map<String, dynamic>.from(_presets[p] as Map? ?? {});
  String get _keyName => '${_preset(_provider)['key'] ?? ''}';
  bool get _hasKey => _keyName.isNotEmpty && (_v?['keys'] as Map?)?[_keyName] == true;
  bool get _isLocal => _preset(_provider)['where'] == 'local';

  /// Models to pick from: installed ones on this PC, or the provider's list once a key is saved.
  Future<void> _findLocal() async {
    if (mounted) setState(() => _modelsFailed = false);
    if (!_isLocal && !_hasKey) return;
    final url = _url.text.isEmpty ? '${_preset(_provider)['base_url']}' : _url.text;
    try {
      final r = await TrustApi.map('GET', '/brain/models?base_url=${Uri.encodeQueryComponent(url)}&provider=$_provider');
      if (!mounted) return;
      setState(() {
        _local = [for (final m in r['models'] as List) '$m'];
        _localRunning = r['running'] == true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localRunning = null;
        _modelsFailed = true;
      });
    }
  }

  Future<void> _save() => widget.run(() async {
    final v = await TrustApi.map('PUT', '/brain', {
      'primary': {'provider': _provider, 'model': _model.text.trim(), 'base_url': _url.text.trim()},
      'fallback': _fallback ? {'provider': _fallbackProvider, 'model': '', 'base_url': ''} : null,
      'fallback_enabled': _fallback,
    });
    if (mounted) _apply(v);
  });

  Future<void> _saveKey() => widget.run(() async {
    final value = _key.text.trim();
    if (value.isEmpty) return;
    final v = await TrustApi.map('PUT', '/keys/$_keyName', {'value': value});
    _key.clear(); // never kept in the app
    if (mounted) {
      final keep = _provider;
      _apply(v);
      _provider = keep;
      await _findLocal();
    }
  });

  Future<void> _removeKey() => widget.run(() async {
    final v = await TrustApi.map('DELETE', '/keys/$_keyName');
    if (mounted) _apply(v);
  });

  Future<void> _test() async {
    setState(() => _testing = true);
    await widget.run(() async {
      if (_dirty) await _save();
      final v = await TrustApi.map('POST', '/brain/test');
      if (mounted) _apply(v);
    });
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = _v;
    if (v == null) {
      return _loadFailed
          ? LoadFailure(onRetry: _load)
          : const TrustCard(child: Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())));
    }
    final probe = v['probe'] as Map?;
    final problem = v['problem'] as String?;
    final fixed = v['fixed'] == true;
    final needsUrl = _provider == 'custom' || _provider == 'lmstudio';

    return TrustCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loadFailed) LoadFailure(onRetry: _load),
          if (_modelsFailed) LoadFailure(onRetry: _findLocal),
          if (fixed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Core is running in rehearsal mode, so changes here take effect next time it starts normally.',
                  style: context.type.bodySmall?.copyWith(color: c.warning)),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _presets.keys)
                ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_preset(p)['label']}'),
                      if ('${_preset(p)['price']}'.startsWith('free')) ...[
                        const SizedBox(width: 6),
                        Pill('${_preset(p)['price']}', color: c.success),
                      ],
                    ],
                  ),
                  avatar: Glyph(_preset(p)['where'] == 'local' ? G.monitor : G.cloud, size: 16),
                  selected: _provider == p,
                  onSelected: (_) {
                    setState(() {
                      _provider = p;
                      _model.text = '${_preset(p)['model']}';
                      _url.text = '';
                      _local = [];
                      _localRunning = null;
                      _dirty = true;
                    });
                    _findLocal();
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (!_isLocal && '${_preset(_provider)['price']}'.startsWith('free') && !_hasKey) ...[
            Row(
              children: [
                Glyph(G.coin, size: 18, color: c.success),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Free to start: make a free account, create an API key, and paste it below. '
                    'Free tiers have daily limits; Compii tells you if you hit one.',
                    style: context.type.bodySmall,
                  ),
                ),
                if ('${_preset(_provider)['signup']}'.isNotEmpty)
                  TextButton.icon(
                    icon: const Glyph(G.external, size: 15),
                    label: const Text('Get a free key'),
                    onPressed: () => _openLink('${_preset(_provider)['signup']}'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (!_isLocal && _local.isNotEmpty) ...[
            Text('Models', style: context.type.labelMedium),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final m in _local)
                    ChoiceChip(
                      label: Text(m),
                      selected: _model.text == m,
                      onSelected: (_) => setState(() {
                        _model.text = m;
                        _dirty = true;
                      }),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (_isLocal) ...[
            Row(
              children: [
                Glyph(G.coin, size: 18, color: c.success),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Free and private: the AI runs on this PC. On a small graphics card it can be slow; '
                    'pick a model that can use tools (Test checks this).',
                    style: context.type.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_localRunning == false)
              Text(
                _provider == 'ollama'
                    ? 'Ollama isn’t running on this PC. Install it from ollama.com, then run “ollama pull qwen3:4b” and come back.'
                    : 'LM Studio’s server isn’t running. Start it from LM Studio’s Developer tab.',
                style: context.type.bodySmall?.copyWith(color: c.warning),
              ),
            if (_localRunning == false) const SizedBox(height: 10),
            if (_local.isNotEmpty) ...[
              Text('Installed models', style: context.type.labelMedium),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final m in _local)
                  ChoiceChip(
                    label: Text(m),
                    selected: _model.text == m,
                    onSelected: (_) => setState(() {
                      _model.text = m;
                      _dirty = true;
                    }),
                  ),
              ]),
              const SizedBox(height: 10),
            ],
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _model,
                  onChanged: (_) => setState(() => _dirty = true),
                  decoration: const InputDecoration(labelText: 'Model', isDense: true),
                ),
              ),
              if (needsUrl) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _url,
                    onChanged: (_) => setState(() => _dirty = true),
                    decoration: InputDecoration(
                      labelText: 'Server address',
                      hintText: '${_preset(_provider)['base_url']}'.isEmpty ? 'https://…/v1' : '${_preset(_provider)['base_url']}',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_keyName.isNotEmpty) ...[
            const SizedBox(height: 14),
            if (_hasKey)
              Row(
                children: [
                  // A stored key is not a working one: Core has just tried it, so say which it is.
                  _chip(context,
                      probe?['ok'] == false ? 'Key saved · it did not answer' : 'Key saved in Windows Credential Manager',
                      probe?['ok'] == false ? c.warning : c.success,
                      probe?['ok'] == false ? c.warningSoft : c.sunken,
                      icon: G.lock),
                  const Spacer(),
                  TextButton(onPressed: _removeKey, child: const Text('Remove key')),
                ],
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _key,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: _hasKey ? 'Replace key' : 'API key',
                      helperText: 'Stored only in Windows Credential Manager. Compii never shows it again.',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _saveKey(),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(onPressed: _saveKey, child: const Text('Save key')),
              ],
            ),
          ],
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _fallback,
            onChanged: (on) => setState(() {
              _fallback = on;
              _dirty = true;
            }),
            title: const Text('Use a backup AI if this one fails'),
            subtitle: Text(_fallback
                ? 'Backup: ${_preset(_fallbackProvider)['label']}. Compii never switches to a cloud AI unless you turn this on.'
                : 'Off: if the AI fails, Compii tells you instead of switching.'),
          ),
          if (_fallback)
            Wrap(spacing: 6, children: [
              for (final p in _presets.keys.where((p) => p != _provider))
                ChoiceChip(
                  label: Text('${_preset(p)['label']}'),
                  selected: _fallbackProvider == p,
                  onSelected: (_) => setState(() {
                    _fallbackProvider = p;
                    _dirty = true;
                  }),
                ),
            ]),
          const SizedBox(height: 12),
          if (problem != null && !fixed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(problem, style: context.type.bodySmall?.copyWith(color: c.danger)),
            ),
          if (probe != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AdaptiveRow(
                children: [
                  if (probe['ok'] != true)
                    _chip(context, 'Didn’t answer', c.danger, c.dangerSoft, icon: G.alert)
                  else if (probe['tools'] == true)
                    _chip(context, 'Works · can do tasks · ${probe['ms']} ms', c.success, c.sunken, icon: G.checkCircle)
                  else
                    _chip(context, 'Chat only · can’t use tools', c.warning, c.warningSoft, icon: G.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${probe['error'] ?? probe['note'] ?? ''}',
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                  ),
                ],
              ),
            ),
          if (v['fallback_note'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('${v['fallback_note']}', style: context.type.bodySmall?.copyWith(color: c.warning)),
            ),
          Row(
            children: [
              FilledButton(onPressed: _dirty ? _save : null, child: const Text('Use this AI')),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Glyph(G.bolt, size: 18),
                label: const Text('Test'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens a web page in the user's browser (sign-up pages for free keys).
void _openLink(String url) {
  if (!url.startsWith('https://')) return;
  if (Platform.isWindows) {
    Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else {
    Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [url]);
  }
}

// ---- Usage: what answering has cost on this PC ----------------------------------------

/// The books Compii keeps on itself: tokens in and out, seconds waited, which model
/// answered and how much ran on this PC. Every number comes from what the provider
/// reported; the ones Compii had to guess are labelled as guessed. There are no prices.
class UsageCard extends StatefulWidget {
  const UsageCard({super.key, required this.run});
  final Run run;

  @override
  State<UsageCard> createState() => _UsageCardState();
}

class _UsageCardState extends State<UsageCard> {
  static const _windows = <int, String>{1: 'Today', 7: 'Week', 30: 'Month'};

  Map<String, dynamic>? _v;
  int _days = 7;
  bool _busy = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    widget.run(_load);
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _loadFailed = false;
    });
    try {
      final v = await TrustApi.usage(days: _days);
      if (mounted) setState(() => _v = v);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pick(int days) {
    if (days == _days) return;
    setState(() => _days = days);
    widget.run(_load);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = _v;

    return TrustCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveRow(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GlyphTile(glyph: G.coin, size: 30, color: c.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('What answering has cost', style: context.type.titleSmall),
                          const SizedBox(height: 3),
                          Text(
                            'Counted on this PC from what each provider reported. Compii doesn’t guess prices: '
                            'what your key costs is your own billing.',
                            style: context.type.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AdaptiveRow(
                children: [
                  if (_busy) const Glyph(G.sync, size: 15),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                    segments: [for (final e in _windows.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                    selected: {_days},
                    onSelectionChanged: _busy ? null : (s) => _pick(s.first),
                  ),
                ],
              ),
            ],
          ),
          if (_loadFailed) LoadFailure(onRetry: () => widget.run(_load)),
          if (v == null)
            _loadFailed
                ? const SizedBox.shrink()
                : const Padding(padding: EdgeInsets.only(top: 16), child: SkeletonCards(rows: 2))
          else
            UsageSummary(report: v),
        ],
      ),
    );
  }
}

/// The numbers themselves, on their own so they can be shown anywhere: the totals, which
/// model did the work, and the plain note about what Compii had to estimate.
class UsageSummary extends StatelessWidget {
  const UsageSummary({super.key, required this.report});
  final Map<String, dynamic> report;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final total = (report['total'] as Map?) ?? const {};
    final steps = (total['steps'] as num?)?.toInt() ?? 0;
    if (steps == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(
          'Nothing counted in this window yet. Compii writes down one line per answer from now on, '
          'in usage.jsonl in its own folder.',
          style: context.type.bodySmall,
        ),
      );
    }
    final models = [for (final m in report['by_model'] as List? ?? const []) Map<String, dynamic>.from(m)];
    final top = models.isEmpty ? 1.0 : ((models.first['tokens'] as num?)?.toDouble() ?? 1).clamp(1.0, 1e18);
    final heard = ((total['heard_ms'] as num?) ?? 0).toInt();
    final failed = (total['failed'] as num?)?.toInt() ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _figure(context, _count(total['tokens']),
                '${_count(total['prompt'])} in · ${_count(total['completion'])} out',
                title: '$steps answers'),
            _figure(context, _minutes(total['ms']), 'spent waiting'),
            _figure(context, '${(((report['local_share'] as num?) ?? 0).toDouble() * 100).round()}%',
                'ran on this PC'),
            _figure(context, _count(report['last_minute_tokens']), 'in the last minute',
                title: 'check your free limit'),
          ],
        ),
        const SizedBox(height: 14),
        for (final m in models)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveRow(
                  children: [
                    Expanded(child: Text('${m['model']}', style: context.type.bodySmall)),
                    Text('${_count(m['tokens'])} tokens · ${m['steps']} steps',
                        style: context.type.bodySmall?.copyWith(color: c.muted)),
                  ],
                ),
                const SizedBox(height: 4),
                LayoutBuilder(
                  builder: (context, box) => Container(
                    height: 5,
                    decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.pill),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: box.maxWidth * ((m['tokens'] as num?)?.toDouble() ?? 0) / top,
                        decoration: BoxDecoration(color: c.accent, borderRadius: Shapes.pill),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (heard > 0 || failed > 0)
          AdaptiveRow(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (heard > 0)
                Pill('${(heard / 1000).round()} s of speech heard', color: c.muted, glyph: G.mic),
              if (failed > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Pill('$failed steps failed', color: c.warning, glyph: G.alert),
                ),
            ],
          ),
        const SizedBox(height: 10),
        Text('${report['note'] ?? ''}', style: context.type.bodySmall?.copyWith(color: c.faint)),
      ],
    );
  }
}

Widget _figure(BuildContext context, String value, String label, {String? title}) {
  final c = context.c;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: context.type.titleMedium),
        const SizedBox(height: 2),
        Text(title ?? label, style: context.type.bodySmall?.copyWith(color: c.muted)),
        if (title != null) Text(label, style: context.type.bodySmall?.copyWith(color: c.faint)),
      ],
    ),
  );
}

String _count(num? n) {
  final v = (n ?? 0).toInt();
  final digits = v.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return (v < 0 ? '-' : '') + out.toString();
}

String _minutes(num? ms) {
  final m = ((ms ?? 0).toDouble() / 60000);
  if (m < 1) return '${((ms ?? 0).toDouble() / 1000).round()} s';
  return '${m.toStringAsFixed(m < 10 ? 1 : 0)} min';
}

// ---- Safety: kill switch, rules, audit log ------------------------------------------------

class SafetyPage extends StatefulWidget {
  const SafetyPage({super.key, required this.run});
  final Run run;
  @override
  State<SafetyPage> createState() => _SafetyPageState();
}

class _SafetyPageState extends State<SafetyPage> {
  bool _loadFailed = false;
  Map<String, dynamic>? _s;
  Map<String, dynamic>? _audit;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // Stay current when the kill switch is pressed elsewhere (hotkey, phone).
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await TrustApi.map('GET', '/safety');
      final a = await TrustApi.map('GET', '/audit?limit=150');
      if (mounted) {
        setState(() {
          _loadFailed = false;
          _s = s;
          _audit = a;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
    final s = await TrustApi.map('GET', '/safety');
    final a = await TrustApi.map('GET', '/audit?limit=150');
    if (mounted) {
      setState(() {
        _s = s;
        _audit = a;
      });
    }
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  Future<void> _do(Future<void> Function() f) => widget.run(() async {
    await f();
    await _load();
  });

  static const _blocked = [
    (G.password, 'Typing passwords, card or bank numbers and one-time codes'),
    (G.lock, 'Locking, signing out or shutting down the PC'),
    (G.box, 'Installing software or editing the registry'),
    (G.shield, 'Opening security, privacy or firewall settings'),
    (G.money, 'Pressing pay, buy or checkout buttons'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = _s;
    final lockdown = s?['lockdown'] == true;
    final rules = [for (final r in (s?['rules'] as List? ?? [])) Map<String, dynamic>.from(r as Map)];
    final verify = Map<String, dynamic>.from(_audit?['verify'] as Map? ?? {});
    final entries = [for (final e in (_audit?['entries'] as List? ?? [])) Map<String, dynamic>.from(e as Map)];
    return TrustPage(
      title: 'Safety',
      subtitle: 'What Compii may never do, what you’ve always allowed, and a tamper-evident record of everything it did.',
      children: [
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (s == null) const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('Safety status is not yet verified. Emergency stop is available.')),
        TrustCard(
          child: AdaptiveRow(
            children: [
              GlyphTile(glyph: lockdown ? G.shieldAlert : G.power, size: 44, color: lockdown ? c.danger : c.muted),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s == null ? 'Safety status unknown' : lockdown ? 'Lockdown is on' : 'Kill switch', style: context.type.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      lockdown
                          ? 'Everything was stopped. Compii asks before every action, and “Always allow” rules are paused.'
                          : 'Ctrl + Alt + Shift + S from anywhere: stops every task, silences Compii, and makes it ask before everything.',
                      style: context.type.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              lockdown
                  ? FilledButton(onPressed: () => _do(TrustApi.lift), child: const Text('Lift lockdown'))
                  : FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: c.danger),
                      onPressed: () => _do(TrustApi.kill),
                      child: const Text('Stop everything'),
                    ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SectionHeader('Always allowed',
            subtitle: 'Actions you approved with “Always allow”. Each covers one tool on one folder, site, window or set of recipients.'),
        TrustCard(
          padding: EdgeInsets.zero,
          child: s == null ? const Padding(padding: EdgeInsets.all(16), child: Text('Rules have not been loaded.')) : rules.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Nothing yet. When Compii asks for approval, “Always allow” adds a rule here.', style: context.type.bodySmall),
                )
              : Column(
                  children: [
                    for (final (i, r) in rules.indexed) ...[
                      if (i > 0) Divider(height: 1, color: c.border),
                      ListTile(
                        leading: GlyphTile(glyph: G.shieldCheck, size: 34, color: c.success),
                        title: Text('${r['label']}'.isEmpty ? '${r['tool']}' : '${r['label']}'),
                        subtitle: Text(
                          '${r['tool']}${'${r['scope']}'.isEmpty ? ' · anywhere' : ' · ${r['scope']}'} · ${_ago(r['created'] as num?)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'Remove rule',
                          icon: const Glyph(G.close),
                          onPressed: () => _do(() => TrustApi.call('DELETE', '/rules/${r['id']}')),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 20),
        SectionHeader('Never, whatever anyone says',
            subtitle: 'These are enforced by Compii’s code, not by the AI, so no web page, file or prompt can unlock them.'),
        TrustCard(
          child: Column(
            children: [
              for (final (icon, text) in _blocked)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: AdaptiveRow(children: [
                    GlyphTile(glyph: icon, size: 28, color: c.danger),
                    const SizedBox(width: 10),
                    Expanded(child: Text(text, style: context.type.bodyMedium)),
                  ]),
                ),
              const SizedBox(height: 6),
              Text(
                'Text Compii reads from files, windows and web pages is treated as data. If it looks like instructions to an AI, '
                'Compii tells you, and sending, deleting or paying in that task need a fresh okay. Card numbers, keys and ID '
                'numbers are hidden before anything goes to a cloud AI.',
                style: context.type.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SectionHeader(
          'Activity record',
          subtitle: 'Append-only and hash-chained: if any line is changed or removed, the check below fails.',
          trailing: verify.isEmpty
              ? null
              : verify['ok'] == true
                  ? _chip(context, 'Intact · ${verify['count']} entries', c.success, c.sunken, icon: G.shieldCheck)
                  : _chip(context, 'Tampered at line ${verify['broken_at']}', c.danger, c.dangerSoft, icon: G.flag),
        ),
        TrustCard(
          padding: EdgeInsets.zero,
          child: _audit == null ? const Padding(padding: EdgeInsets.all(16), child: Text('Activity has not been loaded.')) : entries.isEmpty
              ? Padding(padding: const EdgeInsets.all(16), child: Text('Nothing recorded yet.', style: context.type.bodySmall))
              : Column(
                  children: [
                    for (final (i, e) in entries.take(80).indexed) ...[
                      if (i > 0) Divider(height: 1, color: c.border),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                        child: AdaptiveRow(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 92, child: Text(_ago(e['at'] as num?), style: context.type.labelMedium?.copyWith(color: c.faint))),
                            SizedBox(width: 110, child: Text(_eventName('${e['event']}'), style: context.type.labelLarge)),
                            Expanded(
                              child: Text(
                                [e['tool'], e['reason'], e['scope'], e['name'], e['provider'], e['error']]
                                    .where((x) => x != null && '$x'.isNotEmpty)
                                    .join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.type.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

String _eventName(String e) => switch (e) {
  'asked' => 'Asked you',
  'approved' => 'You approved',
  'declined' => 'You declined',
  'done' => 'Did',
  'failed' => 'Failed',
  'blocked' => 'Blocked',
  'stopped' => 'Stopped',
  'rule_added' => 'Rule added',
  'rule_removed' => 'Rule removed',
  'kill_switch' => 'Kill switch',
  'lockdown_lifted' => 'Lockdown lifted',
  'key_saved' => 'Key saved',
  'key_removed' => 'Key removed',
  'brain_changed' => 'AI changed',
  'brain_fallback' => 'Used backup AI',
  'dial_changed' => 'Autonomy set',
  'skill_saved' => 'Skill saved',
  'library_imported' => 'Library import',
  'library_approved' => 'Library approved',
  'library_rejected' => 'Library turned down',
  'library_enabled' => 'Library on',
  'library_disabled' => 'Library off',
  'library_removed' => 'Library removed',
  'library_key_set' => 'Connector key saved',
  'library_key_removed' => 'Connector key removed',
  'knowledge_folder_added' => 'Knowledge folder added',
  'knowledge_folder_removed' => 'Knowledge folder removed',
  'knowledge_refreshed' => 'Knowledge index refreshed',
  _ => e,
};

/// A red bar at the top of every page while the kill switch is on.
class LockdownBanner extends StatefulWidget {
  const LockdownBanner({super.key, required this.run});
  final Run run;
  @override
  State<LockdownBanner> createState() => _LockdownBannerState();
}

class _LockdownBannerState extends State<LockdownBanner> {
  bool _on = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _check();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final s = await TrustApi.map('GET', '/safety');
      if (mounted && (s['lockdown'] == true) != _on) setState(() => _on = s['lockdown'] == true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return const SizedBox.shrink();
    final c = context.c;
    return Material(
      color: c.dangerSoft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: AdaptiveRow(
          children: [
            Glyph(G.shieldAlert, color: c.danger, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Lockdown: everything was stopped, and Compii asks before every action.',
                  style: context.type.labelLarge?.copyWith(color: c.danger)),
            ),
            TextButton(
              onPressed: () => widget.run(() async {
                await TrustApi.lift();
                await _check();
              }),
              child: const Text('Lift'),
            ),
          ],
        ),
      ),
    );
  }
}

/// While Compii teaches you something: which step you're on.
class WalkthroughBar extends StatefulWidget {
  const WalkthroughBar({super.key});
  @override
  State<WalkthroughBar> createState() => _WalkthroughBarState();
}

class _WalkthroughBarState extends State<WalkthroughBar> {
  Map<String, dynamic>? _w;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final w = await TrustApi.map('GET', '/walkthrough');
      if (mounted) setState(() => _w = w.isEmpty ? null : w);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final w = _w;
    if (w == null || w['status'] != 'running') return const SizedBox.shrink();
    final c = context.c;
    final steps = [for (final s in w['steps'] as List) Map<String, dynamic>.from(s as Map)];
    final i = (w['completed'] as num? ?? 0).toInt().clamp(0, steps.length - 1);
    return Material(
      color: c.accentSoft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: AdaptiveRow(
          children: [
            Glyph(G.skill, color: c.accent, size: 20),
            const SizedBox(width: 10),
            Text('${w['goal']} · step ${i + 1} of ${steps.length}', style: context.type.labelLarge?.copyWith(color: c.accent)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${steps[i]['instruction']}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodyMedium),
            ),
            SizedBox(
              width: 120,
              child: ClipRRect(
                borderRadius: Shapes.pill,
                child: LinearProgressIndicator(value: steps.isEmpty ? 0 : i / steps.length, color: c.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Skills ----------------------------------------------------------------------------------

class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, required this.run, required this.onOpenTask});
  final Run run;
  final void Function(String taskId) onOpenTask;
  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  List<Map<String, dynamic>>? _skills;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
      final s = await TrustApi.call('GET', '/skills') as List;
      if (mounted) setState(() => _skills = [for (final x in s) Map<String, dynamic>.from(x as Map)]);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  Future<void> _routine(Map<String, dynamic> skill) async {
    var kind = 'weekdays';
    var time = const TimeOfDay(hour: 9, minute: 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text('Make “${skill['name']}” a routine'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tip: run it once by hand first. When it works, let it run on its own.', style: context.type.bodySmall),
              const SizedBox(height: 14),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'daily', label: Text('Every day')),
                  ButtonSegment(value: 'weekdays', label: Text('Weekdays')),
                ],
                selected: {kind},
                onSelectionChanged: (v) => set(() => kind = v.first),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Glyph(G.clock, size: 18),
                label: Text('At ${time.format(context)}'),
                onPressed: () async {
                  final t = await showTimePicker(context: context, initialTime: time);
                  if (t != null) set(() => time = t);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Make routine')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final at = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    await widget.run(() => TrustApi.call('POST', '/skills/${skill['id']}/routine', {'schedule': {'kind': kind, 'at': at}}));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('“${skill['name']}” now runs ${kind == 'daily' ? 'every day' : 'on weekdays'} at $at. See Routines.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final skills = _skills;
    return TrustPage(
      title: 'Skills',
      subtitle: 'Things you’ve taught Compii. Do something once, save it, and next time just say its name.',
      children: [
        TrustCard(
          child: AdaptiveRow(
            children: [
              GlyphTile(glyph: G.eye, size: 44, color: c.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Teach a task by showing it', style: context.type.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      'Demonstrate it once in any app. Compii writes down the clicks, shortcuts and window switches — '
                      'never what you type — then you review it and can put it on a schedule.',
                      style: context.type.bodySmall?.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () async {
                  final name = await showTeachDialog(context);
                  if (name == null || !context.mounted) return;
                  await _load();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved “$name”. Try it with Do it now, or find it in Routines.')),
                    );
                  }
                },
                icon: const Glyph(G.play, size: 18),
                label: const Text('Teach a task'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (skills == null)
          _loadFailed ? const SizedBox.shrink() : const SkeletonCards(rows: 3)
        else if (skills.isEmpty)
          TrustCard(
            child: AdaptiveRow(
              children: [
                GlyphTile(glyph: G.skill, size: 48, color: c.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'No skills yet. When a conversation goes well, press “Save as skill” at the top of it, '
                    'or tell Compii “remember how to do this”.',
                    style: context.type.bodyMedium,
                  ),
                ),
              ],
            ),
          )
        else
          for (final s in skills) ...[
            TrustCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GlyphTile(glyph: G.wand, size: 34, color: c.accent),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${s['name']}', style: context.type.titleMedium)),
                      Text(
                        (s['uses'] as num? ?? 0) == 0 ? 'Not used yet' : 'Used ${s['uses']}× · ${_ago(s['last_used'] as num?)}',
                        style: context.type.labelMedium?.copyWith(color: c.faint),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('${s['instruction']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                  if (s['library_id'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Imported from Library. Turning it off in Library keeps it out of Compii; '
                          'deleting here turns the Library entry off.',
                          style: context.type.bodySmall?.copyWith(color: c.muted)),
                    ),
                  if ((s['steps'] as List).isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final (i, step) in (s['steps'] as List).take(8).indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('${i + 1}. $step', style: context.type.bodySmall?.copyWith(color: c.muted)),
                      ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        icon: const Glyph(G.play, size: 18),
                        label: const Text('Do it now'),
                        onPressed: () => widget.run(() async {
                          final t = await TrustApi.map('POST', '/skills/${s['id']}/run');
                          widget.onOpenTask(t['id'] as String);
                        }),
                      ),
                      OutlinedButton.icon(
                        icon: const Glyph(G.routine, size: 18),
                        label: const Text('Make routine'),
                        onPressed: () => _routine(s),
                      ),
                      TextButton(
                        onPressed: () => widget.run(() async {
                          final left = await TrustApi.call('DELETE', '/skills/${s['id']}') as List;
                          if (mounted) setState(() => _skills = [for (final x in left) Map<String, dynamic>.from(x as Map)]);
                        }),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

/// "Save as skill" for a finished conversation.
class SaveSkillButton extends StatelessWidget {
  const SaveSkillButton({super.key, required this.task, required this.run});
  final TaskView task;
  final Run run;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Glyph(G.skill, size: 18),
    label: const Text('Save as skill'),
    onPressed: () async {
      final picked = await showDialog<(String, String)>(
        context: context,
        builder: (_) => SaveSkillDialog(request: task.request, draft: () => TrustApi.draftSkill(task.id)),
      );
      if (picked == null) return;
      await run(() async {
        final s = await TrustApi.saveSkill(task.id, picked.$1, picked.$2);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved “${s['name']}” with ${(s['steps'] as List).length} steps. Say its name any time to use it.')),
          );
        }
      });
    },
  );

  static const _small = {'a', 'an', 'the', 'in', 'on', 'of', 'to', 'for', 'and', 'my', 'me', 'it', 'from', 'with', 'into', 'at'};

  static String suggest(String request) {
    final words = request.replaceAll(RegExp(r'[^\w\s\x27-]'), '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(5).toList();
    while (words.length > 1 && _small.contains(words.last.toLowerCase())) {
      words.removeLast();
    }
    final name = words.join(' ');
    return name.isEmpty ? 'My skill' : name[0].toUpperCase() + name.substring(1);
  }
}

/// Asks what to call a skill. Compii reads the conversation and offers a name
/// that says what it is for; the user can keep it or type their own.
class SaveSkillDialog extends StatefulWidget {
  const SaveSkillDialog({super.key, required this.request, required this.draft});
  final String request;
  final Future<Map<String, dynamic>> Function() draft;

  @override
  State<SaveSkillDialog> createState() => _SaveSkillDialogState();
}

class _SaveSkillDialogState extends State<SaveSkillDialog> {
  late final _name = TextEditingController(text: SaveSkillButton.suggest(widget.request));
  final _about = TextEditingController();
  bool _thinking = true;
  bool _draftFailed = false;
  bool _typed = false;
  List<String> _steps = const [];
  List<String> _names = const [];

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _ask();
  }

  void _ask() {
    setState(() {
      _thinking = true;
      _draftFailed = false;
    });
    widget.draft().then((d) {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        if (!_typed && '${d['name'] ?? ''}'.trim().isNotEmpty) _name.text = '${d['name']}'.trim();
        if (_about.text.isEmpty) _about.text = '${d['about'] ?? ''}';
        _steps = [for (final s in d['steps'] as List? ?? const []) '$s'];
        _names = [for (final s in d['names'] as List? ?? const []) '$s'];
      });
    }, onError: (_) {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _draftFailed = true;
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  String? get _taken {
    final want = _name.text.trim().toLowerCase();
    for (final n in _names) {
      if (n.toLowerCase() == want) return n;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final taken = _taken;
    final name = _name.text.trim();
    return AlertDialog(
      title: const Text('What should this skill be called?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Next time, just say the name and Compii repeats what worked, adapted to that day.',
                style: context.type.bodySmall),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 60,
              onChanged: (_) => _typed = true,
              onSubmitted: (_) => name.isEmpty ? null : Navigator.pop(context, (name, _about.text.trim())),
              decoration: InputDecoration(
                labelText: 'Name',
                helperText: _thinking ? 'Compii is suggesting a name that fits…' : null,
                suffixIcon: _thinking
                    ? const Padding(padding: EdgeInsets.all(14), child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
              ),
            ),
            if (_draftFailed)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: AdaptiveRow(children: [
                  Expanded(
                    child: Text('No suggestion, and its steps aren’t listed yet: Compii couldn’t answer just now.',
                        style: context.type.bodySmall?.copyWith(color: c.danger)),
                  ),
                  TextButton(onPressed: _ask, child: const Text('Try again')),
                ]),
              ),
            if (taken != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text('You already have “$taken”. Saving replaces it; change the name to keep both.',
                    style: context.type.bodySmall?.copyWith(color: c.warning)),
              ),
            TextField(
              controller: _about,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(labelText: 'What it’s for (optional)'),
            ),
            if (_steps.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Steps it keeps', style: context.type.labelLarge),
              const SizedBox(height: 4),
              for (final (i, s) in _steps.take(5).indexed)
                Text('${i + 1}. $s', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
              if (_steps.length > 5) Text('and ${_steps.length - 5} more', style: context.type.bodySmall?.copyWith(color: c.muted)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: name.isEmpty ? null : () => Navigator.pop(context, (name, _about.text.trim())),
          child: Text(taken != null ? 'Replace' : 'Save'),
        ),
      ],
    );
  }
}

/// Notes in a conversation when Compii's safety rules stepped in.
class SafetyNotes extends StatelessWidget {
  const SafetyNotes({super.key, required this.events});
  final List<Map<String, dynamic>> events;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in events)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AdaptiveRow(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Glyph(switch (e['type']) {
                  'action_blocked' => G.block,
                  'injection_warning' => G.shieldAlert,
                  'redacted' => G.eyeOff,
                  _ => G.shieldCheck,
                }, size: 16, color: switch (e['type']) {
                  'action_blocked' || 'injection_warning' => c.danger,
                  'redacted' => c.warning,
                  _ => c.success,
                }),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(switch (e['type']) {
                    'action_blocked' => 'Blocked: ${e['reason']}',
                    'injection_warning' =>
                      'Something Compii read looked like instructions to an AI (“${e['phrase']}”). It ignored them; sending, deleting or paying in this task need your fresh okay.',
                    'redacted' => 'Hid ${e['count']} private ${e['count'] == 1 ? 'item' : 'items'} (${(e['kinds'] as List).join(', ')}) before sending to the AI.',
                    _ => 'Allowed by your rule: ${e['label']}',
                  }, style: context.type.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

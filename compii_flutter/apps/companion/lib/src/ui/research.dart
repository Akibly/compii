import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chrome.dart';
import 'glyphs.dart';
import 'thread.dart' show Run;
import 'tokens.dart';
import 'trust.dart';

/// Research: the places outside this PC Compii can read — web pages, feeds, code,
/// and the big social platforms through the command line tools already installed.
/// It is read-only by construction, and the logged-in platforms wait for the user.
class ResearchPage extends StatefulWidget {
  const ResearchPage({super.key, required this.run});
  final Run run;

  @override
  State<ResearchPage> createState() => _ResearchPageState();
}

class _ResearchPageState extends State<ResearchPage> {
  Map<String, dynamic>? _v;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool probe = false}) async {
    if (probe) setState(() => _probing = true);
    try {
      final v = await TrustApi.research(probe: probe);
      if (mounted) setState(() => _v = v);
    } finally {
      if (mounted && probe) setState(() => _probing = false);
    }
  }

  Future<void> _set({bool? enabled, bool? browserSession}) async {
    if (browserSession == true) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Let Compii read the logged-in platforms?'),
          content: const Text(
            'Compii will run the search commands as your existing browser session, so a logged-in '
            'place answers. It only ever searches and reads — it cannot post, like, follow or message — '
            'and it never reads or copies your cookies or passwords.',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep them off')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Allow reading')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await widget.run(() async {
      final v = await TrustApi.researchSet(enabled: enabled, browserSession: browserSession);
      if (mounted) setState(() => _v = v);
      if (browserSession != null) {
        _toast(browserSession
            ? 'Reading allowed. Ask Compii for X, Reddit or Bilibili whenever you like.'
            : 'Logged-in platforms are shut again.');
      }
    });
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _toast('Copied. Run it yourself in a terminal — Compii never installs anything.');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = _v;
    final platforms = v == null
        ? <Map<String, dynamic>>[]
        : [for (final p in v['platforms'] as List) Map<String, dynamic>.from(p as Map)];
    final live = platforms.where((p) => p['live'] == true).length;

    return TrustPage(
      title: 'Research',
      subtitle: 'What Compii can look up beyond this PC — and what it will never do while doing it.',
      children: [
        TrustCard(child: _switches(context, v)),
        if (v == null)
          const Padding(padding: EdgeInsets.only(top: 16), child: SkeletonCards(rows: 3))
        else ...[
          const SizedBox(height: 18),
          SectionHeader(
            'What answers now',
            subtitle: '$live of ${platforms.length} places. '
                'Ask Compii to “research X on Reddit and GitHub” and it uses these.',
            trailing: TextButton.icon(
              onPressed: _probing ? null : () => _load(probe: true),
              icon: const Glyph(G.sync, size: 15),
              label: Text(_probing ? 'Checking…' : 'Check again'),
            ),
          ),
          for (final p in platforms) ...[ResearchPlatformCard(platform: p, onCopyFix: _copy), const SizedBox(height: 9)],
          const SizedBox(height: 16),
          TrustCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveRow(
                  children: [
                    GlyphTile(glyph: G.shieldCheck, size: 30, color: c.success),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('The rules Compii cannot break here', style: context.type.titleSmall),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                for (final line in const [
                  'It only ever searches and reads. There is no post, like, follow, message or login command '
                      'for it to be talked into.',
                  'Your words are passed as one argument, never as a command, so a search for “--force rm” stays a search.',
                  'It never reads, copies or stores your cookies, tokens or passwords. The logged-in platforms ride '
                      'the browser session you chose to allow, and stop when you turn it off.',
                  'Anything it brings back is labelled as data from outside, and is checked for the classic trick of '
                      'a web page trying to give Compii instructions.',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 3, right: 9),
                          child: Glyph(G.check, size: 13, color: c.success),
                        ),
                        Expanded(child: Text(line, style: context.type.bodySmall?.copyWith(color: c.muted))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _switches(BuildContext context, Map<String, dynamic>? v) {
    final c = context.c;
    final on = v?['enabled'] != false;
    final session = v?['browser_session'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdaptiveRow(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GlyphTile(glyph: G.globe, size: 44, color: c.accent),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reach the wider research places', style: context.type.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    'Compii runs the read-only search tools already on this PC — GitHub, YouTube transcripts, RSS '
                    'feeds, any page as text, and the social platforms through your own browser session — so an '
                    'answer can say what people actually wrote, where it came from, and what it could not check.',
                    style: context.type.bodySmall?.copyWith(color: c.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _row(
          context,
          title: 'Research is on',
          body: 'Off means Compii says it cannot look outside instead of trying.',
          value: on,
          onChanged: v == null ? null : (b) => _set(enabled: b),
        ),
        Divider(height: 22, color: c.border),
        _row(
          context,
          title: 'Use my browser session',
          body: 'Needed for X, Reddit, Xiaohongshu, Facebook, Instagram and LinkedIn, because those places only '
              'answer for someone who is already logged in. Off until you turn it on; Compii never reads the '
              'cookies themselves.',
          value: session,
          onChanged: v == null ? null : (b) => _set(browserSession: b),
        ),
        if (v != null && (v['hints'] as List? ?? const []).isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'To open a place that is missing: '
            '${(v['hints'] as List).take(2).map((h) => '$h').join(' ')}',
            style: context.type.bodySmall?.copyWith(color: c.faint),
          ),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, {
    required String title,
    required String body,
    required bool value,
    void Function(bool)? onChanged,
  }) {
    final c = context.c;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.type.bodyMedium),
              const SizedBox(height: 3),
              Text(body, style: context.type.bodySmall?.copyWith(color: c.muted)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// One platform: whether it answers, the read-only things it can do, and how to fix it.
class ResearchPlatformCard extends StatelessWidget {
  const ResearchPlatformCard({super.key, required this.platform, this.onCopyFix});
  final Map<String, dynamic> platform;
  final void Function(String fix)? onCopyFix;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final live = platform['live'] == true;
    final verbs = [for (final v in platform['verbs'] as List? ?? const []) '$v'];
    final fix = '${platform['fix']}';
    return TrustCard(
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveRow(
                  children: [
                    Text('${platform['name']}', style: context.type.bodyMedium),
                    const SizedBox(width: 8),
                    Pill(live ? 'answers' : 'quiet', color: live ? c.success : c.faint, glyph: live ? G.check : G.block),
                    if (platform['login'] == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Pill('your session', color: c.muted),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  live
                      ? 'Reads: ${verbs.join(', ')}'
                      : '${platform['needs'] == 'browser session is off'
                            ? 'Your browser session is off for it.'
                            : 'Not ready on this PC.'} ${verbs.isNotEmpty ? 'Would read: ${verbs.join(', ')}.' : ''}',
                  style: context.type.bodySmall?.copyWith(color: live ? c.muted : c.warning),
                ),
                if (!live && fix.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(fix, style: context.type.bodySmall?.copyWith(color: c.faint)),
                  ),
              ],
            ),
          ),
          if (!live && fix.isNotEmpty && onCopyFix != null)
            IconButton(
              tooltip: 'Copy what to install or turn on',
              onPressed: () => onCopyFix!(fix),
              icon: const Glyph(G.copy, size: 16),
            ),
        ],
      ),
    );
  }
}

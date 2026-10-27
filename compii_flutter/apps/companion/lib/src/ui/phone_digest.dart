import 'dart:async';

import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'glyphs.dart';
import 'tokens.dart';

/// The morning brief and the evening recap, at the top of the phone's chats:
/// the newest of each from today, its one-line summary, and the sections behind
/// a tap. Both are written by Core from what actually happened; the phone only
/// shows them. "Brief me now" asks for one whenever you like.
class DigestCard extends StatefulWidget {
  const DigestCard({super.key, required this.core, this.now});
  final CoreClient core;

  /// For tests: the clock that decides what "today" is.
  final DateTime Function()? now;

  @override
  State<DigestCard> createState() => _DigestCardState();
}

class _DigestCardState extends State<DigestCard> {
  List<Map<String, dynamic>> _inbox = const [];
  StreamSubscription<Map<String, dynamic>>? _updates;
  bool _asking = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _inbox = _from(widget.core.plansCache);
    _refresh();
    _updates = widget.core.updates.stream.listen((e) {
      if ('${e['kind'] ?? ''}' == 'brief' || '${e['title'] ?? ''}'.isNotEmpty) _refresh();
    });
  }

  @override
  void dispose() {
    _updates?.cancel();
    super.dispose();
  }

  static List<Map<String, dynamic>> _from(Map<String, dynamic>? view) => [
    for (final u in (view?['inbox'] as List? ?? const [])) Map<String, dynamic>.from(u as Map),
  ];

  Future<void> _refresh() async {
    if (widget.core.status != CoreStatus.online) return;
    try {
      final v = await widget.core.proactive();
      if (mounted) setState(() => _inbox = _from(v));
    } on Object {
      // The card keeps what it had; the chats below still work.
    }
  }

  Future<void> _briefNow() async {
    setState(() {
      _asking = true;
      _problem = null;
    });
    try {
      await widget.core.briefNow();
      await _refresh();
    } on Object catch (e) {
      if (mounted) setState(() => _problem = 'Couldn’t get a brief: $e');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  static bool _isRecap(Map<String, dynamic> u) => '${u['title']}'.startsWith('Your day, wrapped up');

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final now = (widget.now ?? DateTime.now)();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch / 1000;
    final today = [
      for (final u in _inbox)
        if (u['kind'] == 'brief' && ((u['at'] as num?)?.toDouble() ?? 0) >= start) u,
    ];
    // The inbox comes newest first.
    final brief = today.where((u) => !_isRecap(u)).firstOrNull;
    final recap = today.where(_isRecap).firstOrNull;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(18), border: Border.all(color: c.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Glyph(G.sun, size: 16, color: c.muted),
              const SizedBox(width: 8),
              Expanded(child: Text('Today', style: context.type.titleSmall)),
              TextButton(
                onPressed: _asking || widget.core.status != CoreStatus.online ? null : _briefNow,
                child: Text(_asking ? 'Asking…' : 'Brief me now'),
              ),
            ],
          ),
          if (brief == null && recap == null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                'Your morning brief and evening recap appear here, and on your lock screen when they land.',
                style: context.type.bodySmall?.copyWith(color: c.muted),
              ),
            ),
          if (brief != null) _Digest(update: brief, label: 'Morning brief'),
          if (recap != null) _Digest(update: recap, label: 'Evening recap'),
          if (_problem != null)
            Text(_problem!, style: context.type.bodySmall?.copyWith(color: c.warning)),
        ],
      ),
    );
  }
}

class _Digest extends StatelessWidget {
  const _Digest({required this.update, required this.label});
  final Map<String, dynamic> update;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final sections = [for (final s in (update['sections'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: sections.isEmpty ? null : () => _open(context, sections),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: context.type.labelSmall?.copyWith(color: c.faint)),
                  const SizedBox(height: 2),
                  Text('${update['body'] ?? ''}', style: context.type.bodyMedium),
                ],
              ),
            ),
            if (sections.isNotEmpty) Glyph(G.chevronRight, size: 14, color: c.faint),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, List<Map<String, dynamic>> sections) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .8),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            shrinkWrap: true,
            children: [
              Text('${update['title'] ?? label}', style: ctx.type.titleLarge),
              const SizedBox(height: 6),
              Text('${update['body'] ?? ''}', style: ctx.type.bodyMedium?.copyWith(color: ctx.c.muted)),
              for (final s in sections) ...[
                const SizedBox(height: 18),
                Text('${s['title'] ?? ''}', style: ctx.type.titleSmall),
                const SizedBox(height: 6),
                for (final item in (s['items'] as List? ?? const []))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('•  $item', style: ctx.type.bodyMedium),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

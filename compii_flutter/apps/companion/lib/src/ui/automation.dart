import 'dart:async';

import 'package:flutter/material.dart';

import '../mobile/phone_automation.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'tokens.dart';

/// "On this phone": what Compii may reach here, the screen it can act on when
/// asked, and the notifications that should reach the PC.
Future<void> showAutomationSheet(BuildContext context, PhoneAutomation automation) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AutomationSheet(automation: automation),
    );

class AutomationSheet extends StatefulWidget {
  const AutomationSheet({super.key, required this.automation});
  final PhoneAutomation automation;

  @override
  State<AutomationSheet> createState() => _AutomationSheetState();
}

class _AutomationSheetState extends State<AutomationSheet> {
  PhoneAutomation get a => widget.automation;

  @override
  void initState() {
    super.initState();
    _warm();
  }

  Future<void> _warm() async {
    await a.refresh();
    if (a.access.notifications) await a.loadNotifications();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.88,
          child: ListenableBuilder(
            listenable: Listenable.merge([a, a.rules]),
            builder: (context, _) {
              final access = a.access;
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('On this phone', style: context.type.headlineSmall)),
                      IconButton(
                        tooltip: 'Check again',
                        onPressed: a.refresh,
                        icon: const Glyph(G.sync, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'What Compii can reach here. It never acts on its own — every action starts with you.',
                    style: context.type.bodySmall?.copyWith(color: c.muted),
                  ),
                  if (a.busy) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                  const SizedBox(height: 14),
                  _AccessRow(
                    glyph: G.eye,
                    title: 'Read and touch this screen',
                    detail: access.screen
                        ? access.screenReady
                            ? 'On — Compii can look, tap, type and scroll when you ask'
                            : 'On in Android; waiting for it to connect'
                        : 'Off — needed to look at, tap, type in or scroll another app',
                    action: access.screen ? 'Settings' : 'Turn on',
                    onAction: a.controls.openAccessibilitySettings,
                  ),
                  const SizedBox(height: 8),
                  _AccessRow(
                    glyph: G.bell,
                    title: 'See notifications',
                    detail: access.notifications
                        ? access.notificationsReady
                            ? 'On — recent ones here, and your rules can act on new ones'
                            : 'On in Android; waiting for it to connect'
                        : 'Off — needed for what you missed and for rules',
                    action: access.notifications ? 'Settings' : 'Turn on',
                    onAction: a.controls.openListenerSettings,
                  ),
                  const SizedBox(height: 20),
                  if (access.screen) ..._screen(context, access) else ..._screenOff(context),
                  const SizedBox(height: 22),
                  ..._rules(context, access),
                  if (access.notifications) ...[
                    const SizedBox(height: 22),
                    ..._recent(context),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ---- screen -----------------------------------------------------------------

  List<Widget> _screen(BuildContext context, PhoneAccess access) {
    final c = context.c;
    final labels = a.seenLabels;
    return [
      Text('The screen in front', style: context.type.titleMedium),
      const SizedBox(height: 2),
      Text(
        'These act on whichever app is open, so Compii waits ${a.switchTime.inSeconds} seconds for you to switch. Home, back and recents happen at once.',
        style: context.type.bodySmall?.copyWith(color: c.muted),
      ),
      if (!access.screenReady) ...[
        const SizedBox(height: 8),
        _Note(
          glyph: G.info,
          text: 'Android hasn’t connected the screen service yet. If you just turned it on, wait a moment and tap the refresh arrow above.',
        ),
      ],
      const SizedBox(height: 12),
      AdaptiveRow(
        breakpoint: 330,
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: a.busy ? null : () => _switchThen(
                    switchHint: 'Open the app you want Compii to read.',
                    then: 'looking',
                    run: a.look,
                  ),
              icon: const Glyph(G.eye, size: 18),
              label: const Text('Look now'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: a.busy ? null : _tap,
              icon: const Glyph(G.hand, size: 18),
              label: const Text('Tap…'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      AdaptiveRow(
        breakpoint: 330,
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: a.busy ? null : _type,
              icon: const Glyph(G.keyboard, size: 18),
              label: const Text('Type…'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: a.busy ? null : _openApp,
              icon: const Glyph(G.search, size: 18),
              label: const Text('Open app…'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      AdaptiveRow(
        breakpoint: 330,
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: a.busy ? null : () => _switchThen(switchHint: 'Open the app you want scrolled.', then: 'scrolling up', run: () => a.scroll('up')),
              child: const Text('Scroll up'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: a.busy ? null : () => _switchThen(switchHint: 'Open the app you want scrolled.', then: 'scrolling down', run: () => a.scroll('down')),
              child: const Text('Scroll down'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (action, label, glyph) in [
            ('back', 'Back', G.undo),
            ('home', 'Home', G.home),
            ('recents', 'Recents', G.sheet),
            ('notifications', 'Notifications', G.bell),
          ])
            ActionChip(
              avatar: Glyph(glyph, size: 16, color: c.accent),
              label: Text(label),
              onPressed: a.busy ? null : () => a.global(action),
            ),
        ],
      ),
      if (a.lastScreen != null) ...[
        const SizedBox(height: 12),
        _SeenCard(screen: a.lastScreen!, labels: labels, onLabel: (label) => _switchThen(
              switchHint: 'Open the app with “$label” on screen.',
              then: 'tapping “$label”',
              run: () => a.tap(label),
            )),
      ],
      if (a.lastResult != null) ...[
        const SizedBox(height: 10),
        Text(a.lastResult!, style: context.type.bodySmall?.copyWith(color: c.muted)),
      ],
    ];
  }

  List<Widget> _screenOff(BuildContext context) {
    final c = context.c;
    return [
      _Note(
        glyph: G.lock,
        text: 'Screen access is off. Turn it on to let Compii look at the app in front, tap by its label, type, scroll and open apps. '
            'Password fields are skipped, and nothing happens unless you ask.',
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          onPressed: () => a.controls.openAccessibilitySettings(),
          child: const Text('Turn on screen access'),
        ),
      ),
      if (a.lastResult != null) ...[
        const SizedBox(height: 8),
        Text(a.lastResult!, style: context.type.bodySmall?.copyWith(color: c.muted)),
      ],
    ];
  }

  Future<void> _tap() async {
    final text = await _ask(
      context,
      title: 'Tap something',
      label: 'Text on the button or link',
      hint: 'Send',
      helper: 'Compii finds the item with this label and taps it.',
      action: 'Next',
    );
    if (text == null || !mounted) return;
    await _switchThen(
      switchHint: 'Open the app with “$text” on screen.',
      then: 'tapping “$text”',
      run: () => a.tap(text),
    );
  }

  Future<void> _type() async {
    final text = await _ask(
      context,
      title: 'Type into another app',
      label: 'What to type',
      helper: 'After this closes, open the app and tap the text field before Compii types.',
      action: 'Next',
    );
    if (text == null || !mounted) return;
    await _switchThen(
      switchHint: 'Open the app and tap the field you want filled.',
      then: 'typing',
      run: () => a.type(text),
    );
  }

  Future<void> _openApp() async {
    final query = await _ask(
      context,
      title: 'Open an app',
      label: 'App name',
      hint: 'WhatsApp',
      action: 'Open',
    );
    if (query == null || !mounted) return;
    await a.openApp(query);
  }

  /// Close the sheet, give the user time to reach the app, then act. The result
  /// is a snackbar while Compii is on screen, or a notification when it isn't.
  Future<void> _switchThen({
    required String switchHint,
    required String then,
    required Future<void> Function() run,
  }) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch apps first'),
        content: Text(
          '$switchHint\n\nCompii will wait ${a.switchTime.inSeconds} seconds, then start $then.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Go')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop(); // the sheet
    messenger.showSnackBar(SnackBar(
      content: Text('Switch now — $then in ${a.switchTime.inSeconds} seconds.'),
      duration: Duration(seconds: a.switchTime.inSeconds),
    ));
    unawaited(run());
  }

  // ---- rules ------------------------------------------------------------------

  List<Widget> _rules(BuildContext context, PhoneAccess access) {
    final c = context.c;
    final rules = a.rules.rules;
    return [
      Row(
        children: [
          Expanded(child: Text('Notifications to your PC', style: context.type.titleMedium)),
          Switch(
            value: !a.rules.paused,
            onChanged: (on) => a.setPaused(!on),
          ),
        ],
      ),
      Text(
        a.rules.paused
            ? 'Paused. Rules keep their place and start again when you turn this back on.'
            : 'When a notification matches one of these, Compii on the PC gets the message. Runs while Compii is open on this phone.',
        style: context.type.bodySmall?.copyWith(color: c.muted),
      ),
      if (!access.notifications) ...[
        const SizedBox(height: 6),
        Text(
          'Notification access is off, so rules can’t see anything yet.',
          style: context.type.bodySmall?.copyWith(color: c.warning),
        ),
      ],
      const SizedBox(height: 6),
      for (final rule in rules)
        _RuleTile(
          rule: rule,
          onEdit: () => _editRule(rule),
          onEnabled: (on) => a.updateRule(rule.copyWith(enabled: on)),
          onDelete: () => a.removeRule(rule.id),
        ),
      if (rules.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'No rules yet. Add one so an urgent message reaches Compii even when your phone is in your pocket.',
            style: context.type.bodySmall?.copyWith(color: c.muted),
          ),
        ),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => _editRule(null),
          icon: const Glyph(G.plus, size: 18),
          label: const Text('Add a rule'),
        ),
      ),
    ];
  }

  Future<void> _editRule(WatchRule? rule) async {
    final made = await showDialog<WatchRule>(
      context: context,
      builder: (_) => _RuleDialog(rule: rule),
    );
    if (made == null || !mounted) return;
    if (rule == null) {
      await a.addRule(made);
    } else {
      await a.updateRule(made);
    }
  }

  // ---- recent notifications ---------------------------------------------------

  List<Widget> _recent(BuildContext context) {
    final c = context.c;
    return [
      Row(
        children: [
          Expanded(child: Text('What you missed', style: context.type.titleMedium)),
          IconButton(
            tooltip: 'Refresh',
            onPressed: a.busy ? null : a.loadNotifications,
            icon: const Glyph(G.sync, size: 20),
          ),
        ],
      ),
      if (a.recent.isEmpty)
        Text('Nothing caught yet.', style: context.type.bodySmall?.copyWith(color: c.muted))
      else
        for (final note in a.recent.take(12))
          _NoteTile(
            app: '${note['app'] ?? ''}',
            title: '${note['title'] ?? ''}',
            text: '${note['text'] ?? ''}',
            at: note['at'] is num ? (note['at'] as num).toInt() : null,
          ),
    ];
  }

  Future<String?> _ask(
    BuildContext context, {
    required String title,
    required String label,
    String hint = '',
    String helper = '',
    String action = 'Continue',
  }) async {
    final field = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (helper.isNotEmpty) ...[
              Text(helper, style: context.type.bodySmall?.copyWith(color: context.c.muted)),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: field,
              autofocus: true,
              decoration: InputDecoration(labelText: label, hintText: hint),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, field.text), child: Text(action)),
        ],
      ),
    );
    final trimmed = text?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

// ---- pieces -------------------------------------------------------------------

class _AccessRow extends StatelessWidget {
  const _AccessRow({
    required this.glyph,
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
  });
  final GlyphData glyph;
  final String title;
  final String detail;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(color: c.raised, borderRadius: Shapes.r16, border: Border.all(color: c.border)),
      child: Row(
        children: [
          Glyph(glyph, color: c.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.type.titleSmall),
                const SizedBox(height: 2),
                Text(detail, style: context.type.bodySmall?.copyWith(color: c.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.glyph, required this.text});
  final GlyphData glyph;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.accentSoft, borderRadius: Shapes.r16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Glyph(glyph, color: c.accent, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: context.type.bodySmall)),
        ],
      ),
    );
  }
}

class _SeenCard extends StatelessWidget {
  const _SeenCard({required this.screen, required this.labels, required this.onLabel});
  final Map<String, dynamic> screen;
  final List<String> labels;
  final void Function(String label) onLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = '${screen['app'] ?? ''}'.trim();
    final title = '${screen['title'] ?? ''}'.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            app.isEmpty ? 'Last look' : 'Last look: $app${title.isEmpty ? '' : ' — $title'}',
            style: context.type.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            labels.isEmpty ? 'No readable labels on that screen.' : 'Tap a label to go do it there.',
            style: context.type.bodySmall?.copyWith(color: c.muted),
          ),
          if (labels.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final label in labels.take(18))
                  ActionChip(
                    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                    onPressed: () => onLabel(label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.onEdit,
    required this.onEnabled,
    required this.onDelete,
  });
  final WatchRule rule;
  final VoidCallback onEdit;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: c.raised,
        borderRadius: Shapes.r14,
        child: InkWell(
          borderRadius: Shapes.r14,
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rule.title, style: context.type.titleSmall),
                      Text(rule.detail, style: context.type.bodySmall?.copyWith(color: c.muted)),
                      Text(
                        rule.prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.bodySmall?.copyWith(color: c.accent),
                      ),
                    ],
                  ),
                ),
                Switch(value: rule.enabled, onChanged: onEnabled),
                IconButton(
                  tooltip: 'Remove rule',
                  onPressed: onDelete,
                  icon: Glyph(G.trash, size: 18, color: c.faint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({this.rule});
  final WatchRule? rule;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _app = TextEditingController(text: widget.rule?.app ?? '');
  late final _contains = TextEditingController(text: widget.rule?.contains ?? '');
  late final _prompt = TextEditingController(text: widget.rule?.prompt ?? '');
  String? _problem;

  @override
  void dispose() {
    _app.dispose();
    _contains.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _save() {
    final app = _app.text.trim();
    final contains = _contains.text.trim();
    final prompt = _prompt.text.trim();
    if (app.isEmpty && contains.isEmpty) {
      setState(() => _problem = 'Name an app, a word in the notification, or both.');
      return;
    }
    if (prompt.isEmpty) {
      setState(() => _problem = 'Tell Compii what to do when it matches.');
      return;
    }
    Navigator.pop(
      context,
      WatchRule(
        id: widget.rule?.id ?? 'r${DateTime.now().microsecondsSinceEpoch}',
        app: app,
        contains: contains,
        prompt: prompt,
        enabled: widget.rule?.enabled ?? true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      title: Text(widget.rule == null ? 'Watch notifications' : 'Edit rule'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'When a notification arrives that matches, Compii sends what the notification said to your PC with your instruction.',
              style: context.type.bodySmall?.copyWith(color: c.muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _app,
              decoration: const InputDecoration(labelText: 'From app (optional)', hintText: 'WhatsApp'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _contains,
              decoration: const InputDecoration(labelText: 'Contains (optional)', hintText: 'urgent'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _prompt,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Ask Compii to',
                hintText: 'Read it and tell me whether I need to reply now.',
              ),
            ),
            if (_problem != null) ...[
              const SizedBox(height: 10),
              Text(_problem!, style: context.type.bodySmall?.copyWith(color: c.danger)),
            ],
            const SizedBox(height: 6),
            Text(
              'While Compii is open on this phone. At most one request per rule a minute.',
              style: context.type.bodySmall?.copyWith(color: c.faint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.app, required this.title, required this.text, required this.at});
  final String app;
  final String title;
  final String text;
  final int? at;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final clock = at == null ? '' : _clock(at!);
    final line = title.isEmpty ? text : text.isEmpty ? title : '$title · $text';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(color: c.raised, borderRadius: Shapes.r14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Glyph(G.bell, size: 18, color: c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(app.isEmpty ? 'An app' : app, style: context.type.labelLarge)),
                      if (clock.isNotEmpty) Text(clock, style: context.type.bodySmall?.copyWith(color: c.faint)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(line, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _clock(int millis) {
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    if (t.year == now.year && t.month == now.month && t.day == now.day) return '$hh:$mm';
    return '${t.day}/${t.month} $hh:$mm';
  }
}

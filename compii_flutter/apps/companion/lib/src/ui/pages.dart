import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'shell.dart';
import 'thread.dart';
import 'tokens.dart';
import 'trust.dart';
import 'voice.dart';

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.subtitle, required this.children});
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.type.headlineMedium),
              const SizedBox(height: 6),
              Text(subtitle, style: context.type.bodyLarge?.copyWith(color: context.c.muted)),
              const SizedBox(height: 24),
              ...children,
            ],
          ),
        ),
      ),
    ],
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: context.c.raised,
      border: Border.all(color: context.c.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );
}

/// What Compii remembers about you: inspectable and deletable.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, required this.core, required this.run});
  final CoreClient core;
  final Run run;
  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => widget.run(() async {
    final items = await widget.core.memories();
    if (mounted) setState(() => _items = items);
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final items = _items;
    return _Page(
      title: 'Memory',
      subtitle: 'Things Compii keeps to help you next time. Only what you or it chose to save — delete anything.',
      children: [
        if (items == null)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else if (items.isEmpty)
          _Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_outlined, color: c.accent),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Nothing saved yet. Try telling Compii: “Remember that I prefer short replies.”',
                      style: context.type.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          _Card(
            child: Column(
              children: [
                for (final (i, m) in items.indexed) ...[
                  if (i > 0) Divider(height: 1, color: c.border),
                  ListTile(
                    leading: Icon(Icons.bookmark_outline, color: c.accent),
                    title: Text('${m['fact']}', style: context.type.bodyMedium),
                    subtitle: m['at'] == null ? null : Text('Saved ${ago((m['at'] as num).toDouble())} ago', style: context.type.labelMedium),
                    trailing: IconButton(
                      tooltip: 'Forget this',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => widget.run(() async {
                        await widget.core.forget(m['id'] as int);
                        await _load();
                      }),
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

const _kinds = [
  ('read', 'Look at things', 'Read files, pages and settings', Icons.visibility_outlined),
  ('create', 'Create things', 'New files, folders and drafts', Icons.note_add_outlined),
  ('change', 'Change things', 'Move or edit files, run scripts, open apps', Icons.edit_outlined),
  ('send', 'Send things', 'Emails and messages to other people', Icons.send_outlined),
  ('delete', 'Delete things', 'Remove files or data', Icons.delete_outline),
  ('spend', 'Spend money', 'Purchases and payments — always asks', Icons.payments_outlined),
];

const _levels = [
  ('just_do_it', 'Just do it'),
  ('ask_once_per_task', 'Ask once'),
  ('ask_every_time', 'Always ask'),
];

/// The autonomy dial and appearance.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.core, required this.state, required this.run});
  final CoreClient core;
  final AppState state;
  final Run run;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, String>? _dial;

  @override
  void initState() {
    super.initState();
    widget.run(() async {
      final d = await widget.core.policy();
      if (mounted) setState(() => _dial = d);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dial = _dial;
    return _Page(
      title: 'Settings',
      subtitle: 'How much Compii may do on its own, and how it looks.',
      children: [
        Text('Brain', style: context.type.titleLarge),
        const SizedBox(height: 4),
        Text('Which AI does the thinking. Free local models run on this PC; cloud ones need your own key.',
            style: context.type.bodySmall),
        const SizedBox(height: 12),
        BrainCard(run: widget.run),
        const SizedBox(height: 28),
        Text('Autonomy', style: context.type.titleLarge),
        const SizedBox(height: 4),
        Text('For each kind of action, choose whether Compii asks first. Every action is recorded either way.', style: context.type.bodySmall),
        const SizedBox(height: 12),
        _Card(
          child: dial == null
              ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              : Column(
                  children: [
                    for (final (i, (kind, title, sub, icon)) in _kinds.indexed) ...[
                      if (i > 0) Divider(height: 1, color: c.border),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                        child: Row(
                          children: [
                            Icon(icon, color: tierColors(context, kind).$1),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title, style: context.type.titleSmall),
                                  Text(sub, style: context.type.bodySmall),
                                ],
                              ),
                            ),
                            SegmentedButton<String>(
                              showSelectedIcon: false,
                              style: SegmentedButton.styleFrom(
                                textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: [
                                for (final (value, label) in _levels)
                                  ButtonSegment(
                                    value: value,
                                    label: Text(label),
                                    enabled: !(kind == 'spend' && value == 'just_do_it'),
                                  ),
                              ],
                              selected: {dial[kind] ?? 'ask_every_time'},
                              onSelectionChanged: (s) => widget.run(() async {
                                final d = await widget.core.setPolicy(kind, s.first);
                                if (mounted) setState(() => _dial = d);
                              }),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 28),
        if (widget.state.voice != null) ...[
          VoiceSettings(voice: widget.state.voice!, run: widget.run),
          const SizedBox(height: 28),
        ],
        Text('Appearance', style: context.type.titleLarge),
        const SizedBox(height: 12),
        _Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                Icon(Icons.contrast, color: c.muted),
                const SizedBox(width: 14),
                Expanded(child: Text('Theme', style: context.type.titleSmall)),
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('System')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ],
                  selected: {widget.state.themeMode},
                  onSelectionChanged: (s) => widget.state.setTheme(s.first),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        Text('Shortcuts', style: context.type.titleLarge),
        const SizedBox(height: 12),
        _Card(
          child: Column(
            children: [
              for (final (i, (keys, what)) in const [
                ('Alt + Space', 'Open the quick bar from anywhere'),
                ('Ctrl + Alt + Space', 'Talk to Compii from anywhere (press again to send)'),
                ('Ctrl + N', 'New conversation'),
                ('Enter / Shift + Enter', 'Send / new line'),
                ('Esc', 'Close the quick bar'),
              ].indexed) ...[
                if (i > 0) Divider(height: 1, color: c.border),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(child: Text(what, style: context.type.bodyMedium)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: c.sunken, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.border)),
                        child: Text(keys, style: context.type.labelMedium?.copyWith(color: c.text)),
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


/// Voice: free and local. Nothing downloads until the user presses a button.
class VoiceSettings extends StatelessWidget {
  const VoiceSettings({super.key, required this.voice, required this.run});
  final VoiceController voice;
  final Run run;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: voice,
    builder: (context, _) {
      final c = context.c;
      final st = voice.status;
      final sizes = Map<String, dynamic>.from(st?['download_sizes_mb'] as Map? ?? {});
      final voices = Map<String, dynamic>.from(st?['voices'] as Map? ?? {});
      final settings = Map<String, dynamic>.from(st?['settings'] as Map? ?? {});
      Widget row(IconData icon, String title, String sub, Widget trailing) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(icon, color: c.accent),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(title, style: context.type.titleSmall), Text(sub, style: context.type.bodySmall)],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      );
      Widget download(String what, String label) {
        final progress = voice.downloading[what];
        if (progress != null) {
          return SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                LinearProgressIndicator(value: (progress as num).toDouble() > 0 ? progress.toDouble() : null),
                const SizedBox(height: 4),
                Text('Downloading…', style: context.type.labelMedium),
              ],
            ),
          );
        }
        return OutlinedButton.icon(
          onPressed: () => run(() => voice.download(what)),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text('$label · ${sizes[what] ?? '?'} MB'),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Voice', style: context.type.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Free and private: speech runs on this PC with open models. No account, no per-use cost, and your audio never leaves your computer.',
            style: context.type.bodySmall,
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(color: c.raised, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(14)),
            child: st == null
                ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                : Column(
                    children: [
                      row(
                        Icons.mic_none,
                        'Talk to Compii',
                        voice.canListen
                            ? 'Ready. Click Compii or the mic and speak; Ctrl + Alt + Space works from anywhere.'
                            : 'Uses Whisper, an open speech model, running on your PC.',
                        voice.canListen
                            ? Icon(Icons.check_circle, color: c.success)
                            : download('listen', 'Download'),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        Icons.hearing,
                        'Hands-free: “Hey Compii”',
                        voice.canListen
                            ? 'Say “Hey Compii” and your request. The mic stays open while this is on, but nothing is recorded or sent anywhere: '
                                'only short bursts of speech are checked on this PC. Pauses while Compii talks.'
                            : 'Needs speech recognition first (above).',
                        Switch(
                          value: voice.wakeListening,
                          onChanged: voice.canListen ? (v) => run(() => voice.set({'wake_word': v})) : null,
                        ),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        Icons.record_voice_over_outlined,
                        'Speak replies out loud',
                        'Compii says its answers and questions. Click it, press the mic, or Stop to interrupt.',
                        Switch(
                          value: voice.speakReplies,
                          onChanged: (v) => run(() => voice.set({'speak_replies': v})),
                        ),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        Icons.graphic_eq,
                        voice.naturalVoice ? 'Natural voice (Kokoro)' : 'Windows voice (built in)',
                        voice.naturalVoice
                            ? 'An open voice model on your PC. Pick how Compii sounds.'
                            : 'Works now. Download Kokoro, a free open voice model, for a much more natural sound.',
                        voice.naturalVoice
                            ? DropdownButton<String>(
                                value: '${settings['voice']}',
                                underline: const SizedBox.shrink(),
                                items: [
                                  for (final e in voices.entries)
                                    DropdownMenuItem(value: e.key, child: Text('${e.value}')),
                                ],
                                onChanged: (v) => run(() => voice.set({'voice': v})),
                              )
                            : download('speak', 'Get natural voice'),
                      ),
                    ],
                  ),
          ),
          if (voice.error != null) ...[
            const SizedBox(height: 8),
            Text(voice.error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
          ],
        ],
      );
    },
  );
}

import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'shell.dart';
import 'thread.dart';
import 'tokens.dart';
import 'trust.dart';
import 'voice.dart';
import 'phones.dart';
import 'chrome.dart';
import 'glyphs.dart';
import '../app_control.dart';
import '../console/character.dart';
import '../updates.dart';
import 'first_run.dart';

/// One of Compii's bodies, shown wearing the face it will actually use. No name
/// under it: the shape is the choice, and a screen reader gets a description.
class _FormTile extends StatelessWidget {
  const _FormTile({required this.body, required this.selected, required this.onTap});
  final CompiiBody body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: selected,
      label: body.desc,
      child: InkWell(
        onTap: onTap,
        borderRadius: Shapes.r12,
        child: AnimatedContainer(
          duration: context.motion(180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: selected ? c.accent.withValues(alpha: .10) : c.sunken,
            borderRadius: Shapes.r12,
            border: Border.all(color: selected ? c.accent : c.border, width: selected ? 1.6 : 1),
          ),
          child: Center(
            child: SizedBox.square(
              dimension: 64,
              child: Ember(
                mood: Mood.idle,
                body: body,
                animate: false,
                phase: .3,
                followPointer: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The coat, as the three tones the fur is actually brushed with.
class _CoatTile extends StatelessWidget {
  const _CoatTile({required this.coat, required this.selected, required this.onTap});
  final CompiiCoat coat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: selected,
      label: '${coat.desc} coat',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: context.motion(180),
          curve: Curves.easeOut,
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: coat.chip,
            ),
            border: Border.all(
              color: selected ? c.accent : c.border,
              width: selected ? 2.6 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: Shapes.panel(context.c),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// What Compii remembers about you: inspectable and deletable.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, required this.core, required this.run, this.focusId});
  final CoreClient core;
  final Run run;

  /// A memory to call out, when search brought the user here.
  final String? focusId;
  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  List<Map<String, dynamic>>? _items;
  final _focusTile = GlobalKey();
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MemoryPage old) {
    super.didUpdateWidget(old);
    if (widget.focusId != null && widget.focusId != old.focusId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocus());
    }
  }

  Future<void> _load() async {
    await widget.run(() async {
      if (mounted) setState(() => _loadFailed = false);
      try {
        final items = await widget.core.memories();
        if (mounted) setState(() => _items = items);
      } catch (_) {
        if (mounted) setState(() => _loadFailed = true);
        rethrow;
      }
    });
    if (mounted && widget.focusId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocus());
    }
  }

  void _revealFocus() {
    final found = _focusTile.currentContext;
    if (found != null) {
      Scrollable.ensureVisible(found, duration: context.motion(240),
          alignment: .35, curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final items = _items;
    return PageScaffold(
      glyph: pageGlyph('Memory'),
      title: 'Memory',
      subtitle: 'Things Compii keeps to help you next time. Only what you or it chose to save — delete anything.',
      children: [
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (items == null)
          _loadFailed ? const SizedBox.shrink() : const SkeletonCards(rows: 3)
        else if (items.isEmpty)
          _Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AdaptiveRow(
                children: [
                  GlyphTile(glyph: G.memory, size: 34, color: c.accent),
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
                    key: widget.focusId != null && '${m['id']}' == widget.focusId ? _focusTile : null,
                    tileColor: widget.focusId != null && '${m['id']}' == widget.focusId ? c.accentSoft : null,
                    leading: GlyphTile(glyph: G.bookmark, size: 34, color: c.accent),
                    title: Text('${m['fact']}', style: context.type.bodyMedium),
                    subtitle: m['at'] == null ? null : Text('Saved ${ago((m['at'] as num).toDouble())} ago', style: context.type.labelMedium),
                    trailing: IconButton(
                      tooltip: 'Forget this',
                      icon: const Glyph(G.trash),
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
  ('read', 'Look at things', 'Read files, pages and settings', G.eye),
  ('create', 'Create things', 'New files, folders and drafts', G.note),
  ('change', 'Change things', 'Move or edit files, run scripts, open apps', G.edit),
  ('send', 'Send things', 'Emails and messages to other people', G.send),
  ('delete', 'Delete things', 'Remove files or data', G.trash),
  ('spend', 'Spend money', 'Purchases and payments — always asks', G.money),
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
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
      final d = await widget.core.policy();
      if (mounted) setState(() => _dial = d);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dial = _dial;
    return PageScaffold(
      glyph: pageGlyph('Settings'),
      title: 'Settings',
      subtitle: 'How much Compii may do on its own, and how it looks.',
      children: [
        SectionHeader('Brain',
            subtitle: 'Which AI does the thinking. Free local models run on this PC; cloud ones need your own key.',
            top: 0),
        BrainCard(run: widget.run),
        const SizedBox(height: 14),
        UsageCard(run: widget.run),
        const SizedBox(height: 28),
        SectionHeader('Autonomy',
            subtitle: 'For each kind of action, choose whether Compii asks first. Every action is recorded either way.',
            top: 0),
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (dial != null || !_loadFailed)
          _Card(
            child: dial == null
                ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                : Column(
                    children: [
                      for (final (i, (kind, title, sub, icon)) in _kinds.indexed) ...[
                        if (i > 0) Divider(height: 1, color: c.border),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                          child: AdaptiveRow(
                            children: [
                              GlyphTile(glyph: icon, size: 34, color: tierColors(context, kind).$1),
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
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 250),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SegmentedButton<String>(
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
                                      if (!mounted) return;
                                      setState(() {
                                        _dial = d;
                                        _loadFailed = false;
                                      });
                                    }),
                                  ),
                                ),
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
        PhonesSettings(core: widget.core, run: widget.run),
        const SizedBox(height: 28),
        SectionHeader('Appearance', top: 0),
        _Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: AdaptiveRow(
              children: [
                GlyphTile(glyph: G.contrast, size: 34, color: c.muted),
                const SizedBox(width: 14),
                Expanded(child: Text('Theme', style: context.type.titleSmall)),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 210),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<ThemeMode>(
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
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _Card(
          child: OptionRow(
            glyph: G.chat,
            title: 'How Compii answers',
            subtitle: 'Character: Compii is the main figure and replies in a speech bubble. Chat: a full message history.',
            color: c.muted,
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Character')),
                    ButtonSegment(value: true, label: Text('Chat')),
                  ],
                  selected: {widget.state.chatView},
                  onSelectionChanged: (s) => widget.state.setChatView(s.first),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveRow(
                  children: [
                    GlyphTile(glyph: G.wand, size: 34, color: c.muted),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Compii’s form', style: context.type.titleSmall),
                          const SizedBox(height: 3),
                          Text(
                            'The same face and the same moods in every body. Pick the shape and '
                            'the colour of its coat. Kept on this PC.',
                            style: context.type.bodySmall?.copyWith(color: c.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, box) {
                    const gap = 10.0;
                    final n = CompiiBody.values.length;
                    final w = ((box.maxWidth - gap * (n - 1)) / n).clamp(66.0, 104.0);
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final b in CompiiBody.values)
                          SizedBox(
                            width: w,
                            child: _FormTile(
                              body: b,
                              selected: b == widget.state.body,
                              onTap: () => widget.state.setBody(b),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final k in CompiiCoat.values)
                      _CoatTile(
                        coat: k,
                        selected: k == widget.state.coat,
                        onTap: () => widget.state.setCoat(k),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        SectionHeader('Shortcuts', top: 0),
        _Card(
          child: Column(
            children: [
              for (final (i, (keys, what)) in const [
                ('Hold Ctrl + Alt', 'Talk to Compii from any app; move the mouse over what you mean, let go to send'),
                ('Tap Ctrl + Alt', 'With words highlighted: Compii reads them off the app and asks what to do — no copying'),
                ('Hold Ctrl + Win', 'Dictate: your words are typed where your cursor is'),
                ('Alt + Space', 'Show or hide the Compii window'),
                ('Ctrl + Alt + Shift + S', 'Emergency stop: stop everything'),
                ('Say “watch me” … “done”', 'Show Compii a task once; it saves the steps as a skill'),
                ('Say “say that again” / “hide”', 'Repeat the last answer, or hide the buddy (“show yourself” brings it back)'),
                ('Ctrl + N', 'New conversation'),
                ('Enter / Shift + Enter', 'Send / new line'),
                ('Esc', 'Close the quick bar'),
              ].indexed) ...[
                if (i > 0) Divider(height: 1, color: c.border),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: AdaptiveRow(
                    children: [
                      Expanded(child: Text(what, style: context.type.bodyMedium)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r6, border: Border.all(color: c.border)),
                        child: Text(keys, style: context.type.labelMedium?.copyWith(color: c.text)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text('Help', style: context.type.titleLarge),
        const SizedBox(height: 12),
        _Card(
          child: OptionRow(
            glyph: G.shield,
            title: 'Save a diagnostic report',
            subtitle: 'If something isn’t working, save a report and send it to whoever helps you. Keys, tokens and '
                'your user name are removed, and nothing is sent automatically.',
            color: c.muted,
            trailing: OutlinedButton(
              onPressed: () => widget.run(() => TrustApi.call('POST', '/diagnostics')),
              child: const Text('Save report'),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _Card(
          child: OptionRow(
            glyph: G.wand,
            title: 'Run setup again',
            subtitle: 'Walk through keys, voice, a first try and your privacy choices again.',
            color: c.muted,
            trailing: OutlinedButton(onPressed: () => firstRunRequested.value = true, child: const Text('Set up')),
          ),
        ),
        const SizedBox(height: 10),
        _Card(
          child: OptionRow(
            glyph: G.power,
            title: 'Quit Compii',
            subtitle: 'Closing the window only hides it, so Ctrl + Alt keeps working. This really quits.',
            color: c.danger,
            trailing: OutlinedButton(onPressed: appControl.quit, child: const Text('Quit')),
          ),
        ),
        const SizedBox(height: 28),
        Text('On this PC', style: context.type.titleLarge),
        const SizedBox(height: 12),
        AboutCard(core: widget.core),
      ],
    );
  }
}

/// What is installed, and how it moves up. A build that didn't come from Compii's own installer
/// can't update itself, and this says that instead of offering a button that would fail.
class AboutCard extends StatefulWidget {
  const AboutCard({super.key, required this.core});
  final CoreClient core;

  @override
  State<AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<AboutCard> {
  final ChangeNotifier _idle = ChangeNotifier();

  @override
  void dispose() {
    _idle.dispose();
    super.dispose();
  }

  (String, Widget?) _shown(Updater? up) {
    final here = 'Compii Core ${widget.core.coreVersion.isEmpty ? 'is running' : widget.core.coreVersion}';
    if (up == null) {
      return (
        '$here. This copy wasn’t installed with Compii’s installer, so it can’t update itself — '
            'run the new Setup.exe when you want a newer one.',
        null,
      );
    }
    final busy = const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2));
    return switch (up.stage) {
      UpdateStage.checking => ('$here. Checking for a newer version…', busy),
      UpdateStage.current => (
        '$here. This is the newest version.',
        OutlinedButton(onPressed: up.check, child: const Text('Check again')),
      ),
      UpdateStage.ready => (
        '$here. Version ${up.to} is waiting.',
        FilledButton(onPressed: up.install, child: const Text('Update and restart')),
      ),
      UpdateStage.downloading => (
        '$here. Downloading version ${up.to}${up.percent > 0 ? ' — ${up.percent}%' : ''}…',
        busy,
      ),
      UpdateStage.applying => (
        'Closing Compii and putting version ${up.to} in place. It opens again by itself.',
        busy,
      ),
      UpdateStage.problem => (
        '$here. ${up.problem}',
        OutlinedButton(
          onPressed: up.canInstall ? up.install : up.check,
          child: const Text('Try again'),
        ),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final up = updates;
    return ListenableBuilder(
      listenable: up ?? _idle,
      builder: (context, _) {
        final (about, action) = _shown(up);
        return _Card(
          child: OptionRow(
            glyph: G.sync,
            title: 'Keep Compii up to date',
            subtitle: about,
            color: c.muted,
            trailing: action,
          ),
        );
      },
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
      Widget row(GlyphData icon, String title, String sub, Widget trailing) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: AdaptiveRow(
          children: [
            GlyphTile(glyph: icon, size: 34, color: c.accent),
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
          icon: const Glyph(G.download, size: 18),
          label: Text('$label · ${sizes[what] ?? '?'} MB'),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            'Voice',
            top: 0,
            subtitle:
                'Free: Compii’s voice runs on this PC. With a Groq key stored, what you say is recognised on Groq (fast, and spares your PC); turn that off below to keep everything on this PC.',
          ),
          const SizedBox(height: 4),
          if (voice.statusFailed && st != null) ...[
            LoadFailure(onRetry: voice.refresh),
            const SizedBox(height: Space.m - 4),
          ],
          Container(
            decoration: BoxDecoration(color: c.raised, border: Border.all(color: c.border), borderRadius: Shapes.r14),
            child: st == null
                ? voice.statusFailed
                    ? Padding(padding: const EdgeInsets.all(Space.s), child: LoadFailure(onRetry: voice.refresh))
                    : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                : Column(
                    children: [
                      row(
                        G.mic,
                        'Talk to Compii',
                        voice.canListen
                            ? 'Ready. Hold Ctrl + Alt in any app and talk, or tap Compii here.'
                            : 'Uses Whisper, an open speech model, running on your PC.',
                        voice.canListen
                            ? Glyph(G.checkCircle, color: c.success)
                            : download('listen', 'Download'),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        G.ear,
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
                        G.speakingHead,
                        'How Compii answers you',
                        'Out loud, a chime with the words on screen, the words on their own, or nothing at all. '
                            'Full answers are always in the conversation.',
                        ScrollCapped(
                          child: DropdownButton<String>(
                            value: voice.outputMode,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final (mode, label) in const [
                                ('voice', 'Speak'),
                                ('sound', 'Chime + words on screen'),
                                ('caption', 'Words on screen'),
                                ('off', 'Nothing'),
                              ])
                                DropdownMenuItem(value: mode, child: Text(label)),
                            ],
                            onChanged: (v) => run(() => voice.set({'output_mode': v})),
                          ),
                        ),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        G.wave,
                        voice.engine == 'fast'
                            ? 'Fast voice (Piper)'
                            : voice.naturalVoice
                                ? 'Natural voice (Kokoro)'
                                : 'Windows voice (built in)',
                        voice.engine == 'fast'
                            ? 'Compii speaks at the speed the words arrive, so answers never trail behind the text.'
                            : voice.naturalVoice
                                ? 'An open voice model on your PC. Pick how Compii sounds.'
                                : 'Works now. Download Kokoro, a free open voice model, for a much more natural sound.',
                        voice.engine != 'fast' && voice.naturalVoice
                            ? ScrollCapped(
                                child: DropdownButton<String>(
                                  value: '${settings['voice']}',
                                  underline: const SizedBox.shrink(),
                                  items: [
                                    for (final e in voices.entries)
                                      DropdownMenuItem(value: e.key, child: Text('${e.value}')),
                                  ],
                                  onChanged: (v) => run(() => voice.set({'voice': v})),
                                ),
                              )
                            : voice.naturalVoice
                                ? Glyph(G.checkCircle, color: c.success)
                                : download('speak', 'Get natural voice'),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        G.bolt,
                        'Speak faster',
                        voice.fastVoice
                            ? 'Piper, a compact voice model that runs faster than real time on this PC. '
                                'Free, downloaded once, never leaves your PC.'
                            : 'A compact voice model that keeps up with the text instead of trailing behind it. '
                                'Free, 64 MB, stays on this PC.',
                        voice.fastVoice
                            ? Switch(
                                value: voice.engine == 'fast',
                                onChanged: (v) => run(() => voice.set({
                                  'engine': v ? 'fast' : (voice.naturalVoice ? 'natural' : 'windows'),
                                })),
                              )
                            : download('speak_fast', 'Get fast voice'),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        G.mic,
                        'Recognise speech on Groq',
                        'Faster and more accurate, and spares your PC. Your recording goes to Groq (free) only while you '
                            'hold Ctrl + Alt. Off: recognised on this PC.',
                        Switch(
                          value: settings['cloud_listening'] != false,
                          onChanged: (v) => run(() => voice.set({'cloud_listening': v})),
                        ),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        G.monitor,
                        'Let Compii see your screen',
                        'Which windows are open and what\'s in them, so Compii can help with the app you\'re '
                            'actually using. Off is a real off: nothing is read, and Compii says so instead of '
                            'guessing. A light shows whenever it looks.',
                        Switch(
                          value: settings['screen_aware'] != false,
                          onChanged: (v) => run(() => voice.set({'screen_aware': v})),
                        ),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        G.eye,
                        'See apps that draw their own screens',
                        'Blender, games and design tools don\'t list their buttons. When you ask about one of them, Compii '
                            'sends a picture of that window (never password managers) to a free NVIDIA vision model.',
                        Switch(
                          value: settings['see_pictures'] != false,
                          onChanged: (v) => run(() => voice.set({'see_pictures': v})),
                        ),
                      ),
                      Divider(height: 1, color: c.border),
                      row(
                        G.power,
                        'Start with Windows',
                        'Compii starts quietly when you sign in, so Ctrl + Alt always works. Alt + Space opens this window.',
                        const _StartWithWindows(),
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

/// Start-with-Windows switch: reads and writes the per-user start-up entry.
class _StartWithWindows extends StatefulWidget {
  const _StartWithWindows();
  @override
  State<_StartWithWindows> createState() => _StartWithWindowsState();
}

class _StartWithWindowsState extends State<_StartWithWindows> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    appControl.startsWithWindows().then((v) => mounted ? setState(() => _on = v) : null, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) => Switch(
    value: _on ?? false,
    onChanged: _on == null
        ? null
        : (v) async {
            setState(() => _on = v);
            try {
              await appControl.setStartWithWindows(v);
            } on Object {
              if (mounted) setState(() => _on = !v);
            }
          },
  );
}

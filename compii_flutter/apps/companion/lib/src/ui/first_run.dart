import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_control.dart';
import '../console/character.dart';
import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'tokens.dart';
import 'trust.dart';
import 'voice.dart';

/// Set to true (e.g. from Settings → Help) to walk through setup again.
final firstRunRequested = ValueNotifier<bool>(false);

const _doneKey = 'first_run_done_v1';

/// Shows the first-run setup until it has been finished once (or everything is already set up),
/// then the app itself.
class FirstRunGate extends StatefulWidget {
  const FirstRunGate({super.key, required this.core, required this.voice, required this.child});
  final CoreClient core;
  final VoiceController? voice;
  final Widget child;
  @override
  State<FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<FirstRunGate> {
  bool? _show;

  @override
  void initState() {
    super.initState();
    firstRunRequested.addListener(_again);
    _decide();
  }

  @override
  void dispose() {
    firstRunRequested.removeListener(_again);
    super.dispose();
  }

  void _again() {
    if (firstRunRequested.value && mounted) setState(() => _show = true);
  }

  Future<void> _decide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) {
      if (mounted) setState(() => _show = false);
      return;
    }
    // Already set up (an AI key and a voice)? Then don't make anyone walk through it.
    var ready = false;
    try {
      final brain = await TrustApi.map('GET', '/brain');
      final keys = Map<String, dynamic>.from(brain['keys'] as Map? ?? {});
      final voice = await TrustApi.map('GET', '/voice');
      ready = keys.values.any((v) => v == true) && voice['listen_ready'] == true && voice['natural_voice'] == true;
    } on Object {
      ready = false;
    }
    if (ready) await prefs.setBool(_doneKey, true);
    if (mounted) setState(() => _show = !ready);
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_doneKey, true);
    firstRunRequested.value = false;
    if (mounted) setState(() => _show = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_show == null) return const SizedBox.shrink();
    if (_show == false) return widget.child;
    return FirstRun(core: widget.core, voice: widget.voice, onDone: _finish);
  }
}

/// Setup in five short steps, with Compii guiding: a free AI key (pasted here, stored in
/// Windows Credential Manager), Compii's voice, a first Ctrl + Alt try, privacy and start-up.
class FirstRun extends StatefulWidget {
  const FirstRun({super.key, required this.core, required this.voice, required this.onDone, this.initialStep = 0,
    this.preview});
  final CoreClient core;
  final VoiceController? voice;
  final Future<void> Function() onDone;
  final int initialStep;

  /// Tests and previews: {'brain': …, 'voice': …} instead of asking Compii Core.
  final Map<String, Map<String, dynamic>>? preview;
  @override
  State<FirstRun> createState() => _FirstRunState();
}

class _FirstRunState extends State<FirstRun> {
  late int step = widget.initialStep;
  Map<String, dynamic> brain = {};
  Map<String, dynamic> voiceStatus = {};
  String? error;
  String heard = '';
  bool busy = false;
  bool? startsWithWindows;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final _groq = TextEditingController();
  final _nvidia = TextEditingController();

  static const steps = ['Hello', 'Thinking', 'Voice', 'Try it', 'Your choices'];

  @override
  void initState() {
    super.initState();
    _refresh();
    if (widget.preview == null) {
      appControl.startsWithWindows().then((v) => mounted ? setState(() => startsWithWindows = v) : null, onError: (_) {});
    } else {
      startsWithWindows = false;
    }
    _sub = widget.core.voiceEvents.stream.listen((e) {
      if (e['type'] == 'voice_buddy' && e['state'] == 'thinking' && '${e['heard'] ?? ''}'.isNotEmpty && mounted) {
        setState(() => heard = '${e['heard']}');
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _groq.dispose();
    _nvidia.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final preview = widget.preview;
    if (preview != null) {
      setState(() => (brain = preview['brain'] ?? {}, voiceStatus = preview['voice'] ?? {}));
      return;
    }
    try {
      final b = await TrustApi.map('GET', '/brain');
      final v = await TrustApi.map('GET', '/voice');
      if (mounted) setState(() => (brain = b, voiceStatus = v));
    } on Object catch (e) {
      if (mounted) setState(() => error = 'Compii Core isn’t answering yet ($e). It starts by itself; try again in a moment.');
    }
  }

  bool _has(String key) => (brain['keys'] as Map?)?[key] == true;
  Map<String, dynamic> get _settings => Map<String, dynamic>.from(voiceStatus['settings'] as Map? ?? {});

  Future<void> _run(Future<void> Function() job) async {
    setState(() => (busy = true, error = null));
    try {
      await job();
      await _refresh();
    } on Object catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveKey(String name, TextEditingController field) => _run(() async {
    final value = field.text.trim();
    if (value.isEmpty) throw Exception('Paste the key first.');
    await TrustApi.map('PUT', '/keys/$name', {'value': value});
    field.clear(); // the key now lives in Windows Credential Manager, never in the app
    if (name == 'groq') {
      // Groq thinks; NVIDIA (if stored) is the backup.
      await TrustApi.map('PUT', '/brain', {
        'primary': {'provider': 'groq', 'model': '', 'base_url': ''},
        'fallback': _has('nvidia') ? {'provider': 'nvidia', 'model': '', 'base_url': ''} : null,
        'fallback_enabled': _has('nvidia'),
      });
    }
  });

  void _open(String url) {
    if (Platform.isWindows) Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      backgroundColor: c.canvas,
      body: Column(
        children: [
          const TitleBar(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _progress(context),
                      const SizedBox(height: 18),
                      Center(
                        child: Aura(
                          size: 190,
                          child: SizedBox.square(
                            dimension: 130,
                            child: Orbling(mood: step == 0 || step == 4 ? Mood.happy : step == 3 ? Mood.listening : Mood.idle),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._page(context),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
                      ],
                      const SizedBox(height: 22),
                      _nav(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progress(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= step ? c.accent : c.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 6),
                Text(steps[i], style: context.type.labelSmall?.copyWith(color: i == step ? c.text : c.muted)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _page(BuildContext context) {
    final t = context.type;
    Text h(String s) => Text(s, textAlign: TextAlign.center, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700));
    Text p(String s) => Text(s, textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: context.c.muted));
    switch (step) {
      case 0:
        return [
          h('Hi, I’m Compii.'),
          const SizedBox(height: 8),
          p('I live beside your cursor. Hold Ctrl + Alt in any app and ask me anything: I can see what you’re '
              'looking at, show you where things are, teach you apps step by step, and do tasks for you, '
              'always asking before anything important. Setup takes about two minutes, and it’s free.'),
        ];
      case 1:
        return [
          h('Give me a brain'),
          const SizedBox(height: 8),
          p('I think with Groq, a free and very fast AI. Make a free key (no card needed), then paste it here. '
              'It’s stored safely in Windows Credential Manager and never shown again.'),
          const SizedBox(height: 16),
          _keyCard(context, 'groq', 'Groq key', 'Free · thinking and listening', 'https://console.groq.com/keys', _groq),
          const SizedBox(height: 10),
          _keyCard(context, 'nvidia', 'NVIDIA key (optional)', 'Free · a backup brain, and seeing apps like Blender',
              'https://build.nvidia.com/settings/api-keys', _nvidia),
        ];
      case 2:
        final natural = voiceStatus['natural_voice'] == true;
        final voices = Map<String, dynamic>.from(voiceStatus['voices'] as Map? ?? {});
        final progress = (voiceStatus['downloading'] as Map?)?['speak'];
        return [
          h('My voice'),
          const SizedBox(height: 8),
          p('My voice runs on your PC, so it’s free and private. Pick the one you like.'),
          const SizedBox(height: 16),
          _card(context, G.speakingHead, natural ? 'Natural voice ready' : 'Natural voice · 120 MB',
              natural ? 'Choose how I sound, then tap Hear me.' : 'A one-time download of an open voice model.',
              natural
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      DropdownButton<String>(
                        value: voices.containsKey(_settings['voice']) ? '${_settings['voice']}' : null,
                        underline: const SizedBox.shrink(),
                        items: [for (final e in voices.entries) DropdownMenuItem(value: e.key, child: Text('${e.value}'))],
                        onChanged: (v) => _run(() async => widget.voice?.set({'voice': v})),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: busy ? null : () => _run(() async => TrustApi.call('POST', '/voice/say',
                            {'text': 'Hi! I’m Compii. I’m here whenever you need me.'})),
                        child: const Text('Hear me'),
                      ),
                    ])
                  : progress != null
                      ? const SizedBox(width: 120, child: LinearProgressIndicator())
                      : FilledButton(
                          onPressed: busy ? null : () => _run(() async => widget.voice?.download('speak')),
                          child: const Text('Download'),
                        )),
        ];
      case 3:
        final ready = voiceStatus['listen_ready'] == true;
        return [
          h('Try it'),
          const SizedBox(height: 8),
          p(ready
              ? 'Hold Ctrl + Alt, say “Hi Compii, what can you do?”, then let go. You can do this in any app.'
              : 'Add a Groq key (step 2) so I can hear you, or download on-PC listening in Settings → Voice.'),
          const SizedBox(height: 16),
          _card(context, G.mic, heard.isEmpty ? 'Waiting for you…' : 'I heard you!',
              heard.isEmpty ? 'Hold both keys while you talk.' : '“$heard”',
              heard.isEmpty ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Glyph(G.checkCircle, color: context.c.success)),
        ];
      default:
        return [
          h('Your choices'),
          const SizedBox(height: 8),
          p('You can change these any time in Settings.'),
          const SizedBox(height: 16),
          _card(context, G.mic, 'Recognise speech on Groq', 'Faster and spares your PC. Your recording goes to Groq only '
              'while you hold Ctrl + Alt.', Switch(
                value: _settings['cloud_listening'] != false,
                onChanged: (v) => _run(() async => widget.voice?.set({'cloud_listening': v})),
              )),
          const SizedBox(height: 10),
          _card(context, G.eye, 'See apps that draw their own screens', 'For Blender, games and editors: a picture of '
              'that window only when you ask about it. Never password managers.', Switch(
                value: _settings['see_pictures'] != false,
                onChanged: (v) => _run(() async => widget.voice?.set({'see_pictures': v})),
              )),
          const SizedBox(height: 10),
          _card(context, G.power, 'Start with Windows', 'So Ctrl + Alt always works. Alt + Space opens this window.',
              Switch(
                value: startsWithWindows ?? false,
                onChanged: startsWithWindows == null
                    ? null
                    : (v) => _run(() async {
                          await appControl.setStartWithWindows(v);
                          if (mounted) setState(() => startsWithWindows = v);
                        }),
              )),
        ];
    }
  }

  Widget _keyCard(BuildContext context, String key, String title, String sub, String url, TextEditingController field) {
    final c = context.c;
    if (_has(key)) return _card(context, G.key, '$title stored', sub, Glyph(G.checkCircle, color: c.success));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.raised, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            GlyphTile(glyph: G.key, size: 34, color: c.accent),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: context.type.titleSmall),
              Text(sub, style: context.type.bodySmall),
            ])),
            TextButton(onPressed: () => _open(url), child: const Text('Get a free key')),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: field,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(isDense: true, hintText: 'Paste your key', border: OutlineInputBorder()),
                onSubmitted: (_) => _saveKey(key, field),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: busy ? null : () => _saveKey(key, field), child: const Text('Save')),
          ]),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, GlyphData glyph, String title, String sub, Widget trailing) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.raised, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        GlyphTile(glyph: glyph, size: 34, color: c.accent),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: context.type.titleSmall),
          Text(sub, style: context.type.bodySmall),
        ])),
        const SizedBox(width: 10),
        trailing,
      ]),
    );
  }

  Widget _nav(BuildContext context) {
    final last = step == steps.length - 1;
    final canGo = step != 1 || _has('groq') || _has('nvidia');
    return Row(
      children: [
        if (step > 0) TextButton(onPressed: () => setState(() => step--), child: const Text('Back')),
        const Spacer(),
        if (!last && step > 0)
          TextButton(onPressed: () => setState(() => step++), child: const Text('Skip')),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: busy || !canGo
              ? null
              : () async {
                  if (last) {
                    await widget.onDone();
                  } else {
                    setState(() => step++);
                    await _refresh();
                  }
                },
          child: Text(step == 0 ? 'Let’s go' : last ? 'Start using Compii' : 'Next'),
        ),
      ],
    );
  }
}

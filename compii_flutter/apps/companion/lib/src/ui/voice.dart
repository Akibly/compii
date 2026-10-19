import 'dart:async';

import 'package:flutter/material.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'tokens.dart';
import 'glyphs.dart';

/// App side of Compii's free, local voice: push-to-talk with a live
/// transcript, and knowing when Compii is speaking so it can be interrupted.
class VoiceController extends ChangeNotifier {
  VoiceController(this.core) {
    _sub = core.voiceEvents.stream.listen(_onEvent);
    core.addListener(_onCore);
  }

  final CoreClient core;
  late final StreamSubscription<Map<String, dynamic>> _sub;

  bool listening = false;
  bool speaking = false;
  bool busy = false; // transcribing after release
  String partial = '';
  double level = 0;

  /// What Compii is saying right now (live caption).
  String caption = '';

  /// The last short command handled by voice ("yes", "no", "stop"…), for a moment.
  Map<String, dynamic>? intent;
  DateTime? intentAt;
  bool get showIntent => intent != null && intentAt != null && DateTime.now().difference(intentAt!) < const Duration(seconds: 4);
  String? error;
  Map<String, dynamic>? status;
  CoreStatus _last = CoreStatus.connecting;

  bool get canListen => status?['listen_ready'] == true;
  bool get naturalVoice => status?['natural_voice'] == true;
  bool get speakReplies => (status?['settings'] as Map?)?['speak_replies'] != false;

  /// "Hey Compii" is on and the mic is listening for it.
  bool get wakeListening => status?['wake_listening'] == true;
  Map<String, dynamic> get downloading => Map<String, dynamic>.from(status?['downloading'] as Map? ?? {});

  /// Called with the final transcript; the screen decides where it goes.
  Future<void> Function(String text)? onHeard;

  void _onCore() {
    if (core.status == CoreStatus.online && _last != CoreStatus.online) refresh();
    _last = core.status;
  }

  Future<void> refresh() async {
    try {
      status = await core.voiceStatus();
      notifyListeners();
    } catch (_) {}
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'voice_listening':
        listening = e['on'] == true;
        if (listening) partial = '';
        if (!listening) level = 0;
      case 'voice_partial':
        partial = '${e['text']}';
      case 'voice_level':
        level = (e['level'] as num).toDouble();
      case 'voice_speaking':
        speaking = e['on'] == true;
        if (!speaking) caption = '';
      case 'voice_caption':
        caption = '${e['text']}';
      case 'voice_intent':
        intent = e;
        intentAt = DateTime.now();
        Future<void>.delayed(const Duration(milliseconds: 4100), notifyListeners);
      case 'voice_wake_word':
        refresh();
      case 'voice_command':
        // Heard hands-free after "Hey Compii": route it like a typed request.
        onHeard?.call('${e['text']}');
      case 'voice_ready':
        refresh();
      case 'voice_error':
        error = '${e['error']}';
    }
    notifyListeners();
  }

  /// Start talking (also silences Compii).
  Future<void> start() async {
    if (listening || busy) return;
    error = null;
    try {
      await core.listenStart();
      listening = true;
      partial = '';
      notifyListeners();
    } catch (e) {
      error = '$e';
      notifyListeners();
    }
  }

  /// Stop talking and hand the transcript to [onHeard].
  Future<void> finish() async {
    if (!listening) return;
    busy = true;
    listening = false;
    notifyListeners();
    try {
      final text = (await core.listenStop()).trim();
      partial = text;
      if (text.isNotEmpty) await onHeard?.call(text);
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      partial = '';
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    listening = false;
    partial = '';
    notifyListeners();
    try {
      await core.listenCancel();
    } catch (_) {}
  }

  Future<void> toggle() => listening ? finish() : start();

  Future<void> quiet() async {
    speaking = false;
    caption = '';
    notifyListeners();
    try {
      await core.quiet();
    } catch (_) {}
  }

  Future<void> set(Map<String, Object?> changes) async {
    status = await core.voiceSettings(changes);
    notifyListeners();
  }

  Future<void> download(String what) async {
    status = await core.voiceDownload(what);
    notifyListeners();
    // Progress arrives by polling; "voice_ready" ends it.
    while (downloading.containsKey(what)) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await refresh();
    }
  }

  /// The character's mood, with voice taking priority over task state.
  Mood moodOver(Mood base) {
    if (listening) return Mood.listening;
    if (speaking) return Mood.speaking;
    return base;
  }

  @override
  void dispose() {
    _sub.cancel();
    core.removeListener(_onCore);
    super.dispose();
  }
}

/// The Orbling you can click: tap to talk, tap again to send; tap while it
/// speaks to interrupt. Eyes follow the mouse.
class TalkableOrbling extends StatelessWidget {
  const TalkableOrbling({super.key, required this.voice, required this.mood, this.jobs = 0, this.size = 150});
  final VoiceController voice;
  final Mood mood;
  final int jobs;
  final double size;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: voice,
    builder: (context, _) {
      final m = voice.moodOver(mood);
      final hint = voice.speaking
          ? 'Tap to interrupt'
          : voice.listening
              ? 'Tap to send'
              : (voice.canListen ? 'Tap to talk · Alt + Space' : 'Turn on listening in Settings → Voice');
      return Tooltip(
        message: hint,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => voice.speaking ? voice.quiet() : voice.toggle(),
            child: SizedBox.square(
              dimension: size,
              child: Orbling(mood: m, jobs: jobs, level: voice.level),
            ),
          ),
        ),
      );
    },
  );
}

/// The microphone button: tap to start and tap to send, or hold to talk and
/// release to send.
class MicButton extends StatefulWidget {
  const MicButton({super.key, required this.voice, this.onSetup});
  final VoiceController voice;
  final VoidCallback? onSetup;
  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> {
  DateTime? _down;
  bool _startedHere = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.voice,
    builder: (context, _) {
      final c = context.c;
      final v = widget.voice;
      if (!v.canListen) {
        return IconButton(
          tooltip: 'Set up free voice input',
          onPressed: widget.onSetup,
          icon: Glyph(G.mic, size: 20, color: c.faint),
        );
      }
      return Tooltip(
        message: v.listening ? 'Release or tap to send' : 'Hold or tap to talk',
        child: GestureDetector(
          onTapDown: (_) {
            _down = DateTime.now();
            _startedHere = !v.listening;
            if (_startedHere) v.start();
          },
          onTapUp: (_) {
            final held = _down != null && DateTime.now().difference(_down!) > const Duration(milliseconds: 400);
            // Hold and release sends; a quick tap keeps listening until the next tap.
            if (!_startedHere || held) v.finish();
          },
          onTapCancel: () {
            if (v.listening) v.finish();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: v.listening ? c.listen : Colors.transparent,
              boxShadow: v.listening ? [BoxShadow(color: c.listen.withValues(alpha: .4), blurRadius: 12)] : null,
            ),
            child: Glyph(
              v.listening ? G.mic : G.mic,
              size: 19,
              duo: v.listening,
              duoColor: Colors.white,
              color: v.listening ? Colors.white : c.muted,
            ),
          ),
        ),
      );
    },
  );
}

/// Shown in place of the text box while listening: your words as you say them.
class LiveTranscript extends StatelessWidget {
  const LiveTranscript({super.key, required this.voice});
  final VoiceController voice;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: voice,
    builder: (context, _) {
      final c = context.c;
      final text = voice.partial.isEmpty
          ? (voice.busy ? 'Getting that…' : 'Listening… speak now')
          : voice.partial;
      return Row(
        children: [
          _Level(level: voice.level, active: voice.listening),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Text(
                text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: context.type.bodyLarge?.copyWith(
                  color: voice.partial.isEmpty ? c.faint : c.text,
                  fontStyle: voice.partial.isEmpty ? FontStyle.italic : null,
                ),
              ),
            ),
          ),
          if (voice.listening)
            TextButton(onPressed: voice.cancel, child: const Text('Cancel')),
        ],
      );
    },
  );
}

class _Level extends StatelessWidget {
  const _Level({required this.level, required this.active});
  final double level;
  final bool active;
  @override
  Widget build(BuildContext context) {
    const teal = Color(0xFF16B8BF);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final k in const [.5, .85, 1.0, .7, .45])
          AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            width: 3.5,
            height: 6 + (active ? 20 * (level * k).clamp(.08, 1.0) : 2),
            decoration: BoxDecoration(color: teal, borderRadius: BorderRadius.circular(2)),
          ),
      ],
    );
  }
}

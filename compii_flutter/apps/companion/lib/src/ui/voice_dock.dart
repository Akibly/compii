import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'shell.dart';
import 'thread.dart' show Run;
import 'tokens.dart';
import 'voice.dart';

/// Voice first: the talk button is the main control and typing is the
/// fallback. Above it, what matters right now: your words as you speak,
/// Compii's words as it speaks, or what it's waiting for you to say.
///
/// Start typing anywhere (or press the keyboard button) and a slim text box
/// appears; Esc goes back to voice.
class VoiceDock extends StatefulWidget {
  const VoiceDock({super.key, required this.core, required this.state, required this.onSend, this.task, this.run, this.hint = 'Ask Compii to do something…', this.showCharacter = true});
  final CoreClient core;
  final AppState state;
  final Future<void> Function(String text) onSend;
  final TaskView? task;
  final Run? run;
  final String hint;

  /// Show the Orbling as the talk button here (off when it's already on screen, like on Home).
  final bool showCharacter;

  @override
  State<VoiceDock> createState() => _VoiceDockState();
}

class _VoiceDockState extends State<VoiceDock> {
  bool _typing = false;
  String _seed = '';

  VoiceController? get _voice => widget.state.voice;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Any printable key opens the text box with that character already in it.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (_typing) {
      if (e.logicalKey == LogicalKeyboardKey.escape && _voice?.canListen == true && ModalRoute.of(context)?.isCurrent == true) {
        setState(() => _typing = false);
        return true;
      }
      return false;
    }
    final focus = FocusManager.instance.primaryFocus?.context?.widget;
    if (focus is EditableText) return false;
    final k = HardwareKeyboard.instance;
    if (k.isControlPressed || k.isAltPressed || k.isMetaPressed) return false;
    final ch = e.character;
    if (ch == null || ch.trim().isEmpty || ch.codeUnitAt(0) < 32) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    setState(() {
      _typing = true;
      _seed = ch;
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final voice = _voice;
    final canTalk = voice?.canListen == true;
    if (!canTalk || _typing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!canTalk && voice != null) _SetupVoiceHint(onSetup: () => widget.state.go(Section.settings)),
          CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _typing = false)},
            child: Composer(
              core: widget.core,
              state: widget.state,
              hint: widget.hint,
              busyTask: widget.task,
              run: widget.run,
              seed: _seed,
              onSend: (t) async {
                await widget.onSend(t);
                if (canTalk && mounted) setState(() => _typing = false);
              },
              onVoice: canTalk ? () => setState(() => _typing = false) : null,
            ),
          ),
        ],
      );
    }
    return ListenableBuilder(
      listenable: voice!,
      builder: (context, _) => _VoiceBar(
        voice: voice,
        state: widget.state,
        showCharacter: widget.showCharacter,
        core: widget.core,
        task: widget.task,
        run: widget.run,
        onType: () => setState(() {
          _typing = true;
          _seed = '';
        }),
      ),
    );
  }
}

class _VoiceBar extends StatelessWidget {
  const _VoiceBar({required this.voice, required this.state, required this.showCharacter, required this.core, required this.onType, this.task, this.run});
  final VoiceController voice;
  final AppState state;
  final bool showCharacter;
  final CoreClient core;
  final TaskView? task;
  final Run? run;
  final VoidCallback onType;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final pending = task?.pendingApproval ?? core.ordered.map((t) => t.pendingApproval).whereType<Map<String, dynamic>>().firstOrNull;
    final working = task?.active == true && pending == null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.bottomCenter,
          child: _Stage(voice: voice, pending: pending),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SideButton(glyph: G.keyboard, tooltip: 'Type instead (or just start typing)', onTap: onType),
            const SizedBox(width: 16),
            if (showCharacter)
              TalkableOrbling(voice: voice, mood: state.moodWith(core), jobs: working ? 1 : 0, size: 76)
            else
              Flexible(child: _Hint(voice: voice)),
            const SizedBox(width: 16),
            if (voice.speaking)
              _SideButton(glyph: G.speaker, tooltip: 'Stop talking', color: c.accent, onTap: voice.quiet)
            else if (working)
              _SideButton(glyph: G.stop, tooltip: 'Stop this task', color: c.danger, onTap: () => run?.call(() => core.stop(task!.id)))
            else
              const SizedBox(width: 44),
          ],
        ),
        if (showCharacter) ...[const SizedBox(height: 6), _Hint(voice: voice)],
      ],
    );
  }
}

/// What matters right now, in big friendly text.
class _Stage extends StatelessWidget {
  const _Stage({required this.voice, this.pending});
  final VoiceController voice;
  final Map<String, dynamic>? pending;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget line(String text, Color color, {GlyphData? glyph, bool big = true}) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (glyph != null) ...[Padding(padding: const EdgeInsets.only(top: 3), child: Glyph(glyph, size: 18, color: color, duo: true)), const SizedBox(width: 10)],
          Flexible(
            child: Text(text, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
                style: (big ? context.type.titleLarge : context.type.bodyLarge)?.copyWith(color: color, fontWeight: big ? FontWeight.w600 : FontWeight.w400, height: 1.35)),
          ),
        ],
      ),
    );

    if (voice.listening) {
      return line(voice.partial.isEmpty ? 'Listening…' : '“${voice.partial}”', voice.partial.isEmpty ? c.muted : c.text, glyph: G.wave);
    }
    if (voice.busy) return line('Got it…', c.muted, glyph: G.wave);
    if (voice.showIntent) {
      final i = voice.intent!;
      final (String text, Color color, GlyphData glyph) = switch ('${i['kind']}') {
        'approve' => ('Approved by voice${'${i['label']}'.isEmpty ? '' : ': ${i['label']}'}', c.success, G.checkCircle),
        'decline' => ('Declined by voice', c.muted, G.close),
        'stop' => ('Stopped everything', c.danger, G.stop),
        'quiet' => ('Okay, quiet', c.muted, G.speaker),
        _ => ('${i['reply']}', c.warning, G.shieldAlert),
      };
      return line(text, color, glyph: glyph, big: false);
    }
    if (voice.speaking && voice.caption.isNotEmpty) {
      return line(voice.caption, c.text, glyph: G.speakingHead, big: false);
    }
    if (pending != null) {
      final kind = '${pending!['kind']}';
      final say = switch (kind) {
        'spend' => 'Payments need the button above.',
        'delete' => 'Say “yes, delete it” or “no”.',
        _ => 'Say “yes” or “no”.',
      };
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: c.warning.withValues(alpha: c.dark ? .14 : .10),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: c.warning.withValues(alpha: .35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Glyph(G.hand, size: 17, color: c.warning, duo: true),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Waiting for your okay — $say', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: context.type.labelLarge?.copyWith(color: c.text)),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({required this.glyph, required this.tooltip, required this.onTap, this.color});
  final GlyphData glyph;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c.raised,
        shape: CircleBorder(side: BorderSide(color: c.border)),
        elevation: 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(dimension: 44, child: Center(child: Glyph(glyph, size: 19, color: color ?? c.muted))),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.voice});
  final VoiceController voice;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = context.type.labelMedium?.copyWith(color: c.faint);
    if (voice.listening) return Text('Listening — tap Compii or press Alt + Space to send', maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(voice.wakeListening ? 'Say “Hey Compii”, tap Compii, or press' : 'Tap Compii or press',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
        const SizedBox(width: 6),
        const Kbd('Alt + Space'),
      ],
    );
  }
}

class _SetupVoiceHint extends StatelessWidget {
  const _SetupVoiceHint({required this.onSetup});
  final VoidCallback onSetup;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Glyph(G.mic, size: 15, color: c.accent),
          const SizedBox(width: 6),
          Text('Compii is built for talking.', style: context.type.labelMedium),
          TextButton(onPressed: onSetup, child: const Text('Set up free voice')),
        ],
      ),
    );
  }
}

/// "Try saying…": tap one to run it.
class TrySaying extends StatelessWidget {
  const TrySaying({super.key, required this.items, required this.onPick});
  final List<(GlyphData, String, String)> items; // glyph, what to say, the full request
  final void Function(String request)? onPick;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      children: [
        Text('TRY SAYING', style: context.type.labelSmall),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (g, say, request) in items)
              _SayChip(glyph: g, text: say, onTap: onPick == null ? null : () => onPick!(request), color: c.accent),
          ],
        ),
      ],
    );
  }
}

class _SayChip extends StatefulWidget {
  const _SayChip({required this.glyph, required this.text, required this.onTap, required this.color});
  final GlyphData glyph;
  final String text;
  final VoidCallback? onTap;
  final Color color;
  @override
  State<_SayChip> createState() => _SayChipState();
}

class _SayChipState extends State<_SayChip> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MouseRegion(
      cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: _hover ? c.accentSoft : c.raised,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: _hover ? c.accent.withValues(alpha: .4) : c.border),
            boxShadow: Shapes.card(c),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Glyph(widget.glyph, size: 15, color: c.accent, duo: _hover),
              const SizedBox(width: 7),
              Text('“${widget.text}”', style: context.type.labelLarge?.copyWith(color: _hover ? c.accent : c.text, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

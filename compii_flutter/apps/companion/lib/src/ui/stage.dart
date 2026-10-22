import 'package:flutter/material.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'bots.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'reply_text.dart';
import 'shell.dart';
import 'thread.dart';
import 'tokens.dart';
import 'trust.dart';
import 'voice.dart';
import 'voice_dock.dart';

/// The default conversation view: the character is the main figure and
/// answers in a speech bubble, the way you'd talk to someone. What you said
/// sits quietly above; anything that needs you (files, a note) appears under
/// the bubble. A decision you owe leads the screen, so it is the first thing
/// you see rather than something below the character. The full chat history is
/// one tap away.
class Stage extends StatelessWidget {
  const Stage({super.key, required this.task, required this.core, required this.state, required this.run});
  final TaskView task;
  final CoreClient core;
  final AppState state;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final turns = turnsOf(task);
    final turn = turns.isEmpty ? null : turns.last;
    final voice = state.voice;
    final pending = turn?.pending;
    final asked = turn?.pendingQuestion;
    final mood = state.moodWith(core);
    final bot = core.botFor(task.botId);
    final role = bot != null && !bot.primary ? bot : null;
    final tint = role == null ? c.accent : botColor(role, c.accent);
    final hero = pending != null || asked != null ? 64.0 : (MediaQuery.sizeOf(context).height * .24).clamp(120.0, 220.0);
    final speakingCaption = voice != null && voice.showCaption ? voice.caption : null;
    final (String bubble, bool working) = switch (turn) {
      null => ('', true),
      _ when speakingCaption != null => (speakingCaption, false),
      _ when pending != null => ('', false),
      _ when asked != null => ('${asked['question']}', false),
      final t when t.reply != null => (t.reply!, false),
      final t when t.draft != null => (t.draft!, true),
      final t when t.current != null => ('${t.current!['label']}…', true),
      final t when t.notes.isNotEmpty && t.active => (t.notes.last, true),
      final t when t.active => ('Thinking…', true),
      _ => ('', false),
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 6, 20, 0),
          child: AdaptiveRow(
            children: [
              if (task.isTeam) ...[TeamStrip(task: task, core: core), const Spacer()]
              else if (role != null) ...[BotChip(bot: role), const Spacer()]
              else const Spacer(),
              if (task.status == 'done' && !task.fromRoutine) SaveSkillButton(task: task, run: run),
              if (task.active)
                TextButton.icon(
                  onPressed: () => run(() => core.stop(task.id)),
                  icon: Glyph(G.stop, size: 15, color: c.danger),
                  label: Text('Stop', style: context.type.labelLarge?.copyWith(color: c.danger)),
                ),
              TextButton.icon(
                onPressed: () => state.setChatView(true),
                icon: const Glyph(G.chat, size: 16),
                label: const Text('Show chat'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pending != null) ...[
                      const SizedBox(height: 18),
                      ApprovalCard(approval: pending, core: core, run: run, compact: true),
                      const SizedBox(height: 18),
                    ],
                    if (turn != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Text('“${turn.ask}”', textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
                            style: context.type.bodyLarge?.copyWith(color: c.muted, fontStyle: FontStyle.italic)),
                      ),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: hero, end: hero),
                      duration: context.motion(Motion.slow),
                      curve: Motion.inOut,
                      builder: (context, size, _) => Aura(
                        size: size * 1.55,
                        color: switch (mood) {
                          Mood.waiting => c.warning,
                          Mood.problem => c.danger,
                          Mood.listening => c.listen,
                          _ => tint,
                        },
                        child: voice != null
                            ? TalkableCompii(voice: voice, mood: mood, jobs: task.active ? 1 : 0, size: size)
                            : SizedBox.square(dimension: size, child: Ember(mood: mood, jobs: task.active ? 1 : 0)),
                      ),
                    ),
                    if (bubble.isNotEmpty && pending == null && asked == null) _SpeechBubble(text: bubble, working: working, failed: turn?.status == 'failed'),
                    if (asked != null) ...[
                      const SizedBox(height: 18),
                      QuestionCard(question: asked, core: core, run: run),
                    ],
                    if (turn != null && !turn.active && turn.files.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [for (final f in turn.files) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 300), child: FileChip(file: f, core: core, run: run))],
                      ),
                    ],
                    if (turn != null && turn.safety.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SafetyNotes(events: turn.safety),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: VoiceDock(
              core: core,
              state: state,
              hint: 'Follow up…',
              task: task,
              run: run,
              showCharacter: false,
              showCaptions: false,
              onSend: (text) => run(() => core.reply(task.id, text)),
              onSendFiles: (text, files) => run(() => core.reply(task.id, text, attachments: files)),
            ),
          ),
        ),
      ],
    );
  }
}

/// A speech bubble with a little tail pointing up at the character.
class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({required this.text, required this.working, this.failed = false});
  final String text;
  final bool working;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final edge = failed ? c.danger.withValues(alpha: .5) : c.accent.withValues(alpha: .28);
    return Column(
      children: [
        CustomPaint(size: const Size(22, 11), painter: _Tail(c.raised, edge)),
        AnimatedSize(
          duration: context.motion(Motion.base),
          curve: Motion.out,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            decoration: BoxDecoration(
              color: c.raised,
              borderRadius: Shapes.r24,
              border: Border.all(color: edge, width: 1.3),
              boxShadow: Shapes.float(c),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (working)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 12),
                    child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
                  ),
                Expanded(
                  child: text.length > 220 || text.contains('\n')
                      ? ReplyText(text, style: context.type.bodyLarge)
                      : SelectableText(
                    plainMarkdown(text),
                    textAlign: working ? TextAlign.start : TextAlign.center,
                    style: (working ? context.type.bodyLarge?.copyWith(color: c.muted) : context.type.titleLarge?.copyWith(
                          fontWeight: FontWeight.w500, height: 1.45, color: failed ? c.danger : c.text)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Tail extends CustomPainter {
  _Tail(this.fill, this.edge);
  final Color fill;
  final Color edge;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()
      ..moveTo(0, s.height + 1)
      ..lineTo(s.width / 2, 0)
      ..lineTo(s.width, s.height + 1);
    canvas.drawPath(p, Paint()..color = fill);
    canvas.drawPath(p, Paint()
      ..color = edge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3);
  }

  @override
  bool shouldRepaint(_Tail o) => o.fill != fill || o.edge != edge;
}

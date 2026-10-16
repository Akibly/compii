import 'package:flutter/material.dart';

import '../ui/shell.dart';
import '../ui/thread.dart';
import '../ui/tokens.dart';
import 'character.dart';
import 'core_client.dart';

/// Root screen: phones get the Face View, desktops the workspace (which can
/// preview the Face View).
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, required this.core, required this.state});
  final CoreClient core;
  final AppState state;
  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  bool _faceView = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final phone = box.biggest.shortestSide < 600;
      if (phone || _faceView) {
        return ListenableBuilder(
          listenable: Listenable.merge([widget.core, widget.state, ?widget.state.voice]),
          builder: (context, _) => FaceStage(
            core: widget.core,
            state: widget.state,
            onExit: phone ? null : () => setState(() => _faceView = false),
          ),
        );
      }
      return Workspace(core: widget.core, state: widget.state, onFaceView: () => setState(() => _faceView = true));
    },
  );
}

/// What the character says in Face View.
String bubbleOf(CoreClient core) {
  if (core.status == CoreStatus.connecting) return 'Waking up…';
  if (core.status == CoreStatus.offline) return "I can't reach Compii Core yet. I'll connect as soon as it's running.";
  final tasks = core.ordered;
  for (final t in tasks) {
    final a = t.pendingApproval;
    if (a != null) return 'Okay to go ahead? ${a['label']}';
  }
  if (tasks.isEmpty) return 'What should we get done?';
  final latest = tasks.first;
  final last = latest.last;
  if (latest.active) {
    if (last?['type'] == 'note') return last!['text'] as String;
    if (last?['type'] == 'action_started') return '${last!['label']}…';
    return 'On it.';
  }
  return latest.finalText ?? 'What next?';
}

/// Phone Face View (Bluey-style): the screen is Compii's face. Status,
/// speech, approvals and the composer float over it; the conversation opens
/// in a sheet.
class FaceStage extends StatelessWidget {
  const FaceStage({super.key, required this.core, required this.state, required this.onExit});
  final CoreClient core;
  final AppState state;
  final VoidCallback? onExit;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      state.fail(null);
    } catch (e) {
      state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mood = state.moodWith(core);
    final voice = state.voice;
    final online = core.status == CoreStatus.online;
    final active = core.ordered.where((t) => t.active).length;
    final waiting = core.ordered.where((t) => t.pendingApproval != null).toList();
    final latest = core.ordered.firstOrNull;
    const glass = Color(0xF2FFFFFF);
    return Scaffold(
      backgroundColor: const Color(0xFF1B1550),
      body: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: 'Compii, ${moodLabel(mood)}',
              image: true,
              // Tap the face to talk; tap again to send, or to interrupt it.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: voice == null ? null : () => voice.speaking ? voice.quiet() : voice.toggle(),
                child: Orbling(mood: mood, jobs: active, face: true, level: voice?.level ?? 0, followPointer: false),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: const Color(0x99140F3D), borderRadius: BorderRadius.circular(20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 10, color: switch (core.status) {
                    CoreStatus.online => const Color(0xFF5BD18B),
                    CoreStatus.connecting => const Color(0xFFF2B24B),
                    CoreStatus.offline => const Color(0xFFFF7A6E),
                  }),
                  const SizedBox(width: 8),
                  Text(
                    online ? moodLabel(mood) : (core.status == CoreStatus.offline ? 'Core offline' : 'Connecting…'),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          if (onExit != null)
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(tooltip: 'Back to desktop view', onPressed: onExit, icon: const Icon(Icons.close)),
            ),
          Positioned(
            top: 56,
            left: 16,
            right: 16,
            // Stay above the composer; long approvals scroll instead of hiding their buttons.
            bottom: waiting.isNotEmpty ? 76 : null,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: waiting.isNotEmpty
                    ? Theme(
                        data: compiiTheme(Brightness.light),
                        child: SingleChildScrollView(
                          child: ApprovalCard(approval: waiting.first.pendingApproval!, core: core, run: _run, compact: true),
                        ),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(color: glass, borderRadius: BorderRadius.circular(16)),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            bubbleOf(core),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFF15122E), fontWeight: FontWeight.w600, fontSize: 14),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Theme(
              data: compiiTheme(Brightness.light),
              child: Builder(
                builder: (context) => Row(
                  children: [
                    Badge(
                      isLabelVisible: active > 0,
                      label: Text('$active'),
                      child: IconButton.filledTonal(
                        tooltip: 'Conversation',
                        onPressed: latest == null
                            ? null
                            : () => showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                showDragHandle: true,
                                backgroundColor: c.canvas,
                                builder: (_) => SizedBox(
                                  height: MediaQuery.of(context).size.height * .75,
                                  child: ListenableBuilder(
                                    listenable: core,
                                    builder: (_, _) => ThreadView(task: core.tasks[latest.id]!, core: core, run: _run, compact: true),
                                  ),
                                ),
                              ),
                        icon: const Icon(Icons.forum_outlined),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Composer(
                        core: core,
                        state: state,
                        autofocus: false,
                        hint: 'Tell Compii…',
                        busyTask: latest?.active == true ? latest : null,
                        run: _run,
                        onSend: (text) => _run(() async {
                          if (latest != null && !latest.active) {
                            await core.reply(latest.id, text);
                          } else {
                            await core.startConversation(text);
                          }
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

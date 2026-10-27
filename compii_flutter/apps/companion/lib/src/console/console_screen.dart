import 'dart:io';

import 'package:flutter/material.dart';

import '../ui/chrome.dart';
import '../ui/shell.dart';
import '../ui/thread.dart';
import '../ui/tokens.dart';
import 'character.dart';
import 'core_client.dart';
import '../ui/glyphs.dart';

/// Root screen: phones get the Presence View, desktops the workspace (which can
/// preview the Presence View).
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, required this.core, required this.state});
  final CoreClient core;
  final AppState state;
  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  bool? _faceView;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      // Phones always get the Presence View. A squeezed desktop window starts
      // there too, because the workspace needs more room than that — but as a
      // default it can leave, not a lock: its own button returns to the
      // workspace, which keeps every destination in its drawer at any width.
      final phone = Platform.isAndroid || Platform.isIOS;
      final squeezed = box.biggest.shortestSide < 600;
      if (phone || _faceView == true || (_faceView == null && squeezed)) {
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

/// What the character says in the Presence View.
String bubbleOf(CoreClient core) {
  if (core.status == CoreStatus.connecting) return 'Waking up…';
  if (core.unauthorized) return '${core.remote?.pc ?? 'Your PC'} doesn’t know this phone any more. Pair it again.';
  if (core.status == CoreStatus.offline) {
    return core.isRemote
        ? "I can't reach ${core.remote!.pc}. Is the phone on the same Wi-Fi, and is the PC awake?"
        : "I can't reach Compii Core yet. I'll connect as soon as it's running.";
  }
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

/// Phone Presence View: the screen becomes the inside of the lens. Status,
/// speech, approvals and the composer float over it; the conversation opens
/// in a sheet.
class FaceStage extends StatelessWidget {
  const FaceStage({super.key, required this.core, required this.state, required this.onExit, this.menu, this.onSend, this.allowOffline = false});
  final CoreClient core;
  final AppState state;
  final VoidCallback? onExit;

  /// Top-right controls on a paired phone (connection, voice, forget this PC).
  final Widget? menu;

  /// What typing does; on a phone it goes through the waiting-when-away queue.
  final Future<void> Function(String text)? onSend;

  /// Keep what was typed when the PC is out of reach, to send later.
  final bool allowOffline;

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
    // Tap the face to talk; tap again to send, or to interrupt it.
    final VoidCallback? talkToFace =
        voice == null ? null : () => voice.speaking ? voice.quiet() : voice.toggle();
    // Black glass around the face, as everywhere else in Compii.
    const glass = Color(0xE60E0E12);
    return Scaffold(
      backgroundColor: const Color(0xFF050507),
      body: Stack(
        children: [
          Positioned.fill(
            child: Keyable(
              label: 'Compii, ${moodLabel(mood)}',
              radius: Shapes.r24,
              onTap: talkToFace,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: talkToFace,
                child: Ember(mood: mood, jobs: active, face: true, level: voice?.level ?? 0, followPointer: false),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xCC0E0E12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x1FFFFFFF)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Glyph(G.dot, size: 10, color: switch (core.status) {
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
          if (menu != null) Positioned(top: 8, right: 8, child: menu!),
          if (onExit != null)
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(tooltip: 'Back to desktop view', onPressed: onExit, icon: const Glyph(G.close)),
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
                        data: compiiTheme(Brightness.dark),
                        child: SingleChildScrollView(
                          child: ApprovalCard(approval: waiting.first.pendingApproval!, core: core, run: _run, compact: true),
                        ),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: glass,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0x1FFFFFFF)),
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            bubbleOf(core),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFFF5F5F7), fontWeight: FontWeight.w500, fontSize: 15, height: 1.35),
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
              data: compiiTheme(Brightness.dark),
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
                        icon: const Glyph(G.chat),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Composer(
                        core: core,
                        state: state,
                        autofocus: false,
                        allowOffline: allowOffline,
                        hint: 'Tell Compii…',
                        busyTask: latest?.active == true ? latest : null,
                        run: _run,
                        onSend: onSend ??
                            (text) => _run(() async {
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

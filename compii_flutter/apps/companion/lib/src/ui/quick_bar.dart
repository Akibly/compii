import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'shell.dart';
import 'thread.dart';
import 'tokens.dart';
import 'voice.dart';
import 'glyphs.dart';

const _barSize = Size(720, 132);
const _openSize = Size(720, 520);

/// Turns the main window into a floating quick bar (ChatGPT Alt+Space /
/// Raycast style) and back. The window itself changes mode, so there is one
/// brain, one history and one connection.
class QuickMode extends ChangeNotifier {
  QuickMode(this.state);
  final AppState state;
  bool active = false;
  String? task; // conversation started from the quick bar
  Rect? _saved;
  bool _wasMaximized = false;

  Future<void> registerHotkey() async {
    await hotKeyManager.unregisterAll();
    await hotKeyManager.register(
      HotKey(key: PhysicalKeyboardKey.space, modifiers: [HotKeyModifier.alt], scope: HotKeyScope.system),
      keyDownHandler: (_) => toggle(),
    );
  }

  Future<void> toggle() async {
    if (active && await windowManager.isFocused()) {
      await close(hide: true);
    } else {
      await open();
    }
  }

  Future<void> open() async {
    if (!active) {
      _wasMaximized = await windowManager.isMaximized();
      if (_wasMaximized) await windowManager.unmaximize();
      _saved = await windowManager.getBounds();
      active = true;
      task = null;
      notifyListeners();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setSize(_barSize);
      await windowManager.setAlignment(const Alignment(0, -.45));
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// Grow the bar when an answer is on its way.
  Future<void> expand() async {
    if (!active) return;
    final b = await windowManager.getBounds();
    if (b.height >= _openSize.height) return;
    await windowManager.setBounds(Rect.fromLTWH(b.left, b.top, _openSize.width, _openSize.height));
  }

  /// Back to the full window; [hide] puts it away instead of showing it.
  Future<void> close({bool hide = false, bool openTask = false}) async {
    if (!active) return;
    final t = task;
    active = false;
    task = null;
    notifyListeners();
    if (hide) await windowManager.hide();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    if (_saved != null) await windowManager.setBounds(_saved!);
    if (_wasMaximized) await windowManager.maximize();
    if (openTask && t != null) state.open(t);
    if (!hide) {
      await windowManager.show();
      await windowManager.focus();
    }
  }
}

class QuickBar extends StatelessWidget {
  const QuickBar({super.key, required this.core, required this.quick});
  final CoreClient core;
  final QuickMode quick;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      quick.state.fail(null);
    } catch (e) {
      quick.state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([core, quick, quick.state, ?quick.state.voice]),
    builder: (context, _) {
      final c = context.c;
      final task = quick.task == null ? null : core.tasks[quick.task];
      final voice = quick.state.voice;
      final base = task == null ? quick.state.moodWith(core) : _moodOf(task);
      final mood = voice?.moodOver(base) ?? base;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => quick.close(hide: true),
        },
        child: Scaffold(
          backgroundColor: c.canvas,
          body: DragToMoveArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (voice != null)
                        TalkableOrbling(voice: voice, mood: mood, jobs: task?.active == true ? 1 : 0, size: 58)
                      else
                        SizedBox.square(dimension: 58, child: Orbling(mood: mood, jobs: task?.active == true ? 1 : 0)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Composer(
                          core: core,
                          state: quick.state,
                          hint: task == null ? 'Ask Compii…' : 'Follow up…',
                          busyTask: task,
                          run: _run,
                          onSend: (text) => _run(() async {
                            if (quick.task == null) {
                              quick.task = await core.startConversation(text);
                              await quick.expand();
                            } else {
                              await core.reply(quick.task!, text);
                            }
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                if (task == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        Text('Enter to send · Esc to close', style: context.type.labelMedium?.copyWith(color: c.faint)),
                        const Spacer(),
                        TextButton(onPressed: () => quick.close(), child: const Text('Open Compii')),
                      ],
                    ),
                  )
                else ...[
                  Divider(height: 1, color: c.border),
                  Expanded(child: ThreadView(task: task, core: core, run: _run, compact: true)),
                  Divider(height: 1, color: c.border),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Text('Esc to close', style: context.type.labelMedium?.copyWith(color: c.faint)),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => quick.close(openTask: true),
                          icon: const Glyph(G.pip, size: 16),
                          label: const Text('Open in Compii'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  Mood _moodOf(TaskView t) {
    if (t.pendingApproval != null) return Mood.waiting;
    return switch (t.status) {
      'running' => t.last?['type'] == 'action_started' ? Mood.acting : Mood.thinking,
      'done' => Mood.happy,
      'failed' => Mood.problem,
      _ => Mood.idle,
    };
  }
}

import 'package:flutter/material.dart';

import 'character.dart';
import 'core_client.dart';

const _ink = Color(0xFF1F1A24);
const _paper = Color(0xFFF7F5F2);
const _accent = Color(0xFF5B4FD9);

ThemeData consoleTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: _paper,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _accent,
    primary: _accent,
    surface: _paper,
    onSurface: _ink,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(48, 44)),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44)),
  ),
);

/// Compii's main screen: the character, what it's saying, the command bar,
/// and the Task Center with live steps, approvals and Stop.
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, required this.core});
  final CoreClient core;
  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  String? _error;

  /// Desktop preview of the phone's Face View; phones use it automatically.
  bool _faceView = false;

  CoreClient get core => widget.core;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _submit() async {
    final text = _input.text.trim();
    if (text.isEmpty || core.status != CoreStatus.online) return;
    _input.clear();
    await _run(() => core.ask(text));
    _focus.requestFocus();
  }

  Mood _mood() {
    if (core.status != CoreStatus.online) return Mood.offline;
    final tasks = core.ordered;
    if (tasks.any((t) => t.pendingApproval != null)) return Mood.waiting;
    final active = tasks.where((t) => t.active).toList();
    if (active.isNotEmpty) {
      return active.first.last?['type'] == 'action_started'
          ? Mood.acting
          : Mood.thinking;
    }
    if (tasks.isEmpty) return Mood.idle;
    final latest = tasks.first;
    final finishedAt = (latest.last?['at'] as num?)?.toDouble() ?? 0;
    final recent =
        DateTime.now().millisecondsSinceEpoch / 1000 - finishedAt < 8;
    if (!recent) return Mood.idle;
    return switch (latest.status) {
      'done' => Mood.happy,
      'failed' => Mood.problem,
      _ => Mood.idle,
    };
  }

  String _bubble(Mood mood) {
    if (core.status == CoreStatus.connecting) return 'Waking up…';
    if (core.status == CoreStatus.offline) {
      return "I can't reach Compii Core yet. Start it and I'll connect by myself.";
    }
    final tasks = core.ordered;
    for (final t in tasks) {
      final approval = t.pendingApproval;
      if (approval != null) return 'Okay to go ahead? ${approval['label']}';
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: core,
    builder: (context, _) {
      final mood = _mood();
      return Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final phone = box.biggest.shortestSide < 600;
              if (phone || _faceView) {
                return _FaceStage(
                  mood: mood,
                  bubble: _bubble(mood),
                  core: core,
                  input: _input,
                  onSubmit: _submit,
                  run: _run,
                  onExit: phone ? null : () => setState(() => _faceView = false),
                );
              }
              final wide = box.maxWidth >= 900;
              final stage = _Stage(
                onFaceView: () => setState(() => _faceView = true),
                mood: mood,
                bubble: _bubble(mood),
                core: core,
                input: _input,
                focus: _focus,
                onSubmit: _submit,
                onStopAll: () => _run(core.stopAll),
                error: _error,
              );
              final center = _TaskCenter(core: core, run: _run);
              if (wide) {
                return Row(
                  children: [
                    Expanded(child: stage),
                    const VerticalDivider(width: 1),
                    SizedBox(width: 440, child: center),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(flex: 3, child: stage),
                  const Divider(height: 1),
                  Expanded(flex: 2, child: center),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

class _Stage extends StatelessWidget {
  const _Stage({
    required this.onFaceView,
    required this.mood,
    required this.bubble,
    required this.core,
    required this.input,
    required this.focus,
    required this.onSubmit,
    required this.onStopAll,
    required this.error,
  });
  final Mood mood;
  final String bubble;
  final CoreClient core;
  final TextEditingController input;
  final FocusNode focus;
  final VoidCallback onSubmit;
  final VoidCallback onStopAll;
  final VoidCallback onFaceView;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final online = core.status == CoreStatus.online;
    final anyActive = core.ordered.any((t) => t.active);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Compii',
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 12),
              _StatusChip(core: core),
              const Spacer(),
              IconButton(
                tooltip: 'Phone face view',
                onPressed: onFaceView,
                icon: const Icon(Icons.smartphone_outlined),
              ),
              const SizedBox(width: 8),
              if (anyActive)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC0392B),
                  ),
                  onPressed: onStopAll,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop everything'),
                ),
            ],
          ),
          if (online && core.brain == 'rehearsal')
            const _Banner(
              icon: Icons.theater_comedy_outlined,
              text:
                  'Rehearsal mode: a scripted test run, not AI. It always plays the same invoice task.',
            ),
          if (online && !core.credentialsFound)
            const _Banner(
              icon: Icons.key_off_outlined,
              text:
                  'No Anthropic API key found. Set ANTHROPIC_API_KEY and restart Compii Core.',
            ),
          if (core.status == CoreStatus.offline)
            const _Banner(
              icon: Icons.power_off_outlined,
              text:
                  'Compii Core is not running. In the compii_core folder run: uv run compii-core',
            ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SpeechBubble(text: bubble),
                    const SizedBox(height: 12),
                    CharacterSlot(
                      mood: mood,
                      jobs: core.ordered.where((t) => t.active).length,
                    ),
                    Text(moodLabel(mood), style: text.labelLarge),
                  ],
                ),
              ),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error!,
                style: text.bodySmall?.copyWith(color: const Color(0xFFC0392B)),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  focusNode: focus,
                  autofocus: true,
                  enabled: online,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSubmit(),
                  decoration: InputDecoration(
                    hintText: 'Tell Compii what to do…',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Voice comes in the next build',
                child: IconButton.outlined(
                  onPressed: null,
                  icon: const Icon(Icons.mic_none),
                  tooltip: 'Voice (coming next)',
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: online ? onSubmit : null,
                child: const Text('Go'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.core});
  final CoreClient core;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (core.status) {
      CoreStatus.online => (
        core.brain == 'rehearsal' ? 'Connected · rehearsal' : 'Connected · Claude',
        const Color(0xFF2E9E5B),
      ),
      CoreStatus.connecting => ('Connecting…', const Color(0xFFE0A100)),
      CoreStatus.offline => ('Core offline', const Color(0xFFC0392B)),
    };
    return Chip(
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF4D6),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 520),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      boxShadow: const [
        BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
      ],
    ),
    child: Semantics(
      liveRegion: true,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ),
  );
}

class _TaskCenter extends StatelessWidget {
  const _TaskCenter({required this.core, required this.run});
  final CoreClient core;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final tasks = core.ordered;
    return ColoredBox(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text('Tasks', style: Theme.of(context).textTheme.titleLarge),
          ),
          Expanded(
            child: tasks.isEmpty
                ? const Center(child: Text('Nothing yet. Ask for something.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: tasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) =>
                        _TaskCard(task: tasks[i], core: core, run: run),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.core, required this.run});
  final TaskView task;
  final CoreClient core;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final steps = task.events.where((e) => e['type'] == 'action_done').toList();
    final approval = task.pendingApproval;
    final undoable = steps.any((e) => e['undoable'] == true);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE6E1EA)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    task.request,
                    style: text.titleSmall,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _TaskStatus(status: task.status),
              ],
            ),
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      s['ok'] == true ? Icons.check_circle : Icons.error_outline,
                      size: 18,
                      color: s['ok'] == true
                          ? const Color(0xFF2E9E5B)
                          : const Color(0xFFC0392B),
                      semanticLabel: s['ok'] == true ? 'Done' : 'Failed',
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s['label'] as String, style: text.bodyMedium),
                          // Failures and anything that left the machine show what actually happened.
                          if (s['ok'] != true || s['tool'] == 'send_email')
                            Text(
                              '${s['detail']}',
                              style: text.bodySmall?.copyWith(color: const Color(0xFF6B6570)),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (task.active && approval == null && task.last?['type'] == 'action_started')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${task.last!['label']}…')),
                  ],
                ),
              ),
            if (approval != null) _ApprovalCard(approval: approval, core: core, run: run),
            if (!task.active && task.finalText != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(task.finalText!, style: text.bodyMedium),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                if (task.active)
                  OutlinedButton.icon(
                    onPressed: () => run(() => core.stop(task.id)),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                if (!task.active && undoable)
                  OutlinedButton.icon(
                    onPressed: () => run(() async {
                      final result = await core.undo(task.id);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(result)));
                      }
                    }),
                    icon: const Icon(Icons.undo),
                    label: const Text('Undo last change'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskStatus extends StatelessWidget {
  const _TaskStatus({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'running' => ('Working', _accent),
      'waiting' => ('Needs you', const Color(0xFFB07D00)),
      'done' => ('Done', const Color(0xFF2E9E5B)),
      'failed' => ('Failed', const Color(0xFFC0392B)),
      'stopped' => ('Stopped', const Color(0xFF6B6570)),
      _ => (status, const Color(0xFF6B6570)),
    };
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.approval, required this.core, required this.run});
  final Map<String, dynamic> approval;
  final CoreClient core;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final id = approval['approval_id'] as String;
    final input = Map<String, dynamic>.from(approval['input'] as Map);
    final details = input.entries
        .where((e) => e.key != 'code' && e.value != null)
        .map((e) => '${e.key}: ${e.value is List ? (e.value as List).join(', ') : e.value}')
        .join('\n');
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4D6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Approval needed · ${approval['kind']}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          Text(approval['label'] as String, style: Theme.of(context).textTheme.titleSmall),
          if (input.containsKey('code'))
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(maxHeight: 160),
              color: const Color(0xFFF2EFF5),
              child: SingleChildScrollView(
                child: Text(
                  input['code'] as String,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                ),
              ),
            ),
          if (details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(details, maxLines: 8, overflow: TextOverflow.ellipsis),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                onPressed: () => run(() => core.decide(id, approved: true)),
                child: const Text('Approve'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => run(() => core.decide(id, approved: false)),
                child: const Text('Decline'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Phone Face View (Bluey-style): the screen is Compii's face. Status,
/// speech, approvals and the controls float over it; tasks open in a sheet.
class _FaceStage extends StatelessWidget {
  const _FaceStage({
    required this.mood,
    required this.bubble,
    required this.core,
    required this.input,
    required this.onSubmit,
    required this.run,
    required this.onExit,
  });
  final Mood mood;
  final String bubble;
  final CoreClient core;
  final TextEditingController input;
  final VoidCallback onSubmit;
  final Future<void> Function(Future<void> Function()) run;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final online = core.status == CoreStatus.online;
    final active = core.ordered.where((t) => t.active).length;
    final waiting = core.ordered.where((t) => t.pendingApproval != null).toList();
    const glass = Color(0xE6FFFFFF);
    return ColoredBox(
      color: const Color(0xFF1B1550),
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: 'Compii, ${moodLabel(mood)}',
              image: true,
              child: Orbling(mood: mood, jobs: active, face: true),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: _Pill(
              icon: Icons.circle,
              iconColor: switch (core.status) {
                CoreStatus.online => const Color(0xFF2E9E5B),
                CoreStatus.connecting => const Color(0xFFE0A100),
                CoreStatus.offline => const Color(0xFFC0392B),
              },
              text: online ? moodLabel(mood) : (core.status == CoreStatus.offline ? 'Core offline' : 'Connecting…'),
            ),
          ),
          if (onExit != null)
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(
                tooltip: 'Back to desktop view',
                onPressed: onExit,
                icon: const Icon(Icons.close),
              ),
            ),
          Positioned(
            top: 56,
            left: 16,
            right: 16,
            child: Center(
              child: waiting.isNotEmpty
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Material(
                        color: glass,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
                          child: _ApprovalCard(approval: waiting.first.pendingApproval!, core: core, run: run),
                        ),
                      ),
                    )
                  : Container(
                      constraints: const BoxConstraints(maxWidth: 460),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: glass, borderRadius: BorderRadius.circular(16)),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          bubble,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Row(
              children: [
                Badge(
                  isLabelVisible: active > 0,
                  label: Text('$active'),
                  child: IconButton.filledTonal(
                    tooltip: 'Tasks',
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => SizedBox(
                        height: MediaQuery.of(context).size.height * .7,
                        child: ListenableBuilder(
                          listenable: core,
                          builder: (_, _) => _TaskCenter(core: core, run: run),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.checklist),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: input,
                    enabled: online,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSubmit(),
                    decoration: InputDecoration(
                      hintText: 'Tell Compii…',
                      isDense: true,
                      filled: true,
                      fillColor: glass,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const IconButton.filledTonal(
                  tooltip: 'Voice (coming next)',
                  onPressed: null,
                  icon: Icon(Icons.mic_none),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Stop everything',
                  style: IconButton.styleFrom(backgroundColor: const Color(0xFFC0392B)),
                  onPressed: active > 0 ? () => run(core.stopAll) : null,
                  icon: const Icon(Icons.stop),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.iconColor, required this.text});
  final IconData icon;
  final Color iconColor;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0x99140F3D),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 10, color: iconColor),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

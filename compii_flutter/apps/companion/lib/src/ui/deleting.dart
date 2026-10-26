import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'tokens.dart';

/// Deleting things, one way everywhere: say exactly what goes, ask once, do it,
/// then say what actually happened — including anything that was kept because
/// it was still working. Nothing here is undoable, and every dialog says so.

Future<bool> confirmDeletion(
  BuildContext context, {
  required String title,
  required String detail,
  String confirm = 'Delete',
}) async {
  final c = context.c;
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text('$detail\n\nThis can’t be undone.', style: ctx.type.bodyMedium?.copyWith(color: c.muted)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirm),
            ),
          ],
        ),
      ) ??
      false;
}

void _say(BuildContext context, String text) {
  // The newest outcome replaces the last one rather than queueing behind it.
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Delete one conversation. One that is still working has to be stopped first.
Future<bool> deleteConversationFlow(BuildContext context, CoreClient core, TaskView task) async {
  if (task.active) {
    _say(context, 'Compii is still working on this. Stop it first, then delete it.');
    return false;
  }
  final ok = await confirmDeletion(
    context,
    title: 'Delete this conversation?',
    detail:
        '“${_short(task.request)}” and everything in it will be removed from this PC. '
        'Files it made stay where they are.',
  );
  if (!ok || !context.mounted) return false;
  try {
    await core.deleteConversation(task.id);
    if (context.mounted) _say(context, 'Conversation deleted.');
    return true;
  } on Object catch (e) {
    if (context.mounted) _say(context, 'Couldn’t delete it: $e');
    return false;
  }
}

/// Clear history: all finished conversations, or one teammate's.
Future<void> clearHistoryFlow(BuildContext context, CoreClient core, {BotView? bot}) async {
  final whose = bot == null ? 'every' : '${bot.name}’s';
  final ok = await confirmDeletion(
    context,
    title: bot == null ? 'Delete all conversations?' : 'Delete ${bot.name}’s conversations?',
    detail:
        'Removes $whose finished conversations from this PC. Ones still working are kept. '
        'Files they made stay where they are.',
    confirm: 'Delete conversations',
  );
  if (!ok || !context.mounted) return;
  try {
    final r = await core.clearHistory(botId: bot?.id ?? '');
    if (!context.mounted) return;
    _say(
      context,
      r.deleted == 0 && r.running == 0
          ? 'There was nothing to delete.'
          : 'Deleted ${r.deleted} conversation${r.deleted == 1 ? '' : 's'}.'
                '${r.running > 0 ? ' Kept ${r.running} still working.' : ''}',
    );
  } on Object catch (e) {
    if (context.mounted) _say(context, 'Couldn’t delete them: $e');
  }
}

/// Delete a teammate. Compii itself can only be reset.
Future<bool> deleteTeammateFlow(BuildContext context, CoreClient core, BotView bot) async {
  if (bot.primary) return resetCompiiFlow(context, core);
  final ok = await confirmDeletion(
    context,
    title: 'Delete ${bot.name}?',
    detail:
        '${bot.name} and everything it remembers will be removed. Its past conversations stay '
        'until you delete them.',
    confirm: 'Delete ${bot.name}',
  );
  if (!ok || !context.mounted) return false;
  try {
    await core.deleteBot(bot.id);
    if (context.mounted) _say(context, '${bot.name} deleted.');
    return true;
  } on Object catch (e) {
    if (context.mounted) _say(context, 'Couldn’t delete ${bot.name}: $e');
    return false;
  }
}

/// Reset Compii: choose what goes — what it saved about you, its own set-up,
/// and/or every finished conversation.
Future<bool> resetCompiiFlow(BuildContext context, CoreClient core) async {
  final picked = await showDialog<Set<String>>(context: context, builder: (_) => const _ResetDialog());
  if (picked == null || picked.isEmpty || !context.mounted) return false;
  final done = <String>[];
  try {
    if (picked.contains('memory')) {
      final n = await core.forgetAllMemory();
      done.add('forgot $n saved fact${n == 1 ? '' : 's'}');
    }
    if (picked.contains('setup')) {
      await core.resetCompii();
      done.add('restored its name, instructions and look');
    }
    if (picked.contains('conversations')) {
      final r = await core.clearHistory();
      done.add(
        'deleted ${r.deleted} conversation${r.deleted == 1 ? '' : 's'}'
        '${r.running > 0 ? ' (kept ${r.running} still working)' : ''}',
      );
    }
    if (context.mounted) _say(context, 'Compii reset: ${done.join(', ')}.');
    return true;
  } on Object catch (e) {
    if (context.mounted) {
      _say(context, done.isEmpty ? 'Couldn’t reset Compii: $e' : 'Partly reset (${done.join(', ')}), then: $e');
    }
    return false;
  }
}

class _ResetDialog extends StatefulWidget {
  const _ResetDialog();

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  final _what = <String>{'memory', 'setup'};

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget option(String key, String title, String detail) => CheckboxListTile(
      value: _what.contains(key),
      onChanged: (v) => setState(() => v == true ? _what.add(key) : _what.remove(key)),
      title: Text(title),
      subtitle: Text(detail, style: context.type.bodySmall?.copyWith(color: c.muted)),
      contentPadding: EdgeInsets.zero,
    );
    return AlertDialog(
      title: const Text('Reset Compii'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Compii can’t be deleted — something has to answer — but it can start over. Choose what goes:',
              style: context.type.bodyMedium?.copyWith(color: c.muted),
            ),
            const SizedBox(height: 8),
            option('memory', 'What it remembers about you', 'Every fact it saved, across all conversations.'),
            option('setup', 'Its set-up', 'Name, instructions, look and AI back to how they started.'),
            option('conversations', 'All conversations', 'Every finished conversation. Ones still working are kept.'),
            const SizedBox(height: 4),
            Text('This can’t be undone.', style: context.type.bodySmall?.copyWith(color: c.warning)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: Colors.white),
          onPressed: _what.isEmpty ? null : () => Navigator.pop(context, Set.of(_what)),
          child: const Text('Reset'),
        ),
      ],
    );
  }
}

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 60 ? '${one.substring(0, 59)}…' : one;
}

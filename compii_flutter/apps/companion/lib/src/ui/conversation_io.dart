import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/core_client.dart';
import 'glyphs.dart';
import 'shell.dart';
import 'thread.dart';
import 'tokens.dart';

/// The conversation as a document the user can keep: every ask, the answer that came
/// back, who gave it, and what was read, touched or handed on. Nothing is invented —
/// a line only appears where Core reported it, and a turn with no answer says so.
String threadMarkdown(TaskView task, CoreClient core) {
  final turns = turnsOf(task);
  final out = StringBuffer('# ${task.request}\n\n');
  final said = <String>[];
  final at = turns.isEmpty ? null : turns.first.at;
  if (at != null && at > 0) {
    said.add(DateTime.fromMillisecondsSinceEpoch((at * 1000).round()).toString().substring(0, 16));
  }
  final exchanges = turns.length == 1 ? 'exchange' : 'exchanges';
  said.add('${turns.length} $exchanges');
  if (task.answersWith.isNotEmpty) said.add('answered by ${task.answersWith}');
  final names = <String>{for (final t in turns) core.botFor(t.botId)?.name ?? 'Compii'};
  if (names.length > 1) said.add('with ${names.join(', ')}');
  out.write('${said.join(' · ')}\n');
  for (final (i, t) in turns.indexed) {
    final ask = t.ask;
    out.write('\n---\n\n## ${i + 1}. $ask\n\n');
    final speaker = core.botFor(t.botId);
    if (speaker != null && !speaker.primary) {
      final name = speaker.name;
      out.write('_$name answered._\n\n');
    }
    final reply = t.reply;
    if (reply != null) {
      out.write('$reply\n');
    } else if (t.active) {
      out.write('_Still working when this was saved._\n');
    } else {
      final notSaid = switch (t.status) {
        'failed' => '_It stopped on a problem before answering._',
        'stopped' => '_Stopped before answering._',
        _ => '_No answer was recorded._',
      };
      out.write('$notSaid\n');
    }
    if (t.attachments.isNotEmpty) {
      out.write('\nSent with it:\n');
      for (final f in t.attachments) {
        final name = '${f['name'] ?? 'file'}';
        out.write('- $name\n');
      }
    }
    if (t.finished.isNotEmpty) {
      out.write('\nDid:\n');
      for (final s in t.finished) {
        final step = '${s['label'] ?? s['tool'] ?? 'a step'}';
        final bad = s['ok'] == true ? '' : ' (didn’t work)';
        out.write('- $step$bad\n');
      }
    }
    for (final s in t.screens) {
      final title = '${s['title'] ?? ''}'.trim();
      final where = title.isEmpty ? 'your screen' : '“$title”';
      out.write('- Looked at $where\n');
    }
    for (final h in t.handoffs) {
      final to = '${h['to'] ?? 'another teammate'}';
      out.write('- Handed the thread to $to\n');
    }
    for (final d in t.delegations) {
      final jobId = '${d['job_id'] ?? d['child_task']}';
      final came = switch ('${t.delegationDone[jobId]?['status']}') {
        '' => '',
        'done' => ' — finished',
        'stopped' => ' — stopped',
        'failed' => ' — didn’t finish',
        final other => ' — $other',
      };
      final who = '${d['bot_name'] ?? 'a teammate'}';
      final what = '${d['objective'] ?? 'a job'}';
      out.write('- Asked $who to $what$came\n');
    }
    for (final f in t.files) {
      final action = '${f['action'] ?? 'touched'}';
      final path = '${f['path'] ?? ''}';
      out.write('- $action $path\n');
    }
    final seen = <String>{};
    for (final s in t.sources) {
      final url = '${s['url']}';
      if (seen.add(url)) {
        final title = '${s['title'] ?? ''}'.trim();
        out.write('- Read: $title $url\n');
      }
    }
  }
  return out.toString();
}

/// A file name worth recognising later, from what the conversation was about.
String threadFileName(String request) {
  var words = request
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (words.length > 41) {
    words = words.substring(0, 41).replaceAll(RegExp(r'-+$'), '');
  }
  final slug = words.isEmpty ? 'conversation' : words;
  return 'compii-$slug.md';
}

/// Keep or remove the conversation you are looking at: copy it, save it as a file
/// you own, or delete it from Compii for good. Deleting asks first, because the thread
/// leaves Compii's archive as well as the screen.
class ConversationMenu extends StatelessWidget {
  const ConversationMenu({
    super.key,
    required this.task,
    required this.core,
    required this.state,
  });
  final TaskView task;
  final CoreClient core;
  final AppState state;

  void _pick(BuildContext context, String choice) {
    switch (choice) {
      case 'copy':
        _copy(context);
      case 'save':
        _save(context);
      case 'delete':
        _delete(context);
    }
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: threadMarkdown(task, core)));
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Copied the conversation'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _save(BuildContext context) async {
    try {
      final saved = await FilePicker.saveFile(
        fileName: threadFileName(task.request),
        bytes: Uint8List.fromList(utf8.encode(threadMarkdown(task, core))),
        dialogTitle: 'Save this conversation',
        type: FileType.custom,
        allowedExtensions: const ['md'],
      );
      if (saved == null || !context.mounted) return;
      final where = saved.scheme == 'file' ? saved.toFilePath() : saved.path;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Saved to $where'), duration: const Duration(seconds: 3)),
      );
    } on Object catch (e) {
      state.fail(e);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this conversation?'),
        content: const Text('It goes off the screen and out of Compii’s archive, so it won’t be '
            'there after a restart. Anything it already did on your PC stays as it is.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await core.deleteConversation(task.id);
      // Only leave once Core has forgotten it: if it refused, the conversation is still
      // there, and the user should be looking at the reason rather than at another page.
      state.go(Section.home);
    } on Object catch (e) {
      state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final working = task.active;
    final delete = working ? 'Delete it (stop Compii first)' : 'Delete this conversation';
    return PopupMenuButton<String>(
      key: const Key('conversation-menu'),
      tooltip: 'Conversation options',
      padding: EdgeInsets.zero,
      icon: const Glyph(G.more, size: 18),
      onSelected: (choice) => _pick(context, choice),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'copy', child: Text('Copy the whole thread')),
        const PopupMenuItem(value: 'save', child: Text('Save it as a Markdown file')),
        PopupMenuItem(value: 'delete', enabled: !working, child: Text(delete, style: context.type.bodyMedium)),
      ],
    );
  }
}

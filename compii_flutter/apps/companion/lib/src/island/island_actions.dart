import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../console/core_client.dart';
import 'island_platform.dart';

/// What the island can ask Compii to do. One seam so a widget test can drive
/// every flow without a running Core or a native window.
abstract class IslandActions {
  Future<String> start(String text, {String? botId, List<String> attachments = const []});
  Future<void> reply(String taskId, String text, {List<String> attachments = const []});
  Future<void> stop(String taskId);
  Future<void> decide(String approvalId, {required bool approved});
  Future<void> answerQuestion(String questionId, String text);
  Future<void> finishTakeover(String takeoverId, {String outcome = 'done'});
  Future<void> retry(String taskId);
  Future<void> openInMain(String taskId);

  /// Show the inbox in the full workspace: this is where news with no thread of
  /// its own — a brief, a watch, a journal day — is actually kept.
  Future<void> openInbox();

  /// A picture of the app in front, uploaded to Core and ready to attach.
  /// Throws with a plain reason when sight is off or the window is private.
  Future<Map<String, dynamic>?> attachScreen();

  /// Files the user picked, uploaded to Core and ready to attach.
  Future<List<Map<String, dynamic>>> pickFiles();
}

class CoreIslandActions implements IslandActions {
  CoreIslandActions(this.core, this.platform);

  final CoreClient core;
  final IslandPlatform platform;

  @override
  Future<String> start(String text, {String? botId, List<String> attachments = const []}) =>
      core.startConversation(text, botId: botId, attachments: attachments);

  @override
  Future<void> reply(String taskId, String text, {List<String> attachments = const []}) =>
      core.reply(taskId, text, attachments: attachments);

  @override
  Future<void> stop(String taskId) => core.stop(taskId);

  @override
  Future<void> decide(String approvalId, {required bool approved}) =>
      core.decide(approvalId, approved: approved);

  @override
  Future<void> answerQuestion(String questionId, String text) =>
      core.answerQuestion(questionId, text);

  @override
  Future<void> finishTakeover(String takeoverId, {String outcome = 'done'}) =>
      core.finishTakeover(takeoverId, outcome: outcome);

  @override
  Future<void> retry(String taskId) => core.answerAgain(taskId);

  @override
  Future<void> openInMain(String taskId) async {
    // Core tells the workspace which thread to open; the native side brings it
    // forward, because this process cannot activate another process's window.
    await core.uiShow(taskId);
    await platform.revealMain();
  }

  @override
  Future<void> openInbox() async {
    // Same relay, no thread: the workspace reads "updates" as its inbox page.
    await core.uiShow('', section: 'updates');
    await platform.revealMain();
  }

  @override
  Future<Map<String, dynamic>?> attachScreen() async {
    final bytes = await core.peekScreen(full: false);
    final dir = await Directory.systemTemp.createTemp('compii-island-');
    final file = File('${dir.path}${Platform.pathSeparator}screen.png');
    try {
      await file.writeAsBytes(bytes, flush: true);
      final uploaded = await core.uploadFile(file.path);
      return {
        'path': '${uploaded['path'] ?? ''}',
        'name': 'Screen right now',
        'size': bytes.length,
        'screen': true,
      };
    } finally {
      // Core keeps its own copy in its uploads folder.
      try {
        await file.delete();
      } on FileSystemException {
        // already gone
      }
      try {
        await dir.delete();
      } on FileSystemException {
        // not empty or already gone
      }
    }
  }

  @override
  Future<List<Map<String, dynamic>>> pickFiles() async {
    final picked = await FilePicker.pickFiles(dialogTitle: 'Attach to Compii');
    final out = <Map<String, dynamic>>[];
    for (final f in picked) {
      final path = f.path;
      if (path == null || out.length >= 10) continue;
      final uploaded = await core.uploadFile(path);
      out.add({
        'path': '${uploaded['path'] ?? ''}',
        'name': f.name,
        'size': f.lengthSync() ?? 0,
      });
    }
    return out;
  }
}

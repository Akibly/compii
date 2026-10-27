import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/console_screen.dart';
import '../console/core_client.dart';
import '../mobile/outbox.dart';
import '../mobile/phone_automation.dart';
import '../mobile/phone_bridge.dart';
import '../mobile/phone_notifier.dart';
import 'phone_camera.dart';
import 'phone_digest.dart';
import 'automation.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'phone_voice.dart';
import 'shell.dart';
import 'thread.dart';
import 'tokens.dart';

const _night = Color(0xFF050507);

/// The phone, paired with a PC: talk to Compii, follow and answer its
/// conversations, approve what it asks, and glance at or act on the PC.
class PhoneHome extends StatefulWidget {
  const PhoneHome({
    super.key,
    required this.core,
    required this.state,
    required this.voice,
    required this.onForget,
    this.alerts,
    this.outbox,
    this.controls,
  });
  final CoreClient core;
  final AppState state;
  final PhoneVoice voice;
  final Future<void> Function() onForget;

  /// Android notifications and the widget; injectable for tests.
  final PhoneAlerts? alerts;
  final Outbox? outbox;

  /// This phone's screen and notification stream; injectable for tests.
  final PhoneControls? controls;

  @override
  State<PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<PhoneHome> with WidgetsBindingObserver {
  int _tab = 0;
  late final PhoneAlerts _alerts = widget.alerts ?? PhoneBridge.instance;
  late final Outbox _outbox = widget.outbox ?? Outbox(widget.core);
  late final PhoneNotifier _notifier = PhoneNotifier(widget.core, _alerts);
  late final PhoneControls _controls = widget.controls ?? AutomationBridge.instance;
  late final PhoneAutomation _automation = PhoneAutomation(_controls, send: _trigger, say: _automationSaid);
  StreamSubscription<Map<String, dynamic>>? _signals;

  CoreClient get core => widget.core;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _outbox.init();
    _notifier.start();
    unawaited(_automation.start());
    _signals = _alerts.events.listen(_signal);
    widget.voice.onHeard = _heard;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notifier.askPermissionOnce();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _signals?.cancel();
    widget.voice.onHeard = null;
    _notifier.dispose();
    _automation.dispose();
    if (widget.outbox == null) _outbox.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notifier.setForeground(state == AppLifecycleState.resumed);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      widget.state.fail(null);
    } catch (e) {
      widget.state.fail(e);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _done(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _queued() => _done('No connection — saved on this phone and sent when ${core.remote!.pc} is reachable.');

  /// What a notification rule sends the PC when its match arrives.
  Future<void> _trigger(String text) async {
    try {
      if (core.status != CoreStatus.online) throw CoreError('offline', offline: true);
      await core.startConversation(text);
      _done('Sent to ${core.remote!.pc}.');
    } on Object catch (e) {
      if (e is CoreError && e.offline) {
        await _outbox.ask(text);
        _done('Kept on this phone until ${core.remote!.pc} is back.');
        return;
      }
      _done('Couldn’t send that to ${core.remote!.pc}: $e');
    }
  }

  /// A screen action or look finished. On screen it's a snackbar; away from the
  /// app it becomes a notification, so a switched-away result isn't lost.
  void _automationSaid(String message) {
    if (!mounted) return;
    if (_notifier.foreground) {
      _done(message);
    } else {
      unawaited(_alerts.notify(
        tag: 'automation',
        title: 'Compii on this phone',
        body: message,
        destination: 'automation',
      ));
    }
  }

  Future<void> _showAutomation() async {
    await _automation.refresh();
    if (!mounted) return;
    await showAutomationSheet(context, _automation);
  }

  Future<void> _confirmForget() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${core.remote!.pc}?'),
        content: const Text('This phone stops talking to that PC. To also remove it there, use Settings → Phones on the PC.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget')),
        ],
      ),
    );
    if (ok == true) {
      await _outbox.clear();
      await _notifier.unlink(); // nothing keeps talking to a PC you forgot
      await widget.onForget();
    }
  }

  /// Voice or typing from the talk screen: follow up in the last conversation,
  /// or ask anew. Out of reach, either is kept on the phone and sent later.
  Future<void> _talkSend(String text) async {
    final latest = core.ordered.firstOrNull;
    if (latest != null && !latest.active) {
      await _reply(latest.id, text);
    } else {
      await ask(text);
    }
  }

  Future<void> _heard(String text) => _talkSend(text);

  /// Ask Compii from the phone; opens the conversation so the answer is right there.
  /// When the PC can't be reached, the request waits on the phone and goes out later.
  Future<void> ask(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _run(() async {
      try {
        if (core.status != CoreStatus.online) throw CoreError('offline', offline: true);
        final id = await core.startConversation(trimmed);
        if (!mounted) return;
        setState(() => _tab = 1);
        _openChat(id);
      } on Object catch (e) {
        if (e is CoreError && e.offline) {
          await _outbox.ask(trimmed);
          setState(() => _tab = 1);
          _queued();
          return;
        }
        rethrow;
      }
    });
  }

  Future<void> _reply(String taskId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _run(() async {
      try {
        if (core.status != CoreStatus.online) throw CoreError('offline', offline: true);
        await core.reply(taskId, trimmed);
      } on Object catch (e) {
        if (e is CoreError && e.offline) {
          await _outbox.reply(taskId, trimmed);
          _queued();
          return;
        }
        rethrow;
      }
    });
  }

  /// Do it now, or keep it for when the PC is reachable.
  Future<void> _act(Future<void> Function() now, Future<int> Function() later, String done) async {
    await _run(() async {
      try {
        if (core.status != CoreStatus.online) throw CoreError('offline', offline: true);
        await now();
        _done(done);
      } on Object catch (e) {
        if (e is CoreError && e.offline) {
          await later();
          _queued();
          return;
        }
        rethrow;
      }
    });
  }

  Future<void> _openLink(String url) => _act(
        () => core.openUrl(url),
        () => _outbox.open(url),
        'Opened on ${core.remote!.pc}.',
      );

  Future<void> _copyToPc(String text) => _act(
        () => core.pushClipboard(text),
        () => _outbox.clipboard(text),
        'On the PC’s clipboard. Press Ctrl+V there to paste.',
      );

  Future<void> _saveSnippet(String body) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final field = TextEditingController();
        return AlertDialog(
          title: const Text('Save as a snippet'),
          content: TextField(
            controller: field,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'Work signature'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, field.text), child: const Text('Save')),
          ],
        );
      },
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    await _act(
      () => core.saveSnippet(trimmed, body),
      () => _outbox.snippet(trimmed, body),
      'Saved as “$trimmed” — find it in Clips on the PC, or ask Compii for it.',
    );
  }

  void _openChat(String id) {
    if (!core.tasks.containsKey(id)) {
      _done('That conversation isn’t on ${core.remote!.pc} any more.');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ChatPage(
        core: core,
        state: widget.state,
        taskId: id,
        run: _run,
        onReply: (text) => _reply(id, text),
      ),
    ));
  }

  List<TaskView> get _waiting => [
        for (final t in core.ordered) if (t.pendingApproval != null || t.pendingQuestion != null) t
      ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([core, widget.state, widget.voice, _outbox, _notifier]),
        builder: (context, _) {
          final waiting = _waiting;
          final pages = [
            _TalkTab(core: core, state: widget.state, voice: widget.voice, menu: _menu(), onSend: _talkSend, onCamera: _photo),
            _ChatsTab(
              core: core,
              state: widget.state,
              onOpen: _openChat,
              onAsk: ask,
              pending: _outbox.pending,
              problem: _outbox.problem,
              onRetry: _outbox.flush,
            ),
            _PcTab(
              core: core,
              run: _run,
              onAsk: ask,
              onForget: _confirmForget,
              onOpenLink: _openLink,
              onCopyToPc: _copyToPc,
              onPhoto: (ask) => _photo(ask: ask),
            ),
          ];
          return Scaffold(
            backgroundColor: _tab == 0 ? _night : context.c.canvas,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  if (core.unauthorized)
                    _RemovedBanner(
                      pc: core.remote!.pc,
                      onPair: () async {
                        await _notifier.unlink(); // the PC removed this phone: stop the link too
                        await widget.onForget();
                      },
                    ),
                  if (waiting.isNotEmpty) _ApprovalBanner(tasks: waiting, onOpen: _showApprovals),
                  if (!core.unauthorized && core.status != CoreStatus.online)
                    _OfflineBar(core: core, waiting: _outbox.count, onRetry: _outbox.flush),
                  Expanded(child: IndexedStack(index: _tab, children: pages)),
                ],
              ),
            ),
            // On Talk the bar is part of the night around the face, not a light strip under it.
            bottomNavigationBar: Theme(
              data: _tab == 0 ? compiiTheme(Brightness.dark) : Theme.of(context),
              child: NavigationBar(
                backgroundColor: _tab == 0 ? _night : null,
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: [
                  const NavigationDestination(icon: Glyph(G.mic), label: 'Talk'),
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: waiting.isNotEmpty || core.ordered.any((t) => t.active),
                      backgroundColor: waiting.isNotEmpty ? context.c.warning : context.c.accent,
                      child: const Glyph(G.chat),
                    ),
                    label: 'Chats',
                  ),
                  const NavigationDestination(icon: Glyph(G.monitor), label: 'PC'),
                ],
              ),
            ),
          );
        },
      );

  Widget _menu() => PopupMenuButton<String>(
        tooltip: 'More',
        icon: const Glyph(G.sliders, color: Colors.white),
        onSelected: (v) async {
          switch (v) {
            case 'voice':
            case 'sound':
            case 'caption':
            case 'off':
              await widget.voice.setMode(v);
            case 'alerts':
              await _notifier.setEnabled(!_notifier.enabled);
            case 'alert-settings':
              await _notifier.openSettings();
            case 'automation':
              await _showAutomation();
            case 'forget':
              await _confirmForget();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, child: Text('Connected to ${core.remote!.pc}')),
          for (final (mode, label) in const [('voice', 'Speak replies'), ('sound', 'A chime, with the words'), ('caption', 'Words on screen only'), ('off', 'Stay quiet')])
            CheckedPopupMenuItem(value: mode, checked: widget.voice.outputMode == mode, child: Text(label)),
          const PopupMenuDivider(),
          CheckedPopupMenuItem(
            value: 'alerts',
            checked: _notifier.enabled,
            child: const Text('Notify me when away'),
          ),
          const PopupMenuItem(value: 'alert-settings', child: Text('Android alert settings')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'automation', child: Text('On this phone…')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'forget', child: Text('Forget this PC')),
        ],
      );

  /// Taps on notifications and the widget, and text, photos and files shared from other apps.
  void _signal(Map<String, dynamic> event) {
    if (!mounted) return;
    final files = '${event['files'] ?? ''}'.split('\n').where((p) => p.isNotEmpty).toList();
    if (event['type'] == 'share' && files.isNotEmpty) {
      unawaited(_photo(shared: files));
    } else if (event['type'] == 'share') {
      _shareSheet('${event['text'] ?? ''}');
    } else if (event['type'] == 'open') {
      _destination('${event['destination'] ?? ''}');
    }
  }

  void _destination(String dest) {
    if (dest == 'automation') {
      unawaited(_showAutomation());
    } else if (dest == 'talk') {
      setState(() => _tab = 0);
    } else if (dest == 'camera') {
      setState(() => _tab = 0);
      unawaited(_photo());
    } else if (dest.startsWith('task:')) {
      setState(() => _tab = 1);
      _openChat(dest.substring(5));
    } else {
      setState(() => _tab = 1);
      if (dest == 'approvals') _showApprovals();
    }
  }

  static bool _isLink(String text) => RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(text.trim());

  Future<void> _shareSheet(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    final link = _isLink(text);
    final pc = core.remote!.pc;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send to Compii', style: context.type.titleLarge),
              const SizedBox(height: 2),
              Text('From another app, to $pc', style: context.type.bodySmall?.copyWith(color: context.c.muted)),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 120),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: context.c.sunken, borderRadius: Shapes.r12),
                child: SingleChildScrollView(
                  child: Text(text, maxLines: 8, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                ),
              ),
              const SizedBox(height: 10),
              if (link) ...[
                ListTile(
                  leading: const Glyph(G.globe),
                  title: Text('Open on $pc'),
                  subtitle: const Text('In its browser, ready for you there'),
                  onTap: () => Navigator.pop(context, 'open'),
                ),
                ListTile(
                  leading: const Glyph(G.chat),
                  title: const Text('Ask Compii about it'),
                  subtitle: const Text('What it is, and anything worth knowing'),
                  onTap: () => Navigator.pop(context, 'ask-link'),
                ),
              ] else
                ListTile(
                  leading: const Glyph(G.chat),
                  title: const Text('Ask Compii'),
                  subtitle: const Text('Send this text as the request'),
                  onTap: () => Navigator.pop(context, 'ask'),
                ),
              ListTile(
                leading: const Glyph(G.clipboard),
                title: Text('Copy to $pc'),
                subtitle: const Text('Paste it there with Ctrl+V'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
              ListTile(
                leading: const Glyph(G.note),
                title: const Text('Save as a snippet'),
                subtitle: const Text('Keep it in Clips for next time'),
                onTap: () => Navigator.pop(context, 'snippet'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'open':
        await _openLink(text);
      case 'ask-link':
        await ask('Open this link on my PC and tell me what it is, and anything I should know about it: $text');
      case 'ask':
        await ask(text);
      case 'copy':
        await _copyToPc(text);
      case 'snippet':
        await _saveSnippet(text);
    }
  }

  /// Show Compii a photo: take one (or pick one you have), choose what to ask,
  /// and the answer opens as a chat. Photos and files shared from other apps
  /// come in as `shared`. Looking happens on the PC, so it needs the PC.
  Future<void> _photo({List<String>? shared, PhotoAsk? ask}) async {
    final pc = core.remote!.pc;
    var paths = shared;
    var choice = ask;
    if (choice == null) {
      final photos = paths == null || paths.every(isPhotoPath);
      final picked = await choosePhotoAsk(context, pc: pc, shared: paths?.length ?? 0, photos: photos);
      if (picked == null || !mounted) return;
      choice = picked.ask;
      if (picked.gallery) {
        final path = await takePhoto(gallery: true);
        if (path == null || !mounted) return;
        return _photo(shared: [path]);
      }
    }
    if (paths == null) {
      final path = await takePhoto();
      if (path == null || !mounted) return;
      paths = [path];
    }
    final files = paths;
    final what = choice;
    await _run(() async {
      if (core.status != CoreStatus.online) {
        throw CoreError('Compii looks at photos on $pc, and it isn’t reachable right now. Try again when it’s on.');
      }
      _done(files.length == 1 ? 'Sending it to $pc…' : 'Sending ${files.length} to $pc…');
      final up = [for (final p in files) await core.uploadFile(p)];
      if (what == PhotoAsk.save) {
        _done(up.length == 1 ? 'Saved on $pc as ${up.first['name']}.' : 'Saved ${up.length} files on $pc.');
        return;
      }
      final id = await core.startConversation(
        what.request([for (final u in up) '${u['name']}']),
        attachments: [for (final u in up) '${u['path']}'],
      );
      if (!mounted) return;
      setState(() => _tab = 1);
      _openChat(id);
    });
  }

  /// The approvals tray, shared by the banner and notification taps.
  void _showApprovals() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: core,
        builder: (context, _) {
          final cards = <Widget>[
            for (final t in core.ordered)
              if (t.pendingApproval case final a?)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: ApprovalCard(approval: a, core: core, run: _run, compact: true)),
            for (final t in core.ordered)
              if (t.pendingQuestion case final q?)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: QuestionCard(question: q, core: core, run: _run, compact: true)),
          ];
          if (cards.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.of(context).canPop()) Navigator.of(context).pop();
            });
          }
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: cards,
            ),
          );
        },
      ),
    );
  }
}

// ---- Talk -------------------------------------------------------------------------------------

class _TalkTab extends StatelessWidget {
  const _TalkTab({
    required this.core,
    required this.state,
    required this.voice,
    required this.menu,
    required this.onSend,
    required this.onCamera,
  });
  final CoreClient core;
  final AppState state;
  final PhoneVoice voice;
  final Widget menu;
  final Future<void> Function(String text) onSend;
  final Future<void> Function() onCamera;

  @override
  Widget build(BuildContext context) {
    final problem = voice.error ?? state.error;
    final captioning = voice.listening || voice.busy || voice.partial.isNotEmpty;
    return ColoredBox(
      color: _night,
      child: Stack(
        children: [
          FaceStage(core: core, state: state, onExit: null, menu: menu, onSend: onSend, allowOffline: true),
          // Show Compii something: the camera, beside the face.
          Positioned(
            right: Space.xl,
            bottom: 140,
            child: Tooltip(
              message: 'Show Compii a photo',
              child: Material(
                color: const Color(0xCC0E0E12),
                shape: const CircleBorder(side: BorderSide(color: Color(0x1FFFFFFF))),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onCamera,
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Glyph(G.camera, size: 22, color: Color(0xFFF5F5F7)),
                  ),
                ),
              ),
            ),
          ),
          if (problem != null || captioning)
            Positioned(
              left: Space.xl,
              right: Space.xl,
              bottom: 84,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (problem != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.s),
                      child: _VoiceProblem(
                        text: problem,
                        onDismiss: () {
                          voice.error = null;
                          state.fail(null);
                          voice.refresh();
                        },
                      ),
                    ),
                  if (captioning) _Heard(text: voice.partial, busy: voice.busy),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A failure beside the mic. The caption owns the bottom line, so a problem
/// stacks above it instead of painting over what the phone just heard.
class _VoiceProblem extends StatelessWidget {
  const _VoiceProblem({required this.text, required this.onDismiss});
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Material(
        color: context.c.dangerSoft,
        borderRadius: Shapes.r14,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(text, style: context.type.bodyMedium?.copyWith(color: context.c.danger)),
              ),
              IconButton(tooltip: 'Dismiss', onPressed: onDismiss, icon: const Glyph(G.close, size: 18)),
            ],
          ),
        ),
      );
}

class _Heard extends StatelessWidget {
  const _Heard({required this.text, required this.busy});
  final String text;
  final bool busy;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xCC140F3D), borderRadius: Shapes.r16),
        child: Text(
          text.isEmpty ? (busy ? 'Sending…' : 'Listening…') : text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
        ),
      );
}

// ---- Chats ------------------------------------------------------------------------------------

class _ChatsTab extends StatelessWidget {
  const _ChatsTab({
    required this.core,
    required this.state,
    required this.onOpen,
    required this.onAsk,
    required this.pending,
    required this.problem,
    required this.onRetry,
  });
  final CoreClient core;
  final AppState state;
  final void Function(String id) onOpen;
  final Future<void> Function(String text) onAsk;
  final List<Map<String, dynamic>> pending;
  final String? problem;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final list = core.ordered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(children: [Expanded(child: Text('Conversations', style: context.type.headlineSmall))]),
        ),
        DigestCard(core: core),
        if (pending.isNotEmpty)
          _PendingCard(pending: pending, problem: problem, online: core.status == CoreStatus.online, onRetry: onRetry),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('Nothing yet. Ask Compii anything below; it works on your PC while you’re away.',
                        textAlign: TextAlign.center, style: context.type.bodyMedium?.copyWith(color: c.muted)),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _ChatTile(task: list[i], onTap: () => onOpen(list[i].id)),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Composer(core: core, state: state, onSend: onAsk, autofocus: false, allowOffline: true, hint: 'Ask Compii to do something on your PC…'),
        ),
      ],
    );
  }
}

/// Requests made while the PC was away, shown honestly so nothing feels lost.
class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.pending, required this.problem, required this.online, required this.onRetry});
  final List<Map<String, dynamic>> pending;
  final String? problem;
  final bool online;
  final Future<void> Function() onRetry;

  String _label(Map<String, dynamic> a) => switch ('${a['kind']}') {
        'ask' => '${a['text'] ?? ''}',
        'reply' => 'Reply: ${a['text'] ?? ''}',
        'clipboard' => 'Copy to PC: ${a['text'] ?? ''}',
        'url' => 'Open on PC: ${a['url'] ?? ''}',
        'snippet' => 'Snippet: ${a['name'] ?? ''}',
        _ => 'Waiting request',
      };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(color: c.warningSoft, borderRadius: Shapes.r14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Glyph(G.clock, size: 18, color: c.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  online ? 'Sending ${pending.length} waiting ${pending.length == 1 ? 'request' : 'requests'}…' : '${pending.length} waiting to send',
                  style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (online)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                TextButton(onPressed: () => onRetry(), child: const Text('Retry')),
            ],
          ),
          for (final a in pending.take(3)) ...[
            const SizedBox(height: 4),
            Text('· ${_label(a)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
          ],
          if (pending.length > 3) Text('· and ${pending.length - 3} more', style: context.type.bodySmall),
          if (problem != null) ...[
            const SizedBox(height: 4),
            Text(problem!, style: context.type.bodySmall?.copyWith(color: c.danger)),
          ],
        ],
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.task, required this.onTap});
  final TaskView task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final waiting = task.pendingApproval != null;
    final (label, color, glyph) = waiting
        ? ('Needs your OK', c.warning, G.hand)
        : task.pendingQuestion != null
            ? ('Asking you something', c.warning, G.chat)
            : task.active
            ? ('Working…', c.accent, G.sync)
            : task.status == 'failed'
                ? ('Didn’t finish', c.danger, G.alert)
                : ('Done', c.success, G.checkCircle);
    final preview = task.finalText ?? (task.last?['text'] as String?) ?? '';
    return Material(
      color: c.raised,
      borderRadius: Shapes.r16,
      child: InkWell(
        borderRadius: Shapes.r16,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              GlyphTile(glyph: glyph, size: 38, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(task.request, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      preview.isEmpty ? label : '$label · $preview',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.bodySmall?.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ),
              Glyph(G.chevronRight, size: 18, color: c.faint),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatPage extends StatelessWidget {
  const _ChatPage({required this.core, required this.state, required this.taskId, required this.run, required this.onReply});
  final CoreClient core;
  final AppState state;
  final String taskId;
  final Run run;
  final Future<void> Function(String text) onReply;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: core,
        builder: (context, _) {
          final task = core.tasks[taskId];
          return Scaffold(
            backgroundColor: context.c.canvas,
            appBar: AppBar(
              title: Text(task?.request ?? 'Conversation', maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                if (task != null && task.active)
                  IconButton(tooltip: 'Stop', onPressed: () => run(() => core.stop(taskId)), icon: const Glyph(G.stop)),
              ],
            ),
            body: task == null
                ? const Center(child: CircularProgressIndicator())
                : SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        Expanded(child: ThreadView(task: task, core: core, run: run, compact: true)),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          child: Composer(
                            core: core,
                            state: state,
                            autofocus: false,
                            allowOffline: true,
                            busyTask: task,
                            run: run,
                            hint: 'Reply…',
                            onSend: onReply,
                          ),
                        ),
                      ],
                    ),
                  ),
          );
        },
      );
}

// ---- PC ---------------------------------------------------------------------------------------

class _PcTab extends StatefulWidget {
  const _PcTab({
    required this.core,
    required this.run,
    required this.onAsk,
    required this.onForget,
    required this.onOpenLink,
    required this.onCopyToPc,
    required this.onPhoto,
  });
  final CoreClient core;
  final Run run;
  final Future<void> Function(String text) onAsk;
  final Future<void> Function() onForget;
  final Future<void> Function(String url) onOpenLink;
  final Future<void> Function(String text) onCopyToPc;
  final Future<void> Function(PhotoAsk ask) onPhoto;

  @override
  State<_PcTab> createState() => _PcTabState();
}

class _PcTabState extends State<_PcTab> {
  Uint8List? _shot;
  String? _shotError;
  DateTime? _shotAt;
  bool _loading = false;
  bool _live = false;
  Timer? _timer;

  CoreClient get core => widget.core;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _peek() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final png = await core.peekScreen();
      if (!mounted) return;
      setState(() {
        _shot = png;
        _shotError = null;
        _shotAt = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _shotError = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setLive(bool on) {
    _timer?.cancel();
    setState(() => _live = on);
    if (on) {
      _peek();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _peek());
    }
  }

  Future<String?> _prompt(String title, String label, {String seed = '', String action = 'Send'}) {
    final text = TextEditingController(text: seed);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: text, autofocus: true, minLines: 1, maxLines: 5, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: Text(action)),
        ],
      ),
    );
  }

  Future<void> _sendLink() async {
    final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    final url = await _prompt('Open a link on the PC', 'Link', seed: copied.startsWith('http') ? copied : '', action: 'Open');
    if (url == null || url.isEmpty) return;
    await widget.onOpenLink(url.startsWith('http') ? url : 'https://$url');
  }

  Future<void> _sendText() async {
    final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final text = await _prompt('Copy to the PC', 'Text to paste on the PC', seed: copied, action: 'Copy');
    if (text == null || text.isEmpty) return;
    await widget.onCopyToPc(text);
  }

  Future<void> _find() async {
    final what = await _prompt('Find on the PC', 'What are you looking for?', action: 'Find');
    if (what == null || what.isEmpty) return;
    await widget.onAsk('Find this on my PC and tell me where it is: $what');
  }

  void _done(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final link = core.remote!;
    final online = core.status == CoreStatus.online;
    final via = !online ? 'Not connected' : core.viaAnywhere ? 'Connected from anywhere (Tailscale)' : 'Connected on your Wi-Fi';
    final anywhere = link.hosts.any(isOverlayAddress);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(link.pc, style: context.type.headlineSmall),
        const SizedBox(height: 4),
        Row(
          children: [
            Glyph(G.dot, size: 10, color: online ? c.success : c.faint),
            const SizedBox(width: 6),
            Expanded(child: Text(via, style: context.type.bodySmall?.copyWith(color: c.muted))),
          ],
        ),
        const SizedBox(height: 14),
        _ScreenCard(
          shot: _shot,
          error: _shotError,
          at: _shotAt,
          loading: _loading,
          live: _live,
          onPeek: _peek,
          onLive: _setLive,
        ),
        const SizedBox(height: 18),
        Text('Do on the PC', style: context.type.titleMedium),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.3,
          children: [
            _Action(glyph: G.eye, label: 'What’s on screen?', onTap: () => widget.onAsk(
                'Look at my PC screen and tell me briefly what’s on it and anything that needs my attention.')),
            _Action(glyph: G.camera, label: 'What is this?', onTap: () => widget.onPhoto(PhotoAsk.what)),
            _Action(glyph: G.file, label: 'Snap a document', onTap: () => widget.onPhoto(PhotoAsk.document)),
            _Action(glyph: G.globe, label: 'Open a link', onTap: _sendLink),
            _Action(glyph: G.doc, label: 'Copy to PC', onTap: _sendText),
            _Action(glyph: G.search, label: 'Find a file', onTap: _find),
            _Action(glyph: G.bell, label: 'Brief me now', onTap: () => widget.run(core.briefNow)),
            _Action(glyph: G.stop, label: 'Stop everything', danger: true, onTap: () async {
              await widget.run(core.stopAll);
              _done('Compii stopped everything on ${link.pc}.');
            }),
          ],
        ),
        const SizedBox(height: 18),
        if (!anywhere)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: c.accentSoft, borderRadius: Shapes.r16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Glyph(G.cloud, color: c.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Want Compii when you’re out? Install the free Tailscale app on this phone and the PC and sign in to both '
                    'with the same account. Compii finds the new address by itself; nothing to set up here.',
                    style: context.type.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        TextButton(onPressed: widget.onForget,
            child: Text('Forget ${link.pc}', style: context.type.labelLarge?.copyWith(color: c.danger))),
      ],
    );
  }
}

class _ScreenCard extends StatelessWidget {
  const _ScreenCard({required this.shot, required this.error, required this.at, required this.loading, required this.live,
      required this.onPeek, required this.onLive});
  final Uint8List? shot;
  final String? error;
  final DateTime? at;
  final bool loading;
  final bool live;
  final VoidCallback onPeek;
  final ValueChanged<bool> onLive;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      decoration: BoxDecoration(color: c.raised, borderRadius: Shapes.r18, border: Border.all(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: c.sunken,
              child: shot != null
                  ? Semantics(
                      button: true,
                      label: 'See the PC screen full size',
                      child: GestureDetector(
                        onTap: () => _fullScreen(context, shot!),
                        child: Image.memory(shot!, fit: BoxFit.contain, gaplessPlayback: true),
                      ),
                    )
                  : Center(
                      child: loading
                          ? const CircularProgressIndicator()
                          : Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(error ?? 'Tap Look to see the PC’s screen.',
                                  textAlign: TextAlign.center, style: context.type.bodySmall?.copyWith(color: c.muted)),
                            ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    error != null && shot != null ? error! : at == null ? 'Screen' : 'Updated ${_clock(at!)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodySmall?.copyWith(color: error != null ? c.danger : c.muted),
                  ),
                ),
                Text('Live', style: context.type.bodySmall),
                Switch(value: live, onChanged: onLive),
                IconButton(tooltip: 'Look now', onPressed: loading ? null : onPeek, icon: const Glyph(G.sync, size: 20)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  static void _fullScreen(BuildContext context, Uint8List png) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(png))),
      ),
    ));
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.glyph, required this.label, required this.onTap, this.danger = false});
  final GlyphData glyph;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = danger ? c.danger : c.accent;
    return Material(
      color: danger ? c.dangerSoft : c.raised,
      borderRadius: Shapes.r16,
      child: InkWell(
        borderRadius: Shapes.r16,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Glyph(glyph, color: fg, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: context.type.labelLarge?.copyWith(color: danger ? c.danger : c.text))),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Banners ----------------------------------------------------------------------------------

class _ApprovalBanner extends StatelessWidget {
  const _ApprovalBanner({required this.tasks, required this.onOpen});
  final List<TaskView> tasks;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final first = tasks.first.pendingApproval;
    final asked = tasks.first.pendingQuestion;
    final headline = first != null
        ? (tasks.length == 1
            ? 'Compii needs your OK: ${first['label'] ?? first['tool'] ?? 'an action'}'
            : '${tasks.length} things need your OK')
        : 'Compii is asking: ${asked?['question'] ?? 'a question'}';
    return Material(
      color: c.warningSoft,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              Glyph(asked != null && first == null ? G.chat : G.hand, color: c.warning),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text('Review', style: context.type.labelLarge?.copyWith(color: c.accent)),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar({required this.core, this.waiting = 0, this.onRetry});
  final CoreClient core;
  final int waiting;
  final Future<void> Function()? onRetry;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                waiting > 0
                    ? 'Looking for ${core.remote!.pc} · $waiting ${waiting == 1 ? 'request' : 'requests'} waiting'
                    : 'Looking for ${core.remote!.pc} at ${core.host}…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.bodySmall?.copyWith(color: c.muted),
              ),
            ),
            if (waiting > 0) TextButton(onPressed: onRetry == null ? null : () => onRetry!(), child: const Text('Send now')),
          ],
        ),
      ),
    );
  }
}

class _RemovedBanner extends StatelessWidget {
  const _RemovedBanner({required this.pc, required this.onPair});
  final String pc;
  final Future<void> Function() onPair;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.dangerSoft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Expanded(
              child: Text('This phone was removed on $pc.',
                  style: context.type.bodyMedium?.copyWith(color: c.danger)),
            ),
            TextButton(onPressed: onPair, child: const Text('Pair again')),
          ],
        ),
      ),
    );
  }
}

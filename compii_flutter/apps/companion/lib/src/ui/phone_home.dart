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
import 'phone_kit.dart';
import 'automation.dart';
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
            _TalkTab(
              core: core,
              state: widget.state,
              voice: widget.voice,
              menu: _menu(),
              onSend: _talkSend,
              onCamera: _photo,
              onAsk: ask,
              onBrief: () => _run(core.briefNow),
            ),
            _ChatsTab(
              core: core,
              state: widget.state,
              onOpen: _openChat,
              onAsk: ask,
              onDelete: _deleteChat,
              onSettings: _showSettings,
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
              onSettings: _showSettings,
            ),
          ];
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: phoneSystemUi,
            child: Scaffold(
            backgroundColor: _night,
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
            // One night from top to bottom: the bar is part of it, with a hairline above.
            bottomNavigationBar: DecoratedBox(
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x0FFFFFFF)))),
              child: NavigationBar(
                backgroundColor: _night,
                indicatorColor: const Color(0x1AFFFFFF),
                height: 68,
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
          ),
          );
        },
      );

  Widget _menu() => IconButton(
        tooltip: 'Settings',
        onPressed: _showSettings,
        icon: const Glyph(G.sliders, color: Colors.white),
      );

  Future<void> _deleteChat(TaskView t) async {
    await _run(() async {
      await core.deleteConversation(t.id);
      _done('Deleted “${chatTitle(t.request)}”.');
    });
  }

  /// Everything you set on the phone, in one sheet: how Compii answers, when it
  /// may notify you, what it can do on this phone, and the PC it's paired with.
  Future<void> _showSettings() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: _night,
        builder: (context) => ListenableBuilder(
          listenable: Listenable.merge([widget.voice, _notifier, core]),
          builder: (context, _) {
            final c = context.c;
            String hm(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60).format(context);
            Future<void> pick(bool from) async {
              final m = from ? _notifier.quietFrom : _notifier.quietTo;
              final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
              if (t == null) return;
              await (from
                  ? _notifier.setQuiet(from: t.hour * 60 + t.minute)
                  : _notifier.setQuiet(to: t.hour * 60 + t.minute));
            }

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .88),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
                      child: Text('Settings', style: context.type.headlineSmall),
                    ),
                    const GroupLabel('When Compii answers'),
                    HaloGroup(children: [
                      for (final (mode, label, sub) in const [
                        ('voice', 'Speak replies', 'Out loud, and written'),
                        ('sound', 'A chime', 'Then the words on screen'),
                        ('caption', 'Words only', 'Nothing out loud'),
                        ('off', 'Stay quiet', 'Answers wait in Chats'),
                      ])
                        HaloRow(
                          title: label,
                          subtitle: sub,
                          onTap: () => widget.voice.setMode(mode),
                          trailing: widget.voice.outputMode == mode
                              ? Glyph(G.check, size: 18, color: c.accent)
                              : const SizedBox(width: 18),
                        ),
                    ]),
                    const GroupLabel('Notifications'),
                    HaloGroup(children: [
                      HaloRow(
                        glyph: G.bell,
                        title: 'Notify me when I’m away',
                        subtitle: _notifier.permission ? 'Answers, approvals and questions' : 'Android hasn’t allowed it yet',
                        onTap: () => _notifier.setEnabled(!_notifier.enabled),
                        trailing: Switch(value: _notifier.enabled, onChanged: _notifier.setEnabled),
                      ),
                      HaloRow(
                        glyph: G.clock,
                        title: 'Quiet hours',
                        subtitle: _notifier.quiet
                            ? '${hm(_notifier.quietFrom)} to ${hm(_notifier.quietTo)} · only what needs you'
                            : 'Only approvals and questions at night',
                        onTap: () => _notifier.setQuiet(on: !_notifier.quiet),
                        trailing: Switch(value: _notifier.quiet, onChanged: (v) => _notifier.setQuiet(on: v)),
                      ),
                      if (_notifier.quiet) ...[
                        HaloRow(title: 'Starts', onTap: () => pick(true),
                            trailing: Text(hm(_notifier.quietFrom), style: context.type.bodyLarge?.copyWith(color: c.accent))),
                        HaloRow(title: 'Ends', onTap: () => pick(false),
                            trailing: Text(hm(_notifier.quietTo), style: context.type.bodyLarge?.copyWith(color: c.accent))),
                      ],
                      HaloRow(glyph: G.external, title: 'Android notification settings', onTap: _notifier.openSettings),
                    ]),
                    const GroupLabel('This phone'),
                    HaloGroup(children: [
                      HaloRow(
                        glyph: G.phone,
                        title: 'On this phone…',
                        subtitle: 'Let Compii read and use apps here, with your OK',
                        onTap: () {
                          Navigator.pop(context);
                          _showAutomation();
                        },
                      ),
                    ]),
                    GroupLabel('Paired PC'),
                    HaloGroup(children: [
                      HaloRow(
                        glyph: G.monitor,
                        title: core.remote!.pc,
                        subtitle: core.status != CoreStatus.online
                            ? 'Not connected'
                            : core.viaAnywhere
                                ? 'Connected from anywhere'
                                : 'Connected on your Wi-Fi',
                        chevron: false,
                      ),
                      HaloRow(
                        glyph: G.power,
                        title: 'Forget this PC',
                        danger: true,
                        onTap: () {
                          Navigator.pop(context);
                          _confirmForget();
                        },
                      ),
                    ]),
                  ],
                ),
              ),
            );
          },
        ),
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
    required this.onAsk,
    required this.onBrief,
  });
  final CoreClient core;
  final AppState state;
  final PhoneVoice voice;
  final Widget menu;
  final Future<void> Function(String text) onSend;
  final Future<void> Function() onCamera;
  final Future<void> Function(String text) onAsk;
  final Future<void> Function() onBrief;

  @override
  Widget build(BuildContext context) {
    final problem = voice.error ?? state.error;
    final captioning = voice.listening || voice.busy || voice.partial.isNotEmpty;
    return ColoredBox(
      color: _night,
      child: Stack(
        children: [
          FaceStage(core: core, state: state, onExit: null, menu: menu, onSend: onSend, allowOffline: true),
          // Ways to start, above the composer: show a photo, look at the PC, get the brief.
          if (!captioning && problem == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 92,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.l),
                child: Row(
                  children: [
                    HaloChip(glyph: G.camera, label: 'Show a photo', onTap: onCamera),
                    const SizedBox(width: 8),
                    HaloChip(
                      glyph: G.eye,
                      label: 'What’s on my PC?',
                      onTap: () => onAsk('Look at my PC screen and tell me briefly what’s on it and anything that needs me.'),
                    ),
                    const SizedBox(width: 8),
                    HaloChip(glyph: G.sun, label: 'Brief me', onTap: onBrief),
                  ],
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
        decoration: BoxDecoration(
          color: const Color(0xE60E0E12),
          borderRadius: Shapes.r16,
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Text(
          text.isEmpty ? (busy ? 'Sending…' : 'Listening…') : text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
        ),
      );
}

// ---- Chats ------------------------------------------------------------------------------------

class _ChatsTab extends StatefulWidget {
  const _ChatsTab({
    required this.core,
    required this.state,
    required this.onOpen,
    required this.onAsk,
    required this.onDelete,
    required this.onSettings,
    required this.pending,
    required this.problem,
    required this.onRetry,
  });
  final CoreClient core;
  final AppState state;
  final void Function(String id) onOpen;
  final Future<void> Function(String text) onAsk;
  final Future<void> Function(TaskView task) onDelete;
  final VoidCallback onSettings;
  final List<Map<String, dynamic>> pending;
  final String? problem;
  final Future<void> Function() onRetry;

  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> {
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(TaskView t, String q) =>
      q.isEmpty ||
      t.request.toLowerCase().contains(q) ||
      (t.finalText ?? '').toLowerCase().contains(q);

  Future<bool> _confirmDelete(TaskView t) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete this conversation?'),
          content: Text('“${chatTitle(t.request)}” is removed from your PC too. Files it made stay where they are.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: context.c.danger, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final q = _search.text.trim().toLowerCase();
    final all = widget.core.ordered.where((t) => _matches(t, q)).toList();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final needs = [for (final t in all) if (ChatState.of(t) case ChatState.needsYou || ChatState.asking) t];
    final working = [for (final t in all) if (ChatState.of(t) == ChatState.working) t];
    final rest = [for (final t in all) if (!needs.contains(t) && !working.contains(t)) t];
    final todays = [for (final t in rest) if (!(lastMoved(t)?.isBefore(today) ?? false)) t];
    final earlier = [for (final t in rest) if (!todays.contains(t)) t];

    Widget group(String label, List<TaskView> tasks, {Color? edge}) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GroupLabel(label),
            HaloGroup(
              edge: edge,
              children: [
                for (final t in tasks)
                  Dismissible(
                    key: ValueKey('chat-${t.id}'),
                    direction: t.active ? DismissDirection.none : DismissDirection.endToStart,
                    confirmDismiss: (_) => _confirmDelete(t),
                    onDismissed: (_) => widget.onDelete(t),
                    background: Container(
                      color: c.danger,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Glyph(G.trash, color: Colors.white),
                    ),
                    child: _ChatTile(task: t, onTap: () => widget.onOpen(t.id)),
                  ),
              ],
            ),
          ],
        );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
          child: _searching
              ? Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        autofocus: true,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(hintText: 'Search conversations', isDense: true),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _searching = false;
                        _search.clear();
                      }),
                      child: const Text('Cancel'),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: Text('Chats', style: context.type.headlineMedium?.copyWith(fontWeight: FontWeight.w600))),
                    IconButton(tooltip: 'Search', onPressed: () => setState(() => _searching = true), icon: const Glyph(G.search)),
                    IconButton(tooltip: 'Settings', onPressed: widget.onSettings, icon: const Glyph(G.sliders)),
                  ],
                ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              if (!_searching) ...[const SizedBox(height: 8), DigestCard(core: widget.core)],
              if (widget.pending.isNotEmpty)
                _PendingCard(
                  pending: widget.pending,
                  problem: widget.problem,
                  online: widget.core.status == CoreStatus.online,
                  onRetry: widget.onRetry,
                ),
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
                  child: Text(
                    q.isNotEmpty
                        ? 'No conversation mentions “${_search.text.trim()}”.'
                        : 'Nothing yet. Ask Compii anything below; it works on your PC while you’re away.',
                    textAlign: TextAlign.center,
                    style: context.type.bodyMedium?.copyWith(color: c.muted),
                  ),
                ),
              if (needs.isNotEmpty) group('Needs you', needs, edge: const Color(0xFFFFC58A)),
              if (working.isNotEmpty) group('Working', working),
              if (todays.isNotEmpty) group('Today', todays),
              if (earlier.isNotEmpty) group('Earlier', earlier),
              if (all.isNotEmpty && !_searching)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Swipe left on a finished chat to delete it.',
                      textAlign: TextAlign.center, style: context.type.bodySmall?.copyWith(color: c.faint)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Composer(
            core: widget.core,
            state: widget.state,
            onSend: widget.onAsk,
            autofocus: false,
            allowOffline: true,
            hint: 'Ask Compii to do something…',
          ),
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
    final state = ChatState.of(task);
    final color = state.color(context);
    final when = lastMoved(task);
    final ask = task.pendingApproval?['label'] ?? task.pendingQuestion?['question'];
    final preview = (ask ?? task.finalText ?? (task.last?['text'] as String?) ?? '').toString();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [if (state != ChatState.done) BoxShadow(color: color.withValues(alpha: .6), blurRadius: 6)],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(chatTitle(task.request),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: context.type.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      if (when != null) ...[
                        const SizedBox(width: 8),
                        Text(shortWhen(when), style: context.type.bodySmall?.copyWith(color: c.faint)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: state.label, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
                      if (preview.isNotEmpty) TextSpan(text: ' · ${preview.replaceAll(RegExp(r'\s+'), ' ')}'),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodyMedium?.copyWith(color: c.muted, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
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
            backgroundColor: _night,
            appBar: AppBar(
              backgroundColor: _night,
              surfaceTintColor: Colors.transparent,
              title: Text(task == null ? 'Conversation' : chatTitle(task.request), maxLines: 1, overflow: TextOverflow.ellipsis),
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
    required this.onSettings,
  });
  final CoreClient core;
  final Run run;
  final Future<void> Function(String text) onAsk;
  final Future<void> Function() onForget;
  final Future<void> Function(String url) onOpenLink;
  final Future<void> Function(String text) onCopyToPc;
  final Future<void> Function(PhotoAsk ask) onPhoto;
  final VoidCallback onSettings;

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
    final via = !online ? 'Not connected' : core.viaAnywhere ? 'Connected from anywhere' : 'On your Wi-Fi';
    final anywhere = link.hosts.any(isOverlayAddress);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 0, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(link.pc, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: context.type.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: (online ? const Color(0xFF7EE2AE) : c.faint).withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Glyph(G.dot, size: 8, color: online ? const Color(0xFF7EE2AE) : c.faint),
                          const SizedBox(width: 6),
                          Text(via, style: context.type.labelMedium?.copyWith(color: online ? const Color(0xFF7EE2AE) : c.faint)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(tooltip: 'Settings', onPressed: widget.onSettings, icon: const Glyph(G.sliders)),
            ],
          ),
        ),
        _ScreenCard(
          shot: _shot,
          error: _shotError,
          at: _shotAt,
          loading: _loading,
          live: _live,
          onPeek: _peek,
          onLive: _setLive,
        ),
        const GroupLabel('Show Compii'),
        HaloGroup(children: [
          HaloRow(glyph: G.camera, title: 'What is this?', subtitle: 'Take a photo and ask about it',
              onTap: () => widget.onPhoto(PhotoAsk.what)),
          HaloRow(glyph: G.file, title: 'Snap a document', subtitle: 'Summary, deadlines, and the text saved on the PC',
              onTap: () => widget.onPhoto(PhotoAsk.document)),
        ]),
        const GroupLabel('On the PC'),
        HaloGroup(children: [
          HaloRow(glyph: G.eye, title: 'What’s on screen?', onTap: () => widget.onAsk(
              'Look at my PC screen and tell me briefly what’s on it and anything that needs my attention.')),
          HaloRow(glyph: G.search, title: 'Find a file', onTap: _find),
          HaloRow(glyph: G.globe, title: 'Open a link', subtitle: 'In its browser, ready when you sit down', onTap: _sendLink),
          HaloRow(glyph: G.clipboard, title: 'Copy to the PC', subtitle: 'Then paste it there with Ctrl+V', onTap: _sendText),
          HaloRow(glyph: G.sun, title: 'Brief me now', onTap: () => widget.run(core.briefNow)),
        ]),
        const SizedBox(height: 12),
        HaloGroup(children: [
          HaloRow(
            glyph: G.stop,
            title: 'Stop everything',
            subtitle: 'Every conversation that’s working, right now',
            danger: true,
            onTap: () async {
              await widget.run(core.stopAll);
              _done('Compii stopped everything on ${link.pc}.');
            },
          ),
        ]),
        if (!anywhere) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(18), border: Border.all(color: c.border)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Glyph(G.cloud, color: c.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Want Compii when you’re out? Install the free Tailscale app on this phone and the PC and sign in to both '
                    'with the same account. Compii finds the new address by itself.',
                    style: context.type.bodySmall?.copyWith(color: c.muted, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
        ],
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
      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(18), border: Border.all(color: c.border)),
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
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(error ?? 'See what’s on your PC’s screen right now.',
                                      textAlign: TextAlign.center, style: context.type.bodySmall?.copyWith(color: c.muted)),
                                  const SizedBox(height: 12),
                                  FilledButton.icon(
                                    onPressed: onPeek,
                                    icon: const Glyph(G.eye, size: 18),
                                    label: const Text('Look'),
                                  ),
                                ],
                              ),
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

// ---- Banners ----------------------------------------------------------------------------------

class _ApprovalBanner extends StatelessWidget {
  const _ApprovalBanner({required this.tasks, required this.onOpen});
  final List<TaskView> tasks;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final first = tasks.first.pendingApproval;
    final asked = tasks.first.pendingQuestion;
    final headline = first != null
        ? (tasks.length == 1
            ? 'Compii needs your OK: ${first['label'] ?? first['tool'] ?? 'an action'}'
            : '${tasks.length} things need your OK')
        : 'Compii is asking: ${asked?['question'] ?? 'a question'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
      color: const Color(0xFF16120C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0x73FFC58A)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
          child: Row(
            children: [
              Glyph(asked != null && first == null ? G.chat : G.hand, color: const Color(0xFFFFC58A)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text('Review', style: context.type.labelLarge?.copyWith(color: const Color(0xFFFFC58A))),
            ],
          ),
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

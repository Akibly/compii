import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/console_screen.dart';
import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'phone_voice.dart';
import 'shell.dart';
import 'thread.dart';
import 'tokens.dart';

const _night = Color(0xFF1B1550);

/// The phone, paired with a PC: talk to Compii, follow and answer its
/// conversations, approve what it asks, and glance at or act on the PC.
class PhoneHome extends StatefulWidget {
  const PhoneHome({super.key, required this.core, required this.state, required this.voice, required this.onForget});
  final CoreClient core;
  final AppState state;
  final PhoneVoice voice;
  final Future<void> Function() onForget;

  @override
  State<PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<PhoneHome> {
  int _tab = 0;

  CoreClient get core => widget.core;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      widget.state.fail(null);
    } catch (e) {
      widget.state.fail(e);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
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
    if (ok == true) await widget.onForget();
  }

  /// Ask Compii from the phone; opens the conversation so the answer is right there.
  Future<void> ask(String text) => _run(() async {
        final id = await core.startConversation(text);
        if (!mounted) return;
        setState(() => _tab = 1);
        _openChat(id);
      });

  void _openChat(String id) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ChatPage(core: core, state: widget.state, taskId: id, run: _run),
    ));
  }

  List<TaskView> get _waiting => [
        for (final t in core.ordered) if (t.pendingApproval != null || t.pendingQuestion != null) t
      ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([core, widget.state, widget.voice]),
        builder: (context, _) {
          final waiting = _waiting;
          final pages = [
            _TalkTab(core: core, state: widget.state, voice: widget.voice, menu: _menu()),
            _ChatsTab(core: core, state: widget.state, onOpen: _openChat, onAsk: ask),
            _PcTab(core: core, run: _run, onAsk: ask, onForget: _confirmForget),
          ];
          return Scaffold(
            backgroundColor: _tab == 0 ? _night : context.c.canvas,
            body: Column(
              children: [
                if (core.unauthorized) _RemovedBanner(pc: core.remote!.pc, onPair: widget.onForget),
                if (waiting.isNotEmpty) _ApprovalBanner(tasks: waiting, core: core, run: _run),
                if (!core.unauthorized && core.status != CoreStatus.online) _OfflineBar(core: core),
                Expanded(child: IndexedStack(index: _tab, children: pages)),
              ],
            ),
            bottomNavigationBar: NavigationBar(
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
          );
        },
      );

  Widget _menu() => PopupMenuButton<String>(
        tooltip: 'More',
        icon: const Glyph(G.sliders, color: Colors.white),
        onSelected: (v) => switch (v) {
          'voice' || 'sound' || 'caption' || 'off' => widget.voice.setMode(v),
          'forget' => _confirmForget(),
          _ => null,
        },
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, child: Text('Connected to ${core.remote!.pc}')),
          for (final (mode, label) in const [('voice', 'Speak replies'), ('sound', 'A chime, with the words'), ('caption', 'Words on screen only'), ('off', 'Stay quiet')])
            CheckedPopupMenuItem(value: mode, checked: widget.voice.outputMode == mode, child: Text(label)),
          const PopupMenuItem(value: 'forget', child: Text('Forget this PC')),
        ],
      );
}

// ---- Talk -------------------------------------------------------------------------------------

class _TalkTab extends StatelessWidget {
  const _TalkTab({required this.core, required this.state, required this.voice, required this.menu});
  final CoreClient core;
  final AppState state;
  final PhoneVoice voice;
  final Widget menu;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: _night,
        child: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              FaceStage(core: core, state: state, onExit: null, menu: menu),
              if (voice.listening || voice.busy || voice.partial.isNotEmpty)
                Positioned(left: 24, right: 24, bottom: 84, child: _Heard(text: voice.partial, busy: voice.busy)),
              if (voice.error != null || state.error != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 84,
                  child: Material(
                    color: const Color(0xFFFFE9E6),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('${voice.error ?? state.error}', style: const TextStyle(color: Color(0xFF7A1E14))),
                          ),
                          IconButton(
                            tooltip: 'Dismiss',
                            onPressed: () {
                              voice.error = null;
                              state.fail(null);
                              voice.refresh();
                            },
                            icon: const Glyph(G.close, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
        decoration: BoxDecoration(color: const Color(0xCC140F3D), borderRadius: BorderRadius.circular(16)),
        child: Text(
          text.isEmpty ? (busy ? 'Sending…' : 'Listening…') : text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
        ),
      );
}

// ---- Chats ------------------------------------------------------------------------------------

class _ChatsTab extends StatelessWidget {
  const _ChatsTab({required this.core, required this.state, required this.onOpen, required this.onAsk});
  final CoreClient core;
  final AppState state;
  final void Function(String id) onOpen;
  final Future<void> Function(String text) onAsk;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final list = core.ordered;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(children: [Expanded(child: Text('Conversations', style: context.type.headlineSmall))]),
          ),
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
            child: Composer(core: core, state: state, onSend: onAsk, autofocus: false, hint: 'Ask Compii to do something on your PC…'),
          ),
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
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
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
  const _ChatPage({required this.core, required this.state, required this.taskId, required this.run});
  final CoreClient core;
  final AppState state;
  final String taskId;
  final Run run;

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
                            busyTask: task,
                            run: run,
                            hint: 'Reply…',
                            onSend: (text) => run(() => core.reply(taskId, text)),
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
  const _PcTab({required this.core, required this.run, required this.onAsk, required this.onForget});
  final CoreClient core;
  final Run run;
  final Future<void> Function(String text) onAsk;
  final Future<void> Function() onForget;

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
    await widget.run(() => core.openUrl(url.startsWith('http') ? url : 'https://$url'));
    _done('Opened on ${core.remote!.pc}.');
  }

  Future<void> _sendText() async {
    final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final text = await _prompt('Copy to the PC', 'Text to paste on the PC', seed: copied, action: 'Copy');
    if (text == null || text.isEmpty) return;
    await widget.run(() => core.pushClipboard(text));
    _done('On the PC’s clipboard. Press Ctrl+V there to paste.');
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
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text(link.pc, style: context.type.headlineSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: online ? c.success : c.faint),
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
              decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(16)),
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
          TextButton(onPressed: widget.onForget, child: Text('Forget ${link.pc}', style: TextStyle(color: c.danger))),
        ],
      ),
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
                  ? GestureDetector(
                      onTap: () => _fullScreen(context, shot!),
                      child: Image.memory(shot!, fit: BoxFit.contain, gaplessPlayback: true),
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
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
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
  const _ApprovalBanner({required this.tasks, required this.core, required this.run});
  final List<TaskView> tasks;
  final CoreClient core;
  final Run run;

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
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (context) => ListenableBuilder(
              listenable: core,
              builder: (context, _) {
                final cards = <Widget>[
                  for (final t in core.ordered)
                    if (t.pendingApproval case final a?)
                      Padding(padding: const EdgeInsets.only(bottom: 12), child: ApprovalCard(approval: a, core: core, run: run, compact: true)),
                  for (final t in core.ordered)
                    if (t.pendingQuestion case final q?)
                      Padding(padding: const EdgeInsets.only(bottom: 12), child: QuestionCard(question: q, core: core, run: run, compact: true)),
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
          ),
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
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar({required this.core});
  final CoreClient core;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.surface,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Looking for ${core.remote!.pc} at ${core.host}…',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodySmall?.copyWith(color: c.muted)),
              ),
            ],
          ),
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
  Widget build(BuildContext context) => Material(
        color: const Color(0xFFFFE9E6),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Expanded(child: Text('This phone was removed on $pc.', style: const TextStyle(color: Color(0xFF7A1E14)))),
                TextButton(onPressed: onPair, child: const Text('Pair again')),
              ],
            ),
          ),
        ),
      );
}

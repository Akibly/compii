import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../console/core_client.dart';
import '../ui/voice.dart';
import 'island_actions.dart';
import 'island_platform.dart';
import 'island_prefs.dart';

/// The island's view of a conversation, derived from what Core actually
/// reports. Nothing here is guessed: a working card only exists while the
/// task is running, an approval card only while one is unanswered, and a
/// finished card only after Core said how it finished.
enum IslandStage { compact, listening, ask, conversation, working, approval, completed, failed }

/// The one small coloured mark on the compact capsule.
enum IslandSignal { none, listening, working, needsYou, done, failed, offline, news }

/// The one state the island is in. Anything the card shows is decided from this
/// plus [_card], so two of them can never claim the surface at once: a composer
/// cannot sit over an approval it hides, a working card cannot outlive the
/// thread it belongs to, and the mic is only "listening" when the thing on
/// screen is the listening pill.
enum IslandPhase {
  /// Nothing of ours is happening.
  idle,

  /// The capsule is hearing you: the mic is on and no card is up.
  listening,

  /// The composer is open.
  ask,

  /// You sent something and Core has not shown work for it yet.
  starting,

  /// A thread is running.
  working,

  /// A thread is waiting for your okay.
  approval,

  /// A thread is waiting for an answer.
  question,

  /// A thread is waiting for your own hands on the mouse.
  takeover,

  /// A thread finished and its answer is being shown.
  result,

  /// A thread didn't finish, or the island's own step failed.
  failure,

  /// Core cannot be reached.
  offline;

  /// The waiting states: Compii is stuck until the user does something.
  bool get needsUser => this == approval || this == question || this == takeover;

  /// Whether this state can be drawn on the capsule as well as on a card.
  bool get fitsCapsule => this != IslandPhase.ask;
}

/// Something that happened while the user was not looking at it, and the one
/// thread it belongs to.
class IslandNews {
  const IslandNews(this.taskId, this.key, this.kind, this.title, this.body);
  final String taskId;

  /// The event's own id, so the same ask is only announced once and a second
  /// ask on the same thread is announced again.
  final String key;
  final String kind;
  final String title;
  final String body;
}

class IslandSuggestion {
  const IslandSuggestion(this.label, this.prompt, {this.screen = false});
  final String label;
  final String prompt;

  /// This one needs the screen picture, so choosing it turns that on visibly.
  final bool screen;
}

class IslandController extends ChangeNotifier {
  IslandController({
    required this.core,
    required this.actions,
    required this.platform,
    this.voice,
    this.prefs,
  }) {
    core.addListener(_onCore);
    voice?.addListener(_onVoice);
    if (voice != null) voice!.onHeard = _heard;
    // A message waits until the composer is clear, so every edit to it is a
    // chance to send what is waiting.
    draft.addListener(_release);
    // Conversations are only half of what Compii does while you are elsewhere:
    // routines, watches, the daily brief and the journal day land in the inbox,
    // and on this desktop nothing said so until now.
    _newsSub = core.updates.stream.listen(_onInbox);
  }

  final CoreClient core;
  final IslandActions actions;
  final IslandPlatform platform;
  final VoiceController? voice;

  /// Where the message waiting to send is kept, so the pill restarting does not
  /// throw it away. Null in previews and tests that have no storage.
  final IslandPrefs? prefs;

  /// The ask composer's text. Kept here, not in the widget, so collapsing or
  /// losing focus never costs the user what they were writing.
  final TextEditingController draft = TextEditingController();

  final List<Map<String, dynamic>> attachments = [];

  IslandPhase _phase = IslandPhase.idle;

  /// The card is on screen. Only the user's own action, or a background event
  /// the attention policy says is worth a card, turns this on.
  bool _card = false;

  IslandAttention _attention = IslandAttention.defaultPolicy;

  /// A full-screen app owns the monitor: no card opens over it, no toast pops.
  bool _presenting = false;

  /// The last thing announced, so one ask is only ever raised once.
  String _announced = '';

  /// How each thread last looked, so finishing is news and staying finished isn't.
  final Map<String, String> _seenStatus = {};

  /// What Compii left in the inbox since the user last looked. News that has a
  /// conversation of its own never comes in here: the pill already shows that
  /// thread, and telling you twice about one routine is not telling you more.
  final List<IslandNews> _news = [];
  StreamSubscription<Map<String, dynamic>>? _newsSub;

  String? _taskId;
  String? _botId;
  String _pendingAsk = '';
  int _awaitingFrom = 0;
  bool _screenContext = false;
  bool _screenBusy = false;
  bool _sending = false;
  bool _stopping = false;
  DateTime? _attachedAt;

  String? _error;
  bool _canRetry = false;

  /// Which send the failure is about, so "try again" repeats that one and not
  /// whatever the card happens to be showing now.
  bool _lastSendWasAsk = false;

  /// The one message waiting for the running turn to end.
  _Queued? _queued;
  String _foregroundTitle = '';
  int _lastForeign = 0;
  bool _tookFocus = false;
  bool _voiceOwned = false;
  bool _disposed = false;

  bool get isOpen => _card;
  bool get asking => _phase == IslandPhase.ask;
  bool get sending => _sending;
  bool get stopping => _stopping;
  bool get screenBusy => _screenBusy;
  bool get screenContext => _screenContext;
  bool get offline => core.status == CoreStatus.offline;
  String? get error => _error;
  bool get canRetry => _canRetry;
  String? get queuedText => _queued?.text;

  /// How many things Compii left for you that you have not looked at yet.
  int get newsCount => _news.length;

  /// The newest thing waiting in the inbox, for the one line the pill can show.
  IslandNews? get latestNews => _news.isEmpty ? null : _news.last;
  String? get taskId => _taskId;
  String? get selectedBotId => _botId;
  String get foregroundTitle => _foregroundTitle;
  IslandPhase get phase => _phase;
  bool get presenting => _presenting;
  IslandAttention get attention => _attention;

  /// The user's own choice of how loudly to be told. Set from storage at start,
  /// and from the capsule menu afterwards.
  void setAttention(IslandAttention policy) {
    if (_attention == policy) return;
    _attention = policy;
    notifyListeners();
  }

  /// A thread the island is not showing that is waiting on the user. The ask
  /// card must not hide this: Compii is stuck until they answer it.
  TaskView? get backgroundAttention {
    final a = attentionTask;
    if (a == null) return null;
    if (_card && _taskId == a.id) return null;
    return a;
  }

  TaskView? get task {
    final id = _taskId;
    return id == null ? null : core.tasks[id];
  }

  /// An ask was accepted but Core has not announced the thread yet. The card
  /// shows this instead of claiming the conversation is gone.
  bool get starting => _taskId != null && task == null;

  BotView? get agent {
    final id = _botId;
    if (id == null) return core.primaryBot;
    return core.botFor(id);
  }

  /// Who is answering in the card the island is showing: the thread's own
  /// teammate once it exists, otherwise the one the next ask is going to.
  BotView? get speaker {
    final t = task;
    if (t == null || t.botId == null) return agent;
    return core.botFor(t.botId);
  }

  List<BotView> get agents => [
        for (final b in core.bots)
          if (!b.archived) b,
      ];

  /// True while the user is listening through the island's own mic.
  bool get listeningHere => voice?.listening == true;

  /// The text Core is listening to right now, if any.
  String get partial => voice?.partial ?? '';

  /// An active thread (any thread, including one the island did not open)
  /// waiting for an approval, an answer, or the user's own hands.
  TaskView? get attentionTask {
    final own = task;
    if (own != null && _needsUser(own)) return own;
    for (final t in core.ordered) {
      if (_needsUser(t)) return t;
    }
    return null;
  }

  bool get needsYou => attentionTask != null;

  bool get anyWorking => core.ordered.any((t) => t.active);

  int get workingCount => core.ordered.where((t) => t.active).length;

  IslandSignal get signal {
    if (needsYou) return IslandSignal.needsYou;
    if (voice?.listening == true) return IslandSignal.listening;
    if (anyWorking) return IslandSignal.working;
    final t = task;
    if (t != null) {
      if (t.status == 'failed') return IslandSignal.failed;
      if (t.status == 'done' && !t.active) return IslandSignal.done;
    }
    // A step of ours that failed while the card is away is still a step that
    // failed: the pill says so instead of looking idle.
    if (_error != null && !_card) return IslandSignal.failed;
    if (core.status == CoreStatus.offline) return IslandSignal.offline;
    // Something is waiting in the inbox that this pill has not shown you.
    if (_news.isNotEmpty) return IslandSignal.news;
    return IslandSignal.none;
  }

  String get capsuleLabel {
    final a = attentionTask;
    if (a != null) {
      if (a.pendingApproval != null) return 'Needs your okay';
      if (a.pendingQuestion != null) return 'Has a question';
      if (pendingTakeover(a) != null) return 'Your turn';
      return 'Needs you';
    }
    return switch (signal) {
      IslandSignal.needsYou => 'Needs you',
      IslandSignal.listening => 'Listening',
      IslandSignal.working => workingCount > 1 ? 'Working · $workingCount' : 'Working',
      IslandSignal.done => 'Done',
      IslandSignal.failed => 'Didn’t finish',
      IslandSignal.offline => 'Offline',
      IslandSignal.news => _news.length > 1 ? 'New from Compii · ${_news.length}' : 'New from Compii',
      IslandSignal.none => '',
    };
  }

  /// Which card the phase is drawn as. The capsule is never a card in disguise:
  /// a collapsed island is `compact`, or `listening` while it hears you.
  IslandStage get stage {
    if (!_card) {
      return _phase == IslandPhase.listening ? IslandStage.listening : IslandStage.compact;
    }
    return switch (_phase) {
      IslandPhase.ask || IslandPhase.listening => IslandStage.ask,
      IslandPhase.starting || IslandPhase.working => IslandStage.working,
      IslandPhase.approval => IslandStage.approval,
      IslandPhase.result => IslandStage.completed,
      IslandPhase.failure => IslandStage.failed,
      IslandPhase.idle ||
      IslandPhase.question ||
      IslandPhase.takeover ||
      IslandPhase.offline =>
        IslandStage.conversation,
    };
  }

  DateTime? get startedAt {
    final t = task;
    if (t != null) {
      for (final e in t.events) {
        final at = (e['at'] as num?)?.toDouble();
        if (at != null && at > 0) {
          return DateTime.fromMillisecondsSinceEpoch((at * 1000).round());
        }
      }
    }
    return _attachedAt;
  }

  int get attachmentCount => attachments.length + (_screenContext ? 1 : 0);

  // ---- the state machine ----

  /// The phases that are about a thread, so they cannot be entered without one.
  /// `starting` is not on the list: an ask is in flight before Core names it.
  static const _threadPhases = {
    IslandPhase.working,
    IslandPhase.approval,
    IslandPhase.question,
    IslandPhase.takeover,
    IslandPhase.result,
    IslandPhase.failure,
  };

  /// The only place the state moves. The asserts are the point: a composer is
  /// always a card, the listening pill is never one, and a thread state always
  /// has the thread it is about. Nothing else is allowed to set them.
  void _goto(IslandPhase next, {required bool card}) {
    assert(!card || next != IslandPhase.listening, 'the listening pill is the capsule');
    assert(next != IslandPhase.ask || card, 'a composer with no card is nothing to type into');
    assert(!_threadPhases.contains(next) || _taskId != null, '$next needs a thread to be about');
    if (_phase == next && _card == card) return;
    _phase = next;
    _card = card;
    notifyListeners();
  }

  /// What the thread the island is following is doing, read off Core's own
  /// events. Never guessed: a finished card only appears once Core said how it
  /// finished.
  IslandPhase _threadPhase(TaskView t) {
    if (t.pendingApproval != null) return IslandPhase.approval;
    if (t.pendingQuestion != null) return IslandPhase.question;
    if (pendingTakeover(t) != null) return IslandPhase.takeover;
    if (t.active) return IslandPhase.working;
    if (t.status == 'failed') return IslandPhase.failure;
    if (t.status == 'done') return IslandPhase.result;
    return IslandPhase.idle;
  }

  /// Core has the user's send but has shown nothing for it yet.
  bool get _isStarting {
    if (_phase != IslandPhase.starting) return false;
    if (_sending || _pendingAsk.isNotEmpty) return true;
    final t = task;
    return t != null && !t.active && t.events.length <= _awaitingFrom;
  }

  /// Re-derive the state from the facts: the thread being followed, Core's
  /// reach, the mic. Anything that is not a fact is payload — an error band or
  /// the words in the composer — and payload never pretends to be a state.
  void _syncPhase() {
    if (_card && _phase == IslandPhase.ask) return;
    if (_isStarting) return;
    final t = task;
    if (t != null) {
      _goto(_threadPhase(t), card: _card);
      return;
    }
    if (core.status == CoreStatus.offline) {
      _goto(IslandPhase.offline, card: _card);
      return;
    }
    if (voice?.listening == true && !_card) {
      _goto(IslandPhase.listening, card: false);
      return;
    }
    _goto(IslandPhase.idle, card: _card);
  }

  // ---- opening and closing ----

  Future<void> toggle() => _card ? collapse() : openAsk();

  /// The hotkey and a tap on an idle capsule open a fresh, fast ask.
  Future<void> openAsk({bool stealFocus = true}) async {
    _taskId = null;
    _pendingAsk = '';
    _error = null;
    _canRetry = false;
    _attachedAt = null;
    _goto(IslandPhase.ask, card: true);
    if (stealFocus) await _takeFocus();
  }

  /// Open a thread and keep following it. Used by the badge, history, and
  /// approvals that arrived while the island was compact.
  Future<void> openTask(String id, {bool stealFocus = true}) async {
    final t = core.tasks[id];
    if (t == null) return;
    _taskId = id;
    _pendingAsk = '';
    _error = null;
    _canRetry = false;
    _attachedAt = DateTime.now();
    _seenStatus[id] = t.status;
    _goto(_threadPhase(t), card: true);
    if (stealFocus) await _takeFocus();
  }

  /// A tap on the capsule: resume what this island was doing, otherwise open ask.
  Future<void> tapCapsule() async {
    if (_card) return;
    final id = _taskId;
    final t = task;
    if (id != null &&
        t != null &&
        (t.active ||
            t.pendingApproval != null ||
            t.status == 'done' ||
            t.status == 'failed')) {
      await openTask(id);
      return;
    }
    final attention = attentionTask;
    if (attention != null) {
      await openTask(attention.id);
      return;
    }
    // Nothing is waiting on you, but Compii left something: a tap goes to that
    // rather than opening an empty composer you did not ask for.
    if (_news.isNotEmpty) {
      await openNews();
      return;
    }
    await openAsk();
  }

  Future<void> collapse({bool restoreFocus = true}) async {
    if (!_card) return;
    if (_voiceOwned && voice?.listening == true) unawaited(voice!.cancel());
    _voiceOwned = false;
    _error = null;
    _canRetry = false;
    _pendingAsk = '';
    _card = false;
    _syncPhase();
    notifyListeners();
    await platform.clickThrough(true);
    if (restoreFocus && _tookFocus && _lastForeign != 0) {
      await platform.restore(_lastForeign);
    }
    _lastForeign = 0;
    _tookFocus = false;
  }

  /// Put away a finished conversation. Its history stays in Core.
  Future<void> dismissFinished() async {
    _taskId = null;
    _attachedAt = null;
    await collapse();
  }

  Future<void> _takeFocus() async {
    if (_lastForeign == 0) {
      final fg = await platform.foreground();
      if (fg.found) {
        _lastForeign = fg.handle;
        _foregroundTitle = fg.title;
      }
    }
    _tookFocus = true;
    await platform.clickThrough(false);
    await platform.focus();
  }

  /// Called by the window host while the capsule is idle, so closing the
  /// island can give focus back to the app the user came from, and so the
  /// island knows when an app has taken the whole screen.
  Future<void> rememberForeground() async {
    if (_card || _disposed) return;
    final fg = await platform.foreground();
    if (!fg.found) return;
    _lastForeign = fg.handle;
    var changed = false;
    if (fg.title != _foregroundTitle) {
      _foregroundTitle = fg.title;
      changed = true;
    }
    if (fg.fullscreen != _presenting) {
      _presenting = fg.fullscreen;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // ---- ask composer ----

  void setBot(String? id) {
    _botId = id;
    notifyListeners();
  }

  void toggleScreenContext() {
    _screenContext = !_screenContext;
    notifyListeners();
  }

  void removeAttachment(int index) {
    if (index < 0 || index >= attachments.length) return;
    attachments.removeAt(index);
    notifyListeners();
  }

  Future<void> addFiles() async {
    if (_sending) return;
    try {
      final picked = await actions.pickFiles();
      if (picked.isEmpty) return;
      attachments.addAll(picked);
      _error = null;
      _canRetry = false;
      notifyListeners();
    } catch (e) {
      _fail(e);
    }
  }

  void chooseSuggestion(IslandSuggestion suggestion) {
    draft.text = suggestion.prompt;
    draft.selection = TextSelection.collapsed(offset: draft.text.length);
    if (suggestion.screen) _screenContext = true;
    _error = null;
    _canRetry = false;
    notifyListeners();
  }

  List<IslandSuggestion> get suggestions {
    final title = _foregroundTitle.toLowerCase();
    bool has(List<String> words) => words.any(title.contains);
    final out = <IslandSuggestion>[];
    if (title.isNotEmpty) {
      if (has(const ['chrome', 'edge', 'firefox', 'opera', 'brave', 'arc', 'safari'])) {
        out.addAll(const [
          IslandSuggestion('Summarize this page',
              'Summarize the page on my screen. Give me the key points and anything I need to act on.',
              screen: true),
          IslandSuggestion('Explain what I’m looking at',
              'Look at my screen and explain what I’m looking at in plain language.', screen: true),
        ]);
      } else if (has(const ['visual studio', 'cursor', 'android studio', 'intellij', 'sublime', 'code'])) {
        out.addAll(const [
          IslandSuggestion('Explain this code', 'Look at the code on my screen and explain what it does.', screen: true),
          IslandSuggestion('Find the problem', 'Look at my screen and find the bug or error I’m dealing with.', screen: true),
        ]);
      } else if (has(const ['excel', 'sheets', 'numbers', 'calc'])) {
        out.addAll(const [
          IslandSuggestion('Explain this sheet', 'Look at the spreadsheet on my screen and explain what it shows.', screen: true),
          IslandSuggestion('Find the takeaway', 'Look at this spreadsheet and tell me the most important takeaway.', screen: true),
        ]);
      } else if (has(const ['outlook', 'mail', 'gmail', 'superhuman', 'thunderbird'])) {
        out.addAll(const [
          IslandSuggestion('Draft a reply', 'Look at the email on my screen and draft a reply in my voice.', screen: true),
          IslandSuggestion('Summarize this email', 'Summarize the email on my screen and what it needs from me.', screen: true),
        ]);
      }
    }
    out.addAll(const [
      IslandSuggestion('Catch me up', 'Catch me up on what you’ve done recently and anything that needs me.'),
      IslandSuggestion('Plan my day', 'Help me plan the rest of today around what I’m working on.'),
      IslandSuggestion('Summarize my screen', 'Look at my screen and summarize what’s open and what matters.', screen: true),
    ]);
    return out.take(3).toList();
  }

  // ---- sending ----

  Future<void> send() => _dispatch(ask: true);

  /// A follow-up for a thread that is still working waits its turn instead of
  /// being refused; anything else is sent now.
  Future<void> reply() async {
    final t = task;
    if (t != null && t.active && !_sending) {
      queueReply();
      return;
    }
    await _dispatch(ask: false);
  }

  Future<void> _dispatch({required bool ask}) async {
    if (_sending) return;
    final text = draft.text.trim();
    if (text.isEmpty && attachments.isEmpty && !_screenContext) return;
    if (core.status == CoreStatus.offline) {
      // Their own words, their own card: the composer is where this failure
      // belongs, and it is already open in front of them.
      _fail(CoreError('Compii Core isn’t reachable right now. It reconnects by itself, then try again.'),
          retry: true);
      return;
    }

    final wasCard = _card;
    _lastSendWasAsk = ask;
    _sending = true;
    _error = null;
    _canRetry = false;
    _screenBusy = _screenContext;
    _goto(IslandPhase.starting, card: _card);
    notifyListeners();

    try {
      final files = [for (final a in attachments) '${a['path']}'];
      if (_screenContext) {
        final shot = await actions.attachScreen();
        if (shot == null || '${shot['path']}'.isEmpty) {
          throw CoreError('Compii couldn’t take a picture of the screen. Nothing was sent.');
        }
        files.add('${shot['path']}');
      }
      final sent = text.isEmpty ? 'Take a look at what I attached.' : text;
      if (ask) {
        final id = await actions.start(sent, botId: _botId, attachments: files);
        _taskId = id;
        _pendingAsk = sent;
        _attachedAt = DateTime.now();
        _awaitingFrom = core.tasks[id]?.events.length ?? 0;
        _seenStatus[id] = core.tasks[id]?.status ?? 'running';
        draft.clear();
        attachments.clear();
        _screenContext = false;
        // Collapsed while Core was starting: stay collapsed; the capsule shows work.
      } else {
        final t = task;
        if (t == null) throw CoreError('That conversation isn’t here any more.');
        _awaitingFrom = t.events.length;
        await actions.reply(t.id, sent, attachments: files);
        draft.clear();
        attachments.clear();
      }
      _sending = false;
      _screenBusy = false;
      _error = null;
      _syncPhase();
      notifyListeners();
    } catch (e) {
      _sending = false;
      _screenBusy = false;
      _undoSend(ask: ask, wasCard: wasCard);
      _fail(e, retry: true);
    }
  }

  /// A send that never happened puts the state back where it was, with the
  /// words still in the composer. The user's own failure is shown on the card
  /// they sent from; if the card is away, only the policy they chose brings it
  /// back - a collapsed capsule that says "Didn't finish" is not hiding work.
  void _undoSend({required bool ask, required bool wasCard}) {
    if (wasCard) {
      if (ask) {
        _goto(IslandPhase.ask, card: true);
      } else {
        _syncPhase();
      }
      return;
    }
    if (_attention == IslandAttention.expanded && !_presenting) {
      unawaited(openAsk());
      return;
    }
    _syncPhase();
  }

  // ---- saying more while Compii works ----

  /// Keep what the user typed until the running turn ends. The words go neither
  /// into the middle of a step nor into the bin: they wait in plain sight, with
  /// a way to take them back.
  void queueReply() {
    final text = draft.text.trim();
    if (text.isEmpty && attachments.isEmpty && !_screenContext) return;
    if (_queued != null) {
      _fail(CoreError(
        'One message is already waiting to send. Take it back, or wait for it to go.',
      ));
      return;
    }
    _setQueued(_Queued(text, List.of(attachments), _screenContext));
    draft.clear();
    attachments.clear();
    _screenContext = false;
    _error = null;
    _canRetry = false;
    notifyListeners();
  }

  /// Cancelling a waiting message puts the words back in the composer.
  void cancelQueued() {
    final held = _queued;
    if (held == null) return;
    _setQueued(null);
    _putBack(held);
    notifyListeners();
  }

  /// The message waiting to go and its copy on disk are one thing, set here, so
  /// a restart can neither lose a message nor send one the user already took back.
  void _setQueued(_Queued? next) {
    _queued = next;
    final p = prefs;
    if (p == null) return;
    unawaited(
      p.saveHeld(
        next == null ? null : HeldReply(text: next.text, files: next.files, screen: next.screen),
      ),
    );
  }

  /// The pill came back, so a message the user had asked to send later goes
  /// where they left it: in the composer, to send themselves. Nothing restarts
  /// by pressing send for you — the turn it was waiting on may have stopped,
  /// finished, or done half of something you would not want repeated.
  Future<void> restoreHeld() async {
    final p = prefs;
    if (p == null) return;
    final held = await p.held();
    if (held == null || _disposed) return;
    // Words typed since the pill came back are the user's, and one field cannot
    // hold two messages: leave ours saved rather than throwing either away.
    if (draft.text.trim().isNotEmpty || attachments.isNotEmpty || _screenContext) return;
    await p.saveHeld(null);
    _putBack(_Queued(held.text, held.files, held.screen));
    notifyListeners();
  }

  void _putBack(_Queued held) {
    draft.value = TextEditingValue(
      text: held.text,
      selection: TextSelection.collapsed(offset: held.text.length),
    );
    attachments
      ..clear()
      ..addAll(held.files);
    _screenContext = held.screen;
  }

  /// The turn ended, so the waiting message becomes an ordinary reply. If that
  /// send fails, its words are back in the composer like any other failure.
  void _release() {
    final held = _queued;
    if (held == null || _sending) return;
    final t = task;
    if (t == null || t.active) return;
    // Held rather than sent: a reply to an unreachable Core would only fail and
    // lose the thread that was going to answer it.
    if (core.status == CoreStatus.offline) return;
    // The composer is one field, and what is in it right now is not ours to
    // overwrite. Anything half-typed is a reason to wait, and the next change
    // to the field tries again.
    if (draft.text.trim().isNotEmpty ||
        attachments.isNotEmpty ||
        _screenContext) {
      return;
    }
    _setQueued(null);
    _putBack(held);
    unawaited(_dispatch(ask: false));
  }

  Future<void> stop() async {
    final t = task;
    if (t == null || _stopping) return;
    _stopping = true;
    _error = null;
    _canRetry = false;
    notifyListeners();
    try {
      await actions.stop(t.id);
    } catch (e) {
      _fail(e);
    } finally {
      _stopping = false;
      notifyListeners();
    }
  }

  Future<void> retryTask() async {
    final t = task;
    if (t == null || _sending) return;
    _error = null;
    _canRetry = false;
    _awaitingFrom = t.events.length;
    _goto(IslandPhase.starting, card: _card);
    notifyListeners();
    try {
      await actions.retry(t.id);
    } catch (e) {
      _syncPhase();
      _fail(e);
    }
    notifyListeners();
  }

  Future<void> openInMain() async {
    final id = _taskId;
    if (id == null) return;
    _error = null;
    _canRetry = false;
    notifyListeners();
    try {
      await actions.openInMain(id);
      await collapse(restoreFocus: false);
    } catch (e) {
      _fail(e);
    }
  }

  void retry() {
    if (!_canRetry || _sending) return;
    _error = null;
    _canRetry = false;
    unawaited(_dispatch(ask: _lastSendWasAsk));
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    _canRetry = false;
    notifyListeners();
  }

  void reconnect() {
    if (core.status == CoreStatus.online) return;
    core.start();
    notifyListeners();
  }

  /// The cards Core's shared widgets need: run something and keep failures on
  /// the island instead of throwing into a button's tap handler.
  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
      if (_error != null) {
        _error = null;
        _canRetry = false;
      }
    } catch (e) {
      _fail(e);
    }
    notifyListeners();
  }

  // ---- voice ----

  Future<void> startListening() async {
    final v = voice;
    if (v == null) return;
    if (!_card) await openAsk();
    _voiceOwned = true;
    _error = null;
    _canRetry = false;
    notifyListeners();
    await v.start();
    if (v.error != null) _fail(CoreError(v.error!));
    notifyListeners();
  }

  Future<void> finishListening() async {
    final v = voice;
    if (v == null) return;
    await v.finish();
    if (v.error != null) _fail(CoreError(v.error!));
    notifyListeners();
  }

  Future<void> cancelListening() async {
    final v = voice;
    if (v == null) return;
    await v.cancel();
    _voiceOwned = false;
    notifyListeners();
  }

  Future<void> _heard(String text) async {
    _insertHeard(text);
  }

  void _insertHeard(String text) {
    final words = text.trim();
    if (words.isEmpty) return;
    final value = draft.value;
    final start = value.selection.isValid ? value.selection.start : value.text.length;
    final end = value.selection.isValid ? value.selection.end : value.text.length;
    final before = value.text.substring(0, start);
    final after = value.text.substring(end);
    final glue = before.isEmpty || RegExp(r'\s$').hasMatch(before) ? '' : ' ';
    final inserted = '$before$glue$words';
    draft.value = TextEditingValue(
      text: '$inserted$after',
      selection: TextSelection.collapsed(offset: inserted.length),
    );
    notifyListeners();
  }

  void _onVoice() {
    if (_voiceOwned && voice?.listening != true && voice?.busy != true) _voiceOwned = false;
    _syncPhase();
    notifyListeners();
  }

  // ---- Core events ----

  void _onCore() {
    final t = task;
    if (_pendingAsk.isNotEmpty && t != null && t.events.isNotEmpty) _pendingAsk = '';
    final id = _taskId;
    if (id != null && t == null && !core.tasks.containsKey(id) && _pendingAsk.isEmpty && !_sending) {
      // Deleted here or in another window: never show a conversation that is gone.
      _taskId = null;
      _attachedAt = null;
      _card = false;
      // Nobody is left to send the waiting message to, so it goes back to the
      // composer instead of vanishing with the thread.
      if (_queued case final held?) {
        _setQueued(null);
        _putBack(held);
      }
    }
    _announce(_collectNews());
    _release();
    _syncPhase();
    notifyListeners();
  }

  /// What happened since the last look that the user is not looking at: a
  /// thread waiting on them, or a thread that just ended. Progress is not
  /// news - Compii getting on with work is not a reason to interrupt.
  List<IslandNews> _collectNews() {
    final out = <IslandNews>[];
    final shown = _card ? _taskId : null;
    final a = attentionTask;
    if (a != null && a.id != shown) {
      final approval = a.pendingApproval;
      final question = approval == null ? a.pendingQuestion : null;
      final takeover = approval == null && question == null ? pendingTakeover(a) : null;
      final kind = approval != null ? 'approval' : question != null ? 'question' : 'takeover';
      final event = approval ?? question ?? takeover ?? const {};
      out.add(IslandNews(
        a.id,
        '$kind:${event['approval_id'] ?? event['question_id'] ?? event['takeover_id'] ?? ''}',
        kind,
        _newsTitle(kind, a),
        _newsBody(kind, event, a),
      ));
    }
    for (final t in core.ordered) {
      final was = _seenStatus[t.id];
      final over = !t.active && (t.status == 'done' || t.status == 'failed');
      _seenStatus[t.id] = t.status;
      if (was != null && was != t.status && over && t.id != shown) {
        out.add(IslandNews(
          t.id,
          'over:${t.status}',
          t.status,
          _newsTitle(t.status, t),
          _newsBody(t.status, t.last ?? const {}, t),
        ));
      }
    }
    _seenStatus.removeWhere((id, _) => !core.tasks.containsKey(id));
    return out;
  }

  /// The policy the user chose, applied to one piece of news. Two things never
  /// happen however loud they asked it to be: nothing opens over an app that
  /// owns the whole screen, and nothing takes the words out of the composer.
  void _announce(List<IslandNews> news) {
    if (news.isEmpty) return;
    final last = news.last;
    if (last.key == _announced) return;
    _announced = last.key;
    if (_attention == IslandAttention.silent || _presenting) return;
    if (_attention == IslandAttention.toast) {
      unawaited(platform.toast(last.title, last.body));
      return;
    }
    // The mark on the capsule is the whole message: the capsule already shows
    // it, so nothing is added to the screen and nothing is sent to the bell.
    if (_attention == IslandAttention.indicator) return;
    if (_isTyping) {
      unawaited(platform.toast(last.title, last.body));
      return;
    }
    // News with no conversation of its own — the daily brief, a folder watch, a
    // journal day — has no card to open, and the island will not push another
    // app's window over what you are working in. It tells you, and the pill keeps
    // the mark until you tap it.
    if (last.taskId.isEmpty) {
      unawaited(platform.toast(last.title, last.body));
      return;
    }
    unawaited(openTask(last.taskId, stealFocus: false));
  }

  /// Typing into the ask card is the one state no background event may leave.
  bool get _isTyping => asking && _card && draft.text.trim().isNotEmpty;

  // ---- what Compii left in the inbox ----

  /// A routine ran, a folder changed, the daily brief is written. None of it is a
  /// conversation you asked for, so none of it reached this pill until now.
  void _onInbox(Map<String, dynamic> e) {
    if (_disposed) return;
    final id = '${e['id'] ?? ''}';
    if (id.isEmpty) return;
    final taskId = '${e['task_id'] ?? ''}';
    // A routine or an AI watch runs as a thread, and that thread already tells you
    // when it finishes or needs your OK. Telling you twice would only make the
    // second one look like news the first one wasn't.
    if (core.hasThreadFor(e)) return;
    final item = IslandNews(
      taskId,
      'update:$id',
      '${e['kind'] ?? 'update'}',
      _oneLine('${e['title'] ?? 'From Compii'}'),
      _oneLine('${e['body'] ?? ''}'),
    );
    if (_news.any((n) => n.key == item.key)) return;
    _news.add(item);
    // Twelve is plenty for one mark: a pile nobody looked at should not keep the
    // pill counting up forever.
    while (_news.length > 12) {
      _news.removeAt(0);
    }
    _announce([item]);
    notifyListeners();
  }

  /// Look at what is waiting: the conversation it belongs to when there is one,
  /// otherwise the inbox in the full workspace. Either way the mark comes off,
  /// because you have now seen it.
  Future<void> openNews() async {
    if (_news.isEmpty) return;
    final last = _news.last;
    if (last.taskId.isNotEmpty && core.tasks.containsKey(last.taskId)) {
      _news.removeWhere((n) => n.key == last.key);
      await openTask(last.taskId);
      return;
    }
    _news.clear();
    notifyListeners();
    await actions.openInbox();
  }

  static String _oneLine(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 140 ? one : '${one.substring(0, 139)}…';
  }

  String _newsTitle(String kind, TaskView t) {
    final name = core.botFor(t.botId)?.name ?? 'Compii';
    return switch (kind) {
      'approval' => '$name needs your OK',
      'question' => '$name has a question',
      'takeover' => 'Your turn — $name',
      'failed' => '$name ran into a problem',
      _ => '$name finished',
    };
  }

  String _newsBody(String kind, Map<String, dynamic> event, TaskView t) {
    final text = switch (kind) {
      'approval' => '${event['label'] ?? ''}',
      'question' => '${event['text'] ?? event['question'] ?? ''}',
      'takeover' => '${event['what'] ?? event['reason'] ?? ''}',
      _ => _finalWords(t),
    };
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.isNotEmpty) return one.length <= 140 ? one : '${one.substring(0, 139)}…';
    return t.request.length <= 140 ? t.request : '${t.request.substring(0, 139)}…';
  }

  String _finalWords(TaskView t) {
    for (final e in t.events.reversed) {
      if (e['type'] == 'task_finished' || e['type'] == 'answer') {
        final text = '${e['text'] ?? ''}';
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  void _fail(Object e, {bool retry = false}) {
    _error = e is CoreError ? e.message : '$e';
    _canRetry = retry;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _newsSub?.cancel();
    core.removeListener(_onCore);
    voice?.removeListener(_onVoice);
    draft.removeListener(_release);
    draft.dispose();
    super.dispose();
  }
}

/// A running thread waiting on the user's own decision or hands.
bool _needsUser(TaskView task) =>
    task.active &&
    (task.pendingApproval != null || task.pendingQuestion != null || pendingTakeover(task) != null);

Map<String, dynamic>? pendingTakeover(TaskView task) {
  if (!task.active) return null;
  final done = task.events
      .where((e) => e['type'] == 'takeover_done')
      .map((e) => e['takeover_id'])
      .toSet();
  for (final e in task.events.reversed) {
    if (e['type'] == 'takeover' && !done.contains(e['takeover_id'])) return e;
  }
  return null;
}

/// What Core is doing right now, in the fewest honest words.
String islandPhase(TaskView? task) {
  if (task == null) return 'Working';
  final e = task.last;
  if (e == null) return 'Working';
  return switch (e['type']) {
    'task_started' => 'Thinking',
    'plan' => 'Planning',
    'action_started' => 'Using ${prettyTool('${e['tool'] ?? ''}')}',
    'action_done' => 'Checking the result',
    'answer_delta' => 'Writing',
    'screen_seen' => 'Looking at your screen',
    'context' => _contextLabel(e),
    'note' => 'Working',
    'approval_needed' => 'Waiting for your okay',
    'question' => 'Waiting for your answer',
    'takeover' => 'Waiting for you',
    'handoff' => 'Handing over',
    'delegation' => 'Working with a teammate',
    'delegation_done' => 'Reviewing the teammate’s work',
    _ => 'Working',
  };
}

/// The context bundle says where every piece came from, so the capsule can name what is
/// actually being read instead of claiming to look at the screen when it isn't.
String _contextLabel(Map<String, dynamic> e) {
  final items = e['items'];
  if (items is List && items.any((i) => i is Map && i['source'] == 'desktop')) {
    return 'Reading what you have open';
  }
  return 'Reading what it knows';
}

String prettyTool(String tool) {
  if (tool.isEmpty) return 'a tool';
  final words = tool.replaceAll('_', ' ').trim();
  return words.isEmpty ? 'a tool' : '${words[0].toUpperCase()}${words.substring(1)}';
}

String formatElapsed(Duration elapsed) {
  final total = math.max(0, elapsed.inSeconds);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// What the user typed while the thread was busy, kept whole - the words, the
/// files, and whether they wanted the screen read with it.
class _Queued {
  const _Queued(this.text, this.files, this.screen);
  final String text;
  final List<Map<String, dynamic>> files;
  final bool screen;
}

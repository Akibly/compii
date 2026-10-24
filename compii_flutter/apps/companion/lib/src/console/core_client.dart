import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Connection to Compii Core, the local service that does the work.
enum CoreStatus { connecting, offline, online }

/// One of Compii's named teammates: its own role, memory and threads.
class BotView {
  BotView({
    required this.id,
    required this.name,
    this.job = '',
    this.instructions = '',
    this.color = '#7C9CFF',
    this.avatar = '',
    this.pinned = false,
    this.primary = false,
    this.facts = const [],
    this.trust = 'probation',
    this.mode = 'team',
    this.tools = const [],
    this.stats = const {},
    this.working = const [],
    this.provider = '',
    this.model = '',
    this.answersWith = '',
    this.modelNote = '',
    this.template = '',
    this.category = '',
    this.archived = false,
  });

  final String id;
  String name;
  String job;
  String instructions;
  String color;
  String avatar;
  bool pinned;
  bool primary;
  List<String> facts;

  /// The trust ladder: probation, trusted, or full (only Compii itself).
  String trust;

  /// How it works with the team: solo, team or lead.
  String mode;

  /// Tool packs it may use. Empty means every tool.
  List<String> tools;

  /// The supervisor's record for this teammate: jobs, accepted, success…
  Map<String, dynamic> stats;

  /// Threads this teammate is working on right now.
  List<Map<String, dynamic>> working;

  /// The AI the user chose for this teammate, if any; empty means it thinks with Compii's.
  String provider;
  String model;

  /// Which AI is really answering, named by Core from the brain that speaks, and why the chosen
  /// one can't — so no page ever claims a teammate runs a model it isn't running.
  String answersWith;
  String modelNote;

  /// Which ready-made role it started from, and the group that role belongs to in the directory.
  String template;
  String category;

  /// Put away by the user: its role, memory and conversations stay, but it is not on the team
  /// for new work, and Compii never hands anything to it until it is brought back.
  bool archived;

  bool get hasOwnAi => provider.isNotEmpty;
  bool get thinksWithOwnAi => answersWith.isNotEmpty && provider.isNotEmpty;

  bool get trusted => trust == 'trusted' || trust == 'full';
  bool get busy => working.isNotEmpty;

  factory BotView.fromJson(Map<String, dynamic> json) => BotView(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Compii',
        job: json['job'] as String? ?? '',
        instructions: json['instructions'] as String? ?? '',
        color: json['color'] as String? ?? '#7C9CFF',
        avatar: json['avatar'] as String? ?? '',
        pinned: json['pinned'] == true,
        primary: json['primary'] == true,
        facts: [for (final f in (json['facts'] as List? ?? const [])) '$f'],
        trust: json['trust'] as String? ?? (json['primary'] == true ? 'full' : 'probation'),
        mode: json['mode'] as String? ?? (json['primary'] == true ? 'lead' : 'team'),
        tools: [for (final t in (json['tools'] as List? ?? const [])) '$t'],
        stats: json['stats'] is Map ? Map<String, dynamic>.from(json['stats'] as Map) : const {},
        working: [
          for (final w in (json['working'] as List? ?? const []))
            if (w is Map) Map<String, dynamic>.from(w)
        ],
        provider: json['provider'] as String? ?? '',
        model: json['model'] as String? ?? '',
        answersWith: json['answers_with'] as String? ?? '',
        modelNote: json['model_note'] as String? ?? '',
        template: json['template'] as String? ?? '',
        category: json['category'] as String? ?? '',
        archived: json['archived'] == true,
      );
}

class TaskView {
  TaskView({
    required this.id,
    required this.request,
    required this.status,
    this.origin,
    this.botId,
    this.ownerId,
    this.parentId,
    this.job,
    this.probation = false,
    List<String>? team,
    this.answersWith = '',
  }) : team = team ?? [];

  /// Set when a routine or watch started it rather than the user.
  final Map<String, dynamic>? origin;
  bool get fromRoutine => origin?['routine'] != null;
  bool get fromWatch => origin?['watch'] != null;

  /// The bot speaking here now. Core moves it on a handoff, so it follows the events.
  String? botId;

  /// Who the user came to talk to. A handover changes the speaker, never this, so an
  /// agent's own history keeps a thread it passed part-way to a teammate.
  final String? ownerId;
  String get threadOwnerId => ownerId ?? botId ?? '';

  /// A thread this teammate was in: the user came to it, they are answering it now, or
  /// they share it. Delegated jobs are not conversations with the user, so Core leaves
  /// those out of the history list this mirrors.
  bool belongsTo(String bot) => threadOwnerId == bot || (botId == bot && bot.isNotEmpty) || team.contains(bot);

  /// Which AI is thinking behind this conversation, named by Core from the brain that answers
  /// it. Empty when there is nothing to name, so the app never claims a model it isn't using.
  final String answersWith;
  final String id;
  final String request;
  String status;
  final List<Map<String, dynamic>> events = [];

  /// The supervisor's job this thread is carrying out, when Compii delegated it.
  final Map<String, dynamic>? job;
  bool get delegated => job != null || origin?['delegated'] != null;

  /// The thread that assigned this one, if any.
  final String? parentId;

  /// A new teammate's first jobs: changes ask, sends and deletes are off.
  final bool probation;

  /// Every bot sharing a team chat, lead first. Empty for a one-to-one thread.
  final List<String> team;
  bool get isTeam => team.length > 1;

  factory TaskView.fromJson(Map<String, dynamic> json) {
    final task = TaskView(
      id: json['id'] as String,
      request: json['request'] as String,
      status: json['status'] as String,
      origin: json['origin'] == null ? null : Map<String, dynamic>.from(json['origin'] as Map),
      botId: json['bot_id'] as String?,
      ownerId: json['owner_id'] as String?,
      parentId: json['parent_id'] as String?,
      job: json['job'] is Map ? Map<String, dynamic>.from(json['job'] as Map) : null,
      probation: json['probation'] == true,
      team: [for (final b in (json['team'] as List? ?? const [])) '$b'],
      answersWith: json['answers_with'] as String? ?? '',
    );
    for (final e in json['events'] as List) {
      task.events.add(Map<String, dynamic>.from(e as Map));
    }
    return task;
  }

  bool get active => status == 'running' || status == 'waiting';

  /// The approval Compii is waiting on, if any.
  Map<String, dynamic>? get pendingApproval {
    final resolved = events
        .where((e) => e['type'] == 'approval_resolved')
        .map((e) => e['approval_id'])
        .toSet();
    for (final e in events.reversed) {
      if (e['type'] == 'approval_needed' &&
          !resolved.contains(e['approval_id'])) {
        return active ? e : null;
      }
    }
    return null;
  }

  Map<String, dynamic>? get last => events.isEmpty ? null : events.last;

  /// The question Compii is waiting for an answer to, if any.
  Map<String, dynamic>? get pendingQuestion {
    if (!active) return null;
    final answered = events
        .where((e) => e['type'] == 'question_answered')
        .map((e) => e['question_id'])
        .toSet();
    for (final e in events.reversed) {
      if (e['type'] == 'question' && !answered.contains(e['question_id'])) {
        return e;
      }
    }
    return null;
  }

  String? get finalText => events
      .lastWhere((e) => e['type'] == 'task_finished', orElse: () => {})['text']
      as String?;
}

class CoreClient extends ChangeNotifier {
  CoreClient({String host = '127.0.0.1', int port = 8765, this.remote, this.onLinkChanged})
      : host = remote?.host ?? host,
        port = remote?.port ?? port;

  /// The address in use; a phone moves through its PC's addresses until one answers.
  String host;
  final int port;

  /// Set when this app is a paired phone talking to the PC over the network.
  RemoteLink? remote;
  bool get isRemote => remote != null;

  /// The PC told us new addresses (Tailscale installed, Wi-Fi changed): save them.
  final void Function(RemoteLink link)? onLinkChanged;
  int _hostIndex = 0;
  bool _everOnline = false;

  /// Connected through a mesh VPN like Tailscale, i.e. from away from home.
  bool get viaAnywhere => isRemote && isOverlayAddress(host);

  CoreStatus status = CoreStatus.connecting;
  String brain = 'unknown';

  /// Which Core is answering: Settings shows it, so "what do I have installed" has an answer.
  String coreVersion = '';
  bool credentialsFound = true;
  final Map<String, TaskView> tasks = {};

  // ---- bots ----
  List<BotView> bots = [];
  List<Map<String, dynamic>> botTemplates = [];

  /// Every lane a teammate can be given: key, label, description, tools.
  List<Map<String, dynamic>> botPacks = [];
  String? primaryBotId;

  /// The AIs Compii knows how to talk to, so a teammate can be given one of its own.
  /// Core's own list, tagged with `provider` and whether this PC already has a key for it.
  List<Map<String, dynamic>> aiPresets = [];

  BotView? get primaryBot {
    if (bots.isEmpty) return null;
    for (final b in bots) {
      if (b.primary) return b;
    }
    return bots.first;
  }

  /// The bot a thread belongs to; unknown or old threads fall back to Compii.
  BotView? botFor(String? id) {
    for (final b in bots) {
      if (b.id == id) return b;
    }
    return primaryBot;
  }

  void _applyBots(Map<String, dynamic> view) {
    final list = [
      for (final b in view['bots'] as List? ?? const []) BotView.fromJson(Map<String, dynamic>.from(b as Map))
    ];
    if (list.isEmpty) return;
    bots = list;
    primaryBotId = view['primary'] as String?;
    botTemplates = [
      for (final t in view['templates'] as List? ?? const []) Map<String, dynamic>.from(t as Map)
    ];
    if (view['packs'] is List) {
      botPacks = [
        for (final p in view['packs'] as List) if (p is Map) Map<String, dynamic>.from(p)
      ];
    }
    notifyListeners();
  }

  // ---- the supervisor's book ----
  /// Every delegated job, newest first, with its review verdict.
  List<Map<String, dynamic>> teamJobs = [];

  /// Hiring cards not answered yet (usually empty: Core closes them at restart).
  List<Map<String, dynamic>> teamProposals = [];

  void _applyTeam(Map<String, dynamic> view) {
    final roster = view['roster'];
    if (roster is List) {
      _applyBots({'bots': roster, 'primary': view['primary'], 'templates': botTemplates,
        if (view['packs'] is List) 'packs': view['packs']});
    }
    teamJobs = [
      for (final j in (view['jobs'] as List? ?? const []))
        if (j is Map) Map<String, dynamic>.from(j)
    ];
    teamProposals = [
      for (final p in (view['proposals'] as List? ?? const []))
        if (p is Map && p['status'] == 'open') Map<String, dynamic>.from(p)
    ];
    notifyListeners();
  }

  Future<void> fetchTeam() async => _applyTeam(
      Map<String, dynamic>.from(await _request('GET', '/team') as Map));

  /// Pull the roster and the supervisor's record again after Core says the team moved. It may fail
  /// while a hire is still landing; the Team page refetches when it opens, so nothing is lost.
  void refreshTeam() => fetchTeam().then<void>((_) {}, onError: (Object _) {});

  /// Accept a hiring card, with the name and job the user chose.
  Future<BotView?> hireBot(String proposalId, {String name = '', String job = '', String instructions = '',
      String avatar = '', String color = ''}) async {
    final res = Map<String, dynamic>.from(await _request('POST', '/team/hires/$proposalId', {
      'name': name,
      'job': job,
      'instructions': instructions,
      'avatar': avatar,
      'color': color,
    }) as Map);
    final view = res['bots'];
    if (view is Map) _applyBots(Map<String, dynamic>.from(view));
    teamProposals = [for (final p in teamProposals) if (p['id'] != proposalId) p];
    notifyListeners();
    final hired = res['hired'];
    return hired is Map ? BotView.fromJson(Map<String, dynamic>.from(hired)) : null;
  }

  Future<void> declineHire(String proposalId) async {
    await _request('POST', '/team/hires/$proposalId/decline');
    teamProposals = [for (final p in teamProposals) if (p['id'] != proposalId) p];
    notifyListeners();
  }

  String? _token;
  WebSocket? _socket;
  Timer? _retry;
  Timer? _ping;
  bool _disposed = false;

  /// The PC no longer knows this phone (it was removed in Settings → Phones).
  bool unauthorized = false;
  late final HttpClient _http = remote == null
      ? (HttpClient()..connectionTimeout = const Duration(seconds: 3))
      : pinnedClient(remote!.fingerprint);

  /// Conversations, newest first. Background AI-watch checks are not shown.
  List<TaskView> get ordered => tasks.values.where((t) => !t.fromWatch).toList().reversed.toList();

  void start() => _connect();

  static File tokenFile() {
    final env = Platform.environment;
    final home = env['COMPII_HOME'] ??
        '${env['USERPROFILE'] ?? env['HOME'] ?? '.'}${Platform.pathSeparator}Compii';
    return File('$home${Platform.pathSeparator}core-token');
  }

  Future<void> _connect() async {
    _retry?.cancel();
    try {
      final health = await _request('GET', '/health');
      brain = health['brain'] as String? ?? 'unknown';
      coreVersion = health['version'] as String? ?? '';
      credentialsFound = health['credentials'] != 'not_found';
      if (health['sight'] is Map) {
        final s = Map<String, dynamic>.from(health['sight'] as Map);
        sight.value = {'screen_aware': s['screen_aware'] != false, 'looking': s['looking'] == true};
      }
      if (remote == null) _token = (await tokenFile().readAsString()).trim();
      try {
        _applyBots(Map<String, dynamic>.from(await _request('GET', '/bots') as Map));
      } on Object {
        // a Core from before bots: the app still works, just without the team list
      }
      try {
        await fetchTeam();
      } on Object {
        // a Core from before the supervisor: the team page simply has no history
      }
      final list = await _request('GET', '/tasks') as List;
      tasks
        ..clear()
        ..addEntries(
          list.reversed.map((t) {
            final task = TaskView.fromJson(Map<String, dynamic>.from(t as Map));
            return MapEntry(task.id, task);
          }),
        );
      final socket = remote == null
          ? await WebSocket.connect('ws://$host:$port/events?t=${Uri.encodeQueryComponent(_token!)}')
          : await WebSocket.connect(
              'wss://$host:$port/events?d=${Uri.encodeQueryComponent(remote!.token)}',
              customClient: _http,
            );
      _socket = socket;
      unauthorized = false;
      _everOnline = true;
      _setStatus(CoreStatus.online);
      if (remote != null) unawaited(_refreshReach());
      _ping = Timer.periodic(
        const Duration(seconds: 20),
        (_) => socket.add('ping'),
      );
      socket.listen(
        _onData,
        onDone: _lost,
        onError: (_) => _lost(),
        cancelOnError: true,
      );
    } catch (_) {
      _lost();
    }
  }

  /// Decode one frame and dispatch it. A malformed or unexpected event must
  /// never throw into the socket stream — that would trip `cancelOnError`,
  /// drop the connection, and start a reconnect loop over a single bad message.
  void _onData(Object? data) {
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    try {
      _onEvent(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // One bad event is skipped, not fatal: the socket stays open.
    }
  }

  void _lost() {
    _ping?.cancel();
    _socket = null;
    if (_disposed) return;
    final hosts = remote?.hosts ?? const <String>[];
    if (hosts.length > 1) {
      _hostIndex = (_hostIndex + 1) % hosts.length;
      host = hosts[_hostIndex];
    }
    _setStatus(CoreStatus.offline);
    // Out of touch, so nothing can be reading the screen: the light goes off rather than
    // holding a claim Core never made.
    if (sight.value['looking'] == true) {
      sight.value = {...sight.value, 'looking': false};
    }
    // Try the next address at once; after a full round, back off.
    final quick = hosts.length > 1 && _hostIndex != 0;
    _retry = Timer(Duration(seconds: quick ? 1 : (_everOnline ? 3 : 5)), _connect);
  }

  Future<void> _refreshReach() async {
    try {
      final r = Map<String, dynamic>.from(await _request('GET', '/reach') as Map);
      final hosts = [for (final h in r['hosts'] as List) '$h'];
      final link = remote;
      if (link == null || hosts.isEmpty || listEquals(hosts, link.hosts)) return;
      final merged = [...hosts, for (final h in link.hosts) if (!hosts.contains(h)) h];
      remote = link.withHosts(merged);
      _hostIndex = merged.indexOf(host).clamp(0, merged.length - 1);
      onLinkChanged?.call(remote!);
      notifyListeners();
    } on Object {
      // an older PC without /reach: keep the addresses we have
    }
  }

  void _setStatus(CoreStatus next) {
    status = next;
    notifyListeners();
  }

  /// Latest "point at this on screen" event, for the desktop overlay.
  final ValueNotifier<Map<String, dynamic>?> lastPoint = ValueNotifier(null);

  /// Things Compii tells you on its own: briefs, watches, routines.
  final StreamController<Map<String, dynamic>> updates = StreamController.broadcast();
  int unread = 0;

  /// Voice events (listening, live transcript, speaking, downloads).
  final StreamController<Map<String, dynamic>> voiceEvents = StreamController.broadcast();

  /// Every live task event (finished, needs you, questions), for desktop toasts.
  final StreamController<Map<String, dynamic>> taskEvents = StreamController.broadcast();

  /// "Show this conversation" asked for by another Compii surface, such as the
  /// island handing a thread to the full window.
  final StreamController<Map<String, dynamic>> uiEvents = StreamController.broadcast();

  /// Compii's eyes: `screen_aware` (the user's switch) and `looking` (it is reading right now).
  /// The light next to the cursor and the one in this window both come from this, and Core is the
  /// only thing that can say it looked - so it never lights up on a guess.
  final ValueNotifier<Map<String, dynamic>> sight = ValueNotifier(const {'screen_aware': true, 'looking': false});

  /// True when this client already carries the conversation an inbox update came
  /// from. Both surfaces that tell you about work use this: a thread they can see
  /// has already said it once, so the update is the same news in a second voice.
  bool hasThreadFor(Map<String, dynamic> update) {
    final id = update['task_id'];
    return id is String && id.isNotEmpty && tasks.containsKey(id);
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['type'] == 'point') lastPoint.value = e;
    if ('${e['type']}'.startsWith('voice_')) voiceEvents.add(e);
    if (e['type'] == 'voice_sight') {
      sight.value = {'screen_aware': e['screen_aware'] != false, 'looking': e['looking'] == true};
    }
    if (e['type'] == 'device_paired') deviceEvents.add(e);
    if (e['type'] == 'ui_show') {
      uiEvents.add(e);
      return;
    }
    if (e['type'] == 'update') {
      updates.add(e);
      unread += 1;
      notifyListeners();
      return;
    }
    if (e['type'] == 'team_changed') {
      // A teammate was created, renamed, hired or let go — possibly from the phone or by Compii
      // itself. This window holds a copy of the roster, so ask for the live one rather than
      // showing a team that no longer matches the PC.
      refreshTeam();
      return;
    }
    final id = e['task_id'];
    if (id is! String || id.isEmpty) return; // not part of a task
    if (e['type'] == 'task_dropped') {
      // A conversation deleted — here or in another window. Nothing may recreate it, so it
      // leaves this app's memory at once instead of lingering until the next restart.
      if (tasks.remove(id) != null) notifyListeners();
      return;
    }
    final task = tasks.putIfAbsent(
      id,
      () => TaskView(
        id: id,
        request: e['request'] as String? ?? '',
        status: 'running',
        origin: e['origin'] == null ? null : Map<String, dynamic>.from(e['origin'] as Map),
        botId: e['bot_id'] as String?,
        ownerId: e['owner_id'] as String?,
        team: [for (final b in (e['team'] as List? ?? const [])) '$b'],
      ),
    );
    // A handoff moves the speaker mid-thread; the chip must follow who answers now.
    final speaker = e['bot_id'];
    if (speaker is String && speaker.isNotEmpty) task.botId = speaker;
    if (task.team.isEmpty && e['team'] is List) {
      task.team.addAll([for (final b in e['team'] as List) '$b']);
    }
    // Words still being written replace one another: keep the newest frame, not the whole stream.
    if (e['type'] == 'answer_delta' && task.events.isNotEmpty && task.events.last['type'] == 'answer_delta') {
      task.events.removeLast();
    }
    task.events.add(e);
    if (e['status'] is String) task.status = e['status'] as String;
    taskEvents.add(e);
    notifyListeners();
  }

  Future<dynamic> _request(String method, String path, [Object? body, Map<String, String>? query]) async {
    final HttpClientRequest req;
    try {
      req = await _http.openUrl(
          method, remote == null ? Uri.http('$host:$port', path, query) : Uri.https('$host:$port', path, query));
    } on SocketException {
      throw CoreError(remote == null
          ? 'Compii Core isn’t reachable right now. It reconnects by itself once Core is running.'
          : remote!.hosts.any(isOverlayAddress)
              ? 'Can’t reach ${remote!.pc} right now. Check Compii is running on the PC and Tailscale is on, on both.'
              : 'Can’t reach ${remote!.pc} right now. Check the phone is on the same Wi-Fi and Compii is running on the PC.',
          offline: true);
    } on HandshakeException {
      throw CoreError('This isn’t the PC you paired with (its security fingerprint doesn’t match). Pair again.');
    }
    if (_token != null) req.headers.set('X-Compii-Token', _token!);
    if (remote != null) req.headers.set('X-Compii-Device', remote!.token);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 401 && remote != null && !unauthorized) {
      unauthorized = true; // this phone was removed on the PC
      notifyListeners();
    }
    if (res.statusCode >= 400) {
      throw CoreError(_detail(text, res.statusCode));
    }
    return jsonDecode(text);
  }

  Future<void> ask(String request, {String? botId, List<String>? team, List<String> attachments = const []}) =>
      _request('POST', '/tasks', {
        'request': request,
        'bot_id': ?botId,
        if (team != null && team.length > 1) 'team': team,
        if (attachments.isNotEmpty) 'attachments': attachments,
      });
  Future<void> stop(String taskId) => _request('POST', '/tasks/$taskId/stop');
  Future<void> stopAll() => _request('POST', '/stop');

  /// Ask whichever Compii window is open to show something: a conversation, or a
  /// page of the app when what it has to show has no thread of its own — the daily
  /// brief, a watch, a journal day. Core relays it, so an island click reaches the
  /// full window and any other listener.
  Future<void> uiShow(String taskId, {String section = ''}) =>
      _request('POST', '/ui/show', {'task_id': taskId, 'section': section});

  /// Close Core on purpose, so an update can replace the files it is running from.
  Future<void> stopCore() => _request('POST', '/shutdown');
  Future<void> decide(String approvalId, {required bool approved}) =>
      _request('POST', '/approvals/$approvalId', {'approved': approved});

  /// Answer a question Compii asked, from the choices or by typing it.
  Future<void> answerQuestion(String questionId, String text) =>
      _request('POST', '/questions/$questionId/answer', {'text': text});

  /// Say a password/card/code step is finished (or skipped) so Compii carries on.
  Future<void> finishTakeover(String takeoverId, {String outcome = 'done'}) =>
      _request('POST', '/takeovers/$takeoverId', {'outcome': outcome});
  Future<String> undo(String taskId) async =>
      (await _request('POST', '/tasks/$taskId/undo'))['result'] as String;

  /// What Compii changed and can still put back, newest first. `hours` 0 means the whole journal.
  Future<List<Map<String, dynamic>>> undoList({int hours = 24}) async {
    final got = await _request('GET', '/undo', null, {'hours': '$hours'});
    return [for (final a in (got as Map)['actions'] as List) Map<String, dynamic>.from(a as Map)];
  }

  /// Put one of those back, by the id the list gave it. Core answers in plain words,
  /// including why something can’t be reversed, so the result is always worth showing.
  Future<String> undoById(String id) async => (await _request('POST', '/undo', {'id': id}))['result'] as String;

  /// Start a conversation; returns its id. `botId` picks which teammate answers first,
  /// and `team` (2–6 ids) opens a shared thread where they can hand work to each other.
  Future<String> startConversation(String request, {String? botId, List<String>? team,
      List<String> attachments = const [], List<String> contextOff = const []}) async =>
      (await _request('POST', '/tasks', {
        'request': request,
        'bot_id': ?botId,
        if (team != null && team.length > 1) 'team': team,
        if (attachments.isNotEmpty) 'attachments': attachments,
        if (contextOff.isNotEmpty) 'context_off': contextOff,
      }))['id'] as String;

  Future<void> createBot({
    required String name,
    String template = '',
    String job = '',
    String instructions = '',
    String color = '',
    String avatar = '',
    String mode = '',
    List<String>? tools,
    String provider = '',
    String model = '',
  }) async =>
      _applyBots(Map<String, dynamic>.from(await _request('POST', '/bots', {
        'name': name,
        'template': template,
        'job': job,
        'instructions': instructions,
        'color': color,
        'avatar': avatar,
        if (mode.isNotEmpty) 'mode': mode,
        'tools': ?tools,
        if (provider.isNotEmpty) 'provider': provider,
        if (model.isNotEmpty) 'model': model,
      }) as Map));

  Future<void> editBot(String id, Map<String, Object?> changes) async =>
      _applyBots(Map<String, dynamic>.from(await _request('PATCH', '/bots/$id', changes) as Map));

  Future<void> deleteBot(String id) async =>
      _applyBots(Map<String, dynamic>.from(await _request('DELETE', '/bots/$id') as Map));

  Future<void> addBotFact(String id, String fact) async =>
      _applyBots(Map<String, dynamic>.from(await _request('POST', '/bots/$id/facts', {'fact': fact}) as Map));

  Future<void> forgetBotFact(String id, int index) async =>
      _applyBots(Map<String, dynamic>.from(await _request('DELETE', '/bots/$id/facts/$index') as Map));

  /// One teammate's own conversations, most recently used first. Core does the filtering,
  /// so an agent's history holds the threads the user opened with it — including any it has
  /// handed part-way to a colleague — and not the jobs it was assigned by another.
  Future<List<TaskView>> fetchConversations(String botId) async {
    final res = Map<String, dynamic>.from(await _request('GET', '/bots/$botId/conversations') as Map);
    final out = <TaskView>[];
    for (final t in (res['conversations'] as List? ?? const [])) {
      final view = TaskView.fromJson(Map<String, dynamic>.from(t as Map));
      // A thread already open in this window keeps its live copy; this fills in the rest.
      final kept = tasks[view.id] ?? view;
      tasks.putIfAbsent(kept.id, () => kept);
      out.add(kept);
    }
    return out;
  }

  /// The AIs Compii can talk to, with the ones this PC already has a key for. Core's own list:
  /// the app never keeps a second one that could go out of date.
  Future<void> fetchBrain() async {
    final v = Map<String, dynamic>.from(await _request('GET', '/brain') as Map);
    final presets = Map<String, dynamic>.from(v['presets'] as Map? ?? {});
    final keys = Map<String, dynamic>.from(v['keys'] as Map? ?? {});
    aiPresets = [
      for (final entry in presets.entries)
        if (entry.value is Map)
          {
            'provider': entry.key,
            'label': '${(entry.value as Map)['label'] ?? entry.key}',
            'model': '${(entry.value as Map)['model'] ?? ''}',
            'where': '${(entry.value as Map)['where'] ?? ''}',
            'price': '${(entry.value as Map)['price'] ?? ''}',
            // A local server needs no key, so it is always ready to answer.
            'hasKey': '${(entry.value as Map)['key'] ?? ''}'.isEmpty ||
                keys['${(entry.value as Map)['key']}'] == true,
          },
    ];
    notifyListeners();
  }

  /// Hand a conversation over to another teammate. The thread, the files it touched and
  /// what was already established travel with it, and the next answer is spoken by them.
  Future<TaskView> transferConversation(String taskId, String botId, {String note = ''}) async {
    final res = Map<String, dynamic>.from(
        await _request('POST', '/tasks/$taskId/transfer', {'bot_id': botId, 'note': note}) as Map);
    final moved = TaskView.fromJson(res);
    tasks[taskId] = moved;
    notifyListeners();
    return moved;
  }

  /// Follow up in an existing conversation. Whatever the user struck off in that chat is
  /// sent with every later message, so a source cannot come back on the next turn.
  Future<void> reply(String taskId, String text, {List<String> attachments = const []}) =>
      _request('POST', '/tasks/$taskId/messages', {
        'text': text,
        if (attachments.isNotEmpty) 'attachments': attachments,
        if (withheld[taskId]?.isNotEmpty == true) 'context_off': withheld[taskId]!.toList(),
      });

  /// Context items the user refused for one conversation, by the id Core gave them.
  final Map<String, Set<String>> withheld = {};

  /// Strike a source off this chat, or put it back. Core keeps the refusal for the
  /// conversation, so it is the app's job only to remember what the user switched off.
  void withhold(String taskId, String id, bool off) {
    final set = withheld.putIfAbsent(taskId, () => {});
    if (off) {
      set.add(id);
    } else {
      set.remove(id);
    }
    notifyListeners();
  }

  /// What the next message would be answered with, before sending it.
  Future<Map<String, dynamic>> contextPreview() async =>
      Map<String, dynamic>.from(await _request('GET', '/context') as Map);

  /// Answer the last ask again. Core re-reads the same history and starts a fresh turn;
  /// the answer already given stays in the thread exactly as it was said.
  Future<void> answerAgain(String taskId) => _request('POST', '/tasks/$taskId/again');

  /// Forget a conversation for good: Core drops it from the live set and from the archive,
  /// so it does not come back after a restart.
  Future<void> deleteConversation(String taskId) => _request('DELETE', '/tasks/$taskId');

  /// Send a file to Core so Compii can read it. Streams the bytes; nothing is loaded whole.
  Future<Map<String, dynamic>> uploadFile(String path) async {
    final file = File(path);
    final length = await file.length();
    final HttpClientRequest req;
    try {
      req = await _http.openUrl('POST',
          remote == null ? Uri.http('$host:$port', '/uploads') : Uri.https('$host:$port', '/uploads'));
    } on SocketException {
      throw CoreError('Can’t reach ${remote?.pc ?? 'Compii Core'} right now.', offline: true);
    } on HandshakeException {
      throw CoreError('This isn’t the PC you paired with (its security fingerprint doesn’t match). Pair again.');
    }
    if (_token != null) req.headers.set('X-Compii-Token', _token!);
    if (remote != null) req.headers.set('X-Compii-Device', remote!.token);
    req.headers.set('X-Compii-Filename', Uri.encodeComponent(file.uri.pathSegments.last));
    req.headers.contentType = ContentType('application', 'octet-stream');
    req.headers.contentLength = length;
    await req.addStream(file.openRead());
    final res = await req.close();
    final data = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw CoreError(_detail(data, res.statusCode));
    return Map<String, dynamic>.from(jsonDecode(data) as Map);
  }

  Future<List<Map<String, dynamic>>> memories() async =>
      [for (final m in await _request('GET', '/memory') as List) Map<String, dynamic>.from(m as Map)];
  Future<void> forget(int id) => _request('DELETE', '/memory/$id');

  Future<void> openFile(String path) => _request('POST', '/files/open', {'path': path});
  Future<void> revealFile(String path) => _request('POST', '/files/reveal', {'path': path});
  Future<void> openUrl(String url) => _request('POST', '/open_url', {'path': url});

  /// Put text on the PC's clipboard, ready to paste there.
  Future<void> pushClipboard(String text) => _request('POST', '/clipboard', {'text': text});

  /// A small live picture of the PC's screen (PNG bytes).
  Future<Uint8List> peekScreen({bool full = true}) => _bytes('/screen/peek', {'full': '$full'});

  /// Do that to the words the user had highlighted when they tapped Ctrl+Alt. Core still holds
  /// the words it read at the press — nothing is copied and nothing is re-read here.
  Future<void> selectionAsk(String instruction) =>
      _request('POST', '/screen/selection', {'instruction': instruction});

  Future<Uint8List> _bytes(String path, [Map<String, String>? query]) async {
    final HttpClientRequest req;
    try {
      req = await _http.openUrl(
          'GET', remote == null ? Uri.http('$host:$port', path, query) : Uri.https('$host:$port', path, query));
    } on SocketException {
      throw CoreError('Can’t reach ${remote?.pc ?? 'Compii Core'} right now.', offline: true);
    } on HandshakeException {
      throw CoreError('This isn’t the PC you paired with (its security fingerprint doesn’t match). Pair again.');
    }
    if (_token != null) req.headers.set('X-Compii-Token', _token!);
    if (remote != null) req.headers.set('X-Compii-Device', remote!.token);
    final res = await req.close();
    final bytes = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d));
    final data = bytes.takeBytes();
    if (res.statusCode >= 400) throw CoreError(_detail(utf8.decode(data, allowMalformed: true), res.statusCode));
    return data;
  }

  // ---- screen timeline ----
  Future<Map<String, dynamic>> daybook({int hours = 24}) async =>
      Map<String, dynamic>.from(await _request('GET', '/daybook', null, {'hours': '$hours'}) as Map);

  Future<Map<String, dynamic>> timelineStatus() async =>
      Map<String, dynamic>.from(await _request('GET', '/timeline') as Map);
  Future<Map<String, dynamic>> setTimeline(Map<String, Object?> changes) async =>
      Map<String, dynamic>.from(await _request('PUT', '/timeline', changes) as Map);
  Future<List<Map<String, dynamic>>> timelineMoments(
      {String q = '', double? after, double? before, String app = '', int limit = 60, bool full = true}) async {
    final query = {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (after != null) 'after': '$after',
      if (before != null) 'before': '$before',
      if (app.isNotEmpty) 'app': app,
      'limit': '$limit',
      'full': '$full',
    };
    return [
      for (final m in await _request('GET', '/timeline/moments', null, query) as List)
        Map<String, dynamic>.from(m as Map)
    ];
  }

  Future<Map<String, dynamic>> timelineMoment(int id) async =>
      Map<String, dynamic>.from(await _request('GET', '/timeline/moments/$id') as Map);

  /// The small picture kept with a moment (PNG bytes). Local to the PC.
  Future<Uint8List> timelinePicture(int id) => _bytes('/timeline/moments/$id/picture');

  Future<int> forgetTimeline({double hours = 0}) async =>
      (await _request('DELETE', '/timeline', null, {'hours': '$hours'}))['deleted'] as int? ?? 0;

  Future<void> forgetTimelineMoment(int id) => _request('DELETE', '/timeline/moments/$id');

  // ---- clipboard history and snippets ----
  Future<Map<String, dynamic>> clipsStatus() async =>
      Map<String, dynamic>.from(await _request('GET', '/clips') as Map);
  Future<Map<String, dynamic>> setClips(Map<String, Object?> changes) async =>
      Map<String, dynamic>.from(await _request('PUT', '/clips', changes) as Map);
  Future<List<Map<String, dynamic>>> clipItems({String q = '', int limit = 100, bool? pinned}) async {
    final query = {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      'limit': '$limit',
      if (pinned != null) 'pinned': '$pinned',
    };
    return [
      for (final c in await _request('GET', '/clips/items', null, query) as List)
        Map<String, dynamic>.from(c as Map)
    ];
  }

  Future<Map<String, dynamic>> clipItem(int id) async =>
      Map<String, dynamic>.from(await _request('GET', '/clips/items/$id') as Map);
  Future<void> copyClip(int id) => _request('POST', '/clips/items/$id/copy');
  Future<Map<String, dynamic>> pinClip(int id, bool pinned) async =>
      Map<String, dynamic>.from(await _request('PATCH', '/clips/items/$id', {'pinned': pinned}) as Map);
  Future<void> forgetClip(int id) => _request('DELETE', '/clips/items/$id');
  Future<int> forgetClips({double hours = 0}) async =>
      (await _request('DELETE', '/clips', null, {'hours': '$hours'}))['deleted'] as int? ?? 0;

  Future<List<Map<String, dynamic>>> snippets({String q = ''}) async => [
        for (final s in await _request('GET', '/snippets', null, {if (q.trim().isNotEmpty) 'q': q.trim()}) as List)
          Map<String, dynamic>.from(s as Map)
      ];
  Future<Map<String, dynamic>> saveSnippet(String name, String body, {bool replace = false}) async =>
      Map<String, dynamic>.from(await _request('POST', '/snippets', {'name': name, 'body': body, 'replace': replace}) as Map);
  Future<Map<String, dynamic>> editSnippet(String id, {String? name, String? body}) async =>
      Map<String, dynamic>.from(await _request('PUT', '/snippets/$id', {
        'name': ?name,
        'body': ?body,
      }) as Map);
  Future<void> deleteSnippet(String id) => _request('DELETE', '/snippets/$id');
  Future<void> copySnippet(String id) => _request('POST', '/snippets/$id/copy');

  /// The autonomy dial: action kind -> ask_every_time | ask_once_per_task | just_do_it.
  Future<Map<String, String>> policy() async =>
      Map<String, String>.from(await _request('GET', '/policy') as Map);
  // ---- phones ----
  /// Start pairing: Core opens its phone listener and returns a one-time QR link.
  Future<Map<String, dynamic>> pairStart() async =>
      Map<String, dynamic>.from(await _request('POST', '/pair/start') as Map);
  Future<Map<String, dynamic>> devices() async =>
      Map<String, dynamic>.from(await _request('GET', '/devices') as Map);
  Future<Map<String, dynamic>> unpair(String id) async =>
      Map<String, dynamic>.from(await _request('DELETE', '/devices/$id') as Map);

  /// Paired-phone events (e.g. "device_paired").
  final StreamController<Map<String, dynamic>> deviceEvents = StreamController.broadcast();

  // ---- thinking ahead ----
  /// The last plan view, so Routines and a bot's home open with content
  /// instead of a spinner while the first request is in flight.
  Map<String, dynamic>? plansCache;

  Future<Map<String, dynamic>> proactive() async {
    final v = Map<String, dynamic>.from(await _request('GET', '/proactive') as Map);
    plansCache = v;
    unread = v['unread'] as int? ?? 0;
    notifyListeners();
    return v;
  }

  Future<Map<String, dynamic>> _pv(String method, String path, [Object? body]) async {
    final v = Map<String, dynamic>.from(await _request(method, path, body) as Map);
    if (v.containsKey('routines')) plansCache = v;
    if (v.containsKey('unread')) {
      unread = v['unread'] as int;
      notifyListeners();
    }
    return v;
  }

  Future<Map<String, dynamic>> addRoutine(String title, String instruction, Map<String, Object?> schedule,
          {String? botId}) =>
      _pv('POST', '/routines', {
        'title': title,
        'instruction': instruction,
        'schedule': schedule,
        'bot_id': ?botId,
      });
  Future<Map<String, dynamic>> updateRoutine(String id, String title, String instruction,
          Map<String, Object?> schedule, {String? botId}) =>
      _pv('PUT', '/routines/$id', {
        'title': title,
        'instruction': instruction,
        'schedule': schedule,
        'bot_id': ?botId,
      });
  Future<Map<String, dynamic>> addWatch(String title, String kind, Map<String, Object?> spec) =>
      _pv('POST', '/watches', {'title': title, 'kind': kind, 'spec': spec});
  Future<Map<String, dynamic>> setEnabled(String id, bool enabled) => _pv('PATCH', '/proactive/$id', {'enabled': enabled});
  Future<Map<String, dynamic>> removePlan(String id) => _pv('DELETE', '/proactive/$id');
  /// Take up an offer Compii made from a repeated ask. A schedule turns a skill offer into a routine.
  Future<Map<String, dynamic>> acceptSuggestion(String id, {Map<String, Object?>? schedule}) =>
      _pv('POST', '/suggestions/$id/accept', {'schedule': ?schedule});
  Future<Map<String, dynamic>> declineSuggestion(String id) => _pv('POST', '/suggestions/$id/decline');
  Future<void> runRoutine(String id) => _request('POST', '/routines/$id/run');
  Future<Map<String, dynamic>> briefSettings({bool? enabled, String? at}) =>
      _pv('PUT', '/brief', {'enabled': ?enabled, 'at': ?at});
  Future<void> briefNow() => _request('POST', '/brief/now');

  // ---- work journal ----
  /// The journal answers with its own small view, so each change reloads the
  /// whole plans page the card sits on rather than replacing it with half a view.
  Future<Map<String, dynamic>> journalSettings({bool? enabled, String? at}) async {
    await _request('PUT', '/journal', {'enabled': ?enabled, 'at': ?at});
    return proactive();
  }

  Future<Map<String, dynamic>> journalNow() async {
    await _request('POST', '/journal/now');
    return proactive();
  }

  Future<String> journalDay(String date) async => (await _request('GET', '/journal/$date'))['text'] as String;
  Future<Map<String, dynamic>> markRead([String? id]) => _pv('POST', '/inbox/read', {'id': id});

  // ---- voice ----
  Future<Map<String, dynamic>> voiceStatus() async =>
      Map<String, dynamic>.from(await _request('GET', '/voice') as Map);
  Future<Map<String, dynamic>> voiceSettings(Map<String, Object?> changes) async =>
      Map<String, dynamic>.from(await _request('PUT', '/voice/settings', changes) as Map);
  Future<Map<String, dynamic>> voiceDownload(String what) async =>
      Map<String, dynamic>.from(await _request('POST', '/voice/download', {'what': what}) as Map);
  Future<void> listenStart() => _request('POST', '/voice/listen/start');
  Future<String> listenStop() async => (await _request('POST', '/voice/listen/stop'))['text'] as String;
  Future<void> listenCancel() => _request('POST', '/voice/listen/cancel');
  Future<void> quiet() => _request('POST', '/voice/quiet');

  Future<Map<String, String>> setPolicy(String kind, String level) async =>
      Map<String, String>.from(await _request('PUT', '/policy', {'kind': kind, 'level': level}) as Map);

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ping?.cancel();
    _socket?.close();
    lastPoint.dispose();
    sight.dispose();
    updates.close();
    voiceEvents.close();
    taskEvents.close();
    deviceEvents.close();
    _http.close(force: true);
    super.dispose();
  }
}


/// An error from Compii Core, worded for people.
class CoreError implements Exception {
  CoreError(this.message, {this.offline = false});
  final String message;

  /// The PC could not be reached at all (as opposed to refusing something).
  final bool offline;
  @override
  String toString() => message;
}

String _detail(String body, int status) {
  try {
    final d = jsonDecode(body);
    if (d is Map && d['detail'] is String) return d['detail'] as String;
  } catch (_) {}
  return switch (status) {
    401 => 'Compii Core didn’t accept this app. Restart both and try again.',
    404 => 'That isn’t there any more.',
    409 => 'Compii is busy with that right now.',
    _ => 'Compii Core couldn’t do that (error $status).',
  };
}


/// An HTTP client that trusts exactly one certificate: the PC's, identified
/// by the SHA-256 fingerprint from the pairing QR code. Nobody else on the
/// network can impersonate the PC or read the traffic.
HttpClient pinnedClient(String fingerprint) {
  final want = fingerprint.toLowerCase().replaceAll(':', '');
  return HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 5)
    ..badCertificateCallback = (cert, host, port) => sha256.convert(cert.der).toString() == want;
}

/// Tailscale and similar mesh VPNs use 100.64.0.0/10, reachable from anywhere.
bool isOverlayAddress(String host) {
  final p = host.split('.');
  if (p.length != 4) return false;
  final a = int.tryParse(p[0]), b = int.tryParse(p[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

/// What a paired phone remembers about its PC.
class RemoteLink {
  const RemoteLink({required this.host, required this.port, required this.fingerprint, required this.token, required this.pc, List<String>? hosts})
      : _hosts = hosts;
  final String host;
  final int port;
  final String fingerprint;
  final String token;
  final String pc;
  final List<String>? _hosts;

  /// Every address to try, best first (home Wi-Fi, then Tailscale and the like).
  List<String> get hosts => _hosts == null || _hosts.isEmpty ? [host] : _hosts;

  RemoteLink withHosts(List<String> next) =>
      RemoteLink(host: next.first, port: port, fingerprint: fingerprint, token: token, pc: pc, hosts: next);

  Map<String, Object> toJson() =>
      {'host': host, 'port': port, 'fingerprint': fingerprint, 'token': token, 'pc': pc, 'hosts': hosts};

  factory RemoteLink.fromJson(Map<String, dynamic> j) => RemoteLink(
    host: j['host'] as String,
    port: j['port'] as int,
    fingerprint: j['fingerprint'] as String,
    token: j['token'] as String,
    pc: j['pc'] as String? ?? 'your PC',
    hosts: j['hosts'] is List ? [for (final h in j['hosts'] as List) '$h'] : null,
  );
}

/// The contents of a pairing QR code: compii://pair?h=&p=&c=&f=&n=&a=
class PairingInvite {
  const PairingInvite({required this.host, required this.port, required this.code, required this.fingerprint, required this.pc, this.also = const []});
  final String host;

  /// More addresses to try after [host] (e.g. Tailscale).
  final List<String> also;
  List<String> get hosts => [host, for (final h in also) if (h != host) h];
  final int port;
  final String code;
  final String fingerprint;
  final String pc;

  static PairingInvite? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'compii' || uri.host != 'pair') return null;
    final q = uri.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    final fp = (q['f'] ?? '').toLowerCase();
    if ((q['h'] ?? '').isEmpty || port == null || (q['c'] ?? '').isEmpty || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) {
      return null;
    }
    final also = [for (final h in (q['a'] ?? '').split(',')) if (h.trim().isNotEmpty) h.trim()];
    return PairingInvite(host: q['h']!, port: port, code: q['c']!, fingerprint: fp, pc: q['n'] ?? 'your PC', also: also);
  }

  /// Swap the one-time code for this phone's own key, over the pinned connection.
  /// Tries each of the PC's addresses in turn.
  Future<RemoteLink> claim(String deviceName) async {
    final http = pinnedClient(fingerprint);
    try {
      for (final h in hosts) {
        try {
          final req = await http.postUrl(Uri.https('$h:$port', '/pair/claim'));
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({'code': code, 'name': deviceName}));
          final res = await req.close();
          final text = await res.transform(utf8.decoder).join();
          if (res.statusCode >= 400) throw CoreError(_detail(text, res.statusCode));
          final j = jsonDecode(text) as Map<String, dynamic>;
          final told = j['hosts'] is List ? [for (final x in j['hosts'] as List) '$x'] : <String>[];
          final all = {h, ...told, ...hosts}.toList();
          return RemoteLink(host: h, port: port, fingerprint: fingerprint, token: j['token'] as String,
              pc: j['pc'] as String? ?? pc, hosts: all);
        } on SocketException {
          continue; // the next address may answer
        }
      }
      throw CoreError('Can’t reach $pc at ${hosts.join(' or ')}. Make sure the phone is on the same Wi-Fi (or Tailscale is on), '
          'and allow Compii through the PC’s firewall if Windows asks.');
    } on HandshakeException {
      throw CoreError('The PC’s security fingerprint doesn’t match the QR code. Pairing was stopped to keep you safe.');
    } finally {
      http.close();
    }
  }
}

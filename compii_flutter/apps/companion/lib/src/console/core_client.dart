import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Connection to Compii Core, the local service that does the work.
enum CoreStatus { connecting, offline, online }

class TaskView {
  TaskView({required this.id, required this.request, required this.status, this.origin});

  /// Set when a routine or watch started it rather than the user.
  final Map<String, dynamic>? origin;
  bool get fromRoutine => origin?['routine'] != null;
  bool get fromWatch => origin?['watch'] != null;
  final String id;
  final String request;
  String status;
  final List<Map<String, dynamic>> events = [];

  factory TaskView.fromJson(Map<String, dynamic> json) {
    final task = TaskView(
      id: json['id'] as String,
      request: json['request'] as String,
      status: json['status'] as String,
      origin: json['origin'] == null ? null : Map<String, dynamic>.from(json['origin'] as Map),
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

  String? get finalText => events
      .lastWhere((e) => e['type'] == 'task_finished', orElse: () => {})['text']
      as String?;
}

class CoreClient extends ChangeNotifier {
  CoreClient({this.host = '127.0.0.1', this.port = 8765});
  final String host;
  final int port;

  CoreStatus status = CoreStatus.connecting;
  String brain = 'unknown';
  bool credentialsFound = true;
  final Map<String, TaskView> tasks = {};

  String? _token;
  WebSocket? _socket;
  Timer? _retry;
  Timer? _ping;
  bool _disposed = false;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);

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
      credentialsFound = health['credentials'] != 'not_found';
      _token = (await tokenFile().readAsString()).trim();
      final list = await _request('GET', '/tasks') as List;
      tasks
        ..clear()
        ..addEntries(
          list.reversed.map((t) {
            final task = TaskView.fromJson(Map<String, dynamic>.from(t as Map));
            return MapEntry(task.id, task);
          }),
        );
      final socket = await WebSocket.connect(
        'ws://$host:$port/events?t=${Uri.encodeQueryComponent(_token!)}',
      );
      _socket = socket;
      _setStatus(CoreStatus.online);
      _ping = Timer.periodic(
        const Duration(seconds: 20),
        (_) => socket.add('ping'),
      );
      socket.listen(
        (data) => _onEvent(jsonDecode(data as String) as Map<String, dynamic>),
        onDone: _lost,
        onError: (_) => _lost(),
        cancelOnError: true,
      );
    } catch (_) {
      _lost();
    }
  }

  void _lost() {
    _ping?.cancel();
    _socket = null;
    if (_disposed) return;
    _setStatus(CoreStatus.offline);
    _retry = Timer(const Duration(seconds: 3), _connect);
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

  void _onEvent(Map<String, dynamic> e) {
    if (e['type'] == 'point') lastPoint.value = e;
    if ('${e['type']}'.startsWith('voice_')) voiceEvents.add(e);
    if (e['type'] == 'update') {
      updates.add(e);
      unread += 1;
      notifyListeners();
      return;
    }
    final id = e['task_id'] as String;
    if (id.isEmpty) return; // not part of a task
    final task = tasks.putIfAbsent(
      id,
      () => TaskView(
        id: id,
        request: e['request'] as String? ?? '',
        status: 'running',
        origin: e['origin'] == null ? null : Map<String, dynamic>.from(e['origin'] as Map),
      ),
    );
    task.events.add(e);
    if (e['status'] is String) task.status = e['status'] as String;
    notifyListeners();
  }

  Future<dynamic> _request(String method, String path, [Object? body]) async {
    final HttpClientRequest req;
    try {
      req = await _http.openUrl(method, Uri.http('$host:$port', path));
    } on SocketException {
      throw CoreError('Compii Core isn’t reachable right now. It reconnects by itself once Core is running.');
    }
    if (_token != null) req.headers.set('X-Compii-Token', _token!);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw CoreError(_detail(text, res.statusCode));
    }
    return jsonDecode(text);
  }

  Future<void> ask(String request) =>
      _request('POST', '/tasks', {'request': request});
  Future<void> stop(String taskId) => _request('POST', '/tasks/$taskId/stop');
  Future<void> stopAll() => _request('POST', '/stop');
  Future<void> decide(String approvalId, {required bool approved}) =>
      _request('POST', '/approvals/$approvalId', {'approved': approved});
  Future<String> undo(String taskId) async =>
      (await _request('POST', '/tasks/$taskId/undo'))['result'] as String;

  /// Start a conversation; returns its id.
  Future<String> startConversation(String request) async =>
      (await _request('POST', '/tasks', {'request': request}))['id'] as String;

  /// Follow up in an existing conversation.
  Future<void> reply(String taskId, String text) =>
      _request('POST', '/tasks/$taskId/messages', {'text': text});

  Future<List<Map<String, dynamic>>> memories() async =>
      [for (final m in await _request('GET', '/memory') as List) Map<String, dynamic>.from(m as Map)];
  Future<void> forget(int id) => _request('DELETE', '/memory/$id');

  Future<void> openFile(String path) => _request('POST', '/files/open', {'path': path});
  Future<void> revealFile(String path) => _request('POST', '/files/reveal', {'path': path});

  /// The autonomy dial: action kind -> ask_every_time | ask_once_per_task | just_do_it.
  Future<Map<String, String>> policy() async =>
      Map<String, String>.from(await _request('GET', '/policy') as Map);
  // ---- thinking ahead ----
  Future<Map<String, dynamic>> proactive() async {
    final v = Map<String, dynamic>.from(await _request('GET', '/proactive') as Map);
    unread = v['unread'] as int? ?? 0;
    notifyListeners();
    return v;
  }

  Future<Map<String, dynamic>> _pv(String method, String path, [Object? body]) async {
    final v = Map<String, dynamic>.from(await _request(method, path, body) as Map);
    if (v.containsKey('unread')) {
      unread = v['unread'] as int;
      notifyListeners();
    }
    return v;
  }

  Future<Map<String, dynamic>> addRoutine(String title, String instruction, Map<String, Object?> schedule) =>
      _pv('POST', '/routines', {'title': title, 'instruction': instruction, 'schedule': schedule});
  Future<Map<String, dynamic>> addWatch(String title, String kind, Map<String, Object?> spec) =>
      _pv('POST', '/watches', {'title': title, 'kind': kind, 'spec': spec});
  Future<Map<String, dynamic>> setEnabled(String id, bool enabled) => _pv('PATCH', '/proactive/$id', {'enabled': enabled});
  Future<Map<String, dynamic>> removePlan(String id) => _pv('DELETE', '/proactive/$id');
  Future<void> runRoutine(String id) => _request('POST', '/routines/$id/run');
  Future<Map<String, dynamic>> briefSettings({bool? enabled, String? at}) =>
      _pv('PUT', '/brief', {'enabled': ?enabled, 'at': ?at});
  Future<void> briefNow() => _request('POST', '/brief/now');
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
    _http.close(force: true);
    super.dispose();
  }
}


/// An error from Compii Core, worded for people.
class CoreError implements Exception {
  CoreError(this.message);
  final String message;
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

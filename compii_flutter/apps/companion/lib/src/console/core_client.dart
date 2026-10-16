import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Connection to Compii Core, the local service that does the work.
enum CoreStatus { connecting, offline, online }

class TaskView {
  TaskView({required this.id, required this.request, required this.status});
  final String id;
  final String request;
  String status;
  final List<Map<String, dynamic>> events = [];

  factory TaskView.fromJson(Map<String, dynamic> json) {
    final task = TaskView(
      id: json['id'] as String,
      request: json['request'] as String,
      status: json['status'] as String,
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

  List<TaskView> get ordered => tasks.values.toList().reversed.toList();

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

  void _onEvent(Map<String, dynamic> e) {
    final id = e['task_id'] as String;
    final task = tasks.putIfAbsent(
      id,
      () => TaskView(
        id: id,
        request: e['request'] as String? ?? '',
        status: 'running',
      ),
    );
    task.events.add(e);
    if (e['status'] is String) task.status = e['status'] as String;
    notifyListeners();
  }

  Future<dynamic> _request(String method, String path, [Object? body]) async {
    final req = await _http.openUrl(method, Uri.http('$host:$port', path));
    if (_token != null) req.headers.set('X-Compii-Token', _token!);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw HttpException('Core said ${res.statusCode}: $text');
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

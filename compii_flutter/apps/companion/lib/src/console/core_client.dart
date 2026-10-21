import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  bool credentialsFound = true;
  final Map<String, TaskView> tasks = {};

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
      credentialsFound = health['credentials'] != 'not_found';
      if (health['sight'] is Map) {
        final s = Map<String, dynamic>.from(health['sight'] as Map);
        sight.value = {'screen_aware': s['screen_aware'] != false, 'looking': s['looking'] == true};
      }
      if (remote == null) _token = (await tokenFile().readAsString()).trim();
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

  /// Compii's eyes: `screen_aware` (the user's switch) and `looking` (it is reading right now).
  /// The light next to the cursor and the one in this window both come from this, and Core is the
  /// only thing that can say it looked - so it never lights up on a guess.
  final ValueNotifier<Map<String, dynamic>> sight = ValueNotifier(const {'screen_aware': true, 'looking': false});

  void _onEvent(Map<String, dynamic> e) {
    if (e['type'] == 'point') lastPoint.value = e;
    if ('${e['type']}'.startsWith('voice_')) voiceEvents.add(e);
    if (e['type'] == 'voice_sight') {
      sight.value = {'screen_aware': e['screen_aware'] != false, 'looking': e['looking'] == true};
    }
    if (e['type'] == 'device_paired') deviceEvents.add(e);
    if (e['type'] == 'update') {
      updates.add(e);
      unread += 1;
      notifyListeners();
      return;
    }
    final id = e['task_id'];
    if (id is! String || id.isEmpty) return; // not part of a task
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
      req = await _http.openUrl(method, remote == null ? Uri.http('$host:$port', path) : Uri.https('$host:$port', path));
    } on SocketException {
      throw CoreError(remote == null
          ? 'Compii Core isn’t reachable right now. It reconnects by itself once Core is running.'
          : remote!.hosts.any(isOverlayAddress)
              ? 'Can’t reach ${remote!.pc} right now. Check Compii is running on the PC and Tailscale is on, on both.'
              : 'Can’t reach ${remote!.pc} right now. Check the phone is on the same Wi-Fi and Compii is running on the PC.');
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

  Future<void> ask(String request) =>
      _request('POST', '/tasks', {'request': request});
  Future<void> stop(String taskId) => _request('POST', '/tasks/$taskId/stop');
  Future<void> stopAll() => _request('POST', '/stop');
  Future<void> decide(String approvalId, {required bool approved}) =>
      _request('POST', '/approvals/$approvalId', {'approved': approved});

  /// Answer a question Compii asked, from the choices or by typing it.
  Future<void> answerQuestion(String questionId, String text) =>
      _request('POST', '/questions/$questionId/answer', {'text': text});
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
  Future<void> openUrl(String url) => _request('POST', '/open_url', {'path': url});

  /// Put text on the PC's clipboard, ready to paste there.
  Future<void> pushClipboard(String text) => _request('POST', '/clipboard', {'text': text});

  /// A small live picture of the PC's screen (PNG bytes).
  Future<Uint8List> peekScreen({bool full = true}) async {
    final q = {'full': '$full'};
    final HttpClientRequest req;
    try {
      req = await _http.openUrl(
          'GET', remote == null ? Uri.http('$host:$port', '/screen/peek', q) : Uri.https('$host:$port', '/screen/peek', q));
    } on SocketException {
      throw CoreError('Can’t reach ${remote?.pc ?? 'Compii Core'} right now.');
    }
    if (_token != null) req.headers.set('X-Compii-Token', _token!);
    if (remote != null) req.headers.set('X-Compii-Device', remote!.token);
    final res = await req.close();
    final bytes = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d));
    final data = bytes.takeBytes();
    if (res.statusCode >= 400) throw CoreError(_detail(utf8.decode(data, allowMalformed: true), res.statusCode));
    return data;
  }

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
    lastPoint.dispose();
    sight.dispose();
    updates.close();
    voiceEvents.close();
    deviceEvents.close();
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

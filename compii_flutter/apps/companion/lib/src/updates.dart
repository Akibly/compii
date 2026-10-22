import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:velopack_flutter/velopack_flutter.dart';

/// Where an installed build looks for its updates, baked in at build time:
/// `--dart-define=VELOPACK_URL=https://github.com/<you>/<repo>/releases/latest/download/`.
/// A build from source has no feed, and Velopack's own calls throw unless the app was packed by
/// `vpk`, so nothing below is ever constructed and Settings says so plainly instead.
const String updateFeed = String.fromEnvironment('VELOPACK_URL');

/// The launch flags Velopack starts a fresh install or a just-updated app with. The app exists
/// for those moments only: initialise, let Velopack record it, close.
const List<String> veloLaunchHooks = [
  '--veloapp-install',
  '--veloapp-updated',
  '--veloapp-obsolete',
  '--veloapp-uninstall',
];

/// Set while an update is going in. `keepCoreAlive` must not start Core again mid-update:
/// an updater cannot replace a file a running pythonw is holding open.
bool _coreHeldDown = false;
bool get coreHeldDown => _coreHeldDown;
void holdCoreDown(bool on) => _coreHeldDown = on;

final Uri _coreHealth = Uri.parse('http://127.0.0.1:8765/health');

/// Wait until Core has really gone, so the updater can have its files.
Future<void> waitForCoreToClose({Duration wait = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(wait);
  while (DateTime.now().isBefore(deadline)) {
    if (!await _coreIsAnswering()) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  throw StateError('Compii Core did not close, so the update can’t replace its files.');
}

Future<bool> _coreIsAnswering() async {
  final http = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
  try {
    final res = await (await http.getUrl(_coreHealth)).close().timeout(const Duration(seconds: 2));
    await res.drain<void>();
    return res.statusCode == 200;
  } on Object {
    return false;
  } finally {
    http.close(force: true);
  }
}

/// What an installed build can ask its updater to do. Behind an interface so the flow around it —
/// Core stopping first, the buttons in Settings — is testable without a packed release.
abstract class UpdateSource {
  /// The newer version on the feed, or null when there isn't one.
  Future<String?> latest();

  /// Fetch the update, reporting 0–100 as it goes.
  Future<void> download(void Function(int percent) onProgress);

  /// Apply it once this process has exited, and start Compii again.
  Future<void> applyAndRestart();
}

class VelopackSource implements UpdateSource {
  const VelopackSource();

  @override
  Future<String?> latest() async => (await getLatestUpdateInfo())?.targetFullRelease.version;

  @override
  Future<void> download(void Function(int percent) onProgress) async {
    await for (final p in checkAndDownloadUpdatesWithProgress()) {
      onProgress(p);
    }
  }

  @override
  Future<void> applyAndRestart() => waitExitThenUpdate(silent: false, restart: true);
}

enum UpdateStage { current, checking, ready, downloading, applying, problem }

/// The one object Settings asks about updates: what's available, and how to get it.
class Updater extends ChangeNotifier {
  Updater({required this.source, required this.clearTheWay, void Function()? quit})
    : quit = quit ?? _exitApp;

  final UpdateSource source;

  /// Make nothing in the install folder be running: the buddy overlay and Core are both
  /// Compii's own files, and both have to let go before the updater touches them.
  final Future<void> Function() clearTheWay;

  /// How this process ends once the updater is armed. Injectable because a test can't
  /// afford the real one.
  final void Function() quit;

  UpdateStage stage = UpdateStage.current;
  String to = '';
  int percent = 0;
  String problem = '';

  bool get busy => stage == UpdateStage.checking || stage == UpdateStage.downloading || stage == UpdateStage.applying;

  /// Installing is only on the table once a newer version is actually known to be waiting; with
  /// nothing to go at, "Try again" means check again.
  bool get canInstall => stage == UpdateStage.ready || (stage == UpdateStage.problem && to.isNotEmpty);

  Future<void> check() async {
    if (busy) return;
    stage = UpdateStage.checking;
    problem = '';
    notifyListeners();
    try {
      to = await source.latest() ?? '';
      stage = to.isEmpty ? UpdateStage.current : UpdateStage.ready;
    } on Object catch (e) {
      problem = _inWords(e);
      stage = UpdateStage.problem;
    }
    notifyListeners();
  }

  Future<void> install() async {
    if (!canInstall) return;
    problem = '';
    percent = 0;
    stage = UpdateStage.downloading;
    notifyListeners();
    try {
      await source.download((p) {
        percent = p;
        notifyListeners();
      });
      stage = UpdateStage.applying;
      notifyListeners();
      holdCoreDown(true);
      await clearTheWay();
      await source.applyAndRestart();
      quit(); // Velopack takes over the instant this process is gone
    } on Object catch (e) {
      holdCoreDown(false);
      problem = _inWords(e);
      stage = UpdateStage.problem;
      notifyListeners();
    }
  }
}

void _exitApp() => exit(0);

/// Set once the app is packed and Velopack is initialised; null means "this build can't update itself".
Updater? updates;

String _inWords(Object e) {
  final said = '$e'.replaceFirst(RegExp(r'^(Exception|StateError): '), '');
  return said.length > 200 ? '${said.substring(0, 200)}…' : said;
}

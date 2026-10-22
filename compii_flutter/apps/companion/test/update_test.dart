// The update path: what Settings shows, and the one rule — Core must be gone before the
// updater is armed, or it can't replace the files Core is running from.
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/updates.dart';
import 'package:compii/src/ui/pages.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSource implements UpdateSource {
  FakeSource({this.available, this.failsAt = ''});

  final String? available;
  final String failsAt;

  @override
  Future<String?> latest() async {
    if (failsAt == 'check') throw Exception('the update site is not answering');
    return available;
  }

  @override
  Future<void> download(void Function(int percent) onProgress) async {
    if (failsAt == 'download') throw Exception('not enough disk space');
    onProgress(100);
  }
  @override
  Future<void> applyAndRestart() async {}
}

void main() {
  late List<String> went;
  late Updater up;

  anUpdater({String? available, String failsAt = '', Future<void> Function()? stop}) {
    went = [];
    up = Updater(
      source: FakeSource(available: available, failsAt: failsAt),
      clearTheWay: () async {
        went.add('stop');
        if (stop != null) await stop();
      },
      quit: () => went.add('quit'),
    );
  }

  tearDown(() {
    updates = null;
    holdCoreDown(false);
    up.dispose();
  });

  test('checking a feed with nothing newer leaves nothing to install', () async {
    anUpdater();
    await up.check();
    expect(up.stage, UpdateStage.current);
    expect(up.canInstall, isFalse);
  });

  test('Core is stopped before the updater is armed, then Compii closes', () async {
    anUpdater(available: '0.2.0');
    await up.check();
    expect((up.stage, up.to), (UpdateStage.ready, '0.2.0'));
    expect(up.canInstall, isTrue);
    await up.install();
    expect(went, ['stop', 'quit'], reason: 'the updater must not be armed while Core holds its files');
    expect(coreHeldDown, isTrue, reason: 'the watchdog must not start Core again mid-update');
  });

  test('a Core that won’t close stops the update and says why', () async {
    anUpdater(
      available: '0.2.0',
      stop: () async => throw StateError('Compii Core did not close, so the update can’t replace its files.'),
    );
    await up.check();
    await up.install();
    expect(up.stage, UpdateStage.problem);
    expect(up.problem, contains('did not close'));
    expect(went, ['stop'], reason: 'no quit: Compii stays open, on the version it has');
    expect(coreHeldDown, isFalse, reason: 'with no update going in, Core may be started again');
  });

  test('a download that fails leaves the update on the table', () async {
    anUpdater(available: '0.2.0', failsAt: 'download');
    await up.check();
    await up.install();
    expect(up.stage, UpdateStage.problem);
    expect(up.problem, 'not enough disk space');
    expect(up.canInstall, isTrue, reason: '0.2.0 is still waiting, so trying again means installing');
    expect(went, isEmpty, reason: 'Compii stayed open and Core was never asked to close');
  });

  test('a feed that doesn’t answer is reported, not thrown', () async {
    anUpdater(failsAt: 'check');
    await up.check();
    expect(up.stage, UpdateStage.problem);
    expect(up.problem, 'the update site is not answering');
    expect(up.canInstall, isFalse,
        reason: 'nothing is known to be waiting, so Try again must re-check rather than install');
  });

  testWidgets('Settings shows the version and offers what is waiting', (tester) async {
    const size = Size(1000, 700);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    anUpdater(available: '0.2.0');
    updates = up;
    await up.check();
    final core = CoreClient()..coreVersion = '0.1.0';
    addTearDown(core.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: AboutCard(core: core)),
    ));
    expect(find.textContaining('Compii Core 0.1.0. Version 0.2.0 is waiting.'), findsOneWidget);
    expect(find.text('Update and restart'), findsOneWidget);

    await tester.tap(find.text('Update and restart'));
    await tester.pump();
    expect(find.textContaining('putting version 0.2.0 in place'), findsOneWidget);
    expect(went, ['stop', 'quit']);
  });

  testWidgets('a build from source says plainly that it can’t update itself', (tester) async {
    const size = Size(1000, 700);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    anUpdater();
    final core = CoreClient()..coreVersion = '0.1.0';
    addTearDown(core.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: AboutCard(core: core)),
    ));
    expect(find.textContaining('wasn’t installed with Compii’s installer'), findsOneWidget);
    expect(find.text('Update and restart'), findsNothing);
    expect(find.text('Check again'), findsNothing);
  });
}

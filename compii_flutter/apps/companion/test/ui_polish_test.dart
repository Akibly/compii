// The matrix the 21 October audit said was uncovered: keyboard activation on
// controls that only answered the mouse, layout at enlarged text, motion that
// stops when Windows asks for it, and a failed fetch that says so.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/chrome.dart';
import 'package:compii/src/ui/first_run.dart';
import 'package:compii/src/ui/palette.dart';
import 'package:compii/src/ui/phone_home.dart';
import 'package:compii/src/ui/phone_voice.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _capturing = bool.fromEnvironment('CAPTURE');

Future<void> _loadFonts(WidgetTester tester) async {
  await tester.runAsync((FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load);
  for (final family in ['Segoe UI Variable Text', 'Segoe UI Variable Display', 'Roboto']) {
    final loader = FontLoader(family);
    final file = File('C:/Windows/Fonts/SegUIVar.ttf');
    if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await tester.runAsync(loader.load);
  }
}

Widget _host(Widget child, {Size size = const Size(1200, 800), double scale = 1.0, bool still = true}) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), disableAnimations: still),
    child: Scaffold(body: child),
  ),
);

void _noop() {}

void main() {
  group('keyboard reaches what the mouse reaches', () {
    testWidgets('Tab then Enter activates a Keyable control', (tester) async {
      var fires = 0;
      await tester.pumpWidget(_host(Keyable(label: 'Send what you said', onTap: () => fires++, child: const SizedBox(width: 120, height: 40))));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fires, 1, reason: 'Enter activates a control the pointer could already use');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(fires, 2, reason: 'Space activates it too');
    });

    testWidgets('a Keyable with nothing to do is not a tab stop', (tester) async {
      final focus = FocusNode();
      await tester.pumpWidget(_host(
        Column(
          children: [
            Keyable(label: 'Disabled chip', onTap: null, child: const SizedBox(width: 120, height: 40)),
            Focus(focusNode: focus, child: const SizedBox(width: 1, height: 1)),
          ],
        ),
      ));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue, reason: 'the dead control is skipped, not stopped at');
    });

    testWidgets('the control is announced as a button in its own words', (tester) async {
      const tag = Key('teamrow');
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(
        const Keyable(key: tag, label: 'Researcher, your inbox', onTap: _noop, child: SizedBox(width: 120, height: 40)),
      ));
      expect(
        tester.getSemantics(find.byKey(tag)),
        matchesSemantics(
          label: 'Researcher, your inbox',
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          // A plain button says nothing about selection; only a control that
          // toggles takes the `selected:` argument.
          hasSelectedState: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('the focus ring is the theme accent and costs no layout', (tester) async {
      await tester.pumpWidget(_host(Keyable(label: 'Say it', onTap: () {}, child: const SizedBox(width: 120, height: 44))));
      final before = tester.getSize(find.byType(Keyable));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Keyable)), before, reason: 'a ring must not shove the control when it appears');
    });
  });

  group('reading sizes', () {
    testWidgets('the page gutter gives the width back at large text', (tester) async {
      double? gutter;
      await tester.pumpWidget(_host(
        Builder(builder: (context) {
          gutter = Space.gutter(context);
          return const SizedBox();
        }),
        scale: 2.0,
      ));
      expect(gutter, Space.l, reason: '16, not 40: big text needs the margin back');
    });

    testWidgets('the page gutter stays generous at normal text', (tester) async {
      double? gutter;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        gutter = Space.gutter(context);
        return const SizedBox();
      })));
      expect(gutter, 40);
    });

    testWidgets('every duration stops when animations are off', (tester) async {
      late Duration moved;
      late bool quiet;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        moved = context.motion(Motion.page);
        quiet = context.still;
        return const SizedBox();
      })));
      expect(moved, Duration.zero);
      expect(quiet, isTrue);
      await tester.pumpWidget(_host(Builder(builder: (context) {
        moved = context.motion(Motion.page);
        return const SizedBox();
      }), still: false));
      expect(moved, const Duration(milliseconds: Motion.page));
    });
  });

  testWidgets('AdaptiveRow stacks instead of clipping at big text', (tester) async {
    await tester.pumpWidget(_host(
      Center(
        child: SizedBox(
          width: 500,
          child: AdaptiveRow(
            breakpoint: 400,
            children: [Expanded(child: Text('Autonomy', style: TextStyle(fontSize: 14))), TextButton(onPressed: () {}, child: Text('Always ask'))],
          ),
        ),
      ),
      scale: 2.0,
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(Column), findsWidgets);
  });

  testWidgets('a failed load offers retry rather than a permanent wait', (tester) async {
    var retries = 0;
    await tester.pumpWidget(_host(Center(child: LoadFailure(onRetry: () => retries++))));
    expect(find.text('Could not refresh this page. Try again.'), findsOneWidget);
    // The callback directly: a tap would load Flutter's ink-sparkle shader,
    // which this SDK cannot verify in tests.
    tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed!.call();
    expect(retries, 1);
  });

  group('the palette walks both ways and grows with the text', () {
    Widget host(CoreClient core, AppState state) => MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showCommandPalette(
                context: context,
                core: core,
                state: state,
                run: (action) => action(),
                search: (query) async => {'groups': []},
              ),
              child: const Text('open palette'),
            ),
          ),
        ),
      ),
    );

    Future<void> open(WidgetTester tester, CoreClient core, AppState state) async {
      await tester.pumpWidget(host(core, state));
      tester.widget<TextButton>(find.byType(TextButton)).onPressed!.call();
      await tester.pumpAndSettle();
    }

    testWidgets('Tab walks the highlight down, Shift+Tab walks it back', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final core = CoreClient(host: '127.0.0.1', port: 8765)..status = CoreStatus.online;

      // Each run starts from an unopened palette, so the highlight begins on the
      // first row. Doing nothing would leave it there — which is exactly what the
      // old test could not tell apart from working keys.
      Future<Section> walk(int tabs, {int backTabs = 0}) async {
        final state = AppState();
        await open(tester, core, state);
        for (var i = 0; i < tabs; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        }
        for (var i = 0; i < backTabs; i++) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        }
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        return state.section;
      }

      expect(await walk(2), Section.updates, reason: 'two Tabs reach the third row');
      expect(await walk(2, backTabs: 1), Section.team, reason: 'Shift+Tab goes back, not on');
    });

    testWidgets('a row grows with the text instead of clipping it', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final core = CoreClient(host: '127.0.0.1', port: 8765)..status = CoreStatus.online;
      core.tasks['t1'] = TaskView(id: 't1', request: 'Send the invoice to Sam and copy the ledger', status: 'done');
      final state = AppState();
      await tester.pumpWidget(MaterialApp(
        theme: compiiTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2.0)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCommandPalette(
                  context: context,
                  core: core,
                  state: state,
                  run: (action) => action(),
                  search: (query) async => {'groups': []},
                ),
                child: const Text('open palette'),
              ),
            ),
          ),
        ),
      ));
      tester.widget<TextButton>(find.byType(TextButton)).onPressed!.call();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'invoice');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'double-size text must not overflow a result row');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.textContaining('Send the invoice to Sam'), findsOneWidget);
    });
  });

  group('the phone says two things at once without colliding', () {
    Future<PhoneVoice> phone(WidgetTester tester, AppState state, CoreClient core) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(400, 860));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const fp = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12';
      core.remote = const RemoteLink(host: '192.168.1.20', port: 8766, fingerprint: fp, token: 't', pc: 'Desk', hosts: ['192.168.1.20']);
      final voice = PhoneVoice(core);
      await tester.pumpWidget(MaterialApp(
        theme: compiiTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 860), padding: EdgeInsets.only(top: 47, bottom: 34), disableAnimations: true),
          child: PhoneHome(core: core, state: state, voice: voice, onForget: () async {}),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      return voice;
    }

    testWidgets('a failure stacks above the live caption instead of painting over it', (tester) async {
      final core = CoreClient()..status = CoreStatus.online;
      final state = AppState();
      final voice = await phone(tester, state, core);
      voice.listening = true;
      voice.partial = 'send the invoice';
      state.fail('Core unreachable');
      await tester.pump();

      final caption = tester.getRect(find.text('send the invoice'));
      final problem = tester.getRect(find.textContaining('Core unreachable'));
      expect(caption.bottom <= problem.top || problem.bottom <= caption.top, isTrue,
          reason: 'the caption and the failure never share the same pixels');
    });

    testWidgets('the notch is consumed once, not once per banner', (tester) async {
      final core = CoreClient()..status = CoreStatus.online;
      core.unauthorized = true;
      final state = AppState();
      await phone(tester, state, core);
      final banner = tester.getRect(find.textContaining('was removed'));
      expect(banner.top, greaterThanOrEqualTo(47), reason: 'one safe area, at the body edge');
      expect(banner.top, lessThan(47 + 80), reason: 'banners stack on each other, not on another notch');
    });
  });

  group('setup fits a small window and big text', () {
    const preview = {
      'brain': <String, dynamic>{'keys': {'groq': false, 'nvidia': false}},
      'voice': <String, dynamic>{
        'listen_ready': true,
        'natural_voice': true,
        'voices': {'compii_warm': 'Compii (warm)'},
        'settings': {'voice': 'compii_warm', 'cloud_listening': true, 'see_pictures': true},
      },
    };

    Future<void> step(WidgetTester tester, int i, {Size size = const Size(1100, 820), double scale = 1.0}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: compiiTheme(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), disableAnimations: true),
          child: FirstRun(core: CoreClient(), voice: null, onDone: () async {}, initialStep: i, preview: preview),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('every step survives 360px at double text', (tester) async {
      for (var i = 0; i < 5; i++) {
        await step(tester, i, size: const Size(360, 760), scale: 2.0);
        expect(tester.takeException(), isNull, reason: 'setup step $i');
      }
    });

    testWidgets('only one step is marked as the one you are on', (tester) async {
      await step(tester, 2, size: const Size(360, 760), scale: 2.0);
      expect(find.text('Now'), findsOneWidget, reason: 'the current step is named in words, not only in colour');
    });

    testWidgets('waiting on the person is not drawn as working', (tester) async {
      await step(tester, 3);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'nothing is running while setup waits for you to speak');
    });
  });

  if (_capturing) {
    // Widget renders of the surfaces this pass changed, written beside — never
    // inside — the historical v4 folder. They are renders, not device photos.
    testWidgets('renders the states this pass fixed, for an eye check', (tester) async {
      await _loadFonts(tester);
      final frame = GlobalKey();
      Future<void> show(Widget home, Size size, {double scale = 1.0, Brightness brightness = Brightness.light}) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(RepaintBoundary(
          key: frame,
          child: MaterialApp(
            key: UniqueKey(),
            debugShowCheckedModeBanner: false,
            theme: compiiTheme(Brightness.light),
            darkTheme: compiiTheme(Brightness.dark),
            themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
            home: MediaQuery(
              data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), disableAnimations: true),
              child: home,
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull, reason: 'capture lays out');
      }
      Future<void> shot(GlobalKey frame, String name) async {
        final boundary = frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(boundary.toImage))!;
        final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
        final out = Directory('../../../docs/compii/build-previews/polish-2026-10')..createSync(recursive: true);
        await tester.runAsync(() => File('${out.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
        image.dispose();
      }

      const preview = {
        'brain': <String, dynamic>{'keys': {'groq': false, 'nvidia': false}},
        'voice': <String, dynamic>{
          'listen_ready': true,
          'natural_voice': true,
          'voices': {'compii_warm': 'Compii (warm)', 'compii_calm': 'Compii (calm)'},
          'settings': {'voice': 'compii_warm', 'cloud_listening': true, 'see_pictures': true},
        },
      };
      Widget setup(int step) => FirstRun(core: CoreClient(), voice: null, onDone: () async {}, initialStep: step, preview: preview);
      await show(setup(2), const Size(1100, 820));
      await shot(frame, 'onboarding-voice');
      await show(setup(2), const Size(360, 760), scale: 2.0);
      await shot(frame, 'onboarding-voice-2x');

      SharedPreferences.setMockInitialValues({});
      final core = CoreClient()..status = CoreStatus.online;
      core.tasks['t1'] = TaskView(id: 't1', request: 'Send the invoice to Sam and copy the ledger', status: 'done');
      final state = AppState();
      await show(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCommandPalette(context: context, core: core, state: state, run: (a) => a(), search: (q) async => {'groups': []}),
                child: const Text('open palette'),
              ),
            ),
          ),
        ),
        const Size(1100, 820),
        scale: 2.0,
      );
      tester.widget<TextButton>(find.byType(TextButton)).onPressed!.call();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'invoice');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      await shot(frame, 'palette-2x');

      final phoneCore = CoreClient()
        ..status = CoreStatus.online
        ..remote = const RemoteLink(host: '192.168.1.20', port: 8766, fingerprint: 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12', token: 't', pc: 'Desk', hosts: ['192.168.1.20']);
      final voice = PhoneVoice(phoneCore)
        ..listening = true
        ..partial = 'send the invoice';
      state.fail('Core unreachable');
      await show(PhoneHome(core: phoneCore, state: state, voice: voice, onForget: () async {}), const Size(400, 860), brightness: Brightness.dark);
      await shot(frame, 'phone-caption-and-problem-dark');
      tester.view.reset();
    });
  }
}

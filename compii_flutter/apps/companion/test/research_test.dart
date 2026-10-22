import 'package:compii/src/ui/research.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1000, 1200), disableAnimations: true),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 720,
              child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      ),
    );

Map<String, dynamic> _platform({
  String name = 'GitHub',
  bool live = true,
  bool login = false,
  String needs = '',
  String fix = '',
  List<String> verbs = const ['code', 'search'],
}) =>
    {
      'platform': 'github',
      'name': name,
      'login': login,
      'verbs': verbs,
      'live': live,
      'needs': needs,
      'fix': fix,
    };

void main() {
  testWidgets('a platform that answers lists the read-only things it does', (tester) async {
    await tester.pumpWidget(_app(ResearchPlatformCard(platform: _platform())));

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('answers'), findsOneWidget);
    expect(find.textContaining('Reads: code, search'), findsOneWidget);
    expect(find.byTooltip('Copy what to install or turn on'), findsNothing);
  });

  testWidgets('a platform waiting on the browser session says so and offers the fix', (tester) async {
    String? copied;
    await tester.pumpWidget(_app(ResearchPlatformCard(
      platform: _platform(
        name: 'X / Twitter',
        live: false,
        login: true,
        needs: 'browser session is off',
        fix: 'install the OpenCLI browser extension, then turn on “use my browser session”',
        verbs: const ['search'],
      ),
      onCopyFix: (fix) => copied = fix,
    )));

    expect(find.text('quiet'), findsOneWidget);
    expect(find.text('your session'), findsOneWidget);
    expect(find.textContaining('Your browser session is off for it.'), findsOneWidget);
    expect(find.textContaining('Would read: search.'), findsOneWidget);
    expect(find.textContaining('OpenCLI browser extension'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy what to install or turn on'));
    expect(copied, contains('OpenCLI browser extension'));
  });

  testWidgets('a tool that simply is not installed is named as not ready', (tester) async {
    await tester.pumpWidget(_app(ResearchPlatformCard(
      platform: _platform(
        name: 'Bilibili',
        live: false,
        needs: 'no command line tool installed',
        fix: 'pipx install bilibili-cli',
        verbs: const ['search'],
      ),
    )));

    expect(find.textContaining('Not ready on this PC'), findsOneWidget);
    expect(find.text('pipx install bilibili-cli'), findsOneWidget);
    expect(find.text('your session'), findsNothing);
  });
}

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/palette.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host({
  required CoreClient core,
  required AppState state,
  required PaletteSearch search,
}) =>
    MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showCommandPalette(context: context, core: core, state: state,
                  run: (action) => action(), search: search),
              child: const Text('open palette'),
            ),
          ),
        ),
      ),
    );

void _open(WidgetTester tester) {
  // Call the callback directly: Material's ink sparkle loads a shader this SDK
  // can't decode in tests.
  tester.widget<TextButton>(find.byType(TextButton)).onPressed!.call();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

Future<Map<String, dynamic>> _empty(String query) async => {'groups': []};

void main() {
  testWidgets('the palette finds a conversation and opens it with the keyboard', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final core = CoreClient(host: '127.0.0.1', port: 8765)..status = CoreStatus.online;
    core.tasks['t1'] = TaskView(id: 't1', request: 'Send the invoice to Sam', status: 'done');
    final state = AppState();

    await tester.pumpWidget(_host(core: core, state: state, search: _empty));
    _open(tester);
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Updates'), findsOneWidget);

    await _type(tester, 'invoice');
    expect(find.text('Send the invoice to Sam'), findsOneWidget);
    expect(find.text('Ask Compii “invoice”'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(state.selected, 't1');
    expect(state.section, Section.chat);
  });

  testWidgets('a page can be reached by typing part of its name', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final core = CoreClient(host: '127.0.0.1', port: 8765)..status = CoreStatus.online;
    final state = AppState();

    await tester.pumpWidget(_host(core: core, state: state, search: _empty));
    _open(tester);
    await tester.pumpAndSettle();

    await _type(tester, 'clip');
    expect(find.text('Clips'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(state.section, Section.clips);
  });

  testWidgets('matches from the PC are grouped, open where they live, and can be clicked', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final core = CoreClient(host: '127.0.0.1', port: 8765)..status = CoreStatus.online;
    final state = AppState();
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    Future<Map<String, dynamic>> found(String query) async => {
      'query': query,
      'groups': [
        {
          'kind': 'conversations',
          'label': 'Conversations',
          'total': 1,
          'items': [
            {'kind': 'conversation', 'id': 't9', 'title': 'Quarterly invoice review',
              'subtitle': 'Compii · done', 'when': now - 3600},
          ],
        },
        {
          'kind': 'memory',
          'label': 'Memory',
          'total': 1,
          'items': [
            {'kind': 'memory', 'id': 0, 'title': 'Invoices go to accounts@acme.test',
              'subtitle': 'Saved memory', 'when': now - 7200},
          ],
        },
        {
          'kind': 'clips',
          'label': 'Clips',
          'total': 1,
          'items': [
            {'kind': 'clip', 'id': 4, 'title': 'Invoice INV-88 for 320',
              'subtitle': 'Copied from Outlook', 'when': now - 60},
          ],
        },
      ],
    };

    await tester.pumpWidget(_host(core: core, state: state, search: found));
    _open(tester);
    await tester.pumpAndSettle();

    await _type(tester, 'invoice');
    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(find.text('MEMORY'), findsOneWidget);
    expect(find.text('CLIPS'), findsOneWidget);
    expect(find.text('Quarterly invoice review'), findsOneWidget);
    expect(find.textContaining('Saved · 2h'), findsOneWidget);

    // Enter opens the first real result, not a group title.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(state.section, Section.chat);
    expect(state.selected, 't9');

    // A remembered fact takes the user to Memory with that fact called out.
    _open(tester);
    await tester.pumpAndSettle();
    await _type(tester, 'invoice');
    await tester.tap(find.text('Invoices go to accounts@acme.test'));
    await tester.pumpAndSettle();
    expect(state.section, Section.memory);
    expect(state.focusKind, 'memory');
    expect(state.focusId, '0');

    // A clip opens Clips already filtered to what was typed.
    _open(tester);
    await tester.pumpAndSettle();
    await _type(tester, 'invoice');
    await tester.tap(find.text('Invoice INV-88 for 320'));
    await tester.pumpAndSettle();
    expect(state.section, Section.clips);
    expect(state.focusKind, 'clip');
    expect(state.focusQuery, 'invoice');
    expect(state.focusTab, 'history');
  });
}

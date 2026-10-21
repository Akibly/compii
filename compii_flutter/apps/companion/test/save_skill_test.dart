import 'dart:async';

import 'package:compii/src/ui/tokens.dart';
import 'package:compii/src/ui/trust.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(String, String)?> open(WidgetTester tester, Completer<Map<String, dynamic>> draft) async {
    (String, String)? picked;
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => picked = await showDialog<(String, String)>(
            context: context,
            builder: (_) => SaveSkillDialog(request: 'put these in order please', draft: () => draft.future),
          ),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    return picked;
  }

  testWidgets('asks for a name, offers one that fits, and warns before replacing', (tester) async {
    final draft = Completer<Map<String, dynamic>>();
    await open(tester, draft);
    expect(find.text('What should this skill be called?'), findsOneWidget);
    expect(find.text('Put these in order please'), findsOneWidget);
    expect(find.textContaining('suggesting a name'), findsOneWidget);

    draft.complete({
      'name': 'Weekly invoice sort',
      'about': 'Sorts invoices into month folders.',
      'steps': ['List Downloads', 'Move 3 files'],
      'names': ['Morning brief'],
    });
    await tester.pump();
    expect(find.text('Weekly invoice sort'), findsOneWidget);
    expect(find.text('Sorts invoices into month folders.'), findsOneWidget);
    expect(find.text('1. List Downloads'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'morning BRIEF');
    await tester.pump();
    expect(find.textContaining('You already have “Morning brief”'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    final save = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(save.onPressed, isNull);
  });

  testWidgets('a name the user typed is not overwritten by a late suggestion', (tester) async {
    final draft = Completer<Map<String, dynamic>>();
    await open(tester, draft);
    await tester.enterText(find.byType(TextField).first, 'Invoice tidy');
    draft.complete({'name': 'Weekly invoice sort', 'about': '', 'steps': [], 'names': []});
    await tester.pump();
    expect(find.text('Invoice tidy'), findsOneWidget);
    expect(find.text('Weekly invoice sort'), findsNothing);
  });
}

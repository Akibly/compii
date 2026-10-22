import 'package:compii/src/ui/library.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1200, 1400), disableAnimations: true),
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

Map<String, dynamic> _skill({String status = 'pending'}) => {
      'id': 'i1',
      'kind': 'skill',
      'format': 'claude-skill',
      'name': 'PDF Tools',
      'about': 'Fill and merge PDF forms.',
      'status': status,
      'source': r'C:\Users\me\Downloads\pdf-tools',
      'files': ['SKILL.md', 'scripts/fill.py'],
      'scan': [
        {'level': 'warn', 'what': 'Includes code (scripts/fill.py). Compii treats it as reference and never runs it.'},
        {'level': 'info', 'what': 'No instruction hijacking, secret requests or scripts found.'},
      ],
      'skill': {
        'instruction': 'Fill and merge PDF forms.',
        'body': '# PDF Tools\n\nUse pdfplumber to read fields.\n\n1. Open the form.\n2. Fill every field.',
        'truncated': false,
      },
      'has_secret': false,
      'tool_names': const <String>[],
      'folder': r'C:\Compii\library\i1\files',
    };

Map<String, dynamic> _connector({String status = 'pending'}) => {
      'id': 'i2',
      'kind': 'connector',
      'format': 'openapi',
      'name': 'Pet Store',
      'about': 'Everything about pets.',
      'status': status,
      'source': 'https://api.example.com/v1',
      'files': ['pets.json'],
      'scan': [
        {'level': 'warn', 'what': 'api.example.com is on your local network. Turn on local network access at approval if that is intended.'},
      ],
      'skill': const <String, dynamic>{},
      'connector': {
        'url': 'http://192.168.1.20:8080/v1',
        'tools': [
          {'name': 'listPets', 'description': 'List pets'},
          {'name': 'addPet', 'description': 'Add a pet'},
        ],
      },
      'has_secret': true,
      'tool_names': ['conn_pet_store_list_pets', 'conn_pet_store_add_pet'],
      'folder': '',
    };

void main() {
  testWidgets('a catalogue result says what it is and hands the choice to the user', (tester) async {
    var added = 0;
    var opened = 0;
    await tester.pumpWidget(_app(CatalogResultCard(
      row: {
        'id': 'mcp:ai.acme/calendar@2.1.0',
        'kind': 'connector',
        'catalogue': 'MCP registry',
        'name': 'Calendar',
        'about': 'Books meetings and reads your agenda.',
        'homepage': 'https://github.com/acme/calendar',
        'addable': true,
        'needs_key': true,
        'why': '',
      },
      busy: false,
      staged: false,
      onAdd: () => added++,
      onOpen: () => opened++,
    )));

    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('MCP registry'), findsOneWidget);
    expect(find.text('Wants a key'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.tap(find.byType(IconButton));
    expect(added, 1);
    expect(opened, 1);
  });

  testWidgets('a catalogue result Compii cannot fetch explains why instead of offering Add', (tester) async {
    await tester.pumpWidget(_app(CatalogResultCard(
      row: {
        'id': 'mcp:ai.acme/desktop@1',
        'kind': 'connector',
        'catalogue': 'MCP registry',
        'name': 'Desktop thing',
        'about': '',
        'homepage': '',
        'addable': false,
        'needs_key': false,
        'why': 'This one is meant to run as a program on your PC. Compii only connects to servers that '
            'live somewhere else.',
      },
      busy: false,
      staged: false,
    )));

    expect(find.text('Add'), findsNothing);
    expect(find.textContaining('run as a program'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('a catalogue result already imported stops offering a second copy', (tester) async {
    await tester.pumpWidget(_app(CatalogResultCard(
      row: {'id': 'skill:anthropics/skills/pdf', 'kind': 'skill', 'catalogue': 'skills.sh', 'name': 'pdf',
            'detail': 'anthropics/skills · 214,612 installs', 'addable': true, 'why': ''},
      busy: false,
      staged: true,
    )));

    expect(find.text('Add'), findsNothing);
    expect(find.text('In the review list'), findsOneWidget);
    expect(find.textContaining('214,612 installs'), findsOneWidget);
  });

  testWidgets('a pending connector that wants a key offers to take one now', (tester) async {
    var keyed = 0;
    final item = _connector()
      ..['has_secret'] = false
      ..['connector'] = {
        'url': 'https://mcp.acme.test/mcp',
        'auth': {'scheme': 'bearer', 'supported': true},
        'tools': const <String>[],
      };
    await tester.pumpWidget(_app(PendingLibraryCard(item: item, onKey: () => keyed++)));

    expect(find.textContaining('This one asks for a key'), findsOneWidget);
    await tester.tap(find.text('Add key'));
    expect(keyed, 1);
  });

  testWidgets('a pending connector that already has its key asks for nothing', (tester) async {
    final item = _connector()
      ..['connector'] = {
        'url': 'https://mcp.acme.test/mcp',
        'auth': {'scheme': 'bearer', 'supported': true},
        'tools': const <String>[],
      };
    await tester.pumpWidget(_app(PendingLibraryCard(item: item)));
    expect(find.text('Add key'), findsNothing);
  });

  testWidgets('a pending skill shows exactly what was found and what it keeps', (tester) async {
    var approved = 0;
    var rejected = 0;
    await tester.pumpWidget(_app(PendingLibraryCard(
      item: _skill(),
      onApprove: () => approved++,
      onReject: () => rejected++,
    )));

    expect(find.text('PDF Tools'), findsOneWidget);
    expect(find.text('Claude skill'), findsOneWidget);
    expect(find.textContaining('Includes code'), findsOneWidget);
    expect(find.textContaining('Reference files stay'), findsNothing);
    expect(find.text('SKILL.md'), findsOneWidget);
    expect(find.text('scripts/fill.py'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Turn down'), findsOneWidget);
    expect(find.text('Read it'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.tap(find.text('Turn down'));
    expect(approved, 1);
    expect(rejected, 1);
  });

  testWidgets('a dangerous import is offered as “Approve anyway”', (tester) async {
    final item = _skill()
      ..['scan'] = [
        {'level': 'danger', 'what': 'Tries to give Compii new instructions: “ignore all previous instructions”.'},
      ];
    await tester.pumpWidget(_app(PendingLibraryCard(item: item)));
    expect(find.text('Approve anyway'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('a local connector asks before allowing a private address', (tester) async {
    bool? allowed;
    await tester.pumpWidget(_app(PendingLibraryCard(
      item: _connector(),
      allowPrivate: false,
      onAllowPrivate: (on) => allowed = on,
    )));

    expect(find.text('Pet Store'), findsOneWidget);
    expect(find.text('OpenAPI connector'), findsOneWidget);
    expect(find.text('2 tools'), findsOneWidget);
    expect(find.text('listPets'), findsOneWidget);
    expect(find.text('Allow this server on my own network'), findsOneWidget);
    expect(find.textContaining('192.168.1.20'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    expect(allowed, isTrue);
  });

  testWidgets('a live connector shows its state and offers key and power controls', (tester) async {
    var toggled = 0;
    var keyed = 0;
    var removed = 0;
    await tester.pumpWidget(_app(ReadyLibraryCard(
      item: _connector(status: 'approved'),
      onToggle: () => toggled++,
      onKey: () => keyed++,
      onRemove: () => removed++,
    )));

    expect(find.text('On'), findsOneWidget);
    expect(find.text('Key saved'), findsOneWidget);
    expect(find.textContaining('conn_pet_store_list_pets'), findsOneWidget);
    expect(find.text('Turn off'), findsOneWidget);
    expect(find.text('Replace key'), findsOneWidget);

    await tester.tap(find.text('Turn off'));
    await tester.tap(find.text('Replace key'));
    await tester.tap(find.text('Remove'));
    expect(toggled, 1);
    expect(keyed, 1);
    expect(removed, 1);
  });

  testWidgets('a disabled skill says Off and can be turned back on', (tester) async {
    await tester.pumpWidget(_app(ReadyLibraryCard(item: _skill(status: 'disabled'))));
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.textContaining('Reference files stay'), findsOneWidget);
  });
}

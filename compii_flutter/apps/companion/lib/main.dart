import 'package:flutter/material.dart';

import 'src/console/console_screen.dart';
import 'src/console/core_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final core = CoreClient()..start();
  runApp(
    MaterialApp(
      title: 'Compii',
      debugShowCheckedModeBanner: false,
      theme: consoleTheme(),
      home: ConsoleScreen(core: core),
    ),
  );
}

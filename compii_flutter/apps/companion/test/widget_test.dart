import 'package:compii/src/app.dart';
import 'package:compii/src/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  test(
    'fresh install uses face; concurrent changes persist the latest choice',
    () async {
      final preferences = CompanionPreferences(SharedPreferencesAsync());
      await preferences.load();
      expect(preferences.presentation, Presentation.face);
      final first = preferences.update(view: Presentation.fullBody);
      final last = preferences.update(view: Presentation.face, reduce: true);
      await Future.wait([first, last]);
      final restored = CompanionPreferences(SharedPreferencesAsync());
      await restored.load();
      expect(restored.presentation, Presentation.face);
      expect(restored.reducedMotion, isTrue);
    },
  );
  testWidgets('phone switching preserves expression and is reversible', (
    tester,
  ) async {
    final preferences = CompanionPreferences(SharedPreferencesAsync());
    await preferences.update(reduce: true);
    await tester.pumpWidget(CompiiApp(preferences: preferences));
    await tester.tap(find.byTooltip('Open phone preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show full body'));
    await tester.pumpAndSettle();
    expect(preferences.presentation, Presentation.fullBody);
    await tester.tap(find.text('Rest Wisp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show face'));
    await tester.pumpAndSettle();
    expect(find.text('Wake Wisp'), findsOneWidget);
    await tester.tap(find.byTooltip('Exit phone preview'));
    await tester.pumpAndSettle();
    expect(find.text('Your Wisp'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('compact view supports large text without layout exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = CompanionPreferences(SharedPreferencesAsync());
    await preferences.update(reduce: true);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: CompanionHome(preferences: preferences),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

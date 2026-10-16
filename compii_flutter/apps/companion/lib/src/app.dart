import 'package:flutter/material.dart';
import 'preferences.dart';
import 'wisp.dart';

class CompiiApp extends StatelessWidget {
  const CompiiApp({super.key, required this.preferences});
  final CompanionPreferences preferences;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Compii',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: ivory,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6C3BA8),
        surface: ivory,
        onSurface: plum,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: ivory,
        foregroundColor: plum,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    ),
    home: CompanionHome(preferences: preferences),
  );
}

class CompanionHome extends StatefulWidget {
  const CompanionHome({super.key, required this.preferences});
  final CompanionPreferences preferences;
  @override
  State<CompanionHome> createState() => _CompanionHomeState();
}

class _CompanionHomeState extends State<CompanionHome>
    with WidgetsBindingObserver {
  WispExpression expression = WispExpression.curious;
  CompanionMode mode = CompanionMode.teach;
  bool immersive = false;
  bool active = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() => active = state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.preferences,
    builder: (context, _) {
      final prefs = widget.preferences;
      final reduce =
          prefs.reducedMotion || MediaQuery.disableAnimationsOf(context);
      return PopScope(
        canPop: !immersive,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && immersive) setState(() => immersive = false);
        },
        child: Scaffold(
          appBar: immersive
              ? null
              : AppBar(
                  title: const Text(
                    'Compii',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  actions: [
                    TextButton.icon(
                      onPressed: () => showAboutDialog(
                        context: context,
                        applicationName: 'Compii',
                        applicationVersion: '0.1 · Character preview',
                        children: [
                          const Text(
                            'Meet Wisp and choose how your companion appears. AI, voice, pairing and computer control are not connected in this build.',
                          ),
                        ],
                      ),
                      icon: const Icon(Icons.info_outline),
                      label: const Text('About'),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
          body: SafeArea(
            child: immersive
                ? _stage(prefs, reduce, fullScreen: true)
                : LayoutBuilder(
                    builder: (context, box) {
                      final wide =
                          box.maxWidth >= 900 &&
                          MediaQuery.textScalerOf(context).scale(16) < 25;
                      return SingleChildScrollView(
                        padding: EdgeInsets.all(wide ? 32 : 20),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1400),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'A little presence.\nA world of possibility.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -.7,
                                      ),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Meet Wisp. Make Compii feel like your companion.',
                                  style: TextStyle(fontSize: 17),
                                ),
                                const SizedBox(height: 28),
                                if (prefs.error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: Text(
                                      prefs.error!,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                  ),
                                if (wide)
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        flex: 7,
                                        child: Column(
                                          children: [
                                            SizedBox(
                                              height: 430,
                                              child: _stage(prefs, reduce),
                                            ),
                                            const SizedBox(height: 20),
                                            _modeSelector(),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 36),
                                      Expanded(
                                        flex: 4,
                                        child: _settings(prefs),
                                      ),
                                    ],
                                  )
                                else ...[
                                  SizedBox(
                                    height: box.maxWidth > 500 ? 360 : 300,
                                    child: _stage(prefs, reduce),
                                  ),
                                  const SizedBox(height: 24),
                                  _modeSelector(),
                                  const SizedBox(height: 32),
                                  _settings(prefs),
                                ],
                                const SizedBox(height: 32),
                                const Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Icon(Icons.lock_outline, size: 16),
                                    Text(
                                      'Local preview · Microphone off · No screen capture',
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      );
    },
  );

  Widget _stage(
    CompanionPreferences prefs,
    bool reduce, {
    bool fullScreen = false,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(fullScreen ? 0 : 24),
    child: ColoredBox(
      color: const Color(0xFF291736),
      child: Stack(
        children: [
          Positioned.fill(
            child: Wisp(
              presentation: prefs.presentation,
              expression: expression,
              animate: !reduce && active,
              floating: prefs.floating,
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Row(
              children: [
                Flexible(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF493055),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        'Character preview · Mic off',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: fullScreen
                      ? 'Exit phone preview'
                      : 'Open phone preview',
                  onPressed: () => setState(() => immersive = !immersive),
                  icon: Icon(fullScreen ? Icons.close : Icons.open_in_full),
                ),
              ],
            ),
          ),
          if (fullScreen)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => prefs.update(
                      view: prefs.presentation == Presentation.face
                          ? Presentation.fullBody
                          : Presentation.face,
                    ),
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(
                      prefs.presentation == Presentation.face
                          ? 'Show full body'
                          : 'Show face',
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => setState(
                      () => expression = expression == WispExpression.resting
                          ? WispExpression.curious
                          : WispExpression.resting,
                    ),
                    icon: const Icon(Icons.bedtime_outlined),
                    label: Text(
                      expression == WispExpression.resting
                          ? 'Wake Wisp'
                          : 'Rest Wisp',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _settings(CompanionPreferences prefs) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Your Wisp',
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text('One companion. Two ways to keep you company.'),
      const SizedBox(height: 20),
      _viewChoice(
        'Face View',
        'Big, expressive eyes. The original Compii view.',
        Icons.face_outlined,
        Presentation.face,
        prefs,
      ),
      const SizedBox(height: 12),
      _viewChoice(
        'Full-body View',
        'A little Wisp floating or resting nearby.',
        Icons.air,
        Presentation.fullBody,
        prefs,
      ),
      if (prefs.presentation == Presentation.fullBody) ...[
        const SizedBox(height: 16),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Float gently'),
          subtitle: Text(
            prefs.floating
                ? 'Drift inside the companion scene'
                : 'Rest in the center of the scene',
          ),
          value: prefs.floating,
          onChanged: (value) => prefs.update(float: value),
        ),
      ],
      const SizedBox(height: 20),
      const Divider(),
      const SizedBox(height: 20),
      Text(
        'Explore expressions',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      const Text('Preview only — these do not activate the microphone.'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: WispExpression.values
            .map(
              (item) => ChoiceChip(
                label: Text(_expressionLabel(item)),
                selected: expression == item,
                onSelected: (_) => setState(() => expression = item),
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 16),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Reduce motion'),
        subtitle: const Text(
          'Keep Wisp still. System preference also applies.',
        ),
        value: prefs.reducedMotion,
        onChanged: (value) => prefs.update(reduce: value),
      ),
      const SizedBox(height: 12),
      const Text(
        'Appearance is saved on this device.',
        style: TextStyle(color: Color(0xFF66566F)),
      ),
    ],
  );

  Widget _viewChoice(
    String title,
    String subtitle,
    IconData icon,
    Presentation view,
    CompanionPreferences prefs,
  ) {
    final selected = prefs.presentation == view;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? const Color(0xFFE9DDFD) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? const Color(0xFF6C3BA8) : const Color(0xFFD1C5D8),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => prefs.update(view: view),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeSelector() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: CompanionMode.values
            .map(
              (item) => ChoiceChip(
                avatar: Icon(switch (item) {
                  CompanionMode.teach => Icons.menu_book_outlined,
                  CompanionMode.collaborate => Icons.people_outline,
                  CompanionMode.execute => Icons.play_arrow_outlined,
                }, size: 18),
                label: Text(switch (item) {
                  CompanionMode.teach => 'Teach me',
                  CompanionMode.collaborate => 'With me',
                  CompanionMode.execute => 'For me',
                }),
                selected: mode == item,
                onSelected: (_) => setState(() => mode = item),
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 12),
      Text(switch (mode) {
        CompanionMode.teach =>
          'Learn one step at a time, with room to try it yourself.',
        CompanionMode.collaborate =>
          'Share the work, and understand the decisions along the way.',
        CompanionMode.execute => 'Hand over a task and review the result.',
      }, style: const TextStyle(fontSize: 16)),
      const SizedBox(height: 6),
      const Text(
        'Mode preview. AI and actions are not connected yet.',
        style: TextStyle(color: Color(0xFF66566F)),
      ),
    ],
  );

  String _expressionLabel(WispExpression item) => switch (item) {
    WispExpression.curious => 'Curious',
    WispExpression.listening => 'Listening',
    WispExpression.thinking => 'Thinking',
    WispExpression.explaining => 'Explaining',
    WispExpression.resting => 'Resting',
  };
}

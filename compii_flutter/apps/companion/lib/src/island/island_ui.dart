import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import '../ui/bots.dart';
import '../ui/chrome.dart';
import '../ui/glyphs.dart';
import '../ui/thread.dart';
import '../ui/tokens.dart';
import 'island_controller.dart';
import 'island_eyes.dart';
import 'island_geometry.dart';
import 'island_prefs.dart';

/// The island's whole visible surface. One card, drawn top-centre in a much
/// larger transparent window; the window never resizes, so the card can grow
/// downward without the transparent-window stretching Windows suffers from.
///
/// Nothing here animates while the island is idle. The one moving thing is the
/// live microphone level, and it only moves when Core says the mic is open.
class IslandView extends StatefulWidget {
  const IslandView({
    super.key,
    required this.controller,
    required this.cardKey,
    required this.shortcut,
    required this.hotkeyError,
    required this.onDock,
    required this.onResetLayout,
    required this.onShortcut,
    required this.onAttention,
    required this.onRevealMain,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.metrics = const IslandMetrics(),
  });

  final IslandController controller;

  /// The card's own render box: the host uses it to let clicks through the
  /// transparent area around it.
  final GlobalKey cardKey;
  final String shortcut;
  final String? hotkeyError;
  final ValueChanged<IslandDock> onDock;
  final VoidCallback onResetLayout;
  final ValueChanged<String> onShortcut;
  final ValueChanged<IslandAttention> onAttention;
  final VoidCallback onRevealMain;
  final VoidCallback onDragStart;
  final VoidCallback onDragUpdate;
  final VoidCallback onDragEnd;
  final IslandMetrics metrics;

  @override
  State<IslandView> createState() => _IslandViewState();
}

class _IslandViewState extends State<IslandView> {
  late final FocusNode _askFocus = FocusNode(
    debugLabel: 'island-ask',
    onKeyEvent: (_, event) => _enter(event, ask: true),
  );
  late final FocusNode _replyFocus = FocusNode(
    debugLabel: 'island-reply',
    onKeyEvent: (_, event) => _enter(event, ask: false),
  );
  IslandStage _stage = IslandStage.compact;

  /// The surface is black in every state, so the island carries its own night
  /// theme even when the rest of Compii is in light mode. Without it, light
  /// ink would be drawn on a black pill.
  late final ThemeData _theme = compiiTheme(Brightness.dark);

  bool _hover = false;
  bool _menu = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.draft.addListener(_typed);
    _stage = widget.controller.stage;
    if (_stage == IslandStage.ask) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _askFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.draft.removeListener(_typed);
    _askFocus.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final next = widget.controller.stage;
    final leavingAsk = _stage == IslandStage.ask;
    _stage = next;
    if (next == IslandStage.ask && !leavingAsk) {
      // The hotkey is the fast path: the caret is already in the field.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.stage == IslandStage.ask) {
          _askFocus.requestFocus();
        }
      });
    } else if (leavingAsk) {
      _askFocus.unfocus();
    }
    if (next != IslandStage.conversation &&
        next != IslandStage.working &&
        next != IslandStage.completed &&
        next != IslandStage.failed) {
      _replyFocus.unfocus();
    }
    // Opening a conversation or the ask card leaves no capsule menu behind.
    if (next != IslandStage.compact && next != IslandStage.listening) {
      _menu = false;
    }
    // Every Core event changes some of this card (phase, steps, approvals), so
    // the surface is rebuilt even when the stage itself did not move.
    setState(() {});
  }

  void _setHover(bool on) {
    if (_hover != on && mounted) setState(() => _hover = on);
  }

  /// The pill is the camera cutout: as wide as its one label needs and no
  /// wider, so it never clips a word. Height stays at the cutout height.
  Size _compactSize(IslandController c, double maxW, double maxH) {
    final listening = c.stage == IslandStage.listening;
    final label = _compactLabel(c, hover: _hover);
    final style = (_theme.textTheme.labelLarge ?? const TextStyle(fontSize: 13.5)).copyWith(
      fontWeight: FontWeight.w600,
    );
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    // Chrome = padding + eyes + gap (or eyes, waveform, gaps and the two buttons).
    final chrome = listening ? 173.0 : 75.0;
    final width = math.min(
      maxW,
      label.isEmpty ? 84.0 : math.max(listening ? 300.0 : 126.0, chrome + painter.width + 4),
    );
    final height = math.min(maxH, math.max(36.0, painter.height + 18));
    return Size(width, height);
  }

  void _typed() {
    if (mounted) setState(() {});
  }

  KeyEventResult _enter(KeyEvent event, {required bool ask}) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter && event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    // Shift+Enter is a new line; so are Enter presses while an IME is composing
    // (choosing a character must never send half a sentence).
    if (HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (widget.controller.draft.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    if (widget.controller.sending) return KeyEventResult.handled;
    if (ask) {
      widget.controller.send();
    } else {
      widget.controller.reply();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Theme(
      data: _theme,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => c.collapse()},
        child: Focus(
          autofocus: false,
          child: LayoutBuilder(
            builder: (context, box) {
              final m = widget.metrics;
              final maxW = math.max(240.0, math.min(m.maxCardWidth, box.maxWidth - 2 * m.margin));
              final maxH = math.max(260.0, math.min(m.maxCardHeight, box.maxHeight - 2 * m.margin - m.shadowInset));
              final stage = c.stage;
              final compact = stage == IslandStage.compact || stage == IslandStage.listening;
              final scale = MediaQuery.textScalerOf(context).scale(1);
              // At large type the card itself gets taller. Squeezing the same
              // 420 px would leave the conversation no room at all; the
              // placement maths keeps using the normal size.
              final grow = (scale - 1).clamp(0.0, 2.0);
              final limit = math.max(260.0, box.maxHeight - 2 * m.margin - m.shadowInset);
              final size = compact
                  ? _compactSize(c, maxW, maxH)
                  : Size(
                      maxW,
                      math.min(
                        // The composer is the one card whose height is chosen rather
                        // than taken from a thread, and 300 cut its own footer hint in
                        // half. This clears header, field, toolbar, two rows of
                        // suggestions and the two-line hint; anything more scrolls.
                        stage == IslandStage.ask ? 360 + grow * 90 : maxH + grow * 160,
                        limit,
                      ),
                    );
              final Widget content = switch (stage) {
                IslandStage.compact || IslandStage.listening => _Capsule(
                  controller: c,
                  hover: _hover,
                  onHover: _setHover,
                  onMenu: () => setState(() => _menu = !_menu),
                  onDragStart: widget.onDragStart,
                  onDragUpdate: widget.onDragUpdate,
                  onDragEnd: widget.onDragEnd,
                ),
                IslandStage.ask => _AskCard(
                  controller: c,
                  maxHeight: size.height,
                  focus: _askFocus,
                  shortcut: widget.shortcut,
                  onHistory: c.openTask,
                  onRevealMain: widget.onRevealMain,
                  onDragStart: widget.onDragStart,
                  onDragUpdate: widget.onDragUpdate,
                  onDragEnd: widget.onDragEnd,
                ),
                _ => _ConversationCard(
                  controller: c,
                  maxHeight: size.height,
                  focus: _replyFocus,
                  onRevealMain: widget.onRevealMain,
                  onDragStart: widget.onDragStart,
                  onDragUpdate: widget.onDragUpdate,
                  onDragEnd: widget.onDragEnd,
                ),
              };
              // Working, approval, done and failure are the same conversation:
              // only the words inside it change, so the list is never rebuilt.
              final slot = compact
                  ? 'compact'
                  : stage == IslandStage.ask
                  ? 'ask'
                  : 'conversation';
              final card = _IslandShell(
                width: size.width,
                height: size.height,
                radius: compact ? size.height / 2 : _islandRadius,
                halo: compact && c.signal == IslandSignal.working,
                rim: switch (c.signal) {
                  IslandSignal.needsYou => context.c.warning,
                  IslandSignal.failed => context.c.danger,
                  _ => null,
                },
                child: _Enter(key: ValueKey(slot), child: content),
              );
              return Align(
                alignment: Alignment.topCenter,
                child: KeyedSubtree(
                  key: widget.cardKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(top: m.shadowInset),
                        child: card,
                      ),
                      if (_menu && compact) ...[
                        const SizedBox(height: 8),
                        _DockMenu(
                          shortcut: widget.shortcut,
                          hotkeyError: widget.hotkeyError,
                          attention: c.attention,
                          onDock: (dock) {
                            setState(() => _menu = false);
                            widget.onDock(dock);
                          },
                          onReset: () {
                            setState(() => _menu = false);
                            widget.onResetLayout();
                          },
                          onShortcut: (id) {
                            setState(() => _menu = false);
                            widget.onShortcut(id);
                          },
                          onAttention: () {
                            setState(() => _menu = false);
                            widget.onAttention(c.attention.next);
                          },
                          onRevealMain: () {
                            setState(() => _menu = false);
                            widget.onRevealMain();
                          },
                          minWidth: math.min(270, maxW),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- the mark

Color _signalColor(CompiiColors c, IslandSignal signal) => switch (signal) {
  IslandSignal.listening => c.listen,
  IslandSignal.working => c.accent,
  IslandSignal.needsYou => c.warning,
  IslandSignal.done => c.success,
  IslandSignal.failed => c.danger,
  IslandSignal.offline => c.faint,
  IslandSignal.news => c.success,
  IslandSignal.none => c.accent,
};

/// Compii's mark in the island is its pair of eyes: the creature's own eyes,
/// set into the black capsule, following the pointer and wearing the state.
class _Mark extends StatelessWidget {
  const _Mark({this.size = 18, this.signal = IslandSignal.none, this.level = 0, this.listening = false});
  final double size;
  final IslandSignal signal;
  final double level;
  final bool listening;

  @override
  Widget build(BuildContext context) => IslandEyes(signal: signal, size: size, level: level, listening: listening);
}

// ------------------------------------------------------------- the capsule

/// Compact: the camera cutout. At rest it is only Compii's eyes in a black pill:
/// no words, no badge. Hovering offers "Ask Compii"; anything happening says
/// itself in one short line, in the colour of what it is.
String _compactLabel(IslandController c, {bool hover = false}) {
  if (c.stage == IslandStage.listening) {
    return c.voice?.busy == true ? 'Transcribing' : 'Listening';
  }
  if (c.signal == IslandSignal.none) return hover ? 'Ask Compii' : '';
  return c.capsuleLabel;
}

class _Capsule extends StatelessWidget {
  const _Capsule({
    required this.controller,
    required this.hover,
    required this.onHover,
    required this.onMenu,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final IslandController controller;
  final bool hover;
  final ValueChanged<bool> onHover;
  final VoidCallback onMenu;
  final VoidCallback onDragStart;
  final VoidCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final listening = controller.stage == IslandStage.listening;
    final signal = controller.signal;
    final label = _compactLabel(controller, hover: hover);
    final color = _signalColor(c, signal);

    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: controller.tapCapsule,
        onSecondaryTap: onMenu,
        onPanStart: (_) => onDragStart(),
        onPanUpdate: (_) => onDragUpdate(),
        onPanEnd: (_) => onDragEnd(),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: listening ? 12 : 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (listening) ...[
                _Mark(size: 18, signal: IslandSignal.listening, level: controller.voice?.level ?? 0, listening: true),
                const SizedBox(width: 8),
                _Waveform(level: controller.voice?.level ?? 0, color: c.listen, width: 32, height: 20),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    controller.partial.isEmpty ? label : controller.partial,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.labelLarge?.copyWith(
                      color: controller.partial.isEmpty ? c.listen : c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _icon(context, G.check, 'Stop listening and use it', controller.finishListening),
                _icon(context, G.close, 'Cancel listening', controller.cancelListening),
              ] else ...[
                _Mark(size: 18, signal: signal),
                if (label.isNotEmpty) const SizedBox(width: 9),
                if (label.isNotEmpty)
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.labelLarge?.copyWith(
                        color: signal == IslandSignal.none ? (hover ? c.text : c.muted) : color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DockMenu extends StatelessWidget {
  const _DockMenu({
    required this.shortcut,
    required this.hotkeyError,
    required this.attention,
    required this.onDock,
    required this.onReset,
    required this.onShortcut,
    required this.onAttention,
    required this.onRevealMain,
    required this.minWidth,
  });

  final String shortcut;
  final String? hotkeyError;
  final IslandAttention attention;
  final ValueChanged<IslandDock> onDock;
  final VoidCallback onReset;
  final ValueChanged<String> onShortcut;
  final VoidCallback onAttention;
  final VoidCallback onRevealMain;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: BoxConstraints(minWidth: minWidth),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: _islandBlack,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: hc ? _islandRimStrong : _islandRim, width: hc ? 1.6 : 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MenuLabel('Placement'),
            _MenuRow(glyph: G.collapse, label: 'Top left', onTap: () => onDock(IslandDock.left)),
            _MenuRow(glyph: G.menu, label: 'Top centre', onTap: () => onDock(IslandDock.center)),
            _MenuRow(glyph: G.chevronRight, label: 'Top right', onTap: () => onDock(IslandDock.right)),
            _MenuRow(glyph: G.sync, label: 'Reset position', onTap: onReset),
            const Divider(height: 9),
            _MenuLabel('Wake shortcut'),
            for (final id in IslandShortcuts.ids)
              _MenuRow(
                glyph: id == 'f8' ? G.keyboard : G.key,
                label: IslandShortcuts.label(id),
                selected: shortcut == id,
                onTap: () => onShortcut(id),
              ),
            if (hotkeyError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
                child: Text(
                  'Windows did not take that shortcut. $hotkeyError',
                  style: context.type.labelSmall?.copyWith(color: c.warning, height: 1.35),
                ),
              ),
            const Divider(height: 9),
            _MenuLabel('When Compii needs you'),
            _MenuRow(glyph: G.bell, label: 'Tell me: ${attention.label}', onTap: onAttention),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                attention.hint,
                style: context.type.labelSmall?.copyWith(color: context.c.faint, height: 1.35),
              ),
            ),
            const Divider(height: 9),
            _MenuRow(glyph: G.external, label: 'Open Compii', onTap: onRevealMain),
          ],
        ),
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Text(
      text.toUpperCase(),
      style: context.type.labelSmall?.copyWith(color: context.c.faint, letterSpacing: .7),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.glyph, required this.label, required this.onTap, this.selected = false});
  final GlyphData glyph;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      borderRadius: Shapes.r10,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Glyph(glyph, size: 16, color: selected ? c.accent : c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.labelLarge?.copyWith(color: selected ? c.accent : c.text),
              ),
            ),
            if (selected) Glyph(G.check, size: 15, color: c.accent),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- ask + reply

class _AskCard extends StatefulWidget {
  const _AskCard({
    required this.controller,
    required this.maxHeight,
    required this.focus,
    required this.shortcut,
    required this.onHistory,
    required this.onRevealMain,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final IslandController controller;
  final double maxHeight;
  final FocusNode focus;
  final String shortcut;
  final ValueChanged<String> onHistory;
  final VoidCallback onRevealMain;
  final VoidCallback onDragStart;
  final VoidCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_AskCard> createState() => _AskCardState();
}

enum _Panel { none, agents, history }

class _AskCardState extends State<_AskCard> {
  _Panel _panel = _Panel.none;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final agent = c.agent;
    final name = agent?.name ?? 'Compii';
    final listening = c.listeningHere;
    final speaking = c.voice?.speaking == true;
    final busy = c.voice?.busy == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Head(
          controller: c,
          title: listening ? 'Listening' : name,
          subtitle: listening
              ? (c.partial.isEmpty ? 'Speak now' : 'Hearing you')
              : busy
              ? 'Transcribing your words'
              : speaking
              ? 'Compii is speaking'
              : 'Ask anything, or point at your screen',
          subtitleColor: listening ? context.c.listen : null,
          onDragStart: widget.onDragStart,
          onDragUpdate: widget.onDragUpdate,
          onDragEnd: widget.onDragEnd,
          actions: [
            _icon(
              context,
              G.clock,
              'Recent conversations',
              () => setState(() => _panel = _panel == _Panel.history ? _Panel.none : _Panel.history),
            ),
            _icon(context, G.external, 'Open Compii', widget.onRevealMain),
            _icon(context, G.close, 'Close (Esc)', c.collapse),
          ],
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (c.backgroundAttention case final waiting?) ...[
                  _NeedsYouRow(controller: c, task: waiting),
                  const SizedBox(height: 8),
                ],
                if (c.newsCount > 0) ...[_NewsRow(controller: c), const SizedBox(height: 8)],
                if (c.continuing case final prior?) ...[
                  _ContinuingRow(controller: c, task: prior),
                  const SizedBox(height: 8),
                ],
                if (_panel == _Panel.history)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _HistoryPanel(
                      core: c.core,
                      current: c.taskId,
                      maxHeight: math.min(240, widget.maxHeight * .45),
                      onOpen: (id) {
                        setState(() => _panel = _Panel.none);
                        widget.onHistory(id);
                      },
                      onNew: () {
                        setState(() => _panel = _Panel.none);
                        c.openAsk(fresh: true);
                      },
                    ),
                  ),
                if (_panel == _Panel.agents)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _AgentPanel(controller: c, onPicked: () => setState(() => _panel = _Panel.none)),
                  ),
                if (listening || busy || speaking)
                  _VoicePanel(controller: c)
                else ...[
                  _Composer(
                    controller: c,
                    focus: widget.focus,
                    ask: true,
                    onAgents: () => setState(() => _panel = _panel == _Panel.agents ? _Panel.none : _Panel.agents),
                  ),
                  if (c.attachments.isEmpty && !c.screenContext && c.draft.text.trim().isEmpty) ...[
                    const SizedBox(height: 10),
                    _Suggestions(controller: c),
                  ],
                  if (c.error != null) ...[const SizedBox(height: 10), _ErrorBar(controller: c)],
                  const SizedBox(height: 10),
                  _Hint(
                    'Enter to send · Shift+Enter for a new line · '
                    '${IslandShortcuts.label(widget.shortcut)} from anywhere · Esc to close',
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One composer for both asking and replying: the same controls, the same
/// preserved draft, only the words above the caret and where it goes differ.
class _Composer extends StatefulWidget {
  const _Composer({required this.controller, required this.focus, required this.ask, this.onAgents});

  final IslandController controller;
  final FocusNode focus;
  final bool ask;
  final VoidCallback? onAgents;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    // The caret border is the only sign of where typing goes in the island.
    widget.focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant _Composer old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      old.focus.removeListener(_focusChanged);
      widget.focus.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.focus.removeListener(_focusChanged);
    super.dispose();
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    final controller = widget.controller;
    final voice = controller.voice;
    final canSend =
        !controller.sending &&
        !controller.screenBusy &&
        (controller.draft.text.trim().isNotEmpty || controller.attachments.isNotEmpty || controller.screenContext);
    final micKnownOff = voice != null && voice.status != null && !voice.canListen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: c.sunken,
            borderRadius: Shapes.r16,
            border: Border.all(
              color: hc
                  ? c.borderStrong
                  : widget.focus.hasFocus
                  ? c.accent.withValues(alpha: .55)
                  : c.border,
              width: hc ? 1.6 : 1,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
          child: TextField(
            controller: controller.draft,
            focusNode: widget.focus,
            minLines: 1,
            maxLines: 5,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: context.type.bodyMedium?.copyWith(fontSize: 14.5),
            cursorColor: c.accent,
            decoration: InputDecoration(
              hintText: widget.ask ? 'Ask anything…' : 'Reply to Compii…',
              hintStyle: context.type.bodyMedium?.copyWith(color: c.faint, fontSize: 14.5),
              filled: false,
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 11),
            ),
          ),
        ),
        if (controller.attachments.isNotEmpty || controller.screenContext) ...[
          const SizedBox(height: 8),
          _Attachments(controller: controller),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            _tool(context, G.clip, 'Attach a file', controller.addFiles),
            _tool(
              context,
              G.eye,
              controller.screenContext ? 'Screen included' : 'Include the screen',
              controller.toggleScreenContext,
              active: controller.screenContext,
            ),
            if (widget.ask && controller.agents.length > 1)
              Flexible(
                child: _AgentChip(
                  name: controller.agent?.name ?? 'Compii',
                  color: controller.agent == null ? c.accent : botColor(controller.agent!, c.accent),
                  onTap: widget.onAgents,
                ),
              )
            else
              const Spacer(),
            if (controller.screenBusy)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text('Looking…', style: context.type.labelMedium?.copyWith(color: c.muted)),
              ),
            _icon(
              context,
              voice?.listening == true ? G.stop : G.mic,
              micKnownOff
                  ? 'Turn on listening in Settings → Voice'
                  : voice?.listening == true
                  ? 'Stop listening'
                  : 'Talk instead of typing',
              micKnownOff || controller.sending
                  ? null
                  : voice?.listening == true
                  ? controller.finishListening
                  : controller.startListening,
              active: voice?.listening == true,
            ),
            const SizedBox(width: 2),
            _SendButton(
              busy: controller.sending,
              enabled: canSend,
              onTap: widget.ask ? controller.send : controller.reply,
            ),
          ],
        ),
      ],
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.enabled, required this.onTap});
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox.square(
      dimension: 36,
      child: busy
          ? Center(
              child: SizedBox.square(dimension: 17, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
            )
          : IconButton.filled(
              tooltip: enabled ? 'Send (Enter)' : 'Write something first',
              onPressed: enabled ? onTap : null,
              style: IconButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                disabledBackgroundColor: c.hover,
                disabledForegroundColor: c.faint,
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
                minimumSize: const Size.square(36),
              ),
              icon: const Glyph(G.arrowUp, size: 18, weight: 2),
            ),
    );
  }
}

class _AgentChip extends StatelessWidget {
  const _AgentChip({required this.name, required this.color, this.onTap});
  final String name;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: Shapes.pill,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 4, 7, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.labelMedium?.copyWith(color: c.muted),
                ),
              ),
              const SizedBox(width: 3),
              Glyph(G.expand, size: 12, color: c.faint),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentPanel extends StatelessWidget {
  const _AgentPanel({required this.controller, required this.onPicked});
  final IslandController controller;
  final VoidCallback onPicked;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    final selected = controller.agent?.id;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: c.sunken,
        borderRadius: Shapes.r14,
        border: Border.all(color: hc ? c.borderStrong : c.border, width: hc ? 1.6 : 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final bot in controller.agents) ...[
            InkWell(
              onTap: () {
                controller.setBot(bot.primary ? null : bot.id);
                onPicked();
              },
              borderRadius: Shapes.r10,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  children: [
                    BotAvatar(bot: bot, size: 24),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        bot.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.labelLarge?.copyWith(color: selected == bot.id ? c.accent : c.text),
                      ),
                    ),
                    if (bot.job.isNotEmpty)
                      Flexible(
                        child: Text(
                          bot.job,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.labelMedium?.copyWith(color: c.faint),
                        ),
                      ),
                    if (selected == bot.id) ...[const SizedBox(width: 6), Glyph(G.check, size: 15, color: c.accent)],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({required this.controller});
  final IslandController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (controller.screenContext)
          _Chip(
            glyph: G.eye,
            label: 'Screen',
            detail: 'the app behind this island',
            color: c.accent,
            onRemove: controller.toggleScreenContext,
          ),
        for (final (i, file) in controller.attachments.indexed)
          _Chip(
            glyph: G.file,
            label: '${file['name'] ?? 'File'}',
            detail: _size(file['size']),
            color: c.muted,
            onRemove: () => controller.removeAttachment(i),
          ),
        if (controller.screenBusy) _Chip(glyph: G.eye, label: 'Taking a look…', color: c.listen),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.glyph, required this.label, required this.color, this.detail, this.onRemove});
  final GlyphData glyph;
  final String label;
  final String? detail;
  final Color color;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: context.c.dark ? .16 : .09),
        borderRadius: Shapes.pill,
        border: Border.all(color: color.withValues(alpha: .25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Glyph(glyph, size: 13, color: color),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(detail!, style: context.type.labelSmall?.copyWith(color: context.c.faint)),
          ],
          if (onRemove != null)
            IconButton(
              tooltip: 'Remove',
              onPressed: onRemove,
              icon: const Glyph(G.close, size: 12),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.controller});
  final IslandController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final title = controller.foregroundTitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Row(
              children: [
                Glyph(G.monitor, size: 12, color: c.faint),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'You’re in $title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.labelSmall?.copyWith(color: c.faint),
                  ),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final s in controller.suggestions)
              ActionChip(
                onPressed: () => controller.chooseSuggestion(s),
                avatar: Glyph(s.screen ? G.eye : G.memory, size: 13, color: c.muted),
                label: Text(s.label),
                labelStyle: context.type.labelMedium?.copyWith(color: c.muted),
                backgroundColor: c.raised,
                side: BorderSide(color: c.border),
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: context.type.labelSmall?.copyWith(color: context.c.faint.withValues(alpha: .9)),
  );
}

// ------------------------------------------------------------- conversation

class _ConversationCard extends StatefulWidget {
  const _ConversationCard({
    required this.controller,
    required this.maxHeight,
    required this.focus,
    required this.onRevealMain,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final IslandController controller;
  final double maxHeight;
  final FocusNode focus;
  final VoidCallback onRevealMain;
  final VoidCallback onDragStart;
  final VoidCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_ConversationCard> createState() => _ConversationCardState();
}

class _ConversationCardState extends State<_ConversationCard> {
  bool _history = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final task = c.task;
    final stage = c.stage;
    final speaker = c.speaker;
    final name = speaker?.name ?? 'Compii';
    final failed = stage == IslandStage.failed;
    final approval = stage == IslandStage.approval;
    final working = stage == IslandStage.working;
    final waiting = task != null && (task.pendingQuestion != null || pendingTakeover(task) != null);

    final status = switch (stage) {
      IslandStage.working => Pill('Working', color: context.c.accent, glyph: G.bolt, pulse: true),
      IslandStage.approval => Pill('Needs your okay', color: context.c.warning, glyph: G.hand),
      IslandStage.completed => Pill('Done', color: context.c.success, glyph: G.checkCircle),
      IslandStage.failed => Pill('Didn’t finish', color: context.c.danger, glyph: G.alert),
      _ when waiting => Pill('Waiting for you', color: context.c.warning, glyph: G.hand),
      _ when c.needsYou => Pill('Needs you', color: context.c.warning, glyph: G.hand),
      _ when c.offline => Pill('Offline', color: context.c.faint, glyph: G.cloud),
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Head(
          controller: c,
          title: name,
          subtitle: _subtitle(c, task, name, stage),
          subtitleColor: failed ? context.c.danger : null,
          trailing: status,
          onDragStart: widget.onDragStart,
          onDragUpdate: widget.onDragUpdate,
          onDragEnd: widget.onDragEnd,
          actions: [
            _icon(context, G.clock, 'Recent conversations', () => setState(() => _history = !_history)),
            _icon(context, G.external, 'Open in Compii', c.openInMain),
            _icon(context, G.close, 'Close (Esc)', c.collapse),
          ],
        ),
        if (_history)
          _HistoryPanel(
            core: c.core,
            current: c.taskId,
            onOpen: (id) {
              setState(() => _history = false);
              c.openTask(id);
            },
            onNew: () {
              setState(() => _history = false);
              c.openAsk(fresh: true);
            },
            maxItems: 8,
            maxHeight: math.min(280, widget.maxHeight * .5),
          ),
        if (approval) ...[
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_lastAsk(task) case final ask when ask.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                      child: Text(
                        ask,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.bodyMedium?.copyWith(color: context.c.muted),
                      ),
                    ),
                  ApprovalCard(approval: task!.pendingApproval!, core: c.core, run: c.run, compact: true),
                  const SizedBox(height: 10),
                  Text(
                    'Approving covers this step only. Compii will ask again before anything else consequential.',
                    style: context.type.labelSmall?.copyWith(color: context.c.faint, height: 1.4),
                  ),
                  if (c.error != null) ...[const SizedBox(height: 10), _ErrorBar(controller: c)],
                ],
              ),
            ),
          ),
          _Foot(
            children: [
              TextButton.icon(
                onPressed: widget.onRevealMain,
                icon: const Glyph(G.external, size: 15),
                label: const Text('Open in Compii'),
              ),
              TextButton(onPressed: c.collapse, child: const Text('Close')),
            ],
          ),
        ] else if (task == null && (c.starting || c.sending)) ...[
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LiveMark(color: context.c.accent),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        c.sending ? 'Sending to Compii…' : 'Compii is picking it up…',
                        style: context.type.bodyMedium?.copyWith(color: context.c.muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: _ErrorBar(controller: c),
            ),
          _Foot(
            children: [
              TextButton.icon(
                onPressed: widget.onRevealMain,
                icon: const Glyph(G.external, size: 15),
                label: const Text('Open in Compii'),
              ),
              TextButton(onPressed: c.collapse, child: const Text('Close')),
            ],
          ),
        ] else if (task == null) ...[
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  c.error ?? 'This conversation is no longer here.',
                  textAlign: TextAlign.center,
                  style: context.type.bodyMedium?.copyWith(color: context.c.muted),
                ),
              ),
            ),
          ),
          _Foot(
            children: [TextButton(onPressed: () => c.openAsk(fresh: true), child: const Text('Ask something else'))],
          ),
        ] else ...[
          Expanded(
            child: ThreadView(task: task, core: c.core, run: c.run, compact: true, onOpenTask: c.openTask),
          ),
          if (c.error != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: _ErrorBar(controller: c),
            ),
          ],
          if (working || (waiting && (task.active || c.stopping))) ...[
            if (c.queuedText case final held?) _WaitingToSend(controller: c, text: held),
            _WorkingBar(controller: c, task: task, waiting: waiting),
            // Compii is mid-turn, so this field never sends into the middle of
            // a step: the words wait in the thread and go when the turn ends.
            if (working) _SayMore(controller: c),
          ] else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
              child: _Composer(controller: c, focus: widget.focus, ask: false),
            ),
            _Foot(
              children: [
                if (failed)
                  TextButton.icon(
                    onPressed: c.retryTask,
                    icon: const Glyph(G.sync, size: 15),
                    label: const Text('Try again'),
                  ),
                TextButton.icon(
                  onPressed: widget.onRevealMain,
                  icon: const Glyph(G.external, size: 15),
                  label: const Text('Open in Compii'),
                ),
                TextButton(onPressed: () => c.openAsk(fresh: true), child: const Text('New ask')),
                TextButton(onPressed: c.dismissFinished, child: Text(failed ? 'Dismiss' : 'Done')),
              ],
            ),
          ],
        ],
      ],
    );
  }

  String _subtitle(IslandController c, TaskView? task, String name, IslandStage stage) {
    if (c.offline) return 'Compii Core is offline';
    if (task == null) return 'No conversation';
    if (stage == IslandStage.working) return islandPhase(task);
    if (stage == IslandStage.approval) return 'One step is waiting for you';
    if (stage == IslandStage.completed) {
      final took = _duration(task);
      return took.isEmpty ? 'Finished' : 'Finished in $took';
    }
    if (stage == IslandStage.failed) return 'Compii stopped before finishing';
    if (task.pendingQuestion != null) return 'Compii asked you something';
    if (pendingTakeover(task) != null) return 'Your turn — Compii is waiting';
    if (task.active) return islandPhase(task);
    return task.request.trim();
  }

  String _lastAsk(TaskView? task) {
    if (task == null) return '';
    final turns = turnsOf(task);
    return turns.isEmpty ? task.request : turns.last.ask;
  }
}

/// One line for what you want to add while Compii is mid-turn. Enter or the
/// arrow does not interrupt the step it is on; it queues the message and the
/// card shows it waiting.
class _SayMore extends StatelessWidget {
  const _SayMore({required this.controller});
  final IslandController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: hc ? c.borderStrong : c.border)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller.draft,
              maxLines: 2,
              minLines: 1,
              textInputAction: TextInputAction.send,
              style: context.type.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                hintText: 'Say more · waits for this turn to finish',
                hintStyle: context.type.bodyMedium?.copyWith(color: c.faint),
              ),
              onSubmitted: (_) => controller.queueReply(),
            ),
          ),
          IconButton(
            tooltip: 'Queue for the end of this turn',
            onPressed: controller.queueReply,
            icon: const Glyph(G.arrowUp, size: 18, weight: 2),
          ),
        ],
      ),
    );
  }
}

/// The message that is waiting, readable, with the words returned on request.
class _WaitingToSend extends StatelessWidget {
  const _WaitingToSend({required this.controller, required this.text});
  final IslandController controller;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r12),
      child: Row(
        children: [
          Glyph(G.clock, size: 15, color: c.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.type.labelMedium?.copyWith(color: c.muted, height: 1.35),
            ),
          ),
          TextButton(onPressed: controller.cancelQueued, child: const Text('Take back')),
        ],
      ),
    );
  }
}

/// The honest working state: what Core last said, how long it has been, how
/// many real steps it took, and a Stop button. Never a percentage.
class _WorkingBar extends StatelessWidget {
  const _WorkingBar({required this.controller, required this.task, required this.waiting});
  final IslandController controller;
  final TaskView task;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    final steps = task.events.where((e) => e['type'] == 'action_done').length;
    final what = waiting
        ? (task.pendingQuestion != null ? 'Waiting for your answer' : 'Waiting for your hands')
        : islandPhase(task);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 12, 10),
      decoration: BoxDecoration(
        color: c.sunken,
        border: Border(top: BorderSide(color: hc ? c.borderStrong : c.border)),
      ),
      child: Row(
        children: [
          _LiveMark(color: waiting ? c.warning : c.accent),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  what,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.labelLarge?.copyWith(color: waiting ? c.warning : c.text),
                ),
                if (steps > 0)
                  Text(
                    '$steps ${steps == 1 ? 'step' : 'steps'} taken',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.labelSmall?.copyWith(color: c.faint),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (controller.startedAt != null) _Elapsed(from: controller.startedAt!, until: null),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: controller.stopping ? null : controller.stop,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(64, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Text(controller.stopping ? 'Stopping…' : 'Stop'),
          ),
        ],
      ),
    );
  }
}

class _LiveMark extends StatelessWidget {
  const _LiveMark({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: color.withValues(alpha: .5), blurRadius: 7, spreadRadius: 1)],
    ),
  );
}

class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.from, required this.until});
  final DateTime from;
  final DateTime? until;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.until == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final end = widget.until ?? DateTime.now();
    return Text(
      formatElapsed(end.difference(widget.from)),
      style: TextStyle(
        fontFamily: 'Cascadia Mono',
        fontFamilyFallback: const ['Consolas'],
        fontSize: 12,
        color: context.c.faint,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

String _duration(TaskView task) {
  double? start;
  double? end;
  for (final e in task.events) {
    final at = (e['at'] as num?)?.toDouble();
    if (at == null) continue;
    start ??= at;
    if (e['type'] == 'task_finished') end = at;
  }
  if (start == null || end == null) return '';
  return formatElapsed(Duration(milliseconds: math.max(0, ((end - start) * 1000).round())));
}

// --------------------------------------------------------------- history

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({
    required this.core,
    required this.onOpen,
    required this.onNew,
    this.current,
    this.maxItems = 6,
    this.maxHeight = 280,
  });

  final CoreClient core;
  final String? current;
  final ValueChanged<String> onOpen;
  final VoidCallback onNew;
  final int maxItems;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    final tasks = [
      for (final t in core.ordered)
        if (t.id != current) t,
    ].take(maxItems).toList();
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: c.sunken,
        borderRadius: Shapes.r14,
        border: Border.all(color: hc ? c.borderStrong : c.border, width: hc ? 1.6 : 1),
      ),
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onNew,
              borderRadius: Shapes.r10,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Glyph(G.plus, size: 15, color: c.accent),
                    const SizedBox(width: 9),
                    Text('New ask', style: context.type.labelLarge?.copyWith(color: c.accent)),
                  ],
                ),
              ),
            ),
            if (tasks.isNotEmpty) const Divider(height: 7),
            for (final t in tasks)
              InkWell(
                onTap: () => onOpen(t.id),
                borderRadius: Shapes.r10,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: t.status == 'failed'
                              ? c.danger
                              : t.active
                              ? c.accent
                              : c.success,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _conversationTitle(t),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.labelLarge?.copyWith(color: c.text),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_ago(t), style: context.type.labelSmall?.copyWith(color: c.faint)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _conversationTitle(TaskView task) {
  final text = task.request.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty) return 'New conversation';
  return text.length <= 70 ? text : '${text.substring(0, 69)}…';
}

String _ago(TaskView task) {
  double? at;
  for (final e in task.events) {
    at = (e['at'] as num?)?.toDouble();
    if (at != null) break;
  }
  if (at == null || at <= 0) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((at * 1000).round()));
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  return '${d.inDays}d';
}

// ------------------------------------------------------------- voice

class _VoicePanel extends StatelessWidget {
  const _VoicePanel({required this.controller});
  final IslandController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final voice = controller.voice;
    final listening = voice?.listening == true;
    final busy = voice?.busy == true;
    final speaking = voice?.speaking == true;
    final color = speaking ? c.accent : c.listen;
    final title = listening
        ? 'Listening'
        : busy
        ? 'Transcribing'
        : 'Compii is speaking';
    final detail = listening
        ? (controller.partial.isEmpty ? 'Speak now — Compii hears you' : controller.partial)
        : busy
        ? 'Turning your words into text'
        : (voice?.caption.isNotEmpty == true ? voice!.caption : 'You can mute the answer here.');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: context.c.dark ? .13 : .07),
        borderRadius: Shapes.r14,
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (listening)
            _Waveform(level: voice?.level ?? 0, color: color, width: 40, height: 28)
          else
            Glyph(speaking ? G.speaker : G.wave, size: 26, color: color),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.type.labelLarge?.copyWith(color: color)),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.labelMedium?.copyWith(color: c.muted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (listening) ...[
            _icon(context, G.check, 'Stop and use it', controller.finishListening),
            _icon(context, G.close, 'Cancel', controller.cancelListening),
          ] else if (speaking)
            TextButton(onPressed: () => voice?.quiet(), child: const Text('Mute'))
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('…', style: context.type.titleMedium?.copyWith(color: c.faint)),
            ),
        ],
      ),
    );
  }
}

/// Five bars answering the live microphone level Core sends. No level, no
/// movement: this is a meter, not a decorative loop.
class _Waveform extends StatelessWidget {
  const _Waveform({required this.level, required this.color, this.width = 40, this.height = 24});
  final double level;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _WavePainter(level: level.clamp(0, 1).toDouble(), color: color),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.level, required this.color});
  final double level;
  final Color color;

  static const _shape = [.42, .78, 1.0, .64, .38];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2.4, size.width / 14);
    final gap = size.width / (_shape.length * 2);
    final mid = size.height / 2;
    for (var i = 0; i < _shape.length; i++) {
      final x = gap + i * (size.width - gap * 2) / (_shape.length - 1);
      final amp = math.max(3.0, size.height * .82 * _shape[i] * (.18 + level * .95));
      canvas.drawLine(Offset(x, mid - amp / 2), Offset(x, mid + amp / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.level != level || old.color != color;
}

// ------------------------------------------------------- error handling

/// Another thread is stuck until the user answers it, and they are typing
/// something else. The composer stays theirs - their words are never thrown
/// away for a background event - but nothing is hidden either.
class _NeedsYouRow extends StatelessWidget {
  const _NeedsYouRow({required this.controller, required this.task});
  final IslandController controller;
  final TaskView task;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final what = task.pendingApproval != null
        ? 'needs your OK'
        : task.pendingQuestion != null
        ? 'has a question'
        : 'is waiting for your hands';
    return InkWell(
      onTap: () => controller.openTask(task.id),
      borderRadius: Shapes.r12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: c.warningSoft, borderRadius: Shapes.r12),
        child: Row(
          children: [
            Glyph(G.warning, size: 15, color: c.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Compii $what · ${task.request}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.type.labelMedium?.copyWith(color: c.warning, height: 1.35),
              ),
            ),
            Glyph(G.chevronRight, size: 15, color: c.warning),
          ],
        ),
      ),
    );
  }
}

/// Something Compii left in the inbox — a brief, a watch, a routine's note that
/// has no conversation you are in. Offering it inside the composer keeps the pill
/// honest: the words you are typing are never displaced by it, and it is one tap
/// from being read in full.
class _NewsRow extends StatelessWidget {
  const _NewsRow({required this.controller});
  final IslandController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final news = controller.latestNews;
    if (news == null) return const SizedBox.shrink();
    final more = controller.newsCount > 1 ? ' · ${controller.newsCount} new' : '';
    return InkWell(
      onTap: controller.openNews,
      borderRadius: Shapes.r12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: c.successSoft, borderRadius: Shapes.r12),
        child: Row(
          children: [
            Glyph(G.bell, size: 15, color: c.success),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${news.title}$more',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.type.labelMedium?.copyWith(color: c.success, height: 1.35),
              ),
            ),
            Glyph(G.chevronRight, size: 15, color: c.success),
          ],
        ),
      ),
    );
  }
}

/// Which conversation the next ask lands in, so carrying on is never a surprise, and the
/// one tap that gives the next words a thread of their own instead.
class _ContinuingRow extends StatelessWidget {
  const _ContinuingRow({required this.controller, required this.task});
  final IslandController controller;
  final TaskView task;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final about = task.request.split('\n').first.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      decoration: BoxDecoration(color: c.accentSoft, borderRadius: Shapes.r12),
      child: Row(
        children: [
          Glyph(G.chat, size: 15, color: c.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              label: 'Carrying on the conversation about $about',
              excludeSemantics: true,
              child: Text(
                'Carrying on: $about',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.labelMedium?.copyWith(color: c.accent, height: 1.35),
              ),
            ),
          ),
          TextButton(
            onPressed: controller.newTopic,
            child: const Text('New topic'),
          ),
        ],
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.controller});
  final IslandController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: c.dangerSoft,
        borderRadius: Shapes.r12,
        border: Border.all(color: hc ? c.danger : c.danger.withValues(alpha: .3), width: hc ? 1.6 : 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Glyph(G.warning, size: 16, color: c.danger),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(controller.error!, style: context.type.labelMedium?.copyWith(color: c.danger, height: 1.4)),
          ),
          if (controller.offline)
            TextButton(
              onPressed: controller.reconnect,
              style: TextButton.styleFrom(foregroundColor: c.danger, minimumSize: const Size(44, 32)),
              child: const Text('Reconnect'),
            )
          else if (controller.canRetry)
            TextButton(
              onPressed: controller.retry,
              style: TextButton.styleFrom(foregroundColor: c.danger, minimumSize: const Size(44, 32)),
              child: const Text('Try again'),
            ),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: controller.dismissError,
            icon: const Glyph(G.close, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- chrome

/// The island is one opaque black surface in every state. It has no gradient,
/// no drop shadow and no coloured rim: the black *is* the island, the way the
/// camera cutout is on a phone. Only a hairline keeps the edge readable on a
/// dark desktop.
const _islandBlack = Color(0xFF050607);
const _islandRim = Color(0x1FFFFFFF);
const _islandRimStrong = Color(0x7AFFFFFF);
const _islandRadius = 28.0;

/// One shell for the pill and the expanded card, so a press morphs the same
/// surface instead of replacing one card with another. While Compii works, a
/// halo of its colour runs the edge — the one moving thing on the island, and
/// only while there is real work. A state that wants you tints the rim.
class _IslandShell extends StatelessWidget {
  const _IslandShell({
    required this.width,
    required this.height,
    required this.radius,
    required this.child,
    this.halo = false,
    this.rim,
  });

  final double width;
  final double height;
  final double radius;
  final Widget child;
  final bool halo;
  final Color? rim;

  @override
  Widget build(BuildContext context) {
    final hc = MediaQuery.highContrastOf(context);
    final shell = AnimatedContainer(
      duration: context.motion(380),
      curve: Motion.out,
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _islandBlack,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: rim?.withValues(alpha: hc ? .9 : .45) ?? (hc ? _islandRimStrong : _islandRim),
          width: hc ? 1.6 : 1,
        ),
        boxShadow: [if (rim != null) BoxShadow(color: rim!.withValues(alpha: .22), blurRadius: 24, spreadRadius: -4)],
      ),
      // The content is laid out at the final size from the first frame, so a
      // growing shell reveals it instead of squeezing it through every
      // intermediate width (which would overflow on the way).
      child: Material(
        type: MaterialType.transparency,
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minWidth: width,
          maxWidth: width,
          minHeight: height,
          maxHeight: height,
          child: child,
        ),
      ),
    );
    if (!halo) return shell;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        shell,
        Positioned.fill(
          child: IgnorePointer(child: _HaloEdge(radius: radius)),
        ),
      ],
    );
  }
}

/// The working halo: Compii's colour and its neighbours on the wheel, orbiting
/// the pill's edge. Still under reduced motion.
class _HaloEdge extends StatefulWidget {
  const _HaloEdge({required this.radius});
  final double radius;

  @override
  State<_HaloEdge> createState() => _HaloEdgeState();
}

class _HaloEdgeState extends State<_HaloEdge> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_spin, compiiColor]),
    builder: (context, _) => CustomPaint(
      painter: _HaloEdgePainter(t: _spin.value, color: compiiColor.value, radius: widget.radius),
    ),
  );
}

class _HaloEdgePainter extends CustomPainter {
  _HaloEdgePainter({required this.t, required this.color, required this.radius});
  final double t;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final shader = SweepGradient(
      colors: [color, const Color(0xFF2FD3FF), const Color(0xFFC06BFF), color],
      transform: GradientRotation(t * 2 * math.pi),
    ).createShader(Offset.zero & size);
    canvas.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..shader = shader
        ..color = Colors.white.withValues(alpha: .55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(
      r.deflate(.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant _HaloEdgePainter o) => o.t != t || o.color != color || o.radius != radius;
}

/// The new content arrives with a short fade while the shell morphs. Keyed by
/// slot, so a working card becoming a finished one does not fade at all.
class _Enter extends StatefulWidget {
  const _Enter({super.key, required this.child});
  final Widget child;

  @override
  State<_Enter> createState() => _EnterState();
}

class _EnterState extends State<_Enter> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: Motion.out);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _controller.duration = context.motion(Motion.quick);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _fade, child: widget.child);
}

class _Head extends StatelessWidget {
  const _Head({
    required this.controller,
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.subtitleColor,
    this.trailing,
  });

  final IslandController controller;
  final String title;
  final String subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final List<Widget> actions;
  final VoidCallback onDragStart;
  final VoidCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final speaker = controller.speaker;
    final specialist = speaker != null && !speaker.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onDragStart(),
        onPanUpdate: (_) => onDragUpdate(),
        onPanEnd: (_) => onDragEnd(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
          child: Row(
            children: [
              if (specialist)
                BotAvatar(bot: speaker, size: 24, mood: Mood.idle)
              else
                _Mark(size: 20, signal: controller.signal),
              const SizedBox(width: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.titleSmall?.copyWith(fontSize: 14.5),
                      ),
                      const SizedBox(height: 1),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.labelMedium?.copyWith(color: subtitleColor ?? c.muted),
                            ),
                          ),
                          // The status pill sits on the quieter line so a long
                          // title never squeezes it off the card at large type.
                          if (trailing != null && box.maxWidth >= 160) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: trailing!,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}

class _Foot extends StatelessWidget {
  const _Foot({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 8, 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      // Actions wrap instead of clipping when the card is narrow or the text
      // is scaled up, so every decision stays reachable.
      child: OverflowBar(
        alignment: MainAxisAlignment.end,
        overflowAlignment: OverflowBarAlignment.end,
        spacing: 2,
        overflowSpacing: 0,
        children: children,
      ),
    );
  }
}

Widget _icon(BuildContext context, GlyphData glyph, String tooltip, VoidCallback? onTap, {bool active = false}) {
  return IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Glyph(glyph, size: 17, color: active ? context.c.accent : null),
    padding: const EdgeInsets.all(7),
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    visualDensity: VisualDensity.compact,
  );
}

Widget _tool(BuildContext context, GlyphData glyph, String tooltip, VoidCallback? onTap, {bool active = false}) {
  final c = context.c;
  return IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    style: IconButton.styleFrom(
      backgroundColor: active ? c.accentSoft : Colors.transparent,
      foregroundColor: active ? c.accent : c.muted,
      minimumSize: const Size(32, 32),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r10),
    ),
    icon: Glyph(glyph, size: 17, color: active ? c.accent : null),
  );
}

String _size(Object? raw) {
  final bytes = (raw as num?)?.toDouble() ?? 0;
  if (bytes <= 0) return '';
  if (bytes < 1024) return '${bytes.round()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'glyphs.dart';
import 'phone_home.dart';
import 'phone_kit.dart';
import 'phone_voice.dart';
import 'shell.dart';
import 'tokens.dart';

const _linkKey = 'remote_link';
const _night = Color(0xFF050507);

/// The app on a phone (or on Windows with `--remote`, for testing): pair
/// once with a PC, then the screen is Compii's face, connected to that PC.
Future<void> runPhone() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();
  RemoteLink? link;
  try {
    final saved = (await SharedPreferences.getInstance()).getString(_linkKey);
    if (saved != null) link = RemoteLink.fromJson(jsonDecode(saved) as Map<String, dynamic>);
  } on Object {
    // nothing saved, or unreadable: pair again
  }
  runApp(PhoneApp(state: state, initial: link));
}

class PhoneApp extends StatefulWidget {
  const PhoneApp({super.key, required this.state, this.initial});
  final AppState state;
  final RemoteLink? initial;
  @override
  State<PhoneApp> createState() => _PhoneAppState();
}

class _PhoneAppState extends State<PhoneApp> {
  CoreClient? _core;
  PhoneVoice? _voice;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) _connect(widget.initial!);
  }

  void _connect(RemoteLink link) {
    final core = CoreClient(remote: link, onLinkChanged: _save)..start();
    final voice = PhoneVoice(core);
    voice.onHeard = (text) async {
      try {
        await core.startConversation(text, followOn: true);
        widget.state.fail(null);
      } catch (e) {
        widget.state.fail(e);
      }
    };
    widget.state.voice = voice;
    _core = core;
    _voice = voice;
  }

  Future<void> _save(RemoteLink link) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_linkKey, jsonEncode(link.toJson()));
    } on Object {
      // works for this session; pairing again later fixes it
    }
  }

  Future<void> _paired(RemoteLink link) async {
    await _save(link);
    setState(() => _connect(link));
  }

  Future<void> _forget() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_linkKey);
    } on Object {
      // nothing saved
    }
    _voice?.dispose();
    _core?.dispose();
    widget.state.voice = null;
    setState(() {
      _core = null;
      _voice = null;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => MaterialApp(
      title: 'Compii',
      debugShowCheckedModeBanner: false,
      // The phone is always the Halo night: the face, the chats and the PC in one place.
      theme: compiiTheme(Brightness.dark),
      darkTheme: compiiTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: _core == null
          ? PairScreen(onPaired: _paired)
          : PhoneHome(core: _core!, state: widget.state, voice: _voice!, onForget: _forget),
    ),
  );
}

/// First run on the phone: scan the QR code on the PC (or paste its link).
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.onPaired});
  final Future<void> Function(RemoteLink link) onPaired;
  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _paste = TextEditingController();
  final _name = TextEditingController(text: _defaultName());
  bool _busy = false;
  bool _scanning = false;
  String? _error;

  static bool get canScan => Platform.isAndroid || Platform.isIOS;

  static String _defaultName() {
    final h = Platform.localHostname;
    if (Platform.isAndroid || h.isEmpty || h == 'localhost') return 'My phone';
    return h;
  }

  @override
  void dispose() {
    _paste.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _use(String text) async {
    if (_busy) return;
    final invite = PairingInvite.parse(text);
    if (invite == null) {
      setState(() => _error = 'That isn’t a Compii pairing code. On your PC open Settings → Phones → Pair a phone.');
      return;
    }
    setState(() {
      _busy = true;
      _scanning = false;
      _error = null;
    });
    try {
      final link = await invite.claim(_name.text.trim().isEmpty ? 'My phone' : _name.text.trim());
      await widget.onPaired(link);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x33FFFFFF))),
                child: Text(n, style: context.type.labelSmall?.copyWith(color: c.muted)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: context.type.bodyMedium?.copyWith(color: c.muted, height: 1.4))),
            ],
          ),
        );
    return AnnotatedRegion(
      value: phoneSystemUi,
      child: Scaffold(
        backgroundColor: _night,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                children: [
                  if (!_scanning)
                    SizedBox(
                      height: 220,
                      child: Ember(
                        mood: _busy ? Mood.thinking : (_error != null ? Mood.problem : Mood.happy),
                        followPointer: false,
                      ),
                    ),
                  Text('Meet Compii on your phone',
                      textAlign: TextAlign.center,
                      style: context.type.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.3)),
                  const SizedBox(height: 8),
                  Text('Pair once with the PC Compii runs on. Then talk, approve and follow its work from anywhere.',
                      textAlign: TextAlign.center, style: context.type.bodyMedium?.copyWith(color: c.muted, height: 1.45)),
                  const SizedBox(height: 22),
                  if (_scanning)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: SizedBox(
                        height: 320,
                        child: MobileScanner(
                          onDetect: (capture) {
                            for (final b in capture.barcodes) {
                              final v = b.rawValue;
                              if (v != null && v.startsWith('compii://pair')) {
                                _use(v);
                                return;
                              }
                            }
                          },
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                      decoration: BoxDecoration(
                        color: c.raised,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: c.border),
                      ),
                      child: Column(
                        children: [
                          step('1', 'On your PC, open Compii → Settings → Phones → Pair a phone.'),
                          step('2', 'Be on the same Wi-Fi. (For anywhere, install Tailscale on both first.)'),
                          step('3', 'Scan the code it shows.'),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (canScan)
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFF5F5F7),
                          foregroundColor: const Color(0xFF0A0A0D),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _busy ? null : () => setState(() => _scanning = !_scanning),
                        icon: Glyph(_scanning ? G.close : G.camera, color: const Color(0xFF0A0A0D)),
                        label: Text(_busy ? 'Pairing…' : _scanning ? 'Stop scanning' : 'Scan the code',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      initiallyExpanded: !canScan,
                      title: Text('Paste a pairing link instead', style: context.type.bodyMedium?.copyWith(color: c.muted)),
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      children: [
                        TextField(
                          controller: _name,
                          decoration: const InputDecoration(labelText: 'This phone’s name (shown on the PC)'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _paste,
                          minLines: 1,
                          maxLines: 3,
                          decoration: InputDecoration(
                            labelText: 'Pairing link',
                            hintText: 'compii://pair?…',
                            suffixIcon: IconButton(
                              tooltip: 'Paste',
                              icon: const Glyph(G.clipboard),
                              onPressed: () async {
                                final d = await Clipboard.getData(Clipboard.kTextPlain);
                                if (d?.text != null) _paste.text = d!.text!;
                              },
                            ),
                          ),
                          onSubmitted: _use,
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: OutlinedButton(
                            onPressed: _busy ? null : () => _use(_paste.text),
                            child: Text(_busy ? 'Pairing…' : 'Pair'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: c.danger)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

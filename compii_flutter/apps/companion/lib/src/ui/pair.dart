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
import 'phone_voice.dart';
import 'shell.dart';
import 'tokens.dart';

const _linkKey = 'remote_link';
const _night = Color(0xFF1B1550);

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
        final latest = core.ordered.firstOrNull;
        if (latest != null && !latest.active) {
          await core.reply(latest.id, text);
        } else {
          await core.startConversation(text);
        }
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
      theme: compiiTheme(Brightness.light),
      darkTheme: compiiTheme(Brightness.dark),
      themeMode: widget.state.themeMode,
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
    const white = TextStyle(color: Colors.white);
    return Scaffold(
      backgroundColor: _night,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              children: [
                SizedBox(
                  height: 190,
                  child: Ember(mood: _busy ? Mood.thinking : (_error != null ? Mood.problem : Mood.happy), followPointer: false),
                ),
                const SizedBox(height: 8),
                Text('Pair with your PC',
                    textAlign: TextAlign.center,
                    style: context.type.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'On your PC open Compii → Settings → Phones → Pair a phone, then scan the code. '
                  'Pair on the same Wi-Fi. To use Compii when you’re out too, install Tailscale on both first.',
                  textAlign: TextAlign.center,
                  style: white.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                if (_scanning)
                  ClipRRect(
                    borderRadius: Shapes.r20,
                    child: SizedBox(
                      height: 300,
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
                else if (canScan)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => setState(() => _scanning = true),
                    icon: const Glyph(G.eye, color: Colors.white),
                    label: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('Scan the QR code')),
                  ),
                const SizedBox(height: 20),
                Theme(
                  data: compiiTheme(Brightness.dark),
                  child: Column(
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
                          labelText: canScan ? 'Or paste the pairing link' : 'Paste the pairing link',
                          hintText: 'compii://pair?…',
                          suffixIcon: IconButton(
                            tooltip: 'Paste',
                            icon: const Glyph(G.doc),
                            onPressed: () async {
                              final d = await Clipboard.getData(Clipboard.kTextPlain);
                              if (d?.text != null) _paste.text = d!.text!;
                            },
                          ),
                        ),
                        onSubmitted: _use,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _busy ? null : () => _use(_paste.text),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(_busy ? 'Pairing…' : 'Pair'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFFB4A9))),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

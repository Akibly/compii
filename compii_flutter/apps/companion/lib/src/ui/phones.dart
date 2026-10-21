import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../console/core_client.dart';
import 'thread.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'tokens.dart';

/// Settings → Phones: pair a phone with a QR code, see paired phones, remove them.
class PhonesSettings extends StatefulWidget {
  const PhonesSettings({super.key, required this.core, required this.run});
  final CoreClient core;
  final Run run;
  @override
  State<PhonesSettings> createState() => _PhonesSettingsState();
}

class _PhonesSettingsState extends State<PhonesSettings> {
  Map<String, dynamic>? _info;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.core.deviceEvents.stream.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await widget.core.devices();
      if (mounted) setState(() => _info = info);
    } on Object {
      // Core offline: the card says so
    }
  }

  Future<void> _pair() => widget.run(() async {
    final invite = await widget.core.pairStart();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => PairDialog(core: widget.core, invite: invite),
    );
    await _load();
  });

  Future<void> _remove(Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${d['name']}?'),
        content: const Text('It stops working with Compii right away. You can pair it again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.run(() async {
      final info = await widget.core.unpair('${d['id']}');
      if (mounted) setState(() => _info = info);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final devices = [for (final d in (_info?['devices'] as List? ?? const [])) Map<String, dynamic>.from(d as Map)];
    final error = _info?['error'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Phones', style: context.type.titleLarge),
        const SizedBox(height: 4),
        Text(
          _info?['anywhere'] == true
              ? 'Talk to Compii, see your screen, follow its work and approve actions from your phone, at home or away '
                  '(Tailscale is on). The connection is encrypted and only phones you pair here can use it.'
              : 'Talk to Compii, see your screen, follow its work and approve actions from your phone, on the same Wi-Fi. '
                  'Install Tailscale on this PC and the phone to use it from anywhere. Only phones you pair here can use it.',
          style: context.type.bodySmall,
        ),
        const SizedBox(height: 12),
        Container(
          decoration: Shapes.panel(c),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final d in devices) ...[
                OptionRow(
                  glyph: G.phone,
                  title: '${d['name']}',
                  subtitle: _seen(d),
                  color: c.muted,
                  trailing: TextButton(onPressed: () => _remove(d), child: const Text('Remove')),
                ),
                Divider(height: 1, color: c.border),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(error, style: context.type.bodySmall?.copyWith(color: c.danger)),
                ),
              OptionRow(
                glyph: G.phone,
                title: devices.isEmpty ? 'No phones paired yet' : 'Pair another phone',
                subtitle: 'Shows a QR code to scan with the Compii app on your phone.',
                color: c.accent,
                trailing: FilledButton(onPressed: _pair, child: const Text('Pair a phone')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _seen(Map<String, dynamic> d) {
    final last = d['last_seen'] as num?;
    if (last == null) return 'Paired, not connected yet';
    final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((last * 1000).round()));
    if (ago.inMinutes < 2) return 'Connected now';
    if (ago.inHours < 1) return 'Last seen ${ago.inMinutes} min ago';
    if (ago.inDays < 1) return 'Last seen ${ago.inHours} h ago';
    return 'Last seen ${ago.inDays} days ago';
  }
}

/// The QR code, the code in words, a countdown, and "waiting for your phone…".
/// Closes itself when the phone has paired.
class PairDialog extends StatefulWidget {
  const PairDialog({super.key, required this.core, required this.invite});
  final CoreClient core;
  final Map<String, dynamic> invite;
  @override
  State<PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<PairDialog> {
  late final StreamSubscription<Map<String, dynamic>> _sub;
  late final Timer _tick;
  String? _paired;

  DateTime get _expires =>
      DateTime.fromMillisecondsSinceEpoch(((widget.invite['expires'] as num) * 1000).round());

  @override
  void initState() {
    super.initState();
    _sub = widget.core.deviceEvents.stream.listen((e) {
      if (e['type'] != 'device_paired' || !mounted) return;
      setState(() => _paired = '${e['name']}');
      Future<void>.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) Navigator.of(context).pop();
      });
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final left = _expires.difference(DateTime.now());
    final expired = left.isNegative;
    final mm = left.inMinutes, ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return AlertDialog(
      title: Text(_paired != null ? 'Paired' : 'Pair a phone'),
      content: SizedBox(
        width: 320,
        child: _paired != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Glyph(G.check, size: 48, color: c.success),
                  const SizedBox(height: 12),
                  Text('$_paired can now talk to Compii.', textAlign: TextAlign.center),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      widget.invite['anywhere'] == true
                          ? 'Open Compii on your phone and scan this code. It will work at home and, through Tailscale, when you’re out.'
                          : 'Open Compii on your phone and scan this code. Phone and PC need to be on the same Wi-Fi.',
                      style: context.type.bodyMedium),
                  const SizedBox(height: 16),
                  Opacity(
                    opacity: expired ? .25 : 1,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                      child: QrImageView(
                        data: '${widget.invite['link']}',
                        size: 220,
                        backgroundColor: Colors.white,
                        semanticsLabel: 'Pairing QR code',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    '${widget.invite['code']}',
                    style: context.type.headlineSmall?.copyWith(letterSpacing: 3, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    expired ? 'This code has expired.' : 'Waiting for your phone… code works for $mm:$ss',
                    style: context.type.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'If Windows asks, allow Compii on private networks so the phone can reach this PC.',
                    textAlign: TextAlign.center,
                    style: context.type.bodySmall?.copyWith(color: c.faint),
                  ),
                ],
              ),
      ),
      actions: [
        if (_paired == null && expired)
          TextButton(
            onPressed: () async {
              final next = await widget.core.pairStart();
              widget.invite
                ..clear()
                ..addAll(next);
              setState(() {});
            },
            child: const Text('New code'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_paired != null ? 'Done' : 'Cancel')),
      ],
    );
  }
}

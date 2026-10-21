import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../console/core_client.dart';
import 'voice.dart';

/// Voice on a paired phone: the phone's own speech recognition (live words
/// while you talk) and its own text-to-speech voice. Free, and nothing goes
/// through the PC's microphone or speakers.
class PhoneVoice extends VoiceController {
  PhoneVoice(super.core) {
    core.addListener(_onTasks);
    _speech.setMethodCallHandler((call) async {
      speaking = call.method == 'start';
      if (!speaking) caption = '';
      notifyListeners();
    });
    _init();
  }

  final SpeechToText _stt = SpeechToText();
  static const _speech = MethodChannel('compii/speech');
  bool _available = false;
  String _mode = 'voice';
  Completer<String>? _final;

  /// Tasks already spoken (or present at start), so each answer is said once.
  final Set<String> _said = {};
  final Set<String> _askedAbout = {};
  bool _primed = false;

  @override
  bool get canListen => _available;
  @override
  String get outputMode => _mode;
  @override
  bool get naturalVoice => false;
  @override
  bool get wakeListening => false;

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _mode = p.getString('phone_output') ?? (p.getBool('phone_speak') == false ? 'off' : 'voice');
    } on Object {
      // defaults
    }
    try {
      _available = await _stt.initialize(
        onError: (e) {
          if (e.errorMsg != 'error_no_match' && e.errorMsg != 'error_speech_timeout') error = 'Didn’t catch that (${e.errorMsg}).';
          _complete();
        },
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') _complete();
        },
      );
    } on Object catch (e) {
      error = 'Speech recognition isn’t available on this phone: $e';
    }
    notifyListeners();
  }

  @override
  Future<void> refresh() async => notifyListeners();

  Future<void> setMode(String mode) async {
    _mode = mode;
    if (mode != 'voice') await quiet();
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString('phone_output', mode);
    } on Object {
      // not saved; still applies now
    }
  }

  @override
  Future<void> start() async {
    if (listening || busy) return;
    error = null;
    if (!_available) {
      error = 'Allow microphone access for Compii in your phone’s settings to talk.';
      notifyListeners();
      return;
    }
    await quiet();
    partial = '';
    level = 0;
    _final = Completer<String>();
    try {
      await _stt.listen(
        onResult: _onResult,
        onSoundLevelChange: (db) {
          // Android reports roughly -2..10 dB.
          level = ((db + 2) / 12).clamp(0.0, 1.0);
          notifyListeners();
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          pauseFor: const Duration(seconds: 3),
          listenFor: const Duration(seconds: 60),
        ),
      );
      listening = true;
    } on Object catch (e) {
      error = 'Couldn’t start listening: $e';
      _final = null;
    }
    notifyListeners();
  }

  void _onResult(SpeechRecognitionResult r) {
    partial = r.recognizedWords;
    notifyListeners();
    if (r.finalResult) _complete();
  }

  void _complete() {
    final f = _final;
    if (f != null && !f.isCompleted) f.complete(partial);
    if (listening) {
      listening = false;
      level = 0;
      // The phone stopped on its own (you paused): send what it heard.
      _deliver(f);
    }
    notifyListeners();
  }

  bool _delivering = false;

  Future<void> _deliver(Completer<String>? f) async {
    if (_delivering || f == null) return;
    _delivering = true;
    busy = true;
    notifyListeners();
    try {
      final text = (await f.future.timeout(const Duration(seconds: 3), onTimeout: () => partial)).trim();
      if (text.isNotEmpty) await onHeard?.call(text);
    } on Object catch (e) {
      error = '$e';
    } finally {
      busy = false;
      partial = '';
      _final = null;
      _delivering = false;
      notifyListeners();
    }
  }

  @override
  Future<void> finish() async {
    if (!listening) return;
    final f = _final;
    listening = false;
    level = 0;
    notifyListeners();
    try {
      await _stt.stop();
    } on Object {
      // fall through with what we have
    }
    await _deliver(f);
  }

  @override
  Future<void> cancel() async {
    listening = false;
    partial = '';
    _final = null;
    notifyListeners();
    try {
      await _stt.cancel();
    } on Object {
      // nothing to cancel
    }
  }

  @override
  Future<void> quiet() async {
    speaking = false;
    caption = '';
    notifyListeners();
    try {
      await _speech.invokeMethod('stop');
    } on Object {
      // not on Android
    }
  }

  Future<void> say(String text) async {
    text = text.trim();
    if (_mode == 'off' || text.isEmpty || listening) return;
    caption = text;
    captionAt = DateTime.now();
    if (_mode != 'voice') {
      if (_mode == 'sound') {
        try {
          await _speech.invokeMethod('chime');
        } on Object {
          // no tone available; the words on screen still arrive
        }
      }
      notifyListeners();
      return;
    }
    try {
      final ok = await _speech.invokeMethod<bool>('speak', {'text': text});
      if (ok == true) {
        speaking = true;
      } else {
        caption = '';
      }
    } on Object {
      caption = ''; // no phone voice here (e.g. testing on Windows)
    }
    notifyListeners();
  }

  /// Say finished answers and approval questions out loud, once each.
  void _onTasks() {
    if (core.status != CoreStatus.online) return;
    final tasks = core.ordered;
    if (!_primed) {
      // Don't read out history when the app opens.
      for (final t in tasks) {
        _said.add(_key(t));
        if (t.pendingApproval case final a?) _askedAbout.add('${t.id}:approval:${a['approval_id']}');
        if (t.pendingQuestion case final q?) _askedAbout.add('${t.id}:question:${q['question_id']}');
      }
      _primed = true;
      return;
    }
    for (final t in tasks) {
      final q = t.pendingQuestion;
      if (q != null && _askedAbout.add('${t.id}:question:${q['question_id']}')) {
        say('I need to ask you something. ${q['question']}');
        return;
      }
      final a = t.pendingApproval;
      if (a != null && _askedAbout.add('${t.id}:approval:${a['approval_id']}')) {
        say('Okay to go ahead? ${a['label']}');
        return;
      }
      if (!t.active && t.finalText != null && _said.add(_key(t))) {
        say(spokenVersion(t.finalText!));
        return;
      }
    }
  }

  String _key(TaskView t) => '${t.id}:${t.events.length}:${t.finalText?.hashCode}';

  @override
  void dispose() {
    core.removeListener(_onTasks);
    _stt.cancel();
    super.dispose();
  }
}

/// A short, speakable version of an answer: no markdown, links or lists, at most two sentences.
@visibleForTesting
String spokenVersion(String text) {
  var s = text
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1')
      .replaceAll(RegExp(r'https?://\S+'), 'a link')
      .replaceAll(RegExp(r'[*_`#>|]'), '')
      .replaceAll(RegExp(r'^\s*[-•\d.]+\s+', multiLine: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final sentences = RegExp(r'[^.!?]+[.!?]*').allMatches(s).map((m) => m.group(0)!.trim()).where((x) => x.isNotEmpty).toList();
  if (sentences.length > 2) s = '${sentences.take(2).join(' ')} The rest is on screen.';
  return s.length > 320 ? '${s.substring(0, 300).trimRight()}… The rest is on screen.' : s;
}

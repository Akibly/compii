import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum Presentation { face, fullBody }

enum WispExpression { curious, listening, thinking, explaining, resting }

enum CompanionMode { teach, collaborate, execute }

class CompanionPreferences extends ChangeNotifier {
  CompanionPreferences(this.storage);
  final SharedPreferencesAsync storage;
  Presentation presentation = Presentation.face;
  bool floating = true;
  bool reducedMotion = false;
  String? error;
  Future<void> _writes = Future.value();

  Future<void> load() async {
    try {
      presentation =
          await storage.getString('compii.presentation') == 'full_body'
          ? Presentation.fullBody
          : Presentation.face;
      floating = await storage.getBool('compii.floating') ?? true;
      reducedMotion = await storage.getBool('compii.reducedMotion') ?? false;
    } catch (_) {
      error = 'Appearance could not be loaded. Default view is shown.';
    }
    notifyListeners();
  }

  Future<void> update({Presentation? view, bool? float, bool? reduce}) {
    presentation = view ?? presentation;
    floating = float ?? floating;
    reducedMotion = reduce ?? reducedMotion;
    final selected = presentation;
    final drift = floating;
    final quiet = reducedMotion;
    notifyListeners();
    // Serial writes prevent an older selection overwriting the newest one.
    _writes = _writes.then((_) async {
      try {
        await storage.setString(
          'compii.presentation',
          selected == Presentation.face ? 'face' : 'full_body',
        );
        await storage.setBool('compii.floating', drift);
        await storage.setBool('compii.reducedMotion', quiet);
        error = null;
      } catch (_) {
        error =
            'Could not save appearance. Your choice works until you close Compii.';
      }
      notifyListeners();
    });
    return _writes;
  }
}

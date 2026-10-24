
import 'package:flutter/services.dart';

import 'island_geometry.dart';

/// The app the user was in before the island took focus. `handle` is only a
/// number; it is used to give focus back, never shown or stored. `fullscreen`
/// means that window owns its whole monitor — a game, a slideshow, a video —
/// so nothing may be popped over it.
class ForegroundWindow {
  const ForegroundWindow({required this.handle, required this.title, this.fullscreen = false});
  final int handle;
  final String title;
  final bool fullscreen;

  static const none = ForegroundWindow(handle: 0, title: '');
  bool get found => handle != 0;
}

/// Everything the island needs from Windows, behind one seam so the widget
/// tests can run on the Dart VM with a fake.
abstract class IslandPlatform {
  /// One island per desktop: false means another copy is already running.
  Future<bool> claim();

  /// The window's physical rect on the virtual desktop (top-left may be
  /// negative on a monitor left of or above the primary one).
  Future<Rect?> windowBounds();
  Future<void> moveTo(Offset physicalTopLeft);

  Future<List<IslandDisplay>> displays();
  Future<Offset?> cursor();

  /// Mouse events pass through the whole window (true) or are caught by it.
  Future<void> clickThrough(bool through);

  /// Raise and activate the island so it can be typed into.
  Future<void> focus();
  Future<void> hide();

  Future<ForegroundWindow> foreground();

  /// Give focus back to [handle], but only while one of our windows still has
  /// it — if the user has moved on, their new window is left alone.
  Future<bool> restore(int handle);

  /// Bring the main Compii window forward (used by "Open in Compii").
  Future<bool> revealMain();

  /// A real Windows notification. Only used when the user asked to be told by
  /// notification; tests and other platforms quietly do nothing.
  Future<void> toast(String title, String body);
}

class NativeIslandPlatform implements IslandPlatform {
  const NativeIslandPlatform();

  static const _channel = MethodChannel('compii/island');

  /// The island is a separate process with the same runner, so the overlay
  /// channel (which owns the toast) is registered here too.
  static const _toastChannel = MethodChannel('compii/overlay');

  @override
  Future<bool> claim() async {
    try {
      return await _channel.invokeMethod<bool>('claim') ?? true;
    } on MissingPluginException {
      return true; // previews and widget tests: no native window to share
    } on PlatformException {
      return true;
    }
  }

  @override
  Future<Rect?> windowBounds() async {
    try {
      final r = await _channel.invokeListMethod<double>('bounds');
      if (r == null || r.length < 4) return null;
      return Rect.fromLTWH(r[0], r[1], r[2], r[3]);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> moveTo(Offset physicalTopLeft) async {
    try {
      await _channel.invokeMethod<void>('move', {'x': physicalTopLeft.dx, 'y': physicalTopLeft.dy});
    } on MissingPluginException {
      // no native window (tests / previews)
    } on PlatformException {
      // a move that fails leaves the island where it was; the next display
      // clamp tries again, so nothing is lost
    }
  }

  @override
  Future<List<IslandDisplay>> displays() async {
    try {
      final list = await _channel.invokeListMethod<Object?>('displays');
      return [
        for (final d in list ?? const [])
          if (d is Map) IslandDisplay.fromMap(d),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<Offset?> cursor() async {
    try {
      final p = await _channel.invokeListMethod<double>('cursor');
      if (p == null || p.length < 2) return null;
      return Offset(p[0], p[1]);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> clickThrough(bool through) async {
    try {
      await _channel.invokeMethod<void>('clickThrough', through);
    } on MissingPluginException {
      // nothing to pass through
    } on PlatformException {
      // the native side owns this bit; a failed call leaves its last state
    }
  }

  @override
  Future<void> focus() async {
    try {
      await _channel.invokeMethod<void>('focus');
    } on MissingPluginException {
      // tests / previews
    } on PlatformException {
      // the hotkey still brought the card up; typing needs the real window
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      // tests / previews
    } on PlatformException {
      // ignore
    }
  }

  @override
  Future<ForegroundWindow> foreground() async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('foreground');
      if (map == null) return ForegroundWindow.none;
      final handle = (map['handle'] as num?)?.toInt() ?? 0;
      return ForegroundWindow(
        handle: handle,
        title: '${map['title'] ?? ''}',
        fullscreen: map['fullscreen'] == true,
      );
    } on MissingPluginException {
      return ForegroundWindow.none;
    } on PlatformException {
      return ForegroundWindow.none;
    }
  }

  @override
  Future<bool> restore(int handle) async {
    try {
      return await _channel.invokeMethod<bool>('restore', handle.toDouble()) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> revealMain() async {
    try {
      return await _channel.invokeMethod<bool>('revealMain') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> toast(String title, String body) async {
    try {
      await _toastChannel.invokeMethod<void>('toast', {'title': title, 'body': body});
    } on MissingPluginException {
      // no native side (tests, other platforms)
    } on PlatformException {
      // a notification the OS refused to take is not worth failing the turn over
    }
  }
}

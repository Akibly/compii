import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../console/core_client.dart' show RemoteLink;

/// What the phone shell needs from Android: alerts when the app is away, a
/// home-screen widget, and text or links shared into Compii from other apps.
abstract interface class PhoneAlerts {
  /// Taps on notifications, taps on the widget, and shares from other apps.
  Stream<Map<String, dynamic>> get events;
  Future<bool> notificationsAllowed();
  Future<bool> requestNotifications();
  Future<void> notify({
    required String tag,
    required String title,
    required String body,
    String destination = 'chats',
  });
  Future<void> cancel(String tag);
  Future<void> cancelAll();
  Future<void> widget({required String headline, required String detail, String meta = ''});
  Future<void> openNotificationSettings();

  /// Keep a link to the paired PC while the app is closed, so approvals (with
  /// Approve and Deny buttons), answers and briefs still arrive. True when it
  /// is running.
  Future<bool> startLink(RemoteLink link);
  Future<void> stopLink();
}

/// The real Android side. On any other platform every call is a quiet no-op,
/// so the same UI runs on Windows for testing.
class PhoneBridge implements PhoneAlerts {
  PhoneBridge._();
  static final PhoneBridge instance = PhoneBridge._();

  static const _methods = MethodChannel('compii/phone');
  static const _events = EventChannel('compii/phone_events');

  bool get _here => Platform.isAndroid;

  Stream<Map<String, dynamic>>? _stream;

  @override
  Stream<Map<String, dynamic>> get events => _stream ??= _here
      ? _events.receiveBroadcastStream().map((e) {
          try {
            return e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{};
          } on Object {
            return <String, dynamic>{};
          }
        }).where((e) => e.isNotEmpty)
      : const Stream.empty();

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    if (!_here) return null;
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> notificationsAllowed() async => await _call<bool>('notificationsAllowed') ?? false;

  @override
  Future<bool> requestNotifications() async => await _call<bool>('requestNotifications') ?? false;

  @override
  Future<void> notify({
    required String tag,
    required String title,
    required String body,
    String destination = 'chats',
  }) =>
      _call('notify', {'tag': tag, 'title': title, 'body': body, 'destination': destination});

  @override
  Future<void> cancel(String tag) => _call('cancel', {'tag': tag});

  @override
  Future<void> cancelAll() => _call('cancelAll');

  @override
  Future<void> widget({required String headline, required String detail, String meta = ''}) =>
      _call('widget', {'headline': headline, 'detail': detail, 'meta': meta});

  @override
  Future<void> openNotificationSettings() => _call('openNotificationSettings');

  @override
  Future<bool> startLink(RemoteLink link) async =>
      await _call<bool>('startLink', {
        'hosts': link.hosts,
        'port': link.port,
        'fingerprint': link.fingerprint,
        'token': link.token,
        'pc': link.pc,
      }) ??
      false;

  @override
  Future<void> stopLink() => _call('stopLink');
}

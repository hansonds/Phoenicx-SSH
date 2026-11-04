import 'dart:io';

import 'package:flutter/services.dart';

import 'store.dart';

/// Android only: a foreground service (with a small notification) that keeps
/// the app process, network and CPU alive while SSH sessions are open, so the
/// connections are not dropped when the screen is off or the app is in the
/// background. Does nothing on Windows.
class KeepAlive {
  static const _ch = MethodChannel('phoenicx_ssh/keepalive');
  static int _last = -1;

  static Future<void> update(int sessions) async {
    if (!Platform.isAndroid) return;
    if (sessions == _last) return;
    _last = sessions;
    try {
      if (sessions > 0) {
        await _ch.invokeMethod('start', {
          'text': sessions == 1
              ? '1 SSH session connected'
              : '$sessions SSH sessions connected',
          'wakeLock': Store.I.settings.keepCpuAwake,
        });
      } else {
        await _ch.invokeMethod('stop');
      }
    } catch (_) {}
  }

  /// Re-apply after the wake-lock setting changes.
  static Future<void> refresh() async {
    final n = _last;
    _last = -1;
    if (n > 0) await update(n);
  }

  static Future<void> requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('notifPermission');
    } catch (_) {}
  }

  static Future<void> requestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('battery');
    } catch (_) {}
  }

  /// Send the app to the background without finishing it.
  static Future<bool> moveToBack() async {
    if (!Platform.isAndroid) return false;
    try {
      await _ch.invokeMethod('background');
      return true;
    } catch (_) {
      return false;
    }
  }
}

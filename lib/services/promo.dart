import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'store.dart';

/// Share the app and ask for a Play Store rating.
class Promo {
  static const packageId = 'com.hanson.phoenicx_ssh';
  static const storeUrl = 'https://play.google.com/store/apps/details?id=$packageId';

  static const shareText = 'Phoenicx SSH — a free SSH client for Android and Windows.\n'
      '• Sessions stay connected until you close them\n'
      '• Upload and download files (SFTP)\n'
      '• Live server monitor: CPU, RAM, network, processes, Docker\n\n'
      'Get it on Google Play: $storeUrl';

  /// Opens the system share sheet with the promo picture + the Play link.
  static Future<void> shareApp(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      final data = await rootBundle.load('assets/share.jpg');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/phoenicx-ssh.jpg');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      await SharePlus.instance.share(ShareParams(
        text: shareText,
        subject: 'Phoenicx SSH',
        title: 'Share Phoenicx SSH',
        files: [XFile(f.path, mimeType: 'image/jpeg')],
        sharePositionOrigin: origin,
      ));
    } catch (_) {
      // Picture failed for some reason: share the text and link alone.
      await SharePlus.instance.share(ShareParams(text: shareText, subject: 'Phoenicx SSH', sharePositionOrigin: origin));
    }
  }

  /// "Rate on Google Play" button: always opens the app's Play page.
  /// (Google asks apps not to trigger the in-app rating popup from a button,
  /// because its quota means the popup may silently not appear.)
  static Future<void> rateOnPlay() async {
    try {
      final ok = await launchUrl(Uri.parse('market://details?id=$packageId'), mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {}
    await launchUrl(Uri.parse(storeUrl), mode: LaunchMode.externalApplication);
  }

  /// Called once per app start (Android). After the 5th start, asks Google
  /// once for the in-app rating popup. Google decides whether it actually
  /// shows (only for Play installs, limited per user).
  static Future<void> onLaunch() async {
    if (!Platform.isAndroid) return;
    final s = Store.I.settings;
    s.launchCount++;
    final ask = !s.reviewAsked && s.launchCount >= 5;
    if (ask) s.reviewAsked = true;
    await Store.I.saveSettings();
    if (!ask) return;
    // Give the user a moment with the app first.
    await Future.delayed(const Duration(seconds: 25));
    try {
      final r = InAppReview.instance;
      if (await r.isAvailable()) await r.requestReview();
    } catch (_) {}
  }
}

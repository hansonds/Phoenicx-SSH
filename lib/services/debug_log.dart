import 'dart:io';

/// Key/input diagnostics, only active when PHOENICX_KEYLOG is set (tests).
class DebugLog {
  static final String? _path = Platform.environment['PHOENICX_KEYLOG'];
  static bool get on => _path != null && _path!.isNotEmpty;

  static void log(String msg) {
    if (!on) return;
    try {
      File(_path!).writeAsStringSync(
          '${DateTime.now().toIso8601String()} $msg\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}

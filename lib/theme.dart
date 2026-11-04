import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class PX {
  static const bg = Color(0xFF09090D);
  static const surface = Color(0xFF15151C);
  static const surface2 = Color(0xFF1E1E28);
  static const line = Color(0xFF2A2A36);
  static const accent = Color(0xFFFF6A2B);
  static const accent2 = Color(0xFFFFB347);
  static const text = Color(0xFFF4F1EC);
  static const muted = Color(0xFF9C98A6);
  static const green = Color(0xFF4ADE80);
  static const blue = Color(0xFF60A5FA);
  static const purple = Color(0xFFC084FC);
  static const red = Color(0xFFF87171);
  static const yellow = Color(0xFFFACC15);

  static const fire = LinearGradient(
    colors: [Color(0xFFFF3D2E), accent, accent2],
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
  );

  /// Colour tags a host can be given in the editor.
  static const tags = <Color>[
    accent,
    Color(0xFF60A5FA),
    Color(0xFF4ADE80),
    Color(0xFFC084FC),
    Color(0xFFFACC15),
    Color(0xFFF472B6),
    Color(0xFF2DD4BF),
    Color(0xFF9C98A6),
  ];

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        surface: surface,
        primary: accent,
      ),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerColor: line,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
    );
  }

  static const terminal = TerminalTheme(
    cursor: Color(0xFFFF8A4C),
    selection: Color(0x66FF8A4C),
    foreground: Color(0xFFE8E6E3),
    background: Color(0xFF0B0B10),
    black: Color(0xFF1E1E28),
    red: Color(0xFFF87171),
    green: Color(0xFF4ADE80),
    yellow: Color(0xFFFACC15),
    blue: Color(0xFF60A5FA),
    magenta: Color(0xFFC084FC),
    cyan: Color(0xFF2DD4BF),
    white: Color(0xFFD4D4D8),
    brightBlack: Color(0xFF71717A),
    brightRed: Color(0xFFFCA5A5),
    brightGreen: Color(0xFF86EFAC),
    brightYellow: Color(0xFFFDE68A),
    brightBlue: Color(0xFF93C5FD),
    brightMagenta: Color(0xFFD8B4FE),
    brightCyan: Color(0xFF5EEAD4),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFACC15),
    searchHitBackgroundCurrent: Color(0xFFFF6A2B),
    searchHitForeground: Color(0xFF000000),
  );
}

class Layout {
  static bool wide(BuildContext c) => MediaQuery.sizeOf(c).width >= 900;
}

String fmtBytes(num bytes, {int digits = 1}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : digits)} ${units[i]}';
}

String fmtRate(num bytesPerSec) => '${fmtBytes(bytesPerSec)}/s';

String fmtDuration(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

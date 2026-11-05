import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// TCP socket for SSH with Nagle's algorithm switched off (TCP_NODELAY),
/// like PuTTY/OpenSSH do for interactive sessions. Without it every
/// keystroke can wait up to ~200 ms for the previous packet's ACK, which is
/// what makes typing feel laggy.
class FastSocket implements SSHSocket {
  final Socket _s;
  FastSocket._(this._s);

  static Future<SSHSocket> connect(String host, int port, {Duration? timeout}) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    return FastSocket._(s);
  }

  @override
  Stream<Uint8List> get stream => _s;

  @override
  StreamSink<List<int>> get sink => _s;

  @override
  Future<void> get done => _s.done;

  @override
  Future<void> close() async {
    await _s.close();
  }

  @override
  void destroy() => _s.destroy();

  @override
  Future<void> flush() async {
    await _s.flush();
  }
}

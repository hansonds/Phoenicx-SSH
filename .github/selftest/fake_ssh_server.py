"""Tiny SSH server for the Windows typing test.

Accepts user "test" / password "test", gives an interactive shell that echoes
what is typed and logs every received byte to the file given as argv[1].
Exec requests (used by the app's monitor) are answered and closed at once.
"""
import socket
import sys
import threading
import time

import paramiko

LOG = sys.argv[1]
KEY = paramiko.RSAKey.generate(2048)
shells = set()


class Server(paramiko.ServerInterface):
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def get_allowed_auths(self, username):
        return "password"

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ("test", "test") else paramiko.AUTH_FAILED

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_window_change_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        shells.add(channel.get_id())
        return True

    def check_channel_exec_request(self, channel, command):
        def done():
            try:
                channel.send_exit_status(0)
                channel.close()
            except Exception:
                pass

        threading.Timer(0.2, done).start()
        return True

    def check_global_request(self, kind, msg):
        return True


def shell(chan):
    for _ in range(40):
        if chan.get_id() in shells:
            break
        time.sleep(0.05)
    else:
        return
    chan.send(b"Welcome to the Phoenicx SSH typing test\r\nphx$ ")
    while True:
        data = chan.recv(1024)
        if not data:
            break
        with open(LOG, "ab") as f:
            f.write(data)
        with open(LOG + ".t", "a") as f:
            f.write("%.4f %s\n" % (time.time(), data.hex()))
        out = data.replace(b"\r", b"\r\n")
        if b"\r" in data:
            out += b"phx$ "
        chan.send(out)


def handle(sock):
    t = paramiko.Transport(sock)
    t.add_server_key(KEY)
    t.start_server(server=Server())
    while t.is_active():
        chan = t.accept(5)
        if chan is not None:
            threading.Thread(target=shell, args=(chan,), daemon=True).start()


s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 2222))
s.listen(5)
print("fake ssh server ready", flush=True)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()

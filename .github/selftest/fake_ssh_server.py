"""Tiny SSH server for the Windows typing test.

Accepts user "test" / password "test", gives an interactive shell that echoes
what is typed and logs every received byte to the file given as argv[1].
Exec requests (used by the app's monitor) are answered and closed at once.
"""
import os
import posixpath
import socket
import sys
import threading
import time

import paramiko

LOG = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2222
# Demo mode (store screenshots): realistic Ubuntu shell + SFTP on a demo folder.
DEMO_ROOT = os.environ.get("PHX_DEMO_ROOT")  # real folder that is "/" for SFTP
KEY = paramiko.RSAKey.generate(2048)
shells = set()


class Server(paramiko.ServerInterface):
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def get_allowed_auths(self, username):
        return "password"

    def check_auth_password(self, username, password):
        ok = (username, password) in (("test", "test"), ("ubuntu", "demo"))
        return paramiko.AUTH_SUCCESSFUL if ok else paramiko.AUTH_FAILED

    def check_channel_pty_request(self, *args):
        return True

    def check_channel_window_change_request(self, *args):
        return True

    def check_channel_shell_request(self, channel):
        shells.add(channel.get_id())
        return True

    def check_channel_exec_request(self, channel, command):
        if b"PRETTY_NAME" in command:
            def info():
                channel.send(b"oracle-mumbai\nUbuntu 24.04.1 LTS\n6.8.0-1015-oracle\naarch64\n")
                channel.send_exit_status(0)
                channel.close()
            threading.Timer(0.1, info).start()
            return True
        if b"@@S" in command:
            full = command.startswith(b"FULL=1")
            threading.Thread(target=fake_monitor, args=(channel, full), daemon=True).start()
            return True

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


PROCS = [
    ("jellyfin", 2.5, 310000), ("dockerd", 0.6, 22000), ("containerd", 0.3, 12000),
    ("rclone", 1.8, 64000), ("python3", 0.9, 18000), ("caddy", 0.2, 9000),
    ("ffmpeg", 4.0, 52000), ("node", 0.7, 30000), ("sshd-session", 0.1, 2400),
    ("systemd", 0.05, 3200), ("bash", 0.0, 1300), ("tg_video_bot", 0.4, 15000),
    ("wireguard", 0.1, 800), ("rustdesk", 0.3, 7000), ("snapd", 0.05, 8000),
]


def fake_monitor(chan, full):
    import math, random
    cores = 4
    jif = [[0] * 8 for _ in range(cores)]
    rx = tx = 4_200_000_000
    rd = wr = 9_000_000
    ticks = [0] * len(PROCS)
    i = 0
    try:
        while True:
            t = time.time()
            out = ["@@S 4096 %d" % cores]
            for c in range(cores):
                use = 35 + 30 * math.sin(t / 7 + c) + random.uniform(-8, 8)
                use = max(3, min(97, use))
                jif[c][0] += int(use * 0.8); jif[c][2] += int(use * 0.2)
                jif[c][3] += int(100 - use); jif[c][4] += random.randint(0, 2); jif[c][7] += random.randint(0, 2)
            tot = [sum(j[k] for j in jif) for k in range(8)]
            out.append("cpu  " + " ".join(map(str, tot)) + " 0 0")
            for c in range(cores):
                out.append("cpu%d " % c + " ".join(map(str, jif[c])) + " 0 0")
            used = 7_800_000 + int(1_500_000 * math.sin(t / 11))
            out += ["@@M", "MemTotal:       24576000 kB", "MemFree:        %d kB" % (24576000 - used - 6_000_000),
                    "MemAvailable:   %d kB" % (24576000 - used), "Buffers:          300000 kB",
                    "Cached:          5200000 kB", "SReclaimable:     500000 kB",
                    "SwapTotal:       4194300 kB", "SwapFree:        3900000 kB"]
            rx += int(900_000 + 700_000 * abs(math.sin(t / 5)) + random.randint(0, 300_000))
            tx += int(120_000 + 90_000 * abs(math.cos(t / 4)))
            out += ["@@N", "    lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0",
                    "enp0s6: %d 1000 0 0 0 0 0 0 %d 900 0 0 0 0 0 0" % (rx, tx),
                    "docker0: 5000 10 0 0 0 0 0 0 5000 10 0 0 0 0 0 0"]
            out += ["@@L", "1.%02d 0.98 0.85 2/412 9876" % random.randint(0, 99), "%d.00 400000.00" % (380000 + i)]
            out += ["@@D", "/dev/sda1 181600000 28900000 152700000 16% /",
                    "/dev/sda16 900000 197000 703000 22% /boot",
                    "/dev/sda15 99800 6300 93500 6% /boot/efi",
                    "torbox: 1073741824 0 1073741824 0% /mnt/torbox"]
            rd += random.randint(0, 400); wr += random.randint(20, 900)
            out += ["@@I", "sda %d %d" % (rd, wr)]
            if full:
                out.append("@@P")
                for k, (name, rate, rss) in enumerate(PROCS):
                    ticks[k] += int(rate * random.uniform(0.5, 1.6) * 10)
                    out.append("%d\t%s\t%d\t%d" % (1000 + k * 37, name, ticks[k], rss // 4))
                if i % 3 == 0:
                    out += ["@@C", "jellyfin|%.2f%%|1.21GiB / 23.4GiB|5.17%%|2.1GB / 45.3MB|0B / 12.6MB" % random.uniform(8, 30),
                            "movie_bot|0.42%|86.2MiB / 23.4GiB|0.36%|15.2MB / 9.8MB|0B / 1.2MB",
                            "caddy|0.10%|31.5MiB / 23.4GiB|0.13%|820MB / 790MB|0B / 0B",
                            "wireguard|0.05%|12.1MiB / 23.4GiB|0.05%|1.1GB / 1.3GB|0B / 0B"]
            out.append("@@E")
            chan.send(("\n".join(out) + "\n").encode())
            i += 1
            time.sleep(1.5)
    except Exception:
        pass


def event(msg):
    with open(LOG + ".events", "a") as f:
        f.write("%.3f %s\n" % (time.time(), msg))


def shell(chan):
    for _ in range(40):
        if chan.get_id() in shells:
            break
        time.sleep(0.05)
    else:
        return
    if DEMO_ROOT:
        demo_shell(chan)
        return
    chan.send(b"Welcome to the Phoenicx SSH typing test\r\nphx$ ")
    while True:
        try:
            data = chan.recv(1024)
        except Exception as e:
            event("shell error %r" % e)
            break
        if not data:
            event("shell closed by client" if chan.closed or chan.eof_received else "shell ended")
            break
        with open(LOG, "ab") as f:
            f.write(data)
        with open(LOG + ".t", "a") as f:
            f.write("%.4f %s\n" % (time.time(), data.hex()))
        out = data.replace(b"\r", b"\r\n")
        if b"\r" in data:
            out += b"phx$ "
        chan.send(out)


G = "\x1b[01;32m"; B = "\x1b[01;34m"; R = "\x1b[0m"; C = "\x1b[01;36m"; Y = "\x1b[33m"
PROMPT = G + "ubuntu@oracle-mumbai" + R + ":" + B + "~" + R + "$ "
BANNER = (
    "Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-1015-oracle aarch64)\n\n"
    " * Documentation:  https://help.ubuntu.com\n"
    " * Management:     https://landscape.canonical.com\n\n"
    "  System information as of Wed Nov 25 11:42:08 IST 2026\n\n"
    "  System load:  1.32               Processes:             212\n"
    "  Usage of /:   16.1% of 173.18GB  Users logged in:       1\n"
    "  Memory usage: 26%                IPv4 address for enp0s6: 10.0.0.42\n"
    "  Swap usage:   7%\n\n"
    "Last login: Wed Nov 25 09:14:51 2026 from 49.37.120.18\n"
)
SCRIPT = [
    ("uptime", " 11:42:15 up 4 days,  9:03,  1 user,  load average: 1.32, 0.98, 0.85\n"),
    ("docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'",
     "NAMES       STATUS        PORTS\n"
     "jellyfin    Up 4 days     0.0.0.0:8096->8096/tcp\n"
     "caddy       Up 4 days     0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp\n"
     "movie_bot   Up 2 days\n"
     "wireguard   Up 4 days     0.0.0.0:51820->51820/udp\n"),
    ("free -h",
     "               total        used        free      shared  buff/cache   available\n"
     "Mem:            23Gi       6.2Gi       9.8Gi        52Mi       7.4Gi        16Gi\n"
     "Swap:          4.0Gi       287Mi       3.7Gi\n"),
    ("df -h /",
     "Filesystem      Size  Used Avail Use% Mounted on\n"
     "/dev/sda1       174G   28G  146G  16% /\n"),
    ("ls",
     B + "jellyfin" + R + "  " + B + "movie_bot" + R + "  " + B + "backups" + R + "  " + C + "media" + R + "  update.sh\n"),
]


def demo_shell(chan):
    def out(text):
        chan.send(text.replace("\n", "\r\n").encode())
    out(BANNER)
    for cmd, res in SCRIPT:
        out(PROMPT)
        time.sleep(0.15)
        out(cmd + "\n")
        out(res)
    out(PROMPT)
    while True:
        try:
            data = chan.recv(1024)
        except Exception:
            break
        if not data:
            break
        o = data.replace(b"\r", b"\r\n")
        if b"\r" in data:
            o += PROMPT.encode()
        chan.send(o)


class DemoSFTPHandle(paramiko.SFTPHandle):
    def stat(self):
        try:
            return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def chattr(self, attr):
        return paramiko.SFTP_OK


class DemoSFTP(paramiko.SFTPServerInterface):
    def __init__(self, server, *a, **k):
        super().__init__(server, *a, **k)

    def _real(self, path):
        return os.path.join(DEMO_ROOT, self.canonicalize(path).lstrip("/"))

    def canonicalize(self, path):
        if path in ("", "."):
            return "/home/ubuntu"
        if not path.startswith("/"):
            path = "/home/ubuntu/" + path
        return posixpath.normpath(path)

    def list_folder(self, path):
        real = self._real(path)
        try:
            out = []
            for name in os.listdir(real):
                attr = paramiko.SFTPAttributes.from_stat(os.stat(os.path.join(real, name)))
                attr.filename = name
                out.append(attr)
            return out
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(os.stat(self._real(path)))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    lstat = stat

    def open(self, path, flags, attr):
        real = self._real(path)
        try:
            binary = getattr(os, "O_BINARY", 0)
            fd = os.open(real, flags | binary, 0o644)
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        if flags & os.O_WRONLY:
            mode = "ab" if flags & os.O_APPEND else "wb"
        elif flags & os.O_RDWR:
            mode = "a+b" if flags & os.O_APPEND else "r+b"
        else:
            mode = "rb"
        f = os.fdopen(fd, mode)
        h = DemoSFTPHandle(flags)
        h.filename = real
        h.readfile = f
        h.writefile = f
        return h

    def remove(self, path):
        try:
            os.remove(self._real(path))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK

    def rename(self, old, new):
        try:
            os.rename(self._real(old), self._real(new))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK

    def mkdir(self, path, attr):
        try:
            os.mkdir(self._real(path))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK

    def rmdir(self, path):
        try:
            os.rmdir(self._real(path))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK

    def chattr(self, path, attr):
        return paramiko.SFTP_OK


def handle(sock):
    t = paramiko.Transport(sock)
    t.add_server_key(KEY)
    if DEMO_ROOT:
        t.set_subsystem_handler("sftp", paramiko.SFTPServer, DemoSFTP)
    t.start_server(server=Server())
    while t.is_active():
        chan = t.accept(5)
        if chan is not None:
            threading.Thread(target=shell, args=(chan,), daemon=True).start()
    event("connection closed")


s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT))
s.listen(5)
print("fake ssh server ready", flush=True)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()

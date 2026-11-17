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

#!/bin/bash
# Full-resolution screenshots of the real app for the Play Store listing.
set -x
mkdir -p store
SIZE=$(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1); W=${SIZE%x*}; H=${SIZE#*x}
tap() { adb shell input tap $((W*$1/1000)) $((H*$2/1000)); sleep ${3:-2}; }
kbdown() { adb shell dumpsys input_method | grep -q 'mInputShown=true' && adb shell input keyevent 4; sleep 1; }
shot() { adb exec-out screencap -p > "store/$1.png"; }
TB=124   # toolbar row (per mille of height)
# Tap a button by its tooltip / accessibility label (position-independent).
tapdesc() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1
  XY=$(python3 - "$1" <<'PY'
import re,sys
import html
x=open('/tmp/ui.xml',encoding='utf-8',errors='ignore').read()
want=sys.argv[1].lower()
nodes=[]
for m in re.finditer(r'<node [^>]*>', x):
    n=m.group(0)
    d=re.search(r'content-desc="([^"]*)"',n); t=re.search(r' text="([^"]*)"',n)
    d=html.unescape(d.group(1)).lower() if d else ''; t=html.unescape(t.group(1)).lower() if t else ''
    b=list(map(int,re.findall(r'\d+',re.search(r'bounds="([^"]*)"',n).group(1))))
    nodes.append((d,t,b))
# exact text, then label starting with it, then label containing it
for test in (lambda d,t: t==want or d==want, lambda d,t: d.startswith(want), lambda d,t: want in d or want in t):
    hit=[b for d,t,b in nodes if test(d,t)]
    if hit:
        b=hit[0]; print((b[0]+b[2])//2,(b[1]+b[3])//2); break
PY
)
  echo "tapdesc '$1' -> $XY"
  if [ -n "$XY" ]; then adb shell input tap $XY; else echo "NOT FOUND: $1"; fi
  sleep ${2:-2}
}

# 1) Terminal with real output (the monitor is open from the earlier test: switch back)
tap 831 $TB 2
tap 500 700 1      # clears the selection left by the earlier test
tap 500 450 2      # focus the terminal (opens the keyboard)
adb shell "input text 'clear'"; adb shell input keyevent 66; sleep 1
adb shell "input text 'uptime;%sfree%s-h;%sdf%s-h%s/;%sdocker%sps%s--format%s\"{{.Names}}:%s{{.Status}}\"'"
adb shell input keyevent 66; sleep 3
kbdown
shot s2-terminal

# 2) Monitor overview (let the graphs fill a little)
tap 831 $TB 25
shot s3-monitor
# 3) Scroll to network + disks
adb shell input swipe $((W/2)) $((H*80/100)) $((W/2)) $((H*22/100)) 700; sleep 2
adb shell input swipe $((W/2)) $((H*80/100)) $((W/2)) $((H*40/100)) 700; sleep 2
shot s4-network
# 4) Processes list
adb shell input swipe $((W/2)) $((H*85/100)) $((W/2)) $((H*25/100)) 900; sleep 2
shot s5-processes
# 5) Commands panel
tap 831 $TB 2
tapdesc "Commands" 3
shot s6-commands
adb shell input keyevent 4; sleep 2
# 6) Files panel (SFTP) and the action sheet of one file
tapdesc "Files" 6
shot s7-files
tapdesc "Actions" 3
shot s8-file-actions
adb shell input keyevent 4; sleep 1
# ---- Folder upload through the real Android folder picker
adb shell mkdir -p /sdcard/Download/phx-test/sub/deeper
adb shell "echo hello-from-android > /sdcard/Download/phx-test/a.txt"
adb shell "dd if=/dev/urandom of=/sdcard/Download/phx-test/sub/big.bin bs=1024 count=3072 2>/dev/null"
adb shell "echo deep > '/sdcard/Download/phx-test/sub/deeper/with space.txt'"
rm -rf ~/phx-test
tapdesc "Upload" 2
tapdesc "Upload a folder" 5
shot x-picker-1
dumptexts() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1; python3 -c "import re;x=open('/tmp/ui.xml',errors='ignore').read();print('UI LABELS:', [l for l in re.findall(r'(?:text|content-desc)=\"([^\"]+)\"', x)][:40])"; }
dumptexts
# Some Android versions open in "Recent"/root: open the side menu and pick the device storage first.
if ! grep -qi '="Download"' /tmp/ui.xml; then
  tapdesc "Show roots" 2; dumptexts
  for r in "sdk_gphone64_x86_64" "sdk_gphone64_arm64" "Android SDK built for x86_64" "Internal storage"; do grep -q "text=\"$r\"" /tmp/ui.xml && { tapdesc "$r" 3; break; }; done
  dumptexts
fi
tapdesc "Download" 3
tapdesc "phx-test" 3
shot x-picker-2
dumptexts
tapdesc "Use this folder" 3
dumptexts
tapdesc "Allow" 12
shot s9-folder-upload
echo "----- server side -----"
ls -laR ~/phx-test 2>&1 | head -30
L=$(md5sum ~/phx-test/sub/big.bin 2>/dev/null | cut -d' ' -f1)
R=$(adb shell md5sum /sdcard/Download/phx-test/sub/big.bin | cut -d' ' -f1)
A=$(cat ~/phx-test/a.txt 2>/dev/null); D=$(cat "$HOME/phx-test/sub/deeper/with space.txt" 2>/dev/null)
if [ -n "$L" ] && [ "$L" = "$R" ] && [ "$A" = "hello-from-android" ] && [ "$D" = "deep" ]; then
  echo "FOLDER UPLOAD OK (3 MB file identical: $L)"
else
  echo "::error::Folder upload from Android failed (server md5=$L phone md5=$R a=$A d=$D)"; FOLDER_FAIL=1
fi
adb shell input keyevent 4; sleep 2
# ---- Store shots for file transfer: a realistic server folder
J=~/jellyfin
rm -rf $J; mkdir -p $J/config $J/cache $J/media
cat > $J/docker-compose.yml <<'YML'
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/config
      - ./cache:/cache
      - ./media:/media:ro
    environment:
      - TZ=Asia/Kolkata
      - JELLYFIN_PublishedServerUrl=https://media.example.org

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
YML
printf 'media.example.org {\n    reverse_proxy localhost:8096\n    encode gzip\n}\n' > $J/Caddyfile
for i in $(seq 1 400); do echo "[2026-11-18 09:$((i%60)):00] [INF] Playback progress: user=divya item=$i"; done > $J/jellyfin.log
printf 'import os\nprint("movie bot ready")\n' > $J/movie_bot.py
truncate -s 900M $J/backup-2026-11.tar.gz
adb shell mkdir -p /sdcard/Download/website/assets
for f in index.html about.html contact.html style.css app.js; do adb shell "echo '<!-- $f -->' > /sdcard/Download/website/$f"; done
adb shell "dd if=/dev/urandom of=/sdcard/Download/website/assets/hero.jpg bs=1024 count=900 2>/dev/null"
adb shell "dd if=/dev/urandom of=/sdcard/Download/website/assets/logo.png bs=1024 count=40 2>/dev/null"
tapdesc "Files" 5
tapdesc "jellyfin" 4
tapdesc "Upload" 2
tapdesc "Upload a folder" 5
dumptexts
grep -qi '="website"' /tmp/ui.xml || tapdesc "Download" 3
tapdesc "website" 3
tapdesc "Use this folder" 3
tapdesc "Allow" 8
tapdesc "Download" 3
sleep 2
shot st-files
# Open docker-compose.yml in the editor
tapdesc "docker-compose.yml" 3
tapdesc "Edit" 4
adb shell input keyevent 4; sleep 2
shot st-editor
adb shell input keyevent 4; sleep 2
adb shell input keyevent 4; sleep 2
dumptexts
# Narrow phone (360 dp wide) toolbar check
adb shell wm density $((W*160/360)); sleep 4
shot x-narrow-toolbar
adb shell wm density reset; sleep 4
# 6) Servers list
tap 55 75 3
shot s1-servers
ls -la store

if [ -n "$FOLDER_FAIL" ]; then exit 1; fi

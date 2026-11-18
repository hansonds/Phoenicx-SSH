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
x=open('/tmp/ui.xml',encoding='utf-8',errors='ignore').read()
for m in re.finditer(r'<node [^>]*>', x):
    n=m.group(0)
    d=re.search(r'content-desc="([^"]*)"',n); t=re.search(r' text="([^"]*)"',n)
    if (d and d.group(1).startswith(sys.argv[1])) or (t and t.group(1)==sys.argv[1]):
        b=list(map(int,re.findall(r'\d+',re.search(r'bounds="([^"]*)"',n).group(1))))
        print((b[0]+b[2])//2,(b[1]+b[3])//2); break
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
adb shell input keyevent 4; sleep 2
# Narrow phone (360 dp wide) toolbar check
adb shell wm density $((W*160/360)); sleep 4
shot x-narrow-toolbar
adb shell wm density reset; sleep 4
# 6) Servers list
tap 55 75 3
shot s1-servers
ls -la store

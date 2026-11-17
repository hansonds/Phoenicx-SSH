#!/bin/bash
# Full-resolution screenshots of the real app for the Play Store listing.
set -x
mkdir -p store
SIZE=$(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1); W=${SIZE%x*}; H=${SIZE#*x}
tap() { adb shell input tap $((W*$1/1000)) $((H*$2/1000)); sleep ${3:-2}; }
kbdown() { adb shell dumpsys input_method | grep -q 'mInputShown=true' && adb shell input keyevent 4; sleep 1; }
shot() { adb exec-out screencap -p > "store/$1.png"; }
TB=124   # toolbar row (per mille of height)

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
tap 637 $TB 3
shot s6-commands
adb shell input keyevent 4; sleep 2
# 6) Servers list
tap 55 75 3
shot s1-servers
ls -la store

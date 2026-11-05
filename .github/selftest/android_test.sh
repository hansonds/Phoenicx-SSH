#!/bin/bash
# Runs inside the Android emulator job. Drives the real app with adb.
set -x
mkdir -p shots
shot() { adb exec-out screencap -p > "shots/$1.png"; }
adb install -r app.apk
adb shell pm grant com.hanson.phoenicx_ssh android.permission.POST_NOTIFICATIONS || true
SIZE=$(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1); W=${SIZE%x*}; H=${SIZE#*x}
echo "screen $W x $H"
adb shell am start -n com.hanson.phoenicx_ssh/.MainActivity
sleep 30
shot a1-connected
# Focus the terminal and type with the soft keyboard path (retry if a
# system dialog such as "launcher isn't responding" steals the tap).
for try in 1 2 3; do
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null
  adb shell am start -n com.hanson.phoenicx_ssh/.MainActivity >/dev/null
  sleep 2
  adb shell input tap $((W/2)) $((H*45/100))
  sleep 3
  adb shell input text 'touch%s/tmp/android_typed_ok'
  adb shell input keyevent 66
  sleep 3
  [ -f /tmp/android_typed_ok ] && break
done
shot a2-typed
adb shell input keyevent 4   # hide keyboard
sleep 2
# Long-press on the text to select a word.
adb shell input swipe $((W*30/100)) $((H*22/100)) $((W*30/100)) $((H*22/100)) 1500
sleep 2
shot a3-selected
adb shell input tap $((W/2)) $((H*60/100))
sleep 40
shot a4-monitor
adb logcat -d -s flutter | tail -30
if [ -f /tmp/android_typed_ok ]; then echo "ANDROID TYPING OK"; else echo "::error::Typing on Android did not reach the server"; fi

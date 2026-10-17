#!/usr/bin/env bash
set -euo pipefail
mkdir -p artifacts/screenshots
trap 'adb logcat -d -s AndroidRuntime:V ActivityManager:E Instrumentation:V > artifacts/device-logcat.txt || true' EXIT
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb install test-build/android/app/build/outputs/apk/debug/app-debug.apk
adb install test-build/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w org.raye.vultrmanager.test/org.raye.vultrmanager.SmokeRunner | tee artifacts/instrumentation.txt
adb pull /sdcard/Android/data/org.raye.vultrmanager/files/. artifacts/screenshots/ || true
grep -q 'smoke checks passed' artifacts/instrumentation.txt
if [ -f test-build/artifacts/vultr-node-manager.apk ]; then
    adb uninstall org.raye.vultrmanager
    adb install test-build/artifacts/vultr-node-manager.apk
    adb shell am start -W -n org.raye.vultrmanager/.MainActivity
    sleep 2
    adb shell uiautomator dump /sdcard/release-ui.xml
    adb pull /sdcard/release-ui.xml artifacts/
    grep -q '接入已有云端节点' artifacts/release-ui.xml
fi

#!/usr/bin/env bash
# Builds the test app for Android, runs it on the connected device or emulator, and reports the
# checks it ran.
#
# Usage: scripts/run-android.sh
#
# The app is built as a release APK so that its JavaScript is bundled and no Metro server is
# needed. See scripts/build-android-swift.sh for the Swift toolchain this needs.
set -euo pipefail

cd "$(dirname "$0")/.."
package="dev.swiftmmkv.e2e"
results="/sdcard/Android/data/$package/files/e2e-results.json"

abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
[ -n "$abi" ] || { echo "No Android device or emulator is connected." >&2; exit 2; }

[ -d node_modules ] || npm install
npx expo prebuild --platform android
scripts/build-android-swift.sh "$abi"
(cd android && ./gradlew assembleRelease "-PreactNativeArchitectures=$abi" --console=plain | tail -n 3)

adb uninstall "$package" > /dev/null 2>&1 || true
adb install android/app/build/outputs/apk/release/app-release.apk > /dev/null
# Results from an earlier run can outlive the app that wrote them.
adb shell rm -f "$results"
adb shell am start -n "$package/.MainActivity" > /dev/null

for _ in $(seq 1 60); do
  adb shell "[ -f $results ]" && break
  sleep 1
done
local_results=$(mktemp)
adb shell "cat $results" > "$local_results" || { echo "The app did not report any results." >&2; exit 1; }
node scripts/report.js "$local_results"

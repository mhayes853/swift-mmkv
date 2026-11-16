#!/usr/bin/env bash
# Builds the test app for the iOS simulator, runs it, and reports the checks it ran.
#
# Usage: scripts/run-ios.sh [simulator-name]
#
# The app is built in the Release configuration so that its JavaScript is bundled and no Metro
# server is needed.
set -euo pipefail

cd "$(dirname "$0")/.."
bundle_id="dev.swiftmmkv.e2e"

[ -d node_modules ] || npm install
npx expo prebuild --platform ios

if [ -n "${1:-}" ]; then
  udid=$(xcrun simctl list devices available | grep -F "$1 (" | head -1 | grep -oE '[0-9A-F-]{36}')
else
  udid=$(xcrun simctl list devices available | grep -E '^ +iPhone' | head -1 | grep -oE '[0-9A-F-]{36}')
fi
[ -n "$udid" ] || { echo "No matching iOS simulator." >&2; exit 2; }

workspace=$(ls -d ios/*.xcworkspace | head -1)
scheme=$(basename "$workspace" .xcworkspace)
xcodebuild \
  -workspace "$workspace" \
  -scheme "$scheme" \
  -configuration Release \
  -sdk iphonesimulator \
  -destination "id=$udid" \
  -derivedDataPath ios/build \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -n 3

xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl uninstall "$udid" "$bundle_id" 2> /dev/null || true
xcrun simctl install "$udid" "ios/build/Build/Products/Release-iphonesimulator/$scheme.app"
xcrun simctl launch "$udid" "$bundle_id" > /dev/null

results="$(xcrun simctl get_app_container "$udid" "$bundle_id" data)/Documents/e2e-results.json"
for _ in $(seq 1 60); do
  [ -f "$results" ] && break
  sleep 1
done
[ -f "$results" ] || { echo "The app did not report any results." >&2; exit 1; }
node scripts/report.js "$results"

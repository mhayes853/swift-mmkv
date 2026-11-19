#!/usr/bin/env bash
# Builds the Swift half of the native module for Android and copies it, along with the Swift
# runtime libraries it needs, to where Gradle packages them.
#
# Usage: scripts/build-android-swift.sh [android-abi]
#
# Needs a Swift toolchain with a matching Swift SDK for Android installed (see
# https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html), and
# the Android NDK. Set SWIFT to use a toolchain other than the default one, and SWIFT_SDK to the
# name of the Swift SDK to use, such as swift-6.4.2-RELEASE_android, when more than one for
# Android is installed.
set -euo pipefail

cd "$(dirname "$0")/.."
abi="${1:-arm64-v8a}"
case "$abi" in
  arm64-v8a) arch=aarch64 ;;
  x86_64) arch=x86_64 ;;
  *) echo "Unsupported ABI: $abi" >&2; exit 2 ;;
esac
triple="$arch-unknown-linux-android28"
swift="${SWIFT:-swift}"
package=modules/native-mmkv/android/swift
output="modules/native-mmkv/android/src/main/jniLibs/$abi"

# Toolchains before Swift 6.4 pick the wrong architecture when given both the name of a Swift SDK
# and a triple, so they are only given the triple, and choose a Swift SDK that matches themselves.
read -r major minor < <("$swift" --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
if [ -n "${SWIFT_SDK:-}" ] && { [ "${major:-0}" -gt 6 ] || [ "${minor:-0}" -ge 4 ]; }; then
  build=("$swift" build --package-path "$package" -c release --swift-sdk "$SWIFT_SDK" --triple "$triple")
else
  build=("$swift" build --package-path "$package" -c release --swift-sdk "$triple")
fi
"${build[@]}"
# Where the build puts its products depends on the toolchain's build system.
products=$("${build[@]}" --show-bin-path)

runtime=$(find "$HOME/Library/org.swift.swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks" \
  "$HOME/.config/swiftpm/swift-sdks" -type d -path "*${SWIFT_SDK:-}*swift-$arch/android" \
  2> /dev/null | head -1 || true)
[ -n "$runtime" ] || { echo "Could not find the Swift SDK for Android's runtime." >&2; exit 1; }
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
# The newest NDK installed, comparing version numbers rather than text.
ndk=$(ls "$sdk/ndk" 2> /dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
readelf=$(find "$sdk/ndk/$ndk" -name llvm-readelf 2> /dev/null | head -1 || true)
[ -n "$readelf" ] || { echo "Could not find llvm-readelf in the Android NDK." >&2; exit 1; }

rm -rf "$output"
mkdir -p "$output"
cp "$products/libNativeMMKVBridge.so" "$output/"

# Copy every Swift runtime library the bridge needs, directly or not. Libraries that are not in
# the Swift SDK come from Android itself, or from React Native in the case of libc++_shared.
pending=("$output/libNativeMMKVBridge.so")
while [ "${#pending[@]}" -gt 0 ]; do
  library="${pending[0]}"
  pending=("${pending[@]:1}")
  for needed in $("$readelf" -d "$library" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    if [ -f "$runtime/$needed" ] && [ ! -f "$output/$needed" ] && [ "$needed" != libc++_shared.so ]; then
      cp "$runtime/$needed" "$output/"
      pending+=("$output/$needed")
    fi
  done
done
ls "$output"

# The Swift runtime can need a newer libc++ than the one React Native ships, which is the one that
# would otherwise be packaged (Swift 6.4 needs the one from NDK 30). Libraries in the app's own
# directory win over those of its dependencies, so the newest installed NDK's goes there.
libcxx=$(find "$sdk/ndk/$ndk" -path "*/sysroot/usr/lib/$arch-linux-android/libc++_shared.so" \
  2> /dev/null | head -1 || true)
if [ -n "$libcxx" ] && [ -d android/app ]; then
  mkdir -p "android/app/src/main/jniLibs/$abi"
  cp "$libcxx" "android/app/src/main/jniLibs/$abi/"
  echo "Packaging libc++_shared.so from NDK $ndk"
fi

#!/usr/bin/env bash
# Copies MMKV's C++ core at a given tag into Sources/CSwiftMMKVCore/mmkv.
#
# Usage: Scripts/vendor-mmkv.sh v2.4.3
#
# The copy is unmodified. Everything this package needs to change about the core (symbol names,
# platform selection, assembler flags) is done from Package.swift and the files next to `mmkv/`.
set -euo pipefail

tag="${1:?usage: vendor-mmkv.sh <tag>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$root/Sources/CSwiftMMKVCore/mmkv"
checkout="$(mktemp -d)"
trap 'rm -rf "$checkout"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" https://github.com/Tencent/MMKV "$checkout"

rm -rf "$destination"
mkdir -p "$destination"
cp -R "$checkout/Core/." "$destination/"
cp "$checkout/LICENSE.TXT" "$destination/LICENSE.TXT"

# Build files for other build systems, the standalone C bridge (this package has its own), the
# embedded zlib (only used on Windows), and the Objective-C++ and Windows sources.
(
  cd "$destination"
  rm -rf Core.xcodeproj core.vcxproj core.vcxproj.filters CMakeLists.txt crc32/CMakeLists.txt \
    cbridge crc32/zlib fakeinclude
  rm -f ./*_OSX.cpp ./*_Win32.cpp
)

printf '%s\n' "$tag" > "$root/Sources/CSwiftMMKVCore/mmkv.version"
echo "Vendored MMKV $tag into ${destination#"$root"/}"

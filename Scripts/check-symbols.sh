#!/usr/bin/env bash
# Fails if the vendored MMKV core defines a strong global symbol whose name was not renamed.
#
# Usage: Scripts/check-symbols.sh [build-directory] [nm]
#
# Run after `swift build`. An unrenamed symbol would collide with the copy of MMKV that
# react-native-mmkv links into the same app; the fix is to add its name to `renamedCoreSymbols`
# in Package.swift. Weak symbols are template instantiations of the C++ standard library, which
# the linker merges, so they are left alone.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/.build}"
nm="${2:-nm}"

objects=()
while IFS= read -r object; do objects+=("$object"); done < <(
  find "$build" -name '*.o' -path '*CSwiftMMKVCore*' ! -path '*SwiftMMKVTests*'
)
if [ "${#objects[@]}" -eq 0 ]; then
  echo "No CSwiftMMKVCore objects under $build. Run swift build first." >&2
  exit 2
fi

if "$nm" -gUm "${objects[0]}" 2>/dev/null | grep -q 'external'; then
  # Mach-O: `-m` spells out which definitions are weak.
  strong=$("$nm" -gUm "${objects[@]}" 2>/dev/null | grep 'external ' | grep -v 'weak ' \
    | awk '{print $NF}' || true)
else
  # ELF: weak definitions have the type letters W and V.
  strong=$("$nm" -g --defined-only "${objects[@]}" 2>/dev/null \
    | awk 'NF == 3 && $2 !~ /^[WwVv]$/ {print $3}' || true)
fi

# `CRC32` is a function pointer the core defines on 64-bit ARM Linux and Android. The core tests
# whether a macro of that name exists, so it cannot be renamed with one. Two copies sharing the
# pointer is harmless: both hold a CRC-32 routine with the same signature.
unrenamed=$(printf '%s\n' "$strong" | grep -v 'swiftmmkv' | grep -vx 'CRC32' | sort -u || true)
if [ -n "$unrenamed" ]; then
  echo "Unrenamed global symbols in the MMKV core:" >&2
  printf '%s\n' "$unrenamed" >&2
  exit 1
fi
echo "All $(printf '%s\n' "$strong" | sort -u | wc -l | tr -d ' ') strong core symbols are renamed."

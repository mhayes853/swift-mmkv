#!/usr/bin/env bash
# Fails unless the functions `swiftmmkv.h` declares are exactly the `swiftmmkv_` symbols the
# SwiftMMKVC target defines.
#
# Usage: Scripts/check-c-interface.sh [build-directory] [nm]
#
# Run after `swift build`. The compiler checks each function SwiftMMKVC implements against its
# declaration, but says nothing about a declaration that nothing implements, which a binding
# would only find out about when it fails to link.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/.build}"
nm="${2:-nm}"
header="$root/Sources/CSwiftMMKV/include/swiftmmkv.h"

objects=()
while IFS= read -r object; do objects+=("$object"); done < <(
  find "$build" -name '*.o' -path '*SwiftMMKVC.build*'
)
if [ "${#objects[@]}" -eq 0 ]; then
  echo "No SwiftMMKVC objects under $build. Run swift build first." >&2
  exit 2
fi

# A declaration is a name followed by its parameter list. Comments mention functions in
# backticks, without one.
declared=$(grep -v '^ *//' "$header" | grep -oE 'swiftmmkv_[a-z0-9_]+\(' | tr -d '(' | sort -u)

# Mach-O prefixes C symbols with an underscore. Swift's own symbols are mangled, so none of
# them starts with the prefix.
defined=$("$nm" -g "${objects[@]}" 2>/dev/null \
  | awk 'NF == 3 && $2 ~ /^[TtDdSs]$/ {print $3}' | sed 's/^_//' \
  | grep -E '^swiftmmkv_[a-z0-9_]+$' | sort -u || true)

missing=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$defined"))
undeclared=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$defined"))
if [ -n "$missing" ]; then
  echo "Declared in swiftmmkv.h but not implemented:" >&2
  printf '%s\n' "$missing" >&2
fi
if [ -n "$undeclared" ]; then
  echo "Defined by SwiftMMKVC but not declared in swiftmmkv.h:" >&2
  printf '%s\n' "$undeclared" >&2
fi
if [ -n "$missing" ] || [ -n "$undeclared" ]; then
  exit 1
fi
echo "All $(printf '%s\n' "$declared" | wc -l | tr -d ' ') functions of the C interface are implemented."

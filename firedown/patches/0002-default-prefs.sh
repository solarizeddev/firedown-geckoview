#!/usr/bin/env bash
# 0002 — Append Firedown's default-pref overrides to GeckoView's default prefs.
#
# Covers DRM-off, telemetry-off, Pocket/sponsored-off, and the hardened privacy
# defaults — all as *default* prefs (runtime-overridable by Firedown). Appending
# pref lines is version-robust: no source-context matching, just a marker guard.
#
# Source of truth: firedown/prefs/firedown-geckoview.js. Target file:
# mobile/android/app/geckoview-prefs.js (GeckoView's built-in default prefs).
set -euo pipefail

SRC="${1:?usage: 0002-default-prefs.sh <gecko-src-root>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFS_SRC="$HERE/../prefs/firedown-geckoview.js"
TARGET="$SRC/mobile/android/app/geckoview-prefs.js"
MARKER="FIREDOWN-GECKO-PREFS"

if [ ! -f "$PREFS_SRC" ]; then
  echo "ERROR(0002): prefs source $PREFS_SRC missing." >&2
  exit 1
fi
if [ ! -f "$TARGET" ]; then
  echo "ERROR(0002): $TARGET not found — GeckoView default-prefs path changed." >&2
  echo "             Find the GeckoView default prefs .js for this version and" >&2
  echo "             update TARGET in this script." >&2
  exit 1
fi
if grep -q "$MARKER" "$TARGET"; then
  echo "[skip] 0002 default prefs already appended"
  exit 0
fi

{
  printf '\n// ===== appended by firedown-gecko (0002-default-prefs.sh) =====\n'
  cat "$PREFS_SRC"
} >> "$TARGET"
echo "[ok] 0002 default prefs appended to geckoview-prefs.js"

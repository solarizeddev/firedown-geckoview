#!/usr/bin/env bash
# Apply every Firedown modification to a checked-out Gecko source tree.
#
# Idempotent: each patch is marker-gated, so re-runs and partial states are safe
# (same contract as firedown-ffmpeg/apply-firedown-patches.sh). Build-level flags
# (DRM/telemetry configure switches) live in the mozconfig, not here.
#
# Usage: apply-firedown-patches.sh <gecko-src-root>
set -euo pipefail

SRC="${1:?usage: apply-firedown-patches.sh <gecko-src-root>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$SRC/mobile/android/geckoview" ]; then
  echo "ERROR: $SRC doesn't look like a Gecko source tree (no mobile/android/geckoview)." >&2
  exit 1
fi

echo "== Applying Firedown GeckoView patches to: $SRC"
shopt -s nullglob
for p in "$HERE"/patches/[0-9]*.sh; do
  echo "-- $(basename "$p")"
  bash "$p" "$SRC"
done
echo "== Patches done. Build-level DRM/telemetry flags are in the mozconfig."

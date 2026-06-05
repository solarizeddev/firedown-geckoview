#!/usr/bin/env bash
# 02 — `mach bootstrap` for the Android/GeckoView toolchain.
#
# Downloads the Android SDK/NDK, Rust toolchain and a vendored JDK into
# ~/.mozbuild. Idempotent — safe to re-run (it just verifies/updates).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env"

cd "$GECKO_SRC"
echo "== mach bootstrap (GeckoView/Android) — this downloads several GB =="
# --no-interactive: take defaults; --application-choice locks the GeckoView path.
./mach --no-interactive bootstrap --application-choice mobile_android
echo "[ok] bootstrap complete (toolchain under ~/.mozbuild)"

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

# If the user pointed build.env at an existing SDK + NDK, skip the multi-GB
# download. The build (step 04) consumes those paths via the mozconfig; the host
# JDK/Rust come from step 00 (prereqs) on Arch. Requires BOTH paths to exist.
if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -n "${ANDROID_NDK_ROOT:-}" ]; then
  if [ ! -d "$ANDROID_SDK_ROOT" ]; then
    echo "ERROR(02): ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT does not exist." >&2
    exit 1
  fi
  if [ ! -d "$ANDROID_NDK_ROOT" ]; then
    echo "ERROR(02): ANDROID_NDK_ROOT=$ANDROID_NDK_ROOT does not exist." >&2
    exit 1
  fi
  echo "[skip] bootstrap: using existing SDK ($ANDROID_SDK_ROOT) + NDK"
  echo "       ($ANDROID_NDK_ROOT) from build.env — no download."
  echo "       Ensure the NDK version matches what Firefox $FIREFOX_VERSION pins"
  echo "       (python/mozboot/mozboot/android.py NDK_VERSION); configure fails"
  echo "       loudly on a mismatch."
  exit 0
fi

echo "== mach bootstrap (GeckoView/Android) — this downloads several GB =="
# --no-interactive: take defaults; --application-choice locks the GeckoView path.
./mach --no-interactive bootstrap --application-choice mobile_android
echo "[ok] bootstrap complete (toolchain under ~/.mozbuild)"

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

  # Bundletool: a single Google JAR mach expects at ~/.mozbuild/bundletool.jar
  # (configure errors "You must install Bundletool" without it). Bootstrap fetches
  # it; provision it here on the skip path. The version isn't critical — the build
  # only runs build-bundle — so any recent release works; override BUNDLETOOL_VERSION
  # to pin a different one. (The Android SDK *platform* the build needs is content
  # you install with sdkmanager, e.g. `sdkmanager "platforms;android-36.1"`; it's
  # version-pinned by Firefox, so we don't fetch it here.)
  bt_dir="${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}"
  bt_jar="$bt_dir/bundletool.jar"
  bt_ver="${BUNDLETOOL_VERSION:-1.18.3}"
  if [ ! -f "$bt_jar" ]; then
    mkdir -p "$bt_dir"
    bt_url="https://github.com/google/bundletool/releases/download/$bt_ver/bundletool-all-$bt_ver.jar"
    echo "       fetching bundletool $bt_ver -> $bt_jar"
    bt_i=1
    until wget -q -O "$bt_jar" "$bt_url"; do
      if [ "$bt_i" -ge 4 ]; then
        rm -f "$bt_jar"
        echo "ERROR(02): bundletool download failed from $bt_url" >&2
        exit 1
      fi
      bt_s=$((2 ** bt_i)); echo "       retry $bt_i in ${bt_s}s…"; sleep "$bt_s"
      bt_i=$((bt_i + 1))
    done
  else
    echo "       bundletool already present ($bt_jar)"
  fi
  exit 0
fi

echo "== mach bootstrap (GeckoView/Android) — this downloads several GB =="
# --no-interactive: take defaults; --application-choice locks the GeckoView path.
./mach --no-interactive bootstrap --application-choice mobile_android
echo "[ok] bootstrap complete (toolchain under ~/.mozbuild)"

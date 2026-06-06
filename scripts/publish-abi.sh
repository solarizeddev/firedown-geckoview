#!/usr/bin/env bash
# Publish ONE already-built per-ABI GeckoView AAR to mavenLocal (~/.m2), without
# the multi-ABI fat-AAR pass. Use this to test a single ABI on a device/emulator
# quickly — or as a fallback when the fat-AAR repackage is blocked.
#
# Reuses the per-ABI objdir from `./build.sh build` (phase 1) AS-IS: it rewrites
# the SAME compile-environment mozconfig phase 1 used for this ABI, so mach sees
# the objdir up-to-date (no rebuild) and the host tools it needs (e.g.
# embedded-uniffi-bindgen) are present — unlike the `--disable-compile-environment`
# fat-AAR pass. Assumes the bootstrap toolchain (i.e. the Docker flow); run as:
#     ./build.sh docker publish-abi aarch64-linux-android      # arm64 phone
#     ./build.sh docker publish-abi x86_64-linux-android       # x86_64 emulator
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env"

T="${1:?usage: publish-abi.sh <rust-target-triple>  (e.g. aarch64-linux-android)}"
case "$T" in
  aarch64-linux-android) ABI=arm64-v8a ;;
  x86_64-linux-android)  ABI=x86_64 ;;
  arm-linux-androideabi) ABI=armeabi-v7a ;;
  i686-linux-android)    ABI=x86 ;;
  *) echo "ERROR: unknown target triple '$T'." >&2; exit 1 ;;
esac

OBJ="objdir-gv-$ABI"
if [ ! -d "$GECKO_SRC/$OBJ" ]; then
  echo "ERROR: $GECKO_SRC/$OBJ not found — run './build.sh build' (or 'all') first" >&2
  echo "       so phase 1 produces the per-ABI objdir." >&2
  exit 1
fi

# Keep the pinned version label consistent with the full build.
if [ -n "${GECKOVIEW_BUILD_DATE:-}" ]; then
  export MOZ_BUILD_DATE="$GECKOVIEW_BUILD_DATE"
fi

cd "$GECKO_SRC"
# Exactly the phase-1 mozconfig for this ABI (template + target + objdir), so the
# objdir's config is unchanged → no reconfigure/rebuild, just the gradle publish.
cp "$ROOT/mozconfig/geckoview-release.mozconfig" "$GECKO_SRC/mozconfig"
{
  echo ""
  echo "# --- injected by publish-abi.sh ---"
  echo "ac_add_options --target=$T"
  echo "mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/$OBJ"
} >> "$GECKO_SRC/mozconfig"

echo "== publishing single-ABI ($ABI) geckoview to mavenLocal =="
# Assemble the release AAR before publishing — the publish task does NOT build it,
# and publishing without it emits only POM/sources/javadoc (no .aar). Phase 1
# already ran assembleRelease in this objdir, so this is normally UP-TO-DATE; we
# run it anyway so a stale/partial objdir still produces the artifact.
./mach gradle geckoview:assembleRelease
./mach gradle geckoview:publishReleasePublicationToMavenLocal

echo
echo "[ok] published single-ABI ($ABI) geckoview ${GECKOVIEW_VERSION:-} to"
echo "     ~/.m2/repository/org/mozilla/geckoview/geckoview/"
echo "     Next (on the HOST): ./build.sh sync --apply, then build + adb install the app."
echo "     NOTE: this AAR carries ONLY $ABI native libs — fine for a matching"
echo "     device/emulator; use the full fat-AAR for a shippable multi-ABI build."

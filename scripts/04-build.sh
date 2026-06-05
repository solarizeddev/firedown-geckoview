#!/usr/bin/env bash
# 04 — Build GeckoView for each ABI, fat-AAR them into one multi-ABI artifact,
#      and publish it to your local Maven repo (~/.m2 / mavenLocal).
#
# Multi-ABI in mozilla-central is a two-phase build (Mozilla's documented
# approach):
#   phase 1  build each ABI separately (real native compile) into its own objdir
#            and produce a per-ABI geckoview AAR;
#   phase 2  a "fat AAR" pass (--disable-compile-environment, so it only
#            repackages — fast) combines the per-ABI AARs into one and publishes
#            it with a POM carrying GeckoView's transitive deps. A bare .aar in
#            app/libs would miss those deps, so we go through mavenLocal.
#
# Ref: Mozilla "Building multi-architecture GeckoView" (firefox-source-docs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env"

TEMPLATE="$ROOT/mozconfig/geckoview-release.mozconfig"
MOZCONFIG="$GECKO_SRC/mozconfig"

# target triple -> Android ABI name (gradle/AAR naming).
abi_for_target() {
  case "$1" in
    aarch64-linux-android) echo arm64-v8a ;;
    x86_64-linux-android)  echo x86_64 ;;
    arm-linux-androideabi) echo armeabi-v7a ;;
    i686-linux-android)    echo x86 ;;
    *) echo "ERROR: unknown ANDROID_TARGET '$1'" >&2; return 1 ;;
  esac
}
# ABI name -> the MOZ_ANDROID_FAT_AAR_<ABI> env var used by the fat-AAR phase.
fatvar_for_abi() { echo "MOZ_ANDROID_FAT_AAR_$(echo "$1" | tr 'a-z-' 'A-Z_')"; }

cd "$GECKO_SRC"

# ---------------------------------------------------------------------------
# Phase 1 — per-ABI native builds + per-ABI AARs.
# ---------------------------------------------------------------------------
declare -A AAR_FOR_ABI
ABI_LIST=""
for T in $ANDROID_TARGETS; do
  ABI="$(abi_for_target "$T")"
  OBJ="objdir-gv-$ABI"
  ABI_LIST="${ABI_LIST:+$ABI_LIST,}$ABI"

  echo "== [phase 1] building $T ($ABI) into $OBJ =="
  cp "$TEMPLATE" "$MOZCONFIG"
  {
    echo ""
    echo "# --- injected by 04-build.sh (per-ABI) ---"
    echo "ac_add_options --target=$T"
    echo "mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/$OBJ"
  } >> "$MOZCONFIG"

  ./mach build
  ./mach gradle geckoview:assembleWithGeckoBinariesRelease

  AAR="$(find "$GECKO_SRC/$OBJ" -path '*geckoview*outputs/aar*' \
           -name '*withGeckoBinaries-release.aar' 2>/dev/null | head -1)"
  if [ -z "$AAR" ]; then
    echo "ERROR: per-ABI AAR not found under $OBJ (gradle output path changed?)." >&2
    echo "       Look for *withGeckoBinaries-release.aar and update this script." >&2
    exit 1
  fi
  AAR_FOR_ABI[$ABI]="$AAR"
  echo "   -> $AAR"
done

# ---------------------------------------------------------------------------
# Phase 2 — fat-AAR repackage + publish to mavenLocal.
# ---------------------------------------------------------------------------
echo "== [phase 2] fat-AAR ($ABI_LIST) + publish to mavenLocal =="
# Pick any built target as the "host" target for the repackage pass.
FIRST_T="$(set -- $ANDROID_TARGETS; echo "$1")"

cp "$TEMPLATE" "$MOZCONFIG"
{
  echo ""
  echo "# --- injected by 04-build.sh (fat-AAR phase) ---"
  echo "ac_add_options --target=$FIRST_T"
  echo "ac_add_options --disable-compile-environment"   # repackage only, no recompile
  echo "mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/objdir-gv-fat"
  echo "export MOZ_ANDROID_FAT_AAR_ARCHITECTURES=$ABI_LIST"
  for ABI in "${!AAR_FOR_ABI[@]}"; do
    echo "export $(fatvar_for_abi "$ABI")=${AAR_FOR_ABI[$ABI]}"
  done
} >> "$MOZCONFIG"
echo "== fat-AAR mozconfig =="
cat "$MOZCONFIG"
echo

./mach build
./mach gradle geckoview:publishWithGeckoBinariesReleasePublicationToMavenLocal

echo
echo "[ok] build complete. Multi-ABI ($ABI_LIST) published under"
echo "     ~/.m2/repository/org/mozilla/geckoview/"
echo "     Next: ./build.sh sync   (prints the exact app/build.gradle wiring)"

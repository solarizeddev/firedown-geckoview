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

# Pin the GeckoView buildid so the published coordinate is the fixed
# <milestone>.<buildid> (e.g. 151.0.20260601110758) instead of a wall-clock one.
# Exported here so EVERY mach build below — each per-ABI phase-1 build and the
# phase-2 fat-AAR pass — stamps the same buildid; otherwise the per-ABI AARs and
# the fat AAR could disagree on version. Empty GECKOVIEW_BUILD_DATE => default
# wall-clock buildid (non-reproducible).
if [ -n "${GECKOVIEW_BUILD_DATE:-}" ]; then
  export MOZ_BUILD_DATE="$GECKOVIEW_BUILD_DATE"
  echo "== pinning MOZ_BUILD_DATE=$MOZ_BUILD_DATE -> GeckoView ${FIREFOX_VERSION}.$MOZ_BUILD_DATE =="
fi

# Compilation parallelism. mach auto-detects (all logical cores) when no -j is
# given; pinning BUILD_JOBS bounds it. Gecko's Rust/LTO link + codegen steps are
# RAM-hungry, so on a high-core box a full -j$(nproc) can OOM — capping jobs is
# the usual fix. Applies to every mach build below (the per-ABI compiles; the
# fat-AAR pass doesn't compile so it's a no-op there). CARGO_BUILD_JOBS bounds
# the Rust/cargo side to the same value. Empty BUILD_JOBS => mach auto-detect.
MACH_JOBS=()
if [ -n "${BUILD_JOBS:-}" ]; then
  MACH_JOBS=(-j"$BUILD_JOBS")
  export CARGO_BUILD_JOBS="$BUILD_JOBS"
  echo "== build jobs: -j$BUILD_JOBS (CARGO_BUILD_JOBS=$BUILD_JOBS) =="
fi

# Existing Android SDK/NDK (build.env). Export for the gradle step (which reads
# ANDROID_HOME), and emit --with-android-{sdk,ndk} into each per-ABI mozconfig
# below so configure uses them instead of the bootstrap-managed ~/.mozbuild copy.
# Empty => bootstrap-managed toolchain (unchanged default).
if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
  export ANDROID_SDK_ROOT ANDROID_HOME="$ANDROID_SDK_ROOT"
fi
if [ -n "${ANDROID_NDK_ROOT:-}" ]; then
  export ANDROID_NDK_ROOT ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
fi

# Ensure the Rust std target for each ABI is installed before configure probes
# it (otherwise: "can't find crate for std / target may not be installed"). The
# ANDROID_TARGETS triples ARE the rustup target names, so add them directly.
# Idempotent and per-user (no sudo); prereqs does this too, but `build.sh all`
# doesn't run prereqs, so self-heal here. Skipped if rustup isn't managing rustc.
if command -v rustup >/dev/null 2>&1; then
  for T in $ANDROID_TARGETS; do
    rustup target add "$T" >/dev/null 2>&1 || \
      echo "WARN: 'rustup target add $T' failed — install it manually." >&2
  done
fi
# Append --with-android-sdk/ndk (only the ones that are set) to the mozconfig
# currently being assembled. The compile (per-ABI) phase needs both; the fat-AAR
# repackage doesn't compile, so it relies on the ANDROID_HOME export for gradle.
emit_android_paths() {
  local ndk_bin
  if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    echo "ac_add_options --with-android-sdk=$ANDROID_SDK_ROOT"
  fi
  if [ -n "${ANDROID_NDK_ROOT:-}" ]; then
    echo "ac_add_options --with-android-ndk=$ANDROID_NDK_ROOT"
    # Use the NDK's clang as the TARGET compiler. A `mach bootstrap` build would
    # use Mozilla's own clang (which ships the Android compiler-rt builtins +
    # libunwind); when we skip bootstrap to reuse an existing NDK, configure
    # otherwise falls back to the SYSTEM clang, which only has the host runtime —
    # so target conftests fail to link ("cannot open libclang_rt.builtins.a",
    # "unable to find library -l:libunwind.a"). The NDK clang bundles both. Host
    # tools keep the auto-detected system clang (HOST_CC is left unset). The
    # linux-x86_64 prebuilt dir is the only host layout this build supports.
    ndk_bin="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
    echo "CC=\"$ndk_bin/clang\""
    echo "CXX=\"$ndk_bin/clang++\""
    # RLBox wasm-sandboxed libraries (expat/woff2/graphite/hunspell/ogg/…) need a
    # WASI sysroot to compile to wasm32-wasi. A `mach bootstrap` build fetches one;
    # on the skip-bootstrap path there is none, so configure fails ("Cannot find
    # wasi headers").
    #  - WASI_SYSROOT set  -> keep RLBox: point configure at it (e.g. Arch's
    #    wasi-libc, usually /usr/share/wasi-sysroot). Costs a little speed for
    #    those parsers but is the more-hardened, stock-Firefox config.
    #  - WASI_SYSROOT empty -> drop RLBox (--without-wasm-sandboxed-libraries):
    #    the libs build/run NATIVE (slightly FASTER) but un-sandboxed (less
    #    secure). This is only the fallback so the reuse path builds at all.
    if [ -n "${WASI_SYSROOT:-}" ]; then
      echo "ac_add_options --with-wasi-sysroot=$WASI_SYSROOT"
    else
      echo "ac_add_options --without-wasm-sandboxed-libraries"
    fi
  fi
}

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
    emit_android_paths
  } >> "$MOZCONFIG"

  ./mach build "${MACH_JOBS[@]}"
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

./mach build "${MACH_JOBS[@]}"
./mach gradle geckoview:publishWithGeckoBinariesReleasePublicationToMavenLocal

echo
echo "[ok] build complete. Multi-ABI ($ABI_LIST) published under"
echo "     ~/.m2/repository/org/mozilla/geckoview/"
echo "     Next: ./build.sh sync   (prints the exact app/build.gradle wiring)"

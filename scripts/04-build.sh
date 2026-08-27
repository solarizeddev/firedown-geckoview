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

# The pin only takes effect when <objdir>/buildid.h is (re)generated — and outside
# Mozilla automation an incremental `mach build` does NOT regenerate it (the
# generated-file stub isn't FORCEd and the MOZ_BUILD_DATE env var isn't tracked as
# an input). So bumping GECKOVIEW_BUILD_DATE against EXISTING objdirs silently
# keeps the OLD buildid: gradle reads buildid.h for the version, so it assembles
# and publishes under the old coordinate despite the export above (hit on the
# 20260601110758 -> 20260608154138 bump: "GeckoView version = 151.0.<old>" and the
# POM-install step failed loudly on the missing new-version dir). Delete the stale
# buildid.h (+ its .stub/.pp) from an objdir before its mach build so the build
# regenerates it with the pin. Applies to the per-ABI objdirs AND the fat one —
# the Java BuildConfig buildid (fat gradle) and the buildid embedded in each ABI's
# libxul must agree. No-op when the objdir already carries the pin, so re-runs
# don't churn needless libxul relinks; a pin change costs one relink per ABI.
refresh_buildid() {
  local obj="$1" stale=0 f
  [ -n "${MOZ_BUILD_DATE:-}" ] && [ -d "$obj" ] || return 0
  while IFS= read -r f; do
    grep -q "$MOZ_BUILD_DATE" "$f" || stale=1
  done < <(find "$obj" -name buildid.h -not -path '*/.deps/*' 2>/dev/null)
  if [ "$stale" -eq 1 ]; then
    echo "   stale buildid in $obj -> deleting buildid.h so it regenerates as $MOZ_BUILD_DATE"
    find "$obj" \( -name buildid.h -o -name 'buildid.h.*' \) -delete 2>/dev/null || true
  fi
}

# The MILESTONE analogue of refresh_buildid. The published coordinate is
# <milestone>.<buildid>: the buildid is handled above, but the milestone
# (MOZ_APP_VERSION / MOZILLA_VERSION, derived by configure from the SOURCE version
# files that FIREFOX_VERSION selects) is read into <objdir>/config.status ONCE, at
# configure time, and the gradle plugin reads it back from there — it is NOT
# re-derived from source per build. So bumping FIREFOX_VERSION against an EXISTING
# objdir (e.g. an in-place re-fetch to the new tag, which rewrites the source files
# but leaves the untracked objdir's config.status alone) silently keeps the OLD
# milestone: gradle assembles/publishes under <old-milestone>.<newbuildid> and the
# POM-install step fails loudly on the missing <new-milestone>.* dir. Hit on the
# 151->152 bump: "GeckoView version = 151.0.<newbuildid>" despite a 152 source tree
# (the 0006 patch anchor had already moved to its 152 shape, proving the source was
# 152). Unlike the buildid (an env var, untracked), the version IS a tracked
# configure INPUT, so the cure is to force configure to re-run: delete config.status
# and mach reconfigures on the next build, cascading the new MOZ_APP_VERSION into
# the generated files (application.ini, the gradle version) and relinking libxul
# once. No-op when the objdir's configured version already matches FIREFOX_VERSION,
# so re-runs don't churn. (If a major bump also crossed a CLOBBER boundary the
# reconfigure-triggered mach build demands a clobber loudly — also correct.)
refresh_configure() {
  local obj="$1" mk="$1/config/autoconf.mk" cur
  [ -n "${FIREFOX_VERSION:-}" ] && [ -d "$obj" ] && [ -f "$mk" ] || return 0
  cur="$(sed -n 's/^\(MOZILLA_VERSION\|MOZ_APP_VERSION\)[[:space:]]*=[[:space:]]*//p' "$mk" | head -1)"
  [ -n "$cur" ] || return 0
  case "$cur" in
    "$FIREFOX_VERSION"|"$FIREFOX_VERSION".*) return 0 ;;
  esac
  echo "   stale milestone in $obj (configured version=$cur, want $FIREFOX_VERSION)"
  echo "   -> deleting config.status so the next mach build reconfigures against the source"
  rm -f "$obj/config.status" 2>/dev/null || true
}

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
  local ndk_bin java_bin
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
    # "unable to find library -l:libunwind.a"). The NDK clang bundles both. The
    # linux-x86_64 prebuilt dir is the only host layout this build supports.
    #
    # HOST_CC/HOST_CXX must be pinned to the SYSTEM clang: setting only CC makes
    # Firefox use the NDK clang for HOST build tools too (e.g. the glslopt build
    # script, TARGET=x86_64-unknown-linux-gnu). Host tools must build with the
    # native system clang.
    ndk_bin="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
    echo "CC=\"$ndk_bin/clang\""
    echo "CXX=\"$ndk_bin/clang++\""
    echo "HOST_CC=\"${HOST_CC:-/usr/bin/clang}\""
    echo "HOST_CXX=\"${HOST_CXX:-/usr/bin/clang++}\""
    # NOTE: on a bleeding-edge-glibc host (e.g. Arch) the vendored glsl-optimizer
    # (the glslopt host build) fails to compile — glibc declares C11/C23
    # once_flag/call_once that collide with its bundled shim ("typedef
    # redefinition", "static declaration of call_once follows non-static"). This
    # is NOT a toolchain-location problem and can't be fixed from here: it's
    # compiler-independent (system clang hits it too), and --enable-bootstrap's
    # host sysroot does NOT reach cargo build-scripts (cc-rs reads CFLAGS_<host>
    # with no --sysroot). The fix is to build in a container with a stable older
    # glibc — see `docker/` and `./build.sh docker`. (This reuse path still works
    # on a host whose glibc isn't too new.)
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
      # The sandboxed libs are compiled to wasm by a SEPARATE compiler (WASM_CC),
      # which defaults to our target CC = the NDK clang. But the NDK clang has no
      # wasm32 compiler-rt builtins (wasm-ld: "cannot open
      # .../wasm32-unknown-wasi/libclang_rt.builtins.a"), so aim WASM_CC/WASM_CXX
      # at the SYSTEM clang instead — it pairs with Arch's wasi-compiler-rt, which
      # installs the wasm builtins into the system clang's resource dir. Override
      # by exporting WASM_CC/WASM_CXX (e.g. a versioned clang path).
      echo "WASM_CC=\"${WASM_CC:-/usr/bin/clang}\""
      echo "WASM_CXX=\"${WASM_CXX:-/usr/bin/clang++}\""
    else
      echo "ac_add_options --without-wasm-sandboxed-libraries"
    fi
    # JDK: a bootstrap build uses the JDK it downloaded to ~/.mozbuild/jdk/…;
    # on the skip path that's absent, so configure errors "Could not locate Java
    # at ~/.mozbuild/jdk/…". Point it at the system JDK 17 — prefer $JAVA_HOME,
    # else the Arch openjdk-17 default. (Evaluated on the build host.)
    java_bin=""
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
      java_bin="$JAVA_HOME/bin"
    elif [ -x /usr/lib/jvm/java-17-openjdk/bin/javac ]; then
      java_bin="/usr/lib/jvm/java-17-openjdk/bin"
    fi
    if [ -n "$java_bin" ]; then
      echo "ac_add_options --with-java-bin-path=$java_bin"
    else
      echo "WARN: no system JDK 17 found — set JAVA_HOME or install jdk17-openjdk;" \
           "configure will look for the (absent) bootstrap JDK." >&2
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

  refresh_buildid "$GECKO_SRC/$OBJ"
  refresh_configure "$GECKO_SRC/$OBJ"
  ./mach build "${MACH_JOBS[@]}"
  # GeckoView dropped the withGeckoBinaries/withoutGeckoBinaries product flavors:
  # gecko binaries are now configured onto the plain `release` variant
  # (configureVariantWithGeckoBinaries), so the task is `assembleRelease` and the
  # AAR is `geckoview*-release.aar` (no `withGeckoBinaries` infix). The old
  # `assembleWithGeckoBinariesRelease` no longer exists ("task not found").
  ./mach gradle geckoview:assembleRelease

  AAR="$(find "$GECKO_SRC/$OBJ" -path '*geckoview*outputs/aar*' \
           -name 'geckoview*-release.aar' 2>/dev/null | head -1)"
  if [ -z "$AAR" ]; then
    echo "ERROR: per-ABI AAR not found under $OBJ (gradle output path changed?)." >&2
    echo "       Look for geckoview*-release.aar and update this script." >&2
    exit 1
  fi
  AAR_FOR_ABI[$ABI]="$AAR"
  echo "   -> $AAR"
done

# ---------------------------------------------------------------------------
# Phase 2 — fat-AAR repackage + publish to mavenLocal.
# ---------------------------------------------------------------------------
TARGET_COUNT="$(set -- $ANDROID_TARGETS; echo $#)"
if [ "$TARGET_COUNT" -eq 1 ]; then
  # ONE ABI: there is nothing to merge, so the fat-AAR repackage is pure waste —
  # skip it. Phase 1 already assembled this ABI's release AAR from an objdir that
  # HAS a compile environment, and $MOZCONFIG still points at it, so the publish
  # below runs straight against that objdir. Skipping also avoids the whole
  # --disable-compile-environment apparatus (the minimal mozconfig, the
  # EMBEDDED_UNIFFI_BINDGEN/NIMBUS_FML host-tool overrides) and the gradle
  # configuration-cache collision between objdir-gv-<abi> and objdir-gv-fat that
  # a second objdir introduces.
  echo "== [phase 2] single ABI ($ABI_LIST) — skipping the fat-AAR repackage =="
  PUB_AAR="${AAR_FOR_ABI[$ABI_LIST]}"
  PUB_KIND="single-ABI $ABI_LIST"
else
  echo "== [phase 2] fat-AAR ($ABI_LIST) + publish to mavenLocal =="
  # Pick any built target as the "host" target for the repackage pass.
  FIRST_T="$(set -- $ANDROID_TARGETS; echo "$1")"

  # Phase 2 is a REPACKAGE (--disable-compile-environment), so it must NOT carry the
  # compile-only options from the template — configure rejects them in this mode
  # ("InvalidOptionError: --disable-rust-tests is not available in this
  # configuration"; same for --enable-strip/--enable-install-strip, etc.). Write a
  # MINIMAL mozconfig from scratch (overwrite, do NOT cp the template) with only the
  # packaging-relevant options:
  #   - --enable-application / --enable-release / --disable-debug / --disable-tests:
  #     confirmed valid with --disable-compile-environment (they evaluate before the
  #     rejected ones) and pin the release variant the publication is named after.
  #   - --enable-geckoview-lite: REQUIRED here too — computeArtifactId runs during
  #     the publish, so without it the fat-AAR would publish `geckoview-omni`, not
  #     `geckoview`. It's a dependency/substs flag, not compile-env-gated.
  #   - the fat-AAR inputs + --disable-compile-environment + target/objdir.
  # The per-ABI AARs are already release+stripped, so strip/crashreporter/etc. don't
  # belong in the repackage. MOZ_BUILD_DATE (version pin) is an exported env var, so
  # it still applies. SDK for the gradle publish: in Docker it's auto-detected from
  # bootstrap; the reuse path isn't exercised here (it hits the glibc wall — use
  # Docker).
  #
  # Host build tools: a --disable-compile-environment Android pass still needs the
  # UniFFI/Nimbus host binaries (HOST_RUST_PROGRAMS: embedded-uniffi-bindgen,
  # nimbus-fml) to assemble the AAR, but can't BUILD them, so configure's check_prog
  # errors ("Cannot find embedded-uniffi-bindgen" / "... nimbus-fml"). check_prog
  # honors a same-named env override, so point both at the copies phase 1 already
  # built in <objdir>/dist/host/bin (they're HOST tools — arch-independent — so
  # either per-ABI objdir's copy works). This is how Mozilla CI feeds the fat-AAR
  # pass too (it fetches the same toolchains); we just reuse what we already built.
  FIRST_ABI="$(abi_for_target "$FIRST_T")"
  FAT_HOSTBIN="$GECKO_SRC/objdir-gv-$FIRST_ABI/dist/host/bin"
  if [ ! -x "$FAT_HOSTBIN/embedded-uniffi-bindgen" ] || [ ! -x "$FAT_HOSTBIN/nimbus-fml" ]; then
    echo "WARN: host tools not found under $FAT_HOSTBIN (embedded-uniffi-bindgen /" >&2
    echo "      nimbus-fml). Phase 1 should have produced them; the fat-AAR configure" >&2
    echo "      will fail without them." >&2
  fi
  {
    echo "ac_add_options --enable-application=mobile/android"
    echo "ac_add_options --enable-release"
    echo "ac_add_options --disable-debug"
    echo "ac_add_options --disable-tests"
    echo "ac_add_options --enable-geckoview-lite"
    echo "ac_add_options --disable-compile-environment"   # repackage only, no recompile
    echo "ac_add_options --target=$FIRST_T"
    echo "mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/objdir-gv-fat"
    echo "export EMBEDDED_UNIFFI_BINDGEN=$FAT_HOSTBIN/embedded-uniffi-bindgen"
    echo "export NIMBUS_FML=$FAT_HOSTBIN/nimbus-fml"
    echo "export MOZ_ANDROID_FAT_AAR_ARCHITECTURES=$ABI_LIST"
    for ABI in "${!AAR_FOR_ABI[@]}"; do
      echo "export $(fatvar_for_abi "$ABI")=${AAR_FOR_ABI[$ABI]}"
    done
  } > "$MOZCONFIG"
  echo "== fat-AAR mozconfig =="
  cat "$MOZCONFIG"
  echo

  refresh_buildid "$GECKO_SRC/objdir-gv-fat"
  refresh_configure "$GECKO_SRC/objdir-gv-fat"
  ./mach build "${MACH_JOBS[@]}"
  # Assemble the fat RELEASE AAR. This is the pass where
  # MOZ_ANDROID_FAT_AAR_ARCHITECTURES merges every ABI's native libs into one AAR
  # (objdir-gv-fat/gradle/build/.../outputs/aar/geckoview-release.aar). The phase-2
  # `./mach build` above only drives gradle for the DEBUG variant, so the release
  # AAR must be built explicitly here, exactly as phase 1 does per-ABI.
  ./mach gradle geckoview:assembleRelease
  FAT_AAR="$(find "$GECKO_SRC/objdir-gv-fat" -path '*geckoview*outputs/aar*' \
               -name 'geckoview*-release.aar' 2>/dev/null | head -1)"
  if [ -z "$FAT_AAR" ] || [ ! -f "$FAT_AAR" ]; then
    echo "ERROR: fat release AAR not found under objdir-gv-fat after assembleRelease." >&2
    exit 1
  fi
  PUB_AAR="$FAT_AAR"
  PUB_KIND="fat"
fi

# Publish the `release` publication to mavenLocal. NOTE: GeckoView's release
# MavenPublication only carries the POM + sources jar + javadoc jar — its publish
# task graph has NO bundleReleaseAar dependency, so the main .aar is NOT installed
# by this step (verified: ~/.m2 gets the .pom + -sources/-javadoc jars but no
# .aar). We still run it because it generates the POM (with GeckoView's transitive
# deps) and creates the mavenLocal GAV directory we drop the AAR into next.
./mach gradle geckoview:publishReleasePublicationToMavenLocal

# Install the assembled AAR ($PUB_KIND — fat, or the single ABI's own) into the
# mavenLocal layout by hand, beside the POM
# the publish just wrote, named <artifactId>-<version>.aar. mavenLocal resolution
# then finds aar+pom by GAV (a local repo needs no checksums). The artifactId
# (geckoview / geckoview-default / geckoview-omni — varies by update channel and
# --enable-geckoview-lite) is read FROM the POM gradle wrote, not hardcoded.
M2_GV="${HOME}/.m2/repository/org/mozilla/geckoview"
INSTALLED=0
while IFS= read -r POM; do
  AAR_DST="${POM%.pom}.aar"
  cp -f "$PUB_AAR" "$AAR_DST"
  # The publish attached no main artifact, so maven-publish wrote the POM with
  # <packaging>pom</packaging> — gradle then treats the module as metadata-only and
  # NEVER resolves the .aar we just placed (consumer: "package org.mozilla.geckoview
  # does not exist"). Rewrite packaging to `aar` so gradle resolves
  # <artifactId>-<version>.aar as the module's main artifact (the Android gradle
  # plugin registers the `aar` type). No .module file is produced here, so the POM
  # is authoritative; mavenLocal needs no checksums.
  sed -i 's#<packaging>pom</packaging>#<packaging>aar</packaging>#' "$POM"
  echo "   installed $PUB_KIND AAR -> $AAR_DST (POM packaging -> aar)"
  INSTALLED=$((INSTALLED + 1))
done < <(find "$M2_GV" -path "*/$GECKOVIEW_VERSION/*.pom" 2>/dev/null)
if [ "$INSTALLED" -eq 0 ]; then
  echo "ERROR: no published POM found under $M2_GV/*/$GECKOVIEW_VERSION/ —" >&2
  echo "       the gradle publish step did not create the mavenLocal entry." >&2
  exit 1
fi

# Inject GeckoView's transitive runtime dependencies into the POM. The publish
# wrote a POM with an EMPTY <dependencies> (no release component attached), so —
# unlike Mozilla's official POM — consumers get none of GeckoView's deps. Without
# this every dep the app doesn't already provide must be hand-pinned in the app's
# build.gradle, and a Firefox bump silently adds new ones (we hit androidx.core,
# snakeyaml, media3-exoplayer-hls one crash at a time). Write the real list here so
# the artifact is self-contained, exactly like Mozilla's.
#
# What goes in: GeckoView's runtime deps — the androidx set (annotation/collection/
# core/lifecycle) + the media3 set + snakeyaml. DELIBERATELY EXCLUDED:
# `play-services-fido` (patch 0007 removed it — injecting it re-adds the Google FIDO
# binary) and the `exoplayer2` project dep (not in the lite build). The androidx set
# was previously excluded because GeckoView 151's catalog pins it NEWER than the app's
# old compileSdk 36 allowed (core 1.18.0 → needs 36.1) and gradle's highest-wins would
# drag the app onto an AAR-metadata error. The app is now **compileSdk 37**, which
# satisfies core 1.18.0 (and lifecycle 2.10.0), so it's safe to inject the full set and
# let the app drop its hand-pins. CAUTION: if the app ever drops back to compileSdk 36,
# re-exclude androidx here (highest-wins would reintroduce the "requires 36.1/37"
# error). Versions resolve from gradle/libs.versions.toml at publish time
# (self-updating); fail loud if an alias stops resolving (catalog changed → re-verify
# WANT vs build.gradle on a FF bump). After this the app may drop its androidx.core +
# snakeyaml + media3-exoplayer-hls pins (the POM supplies them); it KEEPS its
# media3-exoplayer / media3-ui pins (its own player aligns those up to 1.10.1).
python3 - "$GECKO_SRC" "$M2_GV" "$GECKOVIEW_VERSION" <<'PY'
import sys, os, re, glob
gecko, m2gv, ver = sys.argv[1], sys.argv[2], sys.argv[3]
toml_path = os.path.join(gecko, 'gradle', 'libs.versions.toml')
gv_build  = os.path.join(gecko, 'mobile', 'android', 'geckoview', 'build.gradle')
toml = open(toml_path, encoding='utf-8').read()

def section(name):
    m = re.search(r'(?ms)^\[' + re.escape(name) + r'\]\s*\n(.*?)(?=^\[|\Z)', toml)
    return m.group(1) if m else ''

versions = {}
for line in section('versions').splitlines():
    mm = re.match(r'\s*([\w.\-]+)\s*=\s*"([^"]+)"', line)
    if mm:
        versions[mm.group(1)] = mm.group(2)

libs = {}
for line in section('libraries').splitlines():
    mm = re.match(r'\s*([\w.\-]+)\s*=\s*\{(.*)\}', line)
    if not mm:
        continue
    alias, body = mm.group(1), mm.group(2)
    module = re.search(r'module\s*=\s*"([^"]+)"', body)
    group_ = re.search(r'group\s*=\s*"([^"]+)"', body)
    name   = re.search(r'name\s*=\s*"([^"]+)"', body)
    vref   = re.search(r'version\.ref\s*=\s*"([^"]+)"', body)
    vlit   = re.search(r'(?<!\.)\bversion\s*=\s*"([^"]+)"', body)
    if module:
        g, a = module.group(1).split(':', 1)
    elif group_ and name:
        g, a = group_.group(1), name.group(1)
    else:
        continue
    v = versions.get(vref.group(1)) if vref else (vlit.group(1) if vlit else None)
    libs[alias] = (g, a, v)

# The androidx set (annotation/collection/core/lifecycle) IS injected now that the app
# is compileSdk 37. GeckoView 151's catalog pins androidx.core 1.18.0 (needs compileSdk
# 36.1) and lifecycle 2.10.0 (drags core up too); gradle resolves the highest version,
# so these win over any older app pin. That's fine at compileSdk 37 (it satisfies the
# AAR metadata) — it was NOT at compileSdk 36, which is why this list previously
# excluded androidx. If the app ever reverts to compileSdk 36, drop the androidx
# aliases here again or the build hits the "requires compileSdk 36.1/37" error.
# Re-verify against geckoview/build.gradle on a Firefox bump.
WANT = [
    'androidx-annotation', 'androidx-annotation-experimental', 'androidx-collection',
    'androidx-core', 'androidx-lifecycle-common', 'androidx-lifecycle-process',
    'androidx-media3-common', 'androidx-media3-datasource', 'androidx-media3-decoder',
    'androidx-media3-exoplayer', 'androidx-media3-exoplayer-hls',
]
deps = []
for alias in WANT:
    if alias not in libs or not libs[alias][2]:
        sys.stderr.write(
            "ERROR(POM-deps): catalog alias '%s' missing/unresolved in %s — the version "
            "catalog changed; re-verify the WANT list against geckoview/build.gradle.\n"
            % (alias, toml_path))
        sys.exit(1)
    deps.append(libs[alias])

# snakeyaml is a literal coordinate in geckoview/build.gradle, not the catalog.
sy = re.search(r'org\.yaml:snakeyaml:([\w.\-]+)', open(gv_build, encoding='utf-8').read())
if not sy:
    sys.stderr.write("ERROR(POM-deps): org.yaml:snakeyaml:<ver> not found in %s\n" % gv_build)
    sys.exit(1)
deps.append(('org.yaml', 'snakeyaml', sy.group(1)))

xml = "  <dependencies>\n"
for g, a, v in deps:
    xml += ("    <dependency>\n"
            "      <groupId>%s</groupId>\n      <artifactId>%s</artifactId>\n"
            "      <version>%s</version>\n      <scope>runtime</scope>\n"
            "    </dependency>\n" % (g, a, v))
xml += "  </dependencies>\n"

poms = glob.glob(os.path.join(m2gv, '*', ver, '*.pom'))
if not poms:
    sys.stderr.write("ERROR(POM-deps): no POM under %s/*/%s/\n" % (m2gv, ver))
    sys.exit(1)
for pom in poms:
    s = open(pom, encoding='utf-8').read()
    if '<dependencies>' in s:   # idempotent
        continue
    if '</project>' not in s:
        sys.stderr.write("ERROR(POM-deps): no </project> in %s\n" % pom)
        sys.exit(1)
    s = s.replace('</project>', xml + '</project>', 1)
    open(pom, 'w', encoding='utf-8').write(s)
    print("   injected %d <dependency> entries into %s" % (len(deps), os.path.basename(pom)))
PY

echo
echo "[ok] build complete. $PUB_KIND ($ABI_LIST) published under"
echo "     ~/.m2/repository/org/mozilla/geckoview/"
echo "     Next: ./build.sh sync   (prints the exact app/build.gradle wiring)"

#!/usr/bin/env bash
# 00 — Arch Linux prerequisites for building GeckoView.
#
# `./mach bootstrap` (step 02) fetches the Android SDK/NDK, Rust toolchain and a
# vendored JDK into ~/.mozbuild, so we only need the host basics here. This
# installs them and sanity-checks versions. Re-runnable.
#
# IMPORTANT: when you reuse an existing SDK/NDK (config/build.env
# ANDROID_SDK_ROOT/NDK_ROOT), step 02 is SKIPPED — so the bits bootstrap would
# otherwise provide must come from here: the llvm tools (llvm-objdump),
# cbindgen, and the per-ABI Rust targets. Those are all included below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env" 2>/dev/null || true

PKGS=(
  base-devel        # gcc, make, etc.
  git mercurial     # source methods
  python python-pip
  nodejs npm
  rustup            # mach wants a managed Rust; rustup lets it pin the version
  rust-cbindgen     # C bindings gen (bootstrap installs it; needed if 02 skipped)
  clang llvm lld    # llvm provides llvm-objdump, which configure requires
  jdk17-openjdk     # gradle needs a system JDK 17 for the GeckoView build
  zip unzip wget curl which
  yasm nasm
  pkgconf
)

echo "== Installing host packages (sudo pacman) =="
sudo pacman -S --needed --noconfirm "${PKGS[@]}"

# Rust: ensure a default toolchain + the Android targets exist. mach bootstrap
# can also do this, but doing it here makes a from-tarball build (no bootstrap
# VCS niceties) — and the reuse-existing-SDK/NDK skip path — smoother. Add a
# target for every ABI in build.env's ANDROID_TARGETS (so the x86_64 phase isn't
# missing its target), falling back to both if build.env didn't load.
if command -v rustup >/dev/null 2>&1; then
  rustup default stable || true
  for T in ${ANDROID_TARGETS:-aarch64-linux-android x86_64-linux-android}; do
    rustup target add "$T" || true
  done
fi

echo
echo "== Versions =="
python --version || true
node --version   || true
( archlinux-java status 2>/dev/null || java -version 2>&1 | head -1 ) || true
rustc --version  || true
echo
echo "Note: select JDK 17 if you have several:  sudo archlinux-java set java-17-openjdk"
echo "Done. Next: ./build.sh fetch  (or ./build.sh all)"

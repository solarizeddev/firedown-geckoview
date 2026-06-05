#!/usr/bin/env bash
# 00 — Arch Linux prerequisites for building GeckoView.
#
# `./mach bootstrap` (step 02) fetches the Android SDK/NDK, Rust toolchain and a
# vendored JDK into ~/.mozbuild, so we only need the host basics here. This
# installs them and sanity-checks versions. Re-runnable.
set -euo pipefail

PKGS=(
  base-devel        # gcc, make, etc.
  git mercurial     # source methods
  python python-pip
  nodejs npm
  rustup            # mach wants a managed Rust; rustup lets it pin the version
  clang llvm lld
  jdk17-openjdk     # gradle needs a system JDK 17 for the GeckoView build
  zip unzip wget curl which
  yasm nasm
  pkgconf
)

echo "== Installing host packages (sudo pacman) =="
sudo pacman -S --needed --noconfirm "${PKGS[@]}"

# Rust: ensure a default toolchain + the Android target exist. mach bootstrap can
# also do this, but doing it here makes a from-tarball build (no bootstrap VCS
# niceties) smoother.
if command -v rustup >/dev/null 2>&1; then
  rustup default stable || true
  rustup target add aarch64-linux-android || true
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

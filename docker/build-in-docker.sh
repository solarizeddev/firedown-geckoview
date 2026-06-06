#!/usr/bin/env bash
# Build the GeckoView AAR inside the Docker image (stable older glibc), instead of
# on a bleeding-edge-glibc host where Firefox's vendored glsl-optimizer won't
# compile. Usage:
#     docker/build-in-docker.sh            # == ./build.sh all, in the container
#     docker/build-in-docker.sh build      # run a single stage
#     docker/build-in-docker.sh fetch bootstrap patch build
#
# Design:
# - Runs the FULL bootstrap path: the reuse-existing-SDK/NDK env vars
#   (ANDROID_SDK_ROOT/NDK_ROOT, WASI_SYSROOT, …) are deliberately NOT passed in,
#   so `mach bootstrap` provisions Mozilla's tested clang/sysroot/wasi/SDK/NDK and
#   glslopt + RLBox + everything Just Work.
# - Caches live in host-owned, gitignored bind mounts under `.docker-build/`
#   (~/.mozbuild toolchain+SDK/NDK, ~/.cargo, the gecko checkout), so re-runs are
#   incremental and nothing huge is re-downloaded.
# - The published AAR goes to the HOST's ~/.m2, so the firedown app build on the
#   host resolves it via mavenLocal (gradle/Java don't care about glibc).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="firedown-geckoview-build"
BUILDDIR="$ROOT/.docker-build"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found on PATH." >&2
  exit 1
fi

# Rust toolchain lives IN the image (see Dockerfile); persist only cargo's source
# caches (registry/git) as subdir mounts so they can't shadow the rust install.
mkdir -p "$BUILDDIR/mozbuild" "$BUILDDIR/gecko" \
         "$BUILDDIR/cargo-registry" "$BUILDDIR/cargo-git" "$HOME/.m2"

echo "== building image $IMAGE (uid $(id -u)) =="
# Prefer BuildKit for the image build — it STREAMS each step live (with
# --progress=plain) and drops the "legacy builder is deprecated" warning. The
# legacy builder instead buffers a long RUN layer (apt/rustup) until the layer
# finishes, so a first-time/cache-missed image build looks frozen for minutes
# (the "nothing on console" symptom — the image was building quietly).
# BUT BuildKit needs the `buildx` component; on installs where it's missing,
# DOCKER_BUILDKIT=1 makes `docker build` fail outright ("BuildKit is enabled but
# the buildx component is missing or broken"). So auto-detect: use BuildKit only
# when `docker buildx version` works, else fall back to the legacy builder. An
# explicit DOCKER_BUILDKIT in the environment always wins. (To get streaming on a
# host without it: install the buildx package, e.g. `docker-buildx` on Arch.)
if [ -z "${DOCKER_BUILDKIT:-}" ]; then
  if docker buildx version >/dev/null 2>&1; then
    export DOCKER_BUILDKIT=1
  else
    export DOCKER_BUILDKIT=0
  fi
fi
# --progress is a BuildKit-only flag; only pass it when BuildKit is actually on
# (the legacy builder rejects unknown flags).
BUILD_PROGRESS=()
if [ "${DOCKER_BUILDKIT}" = "1" ]; then
  BUILD_PROGRESS=(--progress=plain)
fi
docker build "${BUILD_PROGRESS[@]}" -t "$IMAGE" \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  "$ROOT/docker"

# Default to a full build; otherwise pass the args straight to ./build.sh.
if [ "$#" -eq 0 ]; then
  set -- all
fi

echo "== running: ./build.sh $* (in container) =="
# Allocate an interactive TTY ONLY when our own stdin+stdout are real terminals.
# `-t` needs a terminal; if you pipe/redirect this command (e.g. `| tee build.log`,
# `> log`, nohup, CI), passing `-t` makes docker abort with "the input device is
# not a TTY" — which looks like the build "logs nothing". Detect it: interactive
# (live mach/gradle progress UI) when attached to a terminal, pipe-friendly plain
# line output when redirected. PYTHONUNBUFFERED keeps mach's Python output
# line-flushed so a piped run streams live instead of block-buffering to the end.
DOCKER_TTY=()
if [ -t 0 ] && [ -t 1 ]; then
  DOCKER_TTY=(-it)
fi
exec docker run --rm "${DOCKER_TTY[@]}" \
  -e PYTHONUNBUFFERED=1 \
  -v "$ROOT":/work/src \
  -v "$BUILDDIR/gecko":/work/src/gecko \
  -v "$BUILDDIR/mozbuild":/home/builder/.mozbuild \
  -v "$BUILDDIR/cargo-registry":/home/builder/.cargo/registry \
  -v "$BUILDDIR/cargo-git":/home/builder/.cargo/git \
  -v "$HOME/.m2":/home/builder/.m2 \
  -w /work/src \
  "$IMAGE" \
  bash -lc "./build.sh $*"

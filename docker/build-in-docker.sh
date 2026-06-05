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

mkdir -p "$BUILDDIR/mozbuild" "$BUILDDIR/gecko" "$BUILDDIR/cargo" "$HOME/.m2"

echo "== building image $IMAGE (uid $(id -u)) =="
docker build -t "$IMAGE" \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  "$ROOT/docker"

# Default to a full build; otherwise pass the args straight to ./build.sh.
if [ "$#" -eq 0 ]; then
  set -- all
fi

echo "== running: ./build.sh $* (in container) =="
exec docker run --rm -it \
  -v "$ROOT":/work/src \
  -v "$BUILDDIR/gecko":/work/src/gecko \
  -v "$BUILDDIR/mozbuild":/home/builder/.mozbuild \
  -v "$BUILDDIR/cargo":/home/builder/.cargo \
  -v "$HOME/.m2":/home/builder/.m2 \
  -w /work/src \
  "$IMAGE" \
  bash -lc "./build.sh $*"

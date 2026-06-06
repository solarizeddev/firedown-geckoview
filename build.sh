#!/usr/bin/env bash
# Firedown GeckoView — top-level build orchestrator.
#
#   ./build.sh prereqs   # 00  install Arch host packages
#   ./build.sh fetch     # 01  download the Gecko source
#   ./build.sh bootstrap # 02  mach bootstrap (Android toolchain)
#   ./build.sh patch     # 03  apply Firedown patches (idempotent)
#   ./build.sh build     # 04  build + publish AAR to mavenLocal
#   ./build.sh sync      # 05  print app wiring  (add --apply to edit firedown)
#   ./build.sh publish-abi <triple>   # publish ONE already-built per-ABI AAR to
#                        #     mavenLocal (skip the fat-AAR) — quick single-ABI
#                        #     device/emulator test, e.g. publish-abi aarch64-linux-android
#   ./build.sh all       # fetch → bootstrap → patch → build → sync
#   ./build.sh docker    #     run `all` (or passed stages) inside the build
#                        #     container — use this on a too-new-glibc host (Arch),
#                        #     where the vendored glsl-optimizer won't compile.
#
# config/build.env holds version/ABI/source-method/app-path settings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$ROOT/scripts"

case "${1:-all}" in
  prereqs)   bash "$S/00-prereqs-arch.sh" ;;
  fetch)     bash "$S/01-fetch-source.sh" ;;
  bootstrap) bash "$S/02-bootstrap.sh" ;;
  patch)     bash "$S/03-apply-patches.sh" ;;
  build)     bash "$S/04-build.sh" ;;
  sync)      shift; bash "$S/05-sync-to-app.sh" "$@" ;;
  publish-abi) shift; bash "$S/publish-abi.sh" "$@" ;;
  docker)    shift; bash "$ROOT/docker/build-in-docker.sh" "$@" ;;
  all)
    bash "$S/01-fetch-source.sh"
    bash "$S/02-bootstrap.sh"
    bash "$S/03-apply-patches.sh"
    bash "$S/04-build.sh"
    bash "$S/05-sync-to-app.sh"
    ;;
  *)
    echo "usage: ./build.sh {prereqs|fetch|bootstrap|patch|build|sync|all|docker}" >&2
    exit 2
    ;;
esac

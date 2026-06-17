#!/usr/bin/env bash
# bump-version.sh — one-command GeckoView version bump.
#
#   ./build.sh bump 152.0.20260612001812   # milestone + pinned buildid (one coordinate)
#   ./build.sh bump 152.0 20260612001812   # same, split into two args
#   ./build.sh bump 153.0                   # milestone only (keeps the current buildid pin)
#
# WHY this exists: a bump used to mean THREE coupled hand-edits in
# config/build.env (FIREFOX_VERSION, the derived FIREFOX_TAG, GECKOVIEW_BUILD_DATE)
# AND remembering to invalidate two pieces of stale state that otherwise make the
# build silently produce the OLD version — the lesson of the 151->152 bump:
#   1. The SOURCE checkout. 01-fetch-source.sh skips a non-empty $GECKO_SRC and a
#      shallow `git clone --branch <tag>` can't be retargeted in place, so an old
#      tree is reused as-is. Worse, the Docker flow builds its OWN tree
#      (.docker-build/gecko, mounted over /work/src/gecko) — a DIFFERENT checkout
#      from the host top-level gecko/, so patching one doesn't touch the other.
#   2. The published ~/.m2 entry. `./build.sh sync` reads it back, so a stale one
#      wires the old coordinate into the app.
# This script does all of it: rewrites the three env lines (FIREFOX_TAG derived
# from the milestone), drops every source tree whose milestone != the new one
# (both checkouts), and drops the stale mavenLocal entry. After it, a plain
# `./build.sh docker` (or `all`) fetches/patches/builds the new version from clean.
# The toolchain caches (.docker-build/mozbuild, cargo-*) are NOT touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVF="$ROOT/config/build.env"
# shellcheck source=/dev/null
source "$ENVF"

usage() {
  echo "usage: ./build.sh bump <milestone[.buildid]> [buildid]" >&2
  echo "   e.g. ./build.sh bump 152.0.20260612001812" >&2
  echo "        ./build.sh bump 152.0 20260612001812" >&2
  echo "        ./build.sh bump 153.0        # keep current buildid pin" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
ARG="$1"
BUILDID="${2:-}"

# A full coordinate in $1 is <milestone>.<buildid>: a TRAILING 14-digit segment is
# the buildid, everything before it is the milestone (so 152.0.20260612001812 ->
# milestone 152.0 + buildid 20260612001812, while a bare 152.0 stays a milestone).
if [ -z "$BUILDID" ]; then
  LAST="${ARG##*.}"
  if printf '%s' "$LAST" | grep -Eq '^[0-9]{14}$'; then
    BUILDID="$LAST"
    ARG="${ARG%.*}"
  fi
fi
MILESTONE="$ARG"

printf '%s' "$MILESTONE" | grep -Eq '^[0-9]+(\.[0-9]+)+$' \
  || { echo "ERROR: milestone '$MILESTONE' is not in x.y[.z] form" >&2; exit 1; }
if [ -n "$BUILDID" ]; then
  printf '%s' "$BUILDID" | grep -Eq '^[0-9]{14}$' \
    || { echo "ERROR: buildid '$BUILDID' must be 14 digits (YYYYMMDDHHMMSS)" >&2; exit 1; }
fi

# Mozilla release-tag convention: FIREFOX_<milestone-with-underscores>_RELEASE.
TAG="FIREFOX_${MILESTONE//./_}_RELEASE"

echo "== bump GeckoView version =="
echo "   FIREFOX_VERSION      : $FIREFOX_VERSION -> $MILESTONE"
echo "   FIREFOX_TAG          : $FIREFOX_TAG -> $TAG"
if [ -n "$BUILDID" ]; then
  echo "   GECKOVIEW_BUILD_DATE : ${GECKOVIEW_BUILD_DATE:-<wall-clock>} -> $BUILDID"
else
  echo "   GECKOVIEW_BUILD_DATE : ${GECKOVIEW_BUILD_DATE:-<wall-clock>} (unchanged)"
fi
echo

# Rewrite config/build.env in place. Each key is a unique top-level assignment, so
# an anchored ^KEY=.* substitution is safe (GECKOVIEW_VERSION is derived from these
# two, so it follows automatically and is left alone).
sed -i -E "s|^FIREFOX_VERSION=.*|FIREFOX_VERSION=\"$MILESTONE\"|" "$ENVF"
sed -i -E "s|^FIREFOX_TAG=.*|FIREFOX_TAG=\"$TAG\"|" "$ENVF"
if [ -n "$BUILDID" ]; then
  sed -i -E "s|^GECKOVIEW_BUILD_DATE=.*|GECKOVIEW_BUILD_DATE=\"$BUILDID\"|" "$ENVF"
fi

# Drop any source checkout whose milestone differs from the new one, so fetch
# re-clones instead of silently reusing it. Both trees: the host top-level gecko/
# and the Docker flow's .docker-build/gecko (separate checkouts — the trap).
for T in "$ROOT/gecko" "$ROOT/.docker-build/gecko"; do
  [ -d "$T" ] || continue
  VF=""
  for C in "$T/browser/config/version.txt" "$T/config/milestone.txt"; do
    [ -f "$C" ] && { VF="$C"; break; }
  done
  HAVE=""
  [ -n "$VF" ] && HAVE="$(grep -v '^[[:space:]]*#' "$VF" | grep -v '^[[:space:]]*$' | tail -1 | tr -d '[:space:]')"
  case "$HAVE" in
    "$MILESTONE"|"$MILESTONE".*)
      echo "   [keep] $T is already $HAVE" ;;
    *)
      echo "   [drop] $T was '${HAVE:-unknown}' -> rm -rf (will re-fetch $MILESTONE)"
      rm -rf "$T" ;;
  esac
done

# Drop the published mavenLocal entry so sync can't read back the old coordinate.
M2="$HOME/.m2/repository/org/mozilla/geckoview"
if [ -d "$M2" ]; then
  echo "   [drop] stale mavenLocal entry $M2"
  rm -rf "$M2"
fi

echo
echo "[ok] bumped to $MILESTONE${BUILDID:+ (buildid $BUILDID)} — tag $TAG"
echo "     next: ./build.sh docker     # fetch + patch + build + publish the new version"
echo "           ./build.sh sync        # wire the new coordinate into the app"
echo "     (re-verify the patch anchors report [ok] during the patch stage, and"
echo "      re-check the NDK pin in gecko/python/mozboot/mozboot/android.py.)"

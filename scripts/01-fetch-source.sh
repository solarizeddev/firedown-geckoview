#!/usr/bin/env bash
# 01 — Fetch the Firefox/Gecko source per SOURCE_METHOD (git | tarball | hg).
#
# Lands the tree at $GECKO_SRC. Network steps retry with backoff. Re-running is
# safe: an existing non-empty $GECKO_SRC is left alone (delete it to refetch).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env"

retry() {  # retry <attempts> <cmd...>
  local n="$1"; shift
  local i=1
  until "$@"; do
    if [ "$i" -ge "$n" ]; then echo "FAILED after $n attempts: $*" >&2; return 1; fi
    local s=$((2 ** i)); echo "retry $i/$n in ${s}s: $*"; sleep "$s"; i=$((i + 1))
  done
}

if [ -d "$GECKO_SRC" ] && [ -n "$(ls -A "$GECKO_SRC" 2>/dev/null || true)" ]; then
  # Guard against a STALE checkout. This skip otherwise silently reuses whatever
  # version is already on disk — the 151->152 trap: the Docker flow's own
  # .docker-build/gecko was a 151 shallow clone, so `./build.sh docker fetch` kept
  # reusing it and the container compiled 151 + published 151.0.<buildid> despite
  # FIREFOX_VERSION=152.0 (the host top-level gecko/, patched to 152, is a
  # DIFFERENT tree the Docker build never compiles). A shallow `git clone --branch
  # <tag>` can't be retargeted in place, so the only correct action is to rm -rf
  # and re-clone — detect the mismatch and fail loudly instead of building the
  # wrong version. (version.txt / milestone.txt is just the milestone string.)
  VF="" HAVE=""
  for C in "$GECKO_SRC/browser/config/version.txt" "$GECKO_SRC/config/milestone.txt"; do
    [ -f "$C" ] && { VF="$C"; break; }
  done
  if [ -n "$VF" ]; then
    HAVE="$(grep -v '^[[:space:]]*#' "$VF" | grep -v '^[[:space:]]*$' | tail -1 | tr -d '[:space:]')"
    case "$HAVE" in
      "$FIREFOX_VERSION"|"$FIREFOX_VERSION".*) : ;;
      *)
        echo "ERROR(01): existing source at $GECKO_SRC is version '$HAVE', but" >&2
        echo "           FIREFOX_VERSION='$FIREFOX_VERSION'. A shallow tag clone cannot be" >&2
        echo "           retargeted in place; remove it and re-fetch:" >&2
        echo "               rm -rf '$GECKO_SRC'" >&2
        exit 1
        ;;
    esac
  fi
  echo "[skip] source already present at $GECKO_SRC ($HAVE, rm -rf to refetch)"
  exit 0
fi

echo "== Fetching source via SOURCE_METHOD=$SOURCE_METHOD into $GECKO_SRC =="
case "$SOURCE_METHOD" in
  git)
    # Official Mozilla git (post-2025 migration). Shallow clone at the tag keeps
    # this to a few GB instead of the full history.
    retry 4 git clone --depth 1 --branch "$FIREFOX_TAG" \
      https://github.com/mozilla-firefox/firefox.git "$GECKO_SRC"
    ;;
  tarball)
    TARBALL="firefox-${FIREFOX_VERSION}.source.tar.xz"
    URL="https://archive.mozilla.org/pub/firefox/releases/${FIREFOX_VERSION}/source/${TARBALL}"
    mkdir -p "$GECKO_SRC"
    retry 4 wget -O "/tmp/$TARBALL" "$URL"
    echo "Extracting (this takes a while)…"
    tar -xf "/tmp/$TARBALL" -C "$GECKO_SRC" --strip-components=1
    ;;
  hg)
    retry 4 hg clone https://hg.mozilla.org/mozilla-unified "$GECKO_SRC"
    ( cd "$GECKO_SRC" && hg update "$FIREFOX_TAG" )
    ;;
  *)
    echo "ERROR: unknown SOURCE_METHOD='$SOURCE_METHOD' (git|tarball|hg)" >&2
    exit 1
    ;;
esac
echo "[ok] source ready at $GECKO_SRC"

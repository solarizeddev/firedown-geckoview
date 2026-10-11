#!/usr/bin/env bash
# 06 — Publish the GeckoView artifact in ~/.m2 as a GitHub Release so another
# machine can consume it WITHOUT the multi-hour build.
#
#   ./build.sh publish                 # package ~/.m2's GECKOVIEW_VERSION entry + release it
#   ./build.sh publish --package-only  # just write dist/…tar.gz (+ .sha256), no tag/upload
#
# What travels: the whole mavenLocal GAV directory 04-build.sh produced —
#   org/mozilla/geckoview/<artifactId>/<version>/
#     <artifactId>-<version>.aar          the fat (multi-ABI) AAR
#     <artifactId>-<version>.pom          packaging rewritten to `aar`, transitive
#                                         deps injected (see 04-build.sh)
#     <artifactId>-<version>-sources.jar / -javadoc.jar
# tarred RELATIVE to org/mozilla/geckoview, so the app's fetch
# (firedown/scripts/fetch-prebuilts.sh) extracts it straight into
# ~/.m2/repository/org/mozilla/geckoview/ and the app's existing
# settings.gradle `exclusiveContent { mavenLocal() }` pin resolves it exactly as
# if 04-build.sh had run on that machine. Nothing in the app changes between a
# locally-built and a fetched GeckoView — same path, same POM, same AAR bytes.
#
# The release tag is `geckoview-<version>` (e.g. geckoview-157.0.20260924084938),
# i.e. the pinned Maven coordinate itself, which is ALSO the app's
# gradle.properties `firedown.geckoviewVersion`. One string names the Firefox
# milestone, the pinned buildid, the ~/.m2 directory, the release and the app
# pin — there is nothing to keep in step.
#
# Why GitHub Releases: the AAR is ~165 MB. Git/LFS would keep every revision
# forever (LFS bandwidth on a private repo is metered), GitHub Packages' free
# tier for a private repo holds ~3 of them; a Release asset is free, unmetered
# and allows 2 GB. The repo is private, so both ends authenticate with `gh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env"

PACKAGE_ONLY=0
[[ "${1:-}" == "--package-only" ]] && PACKAGE_ONLY=1

VER="$GECKOVIEW_VERSION"
if [[ -z "${GECKOVIEW_BUILD_DATE:-}" ]]; then
  echo "ERROR: GECKOVIEW_BUILD_DATE is empty in config/build.env — an unpinned build has" >&2
  echo "       a wall-clock version nothing can reference. Pin it, rebuild, then publish." >&2
  exit 1
fi

M2_GV="${HOME}/.m2/repository/org/mozilla/geckoview"
# Exactly one artifactId dir must hold this version (geckoview-default for our
# lite/unofficial build; never hardcoded — 04-build.sh reads it from the POM).
mapfile -t VER_DIRS < <(find "$M2_GV" -mindepth 2 -maxdepth 2 -type d -name "$VER" 2>/dev/null | sort)
if [[ ${#VER_DIRS[@]} -eq 0 ]]; then
  echo "ERROR: nothing published under $M2_GV/*/$VER — run ./build.sh build (or docker) first." >&2
  exit 1
fi
if [[ ${#VER_DIRS[@]} -gt 1 ]]; then
  echo "ERROR: $VER is published under more than one artifactId:" >&2
  printf '       %s\n' "${VER_DIRS[@]}" >&2
  echo "       remove the stale one so the release is unambiguous." >&2
  exit 1
fi
VER_DIR="${VER_DIRS[0]}"
ART_ID="$(basename "$(dirname "$VER_DIR")")"
AAR="$VER_DIR/$ART_ID-$VER.aar"
POM="$VER_DIR/$ART_ID-$VER.pom"

# Guard against the two half-installed states 04-build.sh's own notes describe:
# the publish task alone leaves NO .aar beside the POM, and a POM still saying
# <packaging>pom</packaging> is metadata-only to gradle (the app then fails with
# "package org.mozilla.geckoview does not exist"). Publishing either would hand
# every other machine a broken entry.
[[ -f "$AAR" ]] || { echo "ERROR: $AAR missing — 04-build.sh's AAR install step did not run" >&2; exit 1; }
[[ -f "$POM" ]] || { echo "ERROR: $POM missing" >&2; exit 1; }
if ! grep -q '<packaging>aar</packaging>' "$POM"; then
  echo "ERROR: $POM does not declare <packaging>aar</packaging> — gradle would treat the" >&2
  echo "       module as metadata-only. Re-run the install step (04-build.sh) first." >&2
  exit 1
fi
if ! grep -q '<dependency>' "$POM"; then
  echo "WARNING: $POM carries no <dependency> entries — the POM-deps injection did not" >&2
  echo "         run; consumers will have to hand-pin GeckoView's transitive deps." >&2
fi
# Inspect the AAR with Python's zipfile, NOT `unzip`: unzip is not in a base
# Arch install, and a missing binary made `unzip -l | grep classes.jar` read as
# "no classes.jar" on the very box that built a perfectly good AAR (reported).
# Python is always present here — mach needs it.
AAR_INFO="$(python3 -I - "$AAR" <<'ZIPCHK'
import sys, zipfile
try:
    names = zipfile.ZipFile(sys.argv[1]).namelist()
except Exception as e:
    print("ERROR " + str(e)); sys.exit(0)
has_classes = "classes.jar" in names
abis = sorted({n.split("/")[1] for n in names if n.startswith("jni/") and n.endswith("/libxul.so")})
print(("ok" if has_classes else "noclasses") + " " + " ".join(abis))
ZIPCHK
)"
case "$AAR_INFO" in
  ERROR*)     echo "ERROR: $AAR is not a readable zip: ${AAR_INFO#ERROR }" >&2; exit 1 ;;
  noclasses*) echo "ERROR: $AAR has no classes.jar — not a usable AAR" >&2; exit 1 ;;
esac
ABIS="${AAR_INFO#ok }"
echo "== Packaging $ART_ID:$VER  (ABIs in AAR: ${ABIS:-?})"

DIST="$ROOT/dist"
mkdir -p "$DIST"
TAG="geckoview-$VER"
ASSET="$DIST/$TAG-m2.tar.gz"
# Fixed owner/mtime/order → byte-identical on a re-run (same sha256 after a
# failed upload). Paths are relative to org/mozilla/geckoview on purpose (see
# the header).
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
    -C "$M2_GV" -czf "$ASSET" "$ART_ID/$VER"
( cd "$DIST" && sha256sum "$(basename "$ASSET")" > "$(basename "$ASSET").sha256" )
echo "[ok] $ASSET"
echo "     $(cat "$ASSET.sha256")"

if [[ $PACKAGE_ONLY -eq 1 ]]; then
  exit 0
fi

command -v gh >/dev/null || { echo "ERROR: gh (GitHub CLI) not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not logged in — run: gh auth login" >&2; exit 1; }
cd "$ROOT"
# Name the GitHub repo EXPLICITLY, from origin: gh otherwise infers it from the
# remotes and refuses when there is more than one ("No default remote
# repository has been set") — which is exactly the case in a fork carrying an
# `upstream` remote. The release must land on OUR repo, never upstream's.
GH_REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
if [[ ! "$GH_REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "ERROR: cannot derive owner/repo from origin ($(git -C "$ROOT" remote get-url origin))" >&2
  exit 1
fi
if gh release view -R "$GH_REPO" "$TAG" >/dev/null 2>&1; then
  echo "ERROR: release $TAG already exists on GitHub. A coordinate is published ONCE:" >&2
  echo "       a different AAR under the same version would silently diverge from what" >&2
  echo "       other machines already fetched. Bump GECKOVIEW_BUILD_DATE" >&2
  echo "       (./build.sh bump …), rebuild, then publish the new coordinate." >&2
  exit 1
fi
# The tag names the patch set that built this AAR: HEAD of this repo. The
# buildid in the version pins the Firefox tag; the git tag pins OUR patches.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "WARNING: working tree is dirty — the tag will not name the exact patch set" >&2
  echo "         that produced this AAR. Commit first for a reproducible record." >&2
fi
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git tag -a "$TAG" -m "GeckoView $VER (Firefox $FIREFOX_VERSION / $FIREFOX_TAG, Firedown patch set at $(git rev-parse --short HEAD))"
  git push origin "refs/tags/$TAG"
fi

NOTES="Patched GeckoView for the Firedown app, built from Firefox $FIREFOX_TAG with the Firedown patch set at $(git rev-parse --short HEAD).

Maven coordinate: org.mozilla.geckoview:$ART_ID:$VER   (ABIs: ${ABIS:-see AAR})

Consumed by firedown/scripts/fetch-prebuilts.sh (extracts into ~/.m2/repository/org/mozilla/geckoview/).
Pin in firedown/gradle.properties:
    firedown.geckoviewVersion=$VER"

gh release create -R "$GH_REPO" "$TAG" "$ASSET" "$ASSET.sha256" \
  --title "GeckoView $VER" --notes "$NOTES"

echo
echo "[ok] published $TAG. Now pin it in the app (if not already):"
echo "       firedown/gradle.properties:  firedown.geckoviewVersion=$VER"
echo "     and commit; every other clone fetches this AAR on its next gradle sync."

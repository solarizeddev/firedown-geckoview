#!/usr/bin/env bash
# 05 — Wire the locally-built GeckoView into the firedown app.
#
# Detects the artifactId + version actually published to ~/.m2 (it varies by
# build flavor, so we never hardcode it) and prints the exact gradle changes.
# Pass --apply to also patch firedown's settings.gradle/app build.gradle in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/build.env"

M2="$HOME/.m2/repository/org/mozilla/geckoview"
if [ ! -d "$M2" ]; then
  echo "ERROR: nothing published under $M2 — run ./build.sh build first." >&2
  exit 1
fi

# Pick the most recently published geckoview-* artifact dir + its newest version.
ART_DIR="$(find "$M2" -maxdepth 1 -mindepth 1 -type d -name 'geckoview*' -printf '%T@ %p\n' \
            | sort -nr | head -1 | cut -d' ' -f2-)"
ART_ID="$(basename "$ART_DIR")"
VER="$(find "$ART_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %f\n' \
        | sort -nr | head -1 | cut -d' ' -f2-)"

echo "== Detected local GeckoView =="
echo "   artifactId : $ART_ID"
echo "   version    : $VER"
echo
echo "== Apply these to the firedown app =="
cat <<EOF
1) settings.gradle  → add mavenLocal() FIRST in dependencyResolutionManagement:
       repositories {
           mavenLocal()
           google()
           mavenCentral()
           maven { url "https://maven.mozilla.org/maven2" }
           maven { url 'https://jitpack.io' }
       }

2) app/build.gradle → replace the GeckoView dependency line with:
       implementation "org.mozilla.geckoview:${ART_ID}:${VER}"
   (and revert the experimental microG play-services-fido swap from the
    claude/jolly-dirac-mSEby branch — the source build bakes the FIDO fix in,
    so the exclude + microG line are no longer needed.)

3) Clean + rebuild the app so it resolves the local AAR.
EOF

if [ "${1:-}" = "--apply" ]; then
  APP="$FIREDOWN_APP"
  echo
  echo "== --apply: editing $APP =="
  [ -d "$APP" ] || { echo "ERROR: FIREDOWN_APP=$APP not found" >&2; exit 1; }

  # settings.gradle: insert mavenLocal() once.
  SG="$APP/settings.gradle"
  if ! grep -q 'mavenLocal()' "$SG"; then
    python3 - "$SG" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
# add mavenLocal() as the first repo inside dependencyResolutionManagement
s = re.sub(r'(dependencyResolutionManagement\s*\{\s*\n\s*repositoriesMode[^\n]*\n\s*repositories\s*\{\s*\n)',
           r'\1            mavenLocal()\n', s, count=1)
open(p, "w").write(s)
print("  settings.gradle: added mavenLocal()")
PY
  else
    echo "  settings.gradle: mavenLocal() already present"
  fi

  # app/build.gradle: point the geckoview dependency at the local artifact.
  BG="$APP/app/build.gradle"
  python3 - "$BG" "$ART_ID" "$VER" <<'PY'
import sys, re
p, art, ver = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
# Replace any existing geckoview implementation line (with or without the
# experimental exclude block) with the local-artifact line.
s = re.sub(r'implementation\((?:[^)]*geckoview[^)]*)\)\s*\{[^}]*\}',
           'implementation "org.mozilla.geckoview:%s:%s"' % (art, ver), s, flags=re.S)
s = re.sub(r'implementation\s+"org\.mozilla\.geckoview:[^"]*"',
           'implementation "org.mozilla.geckoview:%s:%s"' % (art, ver), s)
open(p, "w").write(s)
print("  app/build.gradle: geckoview -> org.mozilla.geckoview:%s:%s" % (art, ver))
PY
  echo "  done. Review the diff in $APP before committing."
fi

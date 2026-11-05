#!/usr/bin/env bash
# 0011 — Let the fat-AAR merge accept per-ABI differences in about:license.
#
# WHY: fat_aar.py (python/mozbuild/mozbuild/action/fat_aar.py) compares every
# non-native file of the per-ABI AARs it merges and stops on a difference not
# in its allow list. Our two per-ABI builds of 159.0.1 differ in
# chrome/toolkit/content/global/license.html (about:license), so the merge
# stopped with 'Disallowed: Path "geckoview/chrome/toolkit/content/global/
# license.html" has architecture-specific versions'. Mozilla CI never met it
# because its inputs are its own builds; until 04-build.sh fed ours, the
# merge ran on downloaded Mozilla builds (see CLAUDE.md, fat-AAR 3b).
#
# Harmless to allow: fat_aar.py takes only jni/** and the per-ABI prefs from
# its inputs. license.html in the fat AAR comes from the fat pass's own build,
# and the per-ABI copies are only compared, never shipped. buildconfig.html,
# which also differs per ABI, is already on the list.
#
# Idempotent + marker-gated. Fails LOUDLY if the anchor moved.
set -euo pipefail

SRC="${1:?usage: 0011-fat-aar-allow-license.sh <gecko-src-root>}"
F="$SRC/python/mozbuild/mozbuild/action/fat_aar.py"
MARKER="FIREDOWN-FAT-AAR-LICENSE"

if [ ! -f "$F" ]; then
  echo "ERROR(0011): $F not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0011 fat-AAR license.html allowance already applied"
  exit 0
fi

python3 - "$F" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
anchor = '        "geckoview/chrome/toolkit/content/global/buildconfig.html",\n'
if src.count(anchor) != 1:
    sys.stderr.write(
        "ERROR(0011): the buildconfig.html entry of fat_aar.py's allow list "
        "was not found exactly once — the list moved; inspect it and update "
        "this script.\n")
    sys.exit(1)
addition = (
    "        # %s: differs between per-ABI builds; the\n" % marker
    + "        # fat AAR's own copy comes from the fat pass, not the inputs.\n"
    "        \"geckoview/chrome/toolkit/content/global/license.html\",\n"
)
src = src.replace(anchor, anchor + addition, 1)
open(path, "w", encoding="utf-8").write(src)
print("[ok] 0011 fat-AAR merge allows a per-ABI license.html")
PY

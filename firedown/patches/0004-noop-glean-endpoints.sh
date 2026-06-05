#!/usr/bin/env bash
# 0004 — Blank Mozilla's Glean/FOG telemetry upload endpoints in the Gecko source.
#
# WHY: Glean (firefox-on-glean / glean-core, the Rust telemetry SDK) is compiled
# into GeckoView and wired through thousands of instrumentation call sites, so it
# cannot be removed with a build flag. We already disable upload at RUNTIME
# (datareporting.healthreport.uploadEnabled=false + toolkit.telemetry.* off in
# firedown-geckoview.js). This adds IronFox-style DEFENSE IN DEPTH at the SOURCE
# level: blank the submission + OHTTP endpoint URLs so the FOG uploader has
# nowhere to POST even if upload were somehow enabled. Mirrors IronFox's
# noop_mozilla_endpoints.sh for the gecko/FOG layer.
#
# Scope note: IronFox's Kotlin glean-core overlay stubs and its Fenix/
# android-components/app-services "liberate" patches operate on the APP-layer
# Glean (Kotlin) and its callers — none of that is part of a bare GeckoView AAR,
# so only this Rust-FOG endpoint neuter is relevant here.
#
# Idempotent + marker-gated. Fails LOUDLY if an endpoint string moved (a version
# bump should re-verify, not silently no-op).
set -euo pipefail

SRC="${1:?usage: 0004-noop-glean-endpoints.sh <gecko-src-root>}"
MARKER="FIREDOWN-GLEAN-NOOP"

python3 - "$SRC" "$MARKER" <<'PY'
import os
import sys

src_root, marker = sys.argv[1], sys.argv[2]

# (relative path, [exact string literals to blank to ""]). The FIRST literal in
# each list is load-bearing — its absence means the anchor moved (hard error).
targets = [
    ("toolkit/components/glean/src/init/mod.rs", [
        '"https://incoming.telemetry.mozilla.org"',
        '"https://incoming.thunderbird.net"',
    ]),
    ("toolkit/components/glean/src/init/viaduct_uploader.rs", [
        '"https://mozilla-ohttp.fastly-edge.com/"',
        '"https://prod.ohttp-gateway.prod.webservices.mozgcp.net/ohttp-configs"',
    ]),
]

for rel, literals in targets:
    path = os.path.join(src_root, rel)
    if not os.path.isfile(path):
        sys.stderr.write(
            "ERROR(0004): %s not found — Glean/FOG source layout changed.\n" % rel)
        sys.exit(1)

    text = open(path, encoding="utf-8").read()
    if marker in text:
        print("[skip] 0004 %s already neutered" % rel)
        continue

    primary = literals[0]
    if primary not in text:
        sys.stderr.write(
            "ERROR(0004): endpoint %s not found in %s — anchor moved; "
            "inspect the file and update this script.\n" % (primary, rel))
        sys.exit(1)

    blanked = 0
    for lit in literals:
        count = text.count(lit)
        if count > 0:
            text = text.replace(lit, '""')
            blanked += count

    text = "// %s: telemetry/OHTTP upload endpoints blanked\n" % marker + text
    open(path, "w", encoding="utf-8").write(text)
    print("[ok] 0004 %s: blanked %d endpoint(s)" % (rel, blanked))
PY

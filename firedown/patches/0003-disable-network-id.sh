#!/usr/bin/env bash
# 0003 — Return an empty network ID from the Android network-link service.
#
# WHY: GeckoView's nsAndroidNetworkLinkService::GetNetworkID hands out a stable
# hash derived from the current network (gateway MAC etc.). That value is a
# network-change fingerprint/correlation signal — it lets content/telemetry tell
# when you've moved between Wi-Fi networks and re-identify a network across
# sessions. A no-telemetry downloader has no use for it. IronFox neutralizes it
# (gecko-disable-network-id.patch) by truncating the out-param; we do the same as
# a precise anchored edit rather than a context-diff.
#
# Android-only on purpose: GeckoView's network ID comes through this Android
# service. The desktop-Linux NetlinkService.cpp that IronFox also patches is not
# on the Android code path, so we leave it untouched.
#
# Idempotent + marker-gated. Fails LOUDLY if the anchor moved (so a version bump
# forces a re-check at the real call site instead of silently no-op'ing).
set -euo pipefail

SRC="${1:?usage: 0003-disable-network-id.sh <gecko-src-root>}"
F="$SRC/netwerk/system/android/nsAndroidNetworkLinkService.cpp"
MARKER="FIREDOWN-NETWORK-ID"

if [ ! -f "$F" ]; then
  echo "ERROR(0003): $F not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0003 disable-network-id already applied"
  exit 0
fi

python3 - "$F" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

# Exact body of GetNetworkID in the targeted Firefox release. If Mozilla
# reflows this method, the anchor won't match and we fail loudly below.
anchor = (
    "  if (!mNetlinkSvc) {\n"
    "    return NS_ERROR_NOT_AVAILABLE;\n"
    "  }\n"
    "\n"
    "  mNetlinkSvc->GetNetworkID(aNetworkID);\n"
    "  return NS_OK;"
)
repl = (
    "  // %s: hand out an empty network ID — drop the network-change\n"
    "  // fingerprint/correlation signal. (mNetlinkSvc lookup intentionally\n"
    "  // skipped.)\n"
    "  aNetworkID.Truncate();\n"
    "  return NS_OK;" % marker
)

n = src.count(anchor)
if n == 0:
    sys.stderr.write(
        "ERROR(0003): GetNetworkID body anchor not found in "
        "nsAndroidNetworkLinkService.cpp.\n"
        "             The method changed for this version; inspect it and\n"
        "             update the anchor in this script.\n"
    )
    sys.exit(1)

src = src.replace(anchor, repl)
open(path, "w", encoding="utf-8").write(src)
print("[ok] 0003 disable-network-id: rewired %d call site(s)" % n)
PY

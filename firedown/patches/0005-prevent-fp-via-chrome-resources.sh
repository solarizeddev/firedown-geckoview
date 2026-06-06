#!/usr/bin/env bash
# 0005 — Stop remote pages from probing chrome:// UI resources to fingerprint.
#
# WHY: a web page can't read chrome:// content, but it CAN tell whether specific
# chrome:// resources exist / how they're styled by trying to load them (CSS/img),
# and that resource set is distinctive to a fork — a fingerprinting vector. This
# blocks an http/https document from loading the build's chrome:// UI resources.
# IronFox-derived (gecko-prevent-fingerprinting-via-chrome-resources, a Tor patch)
# but rewritten to be SELF-CONTAINED: a scheme check on the source (no
# do_GetNetUtil/nsINetUtil, so no extra #include to break on a version bump), and
# the allowlist is the GENERIC Firefox resource areas GeckoView ships — none of
# IronFox's chrome://ironfox / branding paths (which don't exist here).
#
# Inserted into nsScriptSecurityManager::CheckLoadURIFlags, in the ALLOW_CHROME
# branch, just before the existing `resource` scheme check. about:/chrome pages
# are chrome-privileged (not http/https), so the scheme gate excludes them — only
# a remote web page hits this.
#
# Idempotent + marker-gated. Fails LOUDLY if the anchor moved.
set -euo pipefail

SRC="${1:?usage: 0005-prevent-fp-via-chrome-resources.sh <gecko-src-root>}"
F="$SRC/caps/nsScriptSecurityManager.cpp"
MARKER="FIREDOWN-CHROME-FP"

if [ ! -f "$F" ]; then
  echo "ERROR(0005): $F not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0005 chrome-resource FP block already applied"
  exit 0
fi

python3 - "$F" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

anchor = (
    '        if (targetScheme.EqualsLiteral("moz-icon")) {\n'
    "          return NS_OK;\n"
    "        }\n"
    "      }\n"
    "\n"
    '      if (targetScheme.EqualsLiteral("resource")) {\n'
)

if anchor not in src:
    sys.stderr.write(
        "ERROR(0005): CheckLoadURIFlags anchor (moz-icon block + resource check) "
        "not found — the function changed; inspect it and update this script.\n")
    sys.exit(1)

block = (
    "      // %s: deny a remote (http/https) page loading the build's chrome://\n"
    "      // UI resources to fingerprint the fork. Web content never legitimately\n"
    "      // references chrome:// (about:/chrome pages are chrome-privileged, not\n"
    "      // http/https, so this scheme gate excludes them) — only a probe does.\n"
    "      // Self-contained scheme check (no nsINetUtil); generic resource areas\n"
    "      // only.\n"
    "      bool fdSrcHttp = false;\n"
    '      rv = aSourceBaseURI->SchemeIs("http", &fdSrcHttp);\n'
    "      NS_ENSURE_SUCCESS(rv, rv);\n"
    "      bool fdSrcHttps = false;\n"
    '      rv = aSourceBaseURI->SchemeIs("https", &fdSrcHttps);\n'
    "      NS_ENSURE_SUCCESS(rv, rv);\n"
    "      if (fdSrcHttp || fdSrcHttps) {\n"
    "        nsAutoCString fdSpec;\n"
    "        rv = aTargetURI->GetAsciiSpec(fdSpec);\n"
    "        NS_ENSURE_SUCCESS(rv, rv);\n"
    '        if (StringBeginsWith(fdSpec, "chrome://global/skin/"_ns) ||\n'
    '            StringBeginsWith(fdSpec, "chrome://global/content/"_ns) ||\n'
    '            StringBeginsWith(fdSpec, "chrome://mozapps/skin/"_ns) ||\n'
    '            StringBeginsWith(fdSpec, "chrome://browser/"_ns)) {\n'
    "          ReportError(errorTag, aSourceURI, aTargetURI, aFromPrivateWindow,\n"
    "                      aInnerWindowID);\n"
    "          return NS_ERROR_DOM_BAD_URI;\n"
    "        }\n"
    "      }\n"
) % marker

# Re-insert the same anchor with the block placed right before the resource check.
replacement = (
    '        if (targetScheme.EqualsLiteral("moz-icon")) {\n'
    "          return NS_OK;\n"
    "        }\n"
    "      }\n"
    "\n"
    + block +
    '      if (targetScheme.EqualsLiteral("resource")) {\n'
)

src = src.replace(anchor, replacement, 1)
open(path, "w", encoding="utf-8").write(src)
print("[ok] 0005 chrome-resource FP block inserted")
PY

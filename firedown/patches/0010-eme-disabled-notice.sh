#!/usr/bin/env bash
# 0010 — Tell the app when a page asks for DRM while EME is turned off.
#
# WHY: Firedown ships with DRM off (media.eme.enabled=false). A page that calls
# navigator.requestMediaKeySystemAccess("com.widevine.alpha", …) is then
# refused inside MediaKeySystemAccessManager::RequestMediaKeySystemAccess with
# "EME has been preffed off", BEFORE the app-approval step
# (media.eme.require-app-approval, GeckoView's PermissionDelegate
# PERMISSION_MEDIA_KEY_SYSTEM_ACCESS) is ever reached. Gecko does announce it —
# it notifies the "mediakeys-request" topic with status "api-disabled", which
# is what desktop Firefox's "Enable DRM" bar listens to (EncryptedMediaChild) —
# but nothing in GeckoView listens, so the app never learns that the page
# wanted DRM and the user only sees the site's player fail.
#
# FIX: at the end of that same branch, after the page has been refused, when
# the embedder asked to approve EME requests
# (media.eme.require-app-approval, GeckoView's default), also start a
# MediaKeySystemAccessPermissionRequest so the app's PermissionDelegate hears
# about it. The request is a NOTICE only: the page's promise is rejected
# exactly as before, synchronously and with the same message, whatever the app
# answers, so the page cannot tell this build from stock. Once per window
# (a player probes many configurations), and not when media.eme.enabled is
# locked (the same condition as Gecko's own notification). The app knows it
# is a notice because its DRM switch is off; it answers "prompt". GeckoView
# stores that answer as a PROMPT row for the site (it stores every answer),
# which nothing reads: Gecko asks the app every time regardless.
#
# Cannot be done app-side: the refusal happens in content-process C++ before
# any embedder callback, and enabling EME just to hear the request would let
# pages tell supported DRM configurations apart from refused ones.
#
# Idempotent + marker-gated. Fails LOUDLY if an anchor moved.
set -euo pipefail

SRC="${1:?usage: 0010-eme-disabled-notice.sh <gecko-src-root>}"
CPP="$SRC/dom/media/eme/MediaKeySystemAccessManager.cpp"
HDR="$SRC/dom/media/eme/MediaKeySystemAccessManager.h"
MARKER="FIREDOWN-EME-DISABLED-NOTICE"

for f in "$CPP" "$HDR"; do
  if [ ! -f "$f" ]; then
    echo "ERROR(0010): $f not found — source layout changed for this version." >&2
    exit 1
  fi
done
if grep -q "$MARKER" "$CPP" && grep -q "$MARKER" "$HDR"; then
  echo "[skip] 0010 EME-disabled notice already applied"
  exit 0
fi
if grep -q "$MARKER" "$CPP" || grep -q "$MARKER" "$HDR"; then
  echo "ERROR(0010): half-applied (marker in only one of the two files) — restore them and re-run." >&2
  exit 1
fi

python3 - "$CPP" "$HDR" "$MARKER" <<'PY'
import sys
cpp_path, hdr_path, marker = sys.argv[1], sys.argv[2], sys.argv[3]

def replace_once(src, anchor, replacement, what, name):
    if anchor not in src:
        sys.stderr.write(
            "ERROR(0010): anchor for %s not found in %s — the code moved; "
            "inspect it and update this script.\n" % (what, name))
        sys.exit(1)
    if src.count(anchor) != 1:
        sys.stderr.write(
            "ERROR(0010): anchor for %s is not unique in %s — tighten the "
            "anchor.\n" % (what, name))
        sys.exit(1)
    return src.replace(anchor, replacement, 1)

# ── 1. Header: a once-per-window flag beside the other manager state. ─────────
hdr = open(hdr_path, encoding="utf-8").read()
anchor = (
    "  nsCOMPtr<nsPIDOMWindowInner> mWindow;\n"
    "  bool mAddedObservers = false;\n"
)
hdr = replace_once(
    hdr,
    anchor,
    anchor
    + "\n"
    + "  // %s: the app was told this window asked\n" % marker
    + "  // for DRM while media.eme.enabled is off. Once per window: players\n"
      "  // probe many configurations in a row.\n"
      "  bool mFiredownDisabledNoticeSent = false;\n",
    "manager state", "MediaKeySystemAccessManager.h")

# ── 2. The pref-off branch: after the page has been refused, start a ─────────
#       notice-only app-approval request. Placed AFTER the rejection so the
#       path up to the page's rejection is byte-identical to stock.
cpp = open(cpp_path, encoding="utf-8").read()
anchor = (
    "    aRequest->RejectPromiseWithNotSupportedError(\"EME has been preffed off\"_ns);\n"
    "    aRequest->mDiagnostics.StoreMediaKeySystemAccess(\n"
    "        mWindow->GetExtantDoc(), aRequest->mKeySystem, false, __func__);\n"
    "    return;\n"
    "  }\n"
)
notice = (
    "    aRequest->RejectPromiseWithNotSupportedError(\"EME has been preffed off\"_ns);\n"
    "    aRequest->mDiagnostics.StoreMediaKeySystemAccess(\n"
    "        mWindow->GetExtantDoc(), aRequest->mKeySystem, false, __func__);\n"
    "    // %s: nothing in GeckoView listens to the\n" % marker
    + "    // notification above, so an embedder that approves EME requests is\n"
      "    // told through its own permission request instead. A notice only:\n"
      "    // the page was refused above, whatever the app answers, and this\n"
      "    // runs after the refusal so the page's path is exactly stock.\n"
      "    if (StaticPrefs::media_eme_require_app_approval() &&\n"
      "        !mFiredownDisabledNoticeSent &&\n"
      "        !Preferences::IsLocked(\"media.eme.enabled\")) {\n"
      "      mFiredownDisabledNoticeSent = true;\n"
      "      RefPtr<MediaKeySystemAccessPermissionRequest> notice =\n"
      "          MediaKeySystemAccessPermissionRequest::Create(mWindow);\n"
      "      if (notice) {\n"
      "        nsresult rv = notice->Start();\n"
      "        if (NS_FAILED(rv)) {\n"
      "          MKSAM_LOG_DEBUG(\"Failed to start the EME-disabled notice\");\n"
      "        }\n"
      "      }\n"
      "    }\n"
      "    return;\n"
      "  }\n"
)
cpp = replace_once(cpp, anchor, notice, "pref-off branch",
                   "MediaKeySystemAccessManager.cpp")

open(hdr_path, "w", encoding="utf-8").write(hdr)
open(cpp_path, "w", encoding="utf-8").write(cpp)
print("[ok] 0010 EME-disabled notice: permission request started when EME is off")
PY

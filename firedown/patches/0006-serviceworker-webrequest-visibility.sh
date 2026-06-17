#!/usr/bin/env bash
# 0006 — Make ServiceWorker-synthesized responses visible to webRequest.
#
# WHY: when a page's ServiceWorker handles a fetch and answers from its Cache or
# with a constructed Response (event.respondWith(...)), the response never hits
# the network. The originating nsHttpChannel DOES fire http-on-modify-request
# (so webRequest already sees the request URL + request headers), but it then
# internally redirects to an InterceptedHttpChannel that pumps the synthesized
# body straight to its listener and **never fires http-on-examine-response**. So
# `onHeadersReceived` doesn't fire and `filterResponseData` is never offered for
# SW responses — the capture blind spot behind the TikTok-style "the SW serves
# endpoints filterResponseData can't tap" note.
#
# FIX: fire the same notification nsHttpChannel makes on the normal path, from
# InterceptedHttpChannel::OnStartRequest, just before it tells its listener the
# response started. That single funnel covers both the respondWith and the
# pre-synthesized-body paths; the reset-to-network fallthrough redirects to a
# DIFFERENT channel and never reaches here, so there's no double-notification.
# Cannot be done app-side (no observer emits for synthesized responses).
#
# Idempotent + marker-gated. Fails LOUDLY if the anchor moved.
set -euo pipefail

SRC="${1:?usage: 0006-serviceworker-webrequest-visibility.sh <gecko-src-root>}"
F="$SRC/netwerk/protocol/http/InterceptedHttpChannel.cpp"
MARKER="FIREDOWN-SW-WEBREQUEST"

if [ ! -f "$F" ]; then
  echo "ERROR(0006): $F not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0006 ServiceWorker webRequest visibility already applied"
  exit 0
fi

python3 - "$F" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

# Tail of InterceptedHttpChannel::OnStartRequest — fire the notification right
# before the listener is told the (synthesized) response started.
# FF152: the listener call was refactored to go through a local
# `nsCOMPtr<nsIStreamListener> listener(mListener);` (was a direct
# `mListener->OnStartRequest(this)` through FF151), with a trailing
# `return NS_OK;`. The hook still lands before StoreOnStartRequestCalled, so
# placement/semantics are unchanged — only the anchor text moved. Re-verify on
# the next bump; this block is prone to exactly this kind of drift.
anchor = (
    "  StoreOnStartRequestCalled(true);\n"
    "  if (mListener) {\n"
    "    nsCOMPtr<nsIStreamListener> listener(mListener);\n"
    "    return listener->OnStartRequest(this);\n"
    "  }\n"
)

if anchor not in src:
    sys.stderr.write(
        "ERROR(0006): OnStartRequest tail anchor not found in "
        "InterceptedHttpChannel.cpp — the method changed; inspect it and update "
        "this script.\n")
    sys.exit(1)

hook = (
    "  // %s: fire http-on-examine-response for the ServiceWorker-synthesized\n"
    "  // response — the one notification InterceptedHttpChannel otherwise never\n"
    "  // sends. This is the same call nsHttpChannel makes on the normal path, and\n"
    "  // it makes SW-served responses visible to the WebExtension webRequest API\n"
    "  // (onHeadersReceived + filterResponseData). The cast matches this file's\n"
    "  // own `this` casts (see PeekStream above).\n"
    "  gHttpHandler->OnExamineResponse(static_cast<nsIHttpChannel*>(this));\n"
) % marker

src = src.replace(anchor, hook + anchor, 1)
open(path, "w", encoding="utf-8").write(src)
print("[ok] 0006 ServiceWorker webRequest visibility: OnExamineResponse hook added")
PY

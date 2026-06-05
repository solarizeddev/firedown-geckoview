#!/usr/bin/env bash
# 0001 — Route WebAuthn through Android Credential Manager, not GMS FIDO2.
#
# WHY: GeckoView delegates WebAuthn to Google Play Services' FIDO2 *browser* API,
# which Google gates behind a package + signing-cert allowlist that indie forks
# don't get into — Firedown's cert is rejected by FidoBrowserApiChimeraService,
# so passkey logins never prompt. GeckoView already has an Android Credential
# Manager path (androidx.credentials, NOT allowlist-gated); it's just guarded by
# `if (!BuildConfig.MOZILLA_OFFICIAL)`, which is false in an official build.
# Forcing that gate true makes every WebAuthn op use Credential Manager → the
# user's passkey provider prompts. (This is the microg-unbreak-fido change.)
#
# Idempotent + marker-gated. Fails LOUDLY if the anchor moved (so you patch the
# real decision site for your Firefox version rather than silently no-op).
set -euo pipefail

SRC="${1:?usage: 0001-webauthn-credential-manager.sh <gecko-src-root>}"
F="$SRC/mobile/android/geckoview/src/main/java/org/mozilla/geckoview/WebAuthnTokenManager.java"
MARKER="FIREDOWN-WEBAUTHN-CREDMAN"
ANCHOR='if (!BuildConfig.MOZILLA_OFFICIAL)'

if [ ! -f "$F" ]; then
  echo "ERROR(0001): $F not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0001 WebAuthn→CredManager already applied"
  exit 0
fi
if ! grep -qF "$ANCHOR" "$F"; then
  echo "ERROR(0001): anchor \"$ANCHOR\" not found in WebAuthnTokenManager.java." >&2
  echo "             The GMS-vs-CredentialManager decision site changed; inspect" >&2
  echo "             the file and update ANCHOR in this script." >&2
  exit 1
fi

python3 - "$F" "$MARKER" "$ANCHOR" <<'PY'
import sys
path, marker, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
repl = "if (true) /* %s: force Android Credential Manager (not the GMS allowlist) */" % marker
n = src.count(anchor)
src = src.replace(anchor, repl)
open(path, "w", encoding="utf-8").write(src)
print("[ok] 0001 WebAuthn→CredManager: rewired %d gate(s)" % n)
PY

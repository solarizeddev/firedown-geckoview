#!/usr/bin/env bash
# 0007 — Drop the GMS FIDO (play-services-fido) runtime dependency entirely.
#
# WHY: 0001 already routes WebAuthn through Android Credential Manager, but
# WebAuthnTokenManager still *references* GMS FIDO types, so the consuming app had
# to bundle `com.google.android.gms:play-services-fido` just so the class could
# LOAD — a Google binary in a from-source, no-Google build. This patch removes the
# need for it: GeckoView compiles against play-services-fido (compileOnly) but
# neither bundles nor runs any GMS FIDO code, so the app drops the dep and the APK
# carries zero Google FIDO classes.
#
# WHAT MAKES IT SAFE (analysis against FIREFOX_151_0_RELEASE):
#   * Class-LOAD blocker: the only GMS reference executed at <clinit> is the static
#     field `SUPPORTED_ALGORITHMS = {EC2Algorithm…, RSAAlgorithm…}`. Made lazy (a
#     method) so nothing GMS is touched when the class loads. (This static field is
#     literally what crashed: NoClassDefFoundError …fido…Algorithm at <clinit>.)
#   * LIVE GMS entry points for a non-official build (BuildConfig.MOZILLA_OFFICIAL
#     is false) are exactly three, all @WrapForJNI:
#       - webAuthnIsUserVerifyingPlatformAuthenticatorAvailable(): ALWAYS calls
#         Fido2ApiClient (no CredManager alternative) — sites call it on load
#         (accounts.google.com), which is what triggered the crash.
#       - makeCredential()/getAssertion(): the GMS FALLBACK the CredManager wrappers
#         drop to when CredManager declines.
#     Each is short-circuited *before* any GMS call with an `if (true) { return …; }`
#     guard. `if (true)` (not an early bare `return`) keeps the now-dead GMS code
#     below compilable — JLS reachability does NOT fold `if (true)`, so there is no
#     "unreachable statement" error, yet the GMS branch never runs.
#   * Everything else GMS (getRequestOptionsFor*, parseErrorResponse, the GMS body
#     of hasCredentialInGMS [0001 makes it return early], WebAuthnUtils
#     .getTransportsForByte) is reachable ONLY from the methods above, so it all
#     becomes dead. ART soft-fails dead methods that reference absent classes (they
#     would throw only if invoked) — the class still loads. Confirmed these are the
#     entire GMS surface (only WebAuthnTokenManager + WebAuthnUtils import gms).
#
# BEHAVIOUR for our build: WebAuthn is Credential-Manager-ONLY. The GMS fallback
# (which never worked for indie forks anyway — the allowlist rejection 0001 exists
# for) is gone, so it returns NOT_SUPPORTED_ERR instead. isUVPAA reports a platform
# authenticator available (true) so sites offer passkeys; the ceremony runs through
# CredManager. The app must ALSO drop its play-services-fido dep (both sides: the
# app bundling it would otherwise put the classes back in the APK).
#
# Idempotent + marker-gated. Fails LOUDLY if any anchor moved (re-verify against
# the new Firefox version's WebAuthnTokenManager.java rather than silently no-op).
set -euo pipefail

SRC="${1:?usage: 0007-webauthn-drop-gms-fido.sh <gecko-src-root>}"
MARKER="FIREDOWN-WEBAUTHN-NOGMS"
F="$SRC/mobile/android/geckoview/src/main/java/org/mozilla/geckoview/WebAuthnTokenManager.java"
G="$SRC/mobile/android/geckoview/build.gradle"

if [ ! -f "$F" ]; then
  echo "ERROR(0007): $F not found — source layout changed for this version." >&2
  exit 1
fi
if [ ! -f "$G" ]; then
  echo "ERROR(0007): $G not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0007 WebAuthn drop-GMS-FIDO already applied"
  exit 0
fi

python3 - "$F" "$G" "$MARKER" <<'PY'
import sys
fpath, gpath, marker = sys.argv[1], sys.argv[2], sys.argv[3]

def replace_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.stderr.write(
            "ERROR(0007): expected exactly 1 occurrence of %s anchor, found %d — "
            "WebAuthnTokenManager.java changed; re-verify and update 0007.\n" % (what, n))
        sys.exit(1)
    return text.replace(old, new, 1)

src = open(fpath, encoding="utf-8").read()

# --- 1. SUPPORTED_ALGORITHMS static field -> lazy method (fixes the <clinit> load) ---
old_field = (
    "  private static final Algorithm[] SUPPORTED_ALGORITHMS = {\n"
    "    EC2Algorithm.ES256,\n"
    "    EC2Algorithm.ES384,\n"
    "    EC2Algorithm.ES512,\n"
    "    EC2Algorithm.ED256, /* no ED384 */\n"
    "    EC2Algorithm.ED512,\n"
    "    RSAAlgorithm.PS256,\n"
    "    RSAAlgorithm.PS384,\n"
    "    RSAAlgorithm.PS512,\n"
    "    RSAAlgorithm.RS256,\n"
    "    RSAAlgorithm.RS384,\n"
    "    RSAAlgorithm.RS512\n"
    "  };\n"
)
new_field = (
    "  // " + marker + ": lazy, NOT a static field. A static initializer runs at\n"
    "  // <clinit> and instantiates GMS FIDO Algorithm classes — with\n"
    "  // play-services-fido removed that throws NoClassDefFoundError at class load,\n"
    "  // before any gate. As a method it is only touched by the (now-dead) GMS path.\n"
    "  private static Algorithm[] supportedAlgorithms() {\n"
    "    return new Algorithm[] {\n"
    "      EC2Algorithm.ES256,\n"
    "      EC2Algorithm.ES384,\n"
    "      EC2Algorithm.ES512,\n"
    "      EC2Algorithm.ED256, /* no ED384 */\n"
    "      EC2Algorithm.ED512,\n"
    "      RSAAlgorithm.PS256,\n"
    "      RSAAlgorithm.PS384,\n"
    "      RSAAlgorithm.PS512,\n"
    "      RSAAlgorithm.RS256,\n"
    "      RSAAlgorithm.RS384,\n"
    "      RSAAlgorithm.RS512\n"
    "    };\n"
    "  }\n"
)
src = replace_once(src, old_field, new_field, "SUPPORTED_ALGORITHMS field")
src = replace_once(
    src,
    "    for (final Algorithm algo : SUPPORTED_ALGORITHMS) {",
    "    for (final Algorithm algo : supportedAlgorithms()) {",
    "SUPPORTED_ALGORITHMS use")

# --- 2. makeCredential: short-circuit the GMS fallback (CredManager already tried) ---
mk_anchor = (
    '    if (!credentialBundle.containsKey("isWebAuthn")) {\n'
    "      // FIDO U2F not supported by Android (for us anyway) at this time\n"
    '      return GeckoResult.fromException(new WebAuthnUtils.Exception("NOT_SUPPORTED_ERR"));\n'
    "    }\n"
)
mk_guard = mk_anchor + (
    "\n"
    "    // " + marker + ": no GMS FIDO. The wrapper already tried Android Credential\n"
    "    // Manager; if it fell through to this GMS path, report not-supported instead\n"
    "    // of invoking play-services-fido. `if (true)` keeps the dead GMS code below\n"
    "    // compilable (compileOnly) without an unreachable-statement error.\n"
    "    if (true) {\n"
    '      return GeckoResult.fromException(new WebAuthnUtils.Exception("NOT_SUPPORTED_ERR"));\n'
    "    }\n"
)
src = replace_once(src, mk_anchor, mk_guard, "makeCredential isWebAuthn block")

# --- 3. getAssertion: short-circuit the GMS fallback ---
ga_anchor = (
    '    if (!assertionBundle.containsKey("isWebAuthn")) {\n'
    "      // FIDO U2F not supported by Android (for us anyway) at this time\n"
    '      return GeckoResult.fromException(new WebAuthnUtils.Exception("NOT_SUPPORTED_ERR"));\n'
    "    }\n"
)
ga_guard = ga_anchor + (
    "\n"
    "    // " + marker + ": no GMS FIDO. CredManager is the assertion path; if it had\n"
    "    // no credential and fell through to this GMS path, report not-supported\n"
    "    // instead of invoking play-services-fido. `if (true)` keeps the dead GMS\n"
    "    // code below compilable without an unreachable-statement error.\n"
    "    if (true) {\n"
    '      return GeckoResult.fromException(new WebAuthnUtils.Exception("NOT_SUPPORTED_ERR"));\n'
    "    }\n"
)
src = replace_once(src, ga_anchor, ga_guard, "getAssertion isWebAuthn block")

# --- 4. isUVPAA: report available without GMS (CredManager runs the ceremony) ---
uvpaa_anchor = (
    "  private static GeckoResult<Boolean> webAuthnIsUserVerifyingPlatformAuthenticatorAvailable() {\n"
    "    final Task<Boolean> task;\n"
)
uvpaa_guard = (
    "  private static GeckoResult<Boolean> webAuthnIsUserVerifyingPlatformAuthenticatorAvailable() {\n"
    "    // " + marker + ": no GMS FIDO. Report a platform authenticator as available\n"
    "    // so sites offer WebAuthn; the ceremony itself goes through Android\n"
    "    // Credential Manager. `if (true)` keeps the dead GMS code below compilable.\n"
    "    if (true) {\n"
    "      return GeckoResult.fromValue(true);\n"
    "    }\n"
    "    final Task<Boolean> task;\n"
)
src = replace_once(src, uvpaa_anchor, uvpaa_guard, "isUVPAA body")

open(fpath, "w", encoding="utf-8").write(src)

# --- 5. build.gradle: implementation -> compileOnly (compile, don't bundle/declare) ---
g = open(gpath, encoding="utf-8").read()
g_old = "    implementation libs.play.services.fido"
if g_old not in g:
    sys.stderr.write(
        "ERROR(0007): '%s' not found in geckoview/build.gradle — the dependency line "
        "moved; re-verify and update 0007.\n" % g_old)
    sys.exit(1)
g_new = (
    "    // " + marker + ": compileOnly, not implementation — GeckoView compiles\n"
    "    // against the GMS FIDO types (dead code, never executed at runtime) but the\n"
    "    // AAR neither bundles nor declares play-services-fido, so no Google binary\n"
    "    // ships. The consuming app must NOT add it back as a runtime dep.\n"
    "    compileOnly libs.play.services.fido"
)
g = g.replace(g_old, g_new, 1)
open(gpath, "w", encoding="utf-8").write(g)

print("[ok] 0007 WebAuthn drop-GMS-FIDO: lazy algorithms + 3 live-path guards + compileOnly")
PY

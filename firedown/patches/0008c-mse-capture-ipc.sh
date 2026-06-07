#!/usr/bin/env bash
# 0008c — Magic Record, part 3a: the parent-side completion bridge + EXPORTS.
#
# SCOPE NOTE — why this is only "part 3a":
#   The IPC transport has two halves. This script does the half that lives in
#   OUR OWN files (verifiable, fail-loud like 0008a/0008b):
#     * export FiredownCaptureManager.h so the IPC actors can include it;
#     * add the parent-side completion bridge (SetCompletionListener /
#       NotifyCompletion) the GeckoView layer (0008d) uses to forward a finished
#       capture to the app.
#   The OTHER half edits central, shared IPC files — PContent.ipdl,
#   ContentChild.{h,cpp}, ContentParent.{h,cpp} — whose anchors and IPDL recv
#   signatures are version-specific and CANNOT be verified without the checked-out
#   tree + a compile. That half is specified, line-for-line, in the companion
#   `0008c-WIRING.md` (committed beside this script). Apply it by hand against the
#   tree (or paste me the relevant sections of those files and I'll emit exact
#   anchored edits). Do NOT pretend it's validated — it is the only part of the
#   0008 series not anchor-verified against source.
#
# THREADING: the parent-side bridge is parent-process, main-thread only (ContentParent
# recv handlers and the GeckoView listener both run on the parent main thread). The
# listener is stored on the (parent-process) singleton instance — no file-scope static
# std::function (avoids a static ctor/dtor).
#
# DEPENDS ON 0008b. Idempotent, marker-gated (FIREDOWN-MSE-IPC), fail-loud.
set -euo pipefail

SRC="${1:?usage: 0008c-mse-capture-ipc.sh <gecko-src-root>}"
MSDIR="$SRC/dom/media/mediasource"
MGR_H="$MSDIR/FiredownCaptureManager.h"
MGR_CPP="$MSDIR/FiredownCaptureManager.cpp"
MOZBUILD="$MSDIR/moz.build"
MARKER="FIREDOWN-MSE-IPC"

for f in "$MGR_H" "$MGR_CPP" "$MOZBUILD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR(0008c): $f not found — apply 0008b first." >&2
    exit 1
  fi
done
if ! grep -q "FIREDOWN-MSE-CONTROL" "$MGR_H"; then
  echo "ERROR(0008c): 0008b (FIREDOWN-MSE-CONTROL) must be applied first." >&2
  exit 1
fi
if grep -q "$MARKER" "$MGR_H"; then
  echo "[skip] 0008c parent-side completion bridge already applied"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) Export FiredownCaptureManager.h so dom/ipc actors can include it as
#    "mozilla/dom/FiredownCaptureManager.h".
# ---------------------------------------------------------------------------
python3 - "$MOZBUILD" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "FiredownCaptureManager.h" in s:
    print("[skip] 0008c moz.build already exports FiredownCaptureManager.h")
    sys.exit(0)
anchor = "EXPORTS.mozilla.dom += ["
if anchor not in s:
    sys.stderr.write("ERROR(0008c): 'EXPORTS.mozilla.dom += [' not found in "
                     "mediasource/moz.build — confirm the EXPORTS block.\n")
    sys.exit(1)
s = s.replace(anchor, anchor + '\n    "FiredownCaptureManager.h",', 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008c moz.build: EXPORTS FiredownCaptureManager.h")
PY

# ---------------------------------------------------------------------------
# 2) FiredownCaptureManager.h — parent-side completion bridge.
# ---------------------------------------------------------------------------
python3 - "$MGR_H" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
changed = False

# typedef + methods, after the FinishCallback using (0008b).
using_anchor = ("  using FinishCallback =\n"
                "      std::function<void(bool aComplete, uint64_t aBytes, nsresult aStatus)>;")
add = (using_anchor + "\n\n"
       "  // FIREDOWN-MSE-IPC (parent process, main thread): the IPC transport routes\n"
       "  // a child's capture completion up via NotifyCompletion(); the GeckoView\n"
       "  // layer (0008d) sets the listener to forward it to the app.\n"
       "  using CompletionListener =\n"
       "      std::function<void(const nsAString& aCaptureId, bool aComplete,\n"
       "                         uint64_t aBytes, nsresult aStatus)>;\n"
       "  void SetCompletionListener(CompletionListener aListener);\n"
       "  void NotifyCompletion(const nsAString& aCaptureId, bool aComplete,\n"
       "                        uint64_t aBytes, nsresult aStatus);")
if "CompletionListener" not in s:
    if using_anchor not in s:
        sys.stderr.write("ERROR(0008c): FinishCallback using (0008b) not found in "
                         "FiredownCaptureManager.h.\n")
        sys.exit(1)
    s = s.replace(using_anchor, add, 1)
    changed = True

# member, after mCaptures (0008b).
mem_anchor = "  nsTArray<UniquePtr<Capture>> mCaptures;"
if "mCompletionListener" not in s:
    if mem_anchor not in s:
        sys.stderr.write("ERROR(0008c): mCaptures member (0008b) not found in "
                         "FiredownCaptureManager.h.\n")
        sys.exit(1)
    s = s.replace(mem_anchor,
                  mem_anchor +
                  "\n  CompletionListener mCompletionListener;  // FIREDOWN-MSE-IPC (parent)",
                  1)
    changed = True

if changed:
    open(path, "w", encoding="utf-8").write(s)
    print("[ok] 0008c FiredownCaptureManager.h: completion bridge decls")
else:
    print("[skip] 0008c FiredownCaptureManager.h already patched")
PY

# ---------------------------------------------------------------------------
# 3) FiredownCaptureManager.cpp — implement the bridge.
# ---------------------------------------------------------------------------
python3 - "$MGR_CPP" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "SetCompletionListener" in s:
    print("[skip] 0008c FiredownCaptureManager.cpp already patched")
    sys.exit(0)
anchor = ("void FiredownCaptureManager::UnregisterMediaSource(MediaSource* aMediaSource) {\n"
          "  MOZ_ASSERT(NS_IsMainThread());\n"
          "  mMediaSources.RemoveElement(aMediaSource);\n"
          "}")
if anchor not in s:
    sys.stderr.write("ERROR(0008c): UnregisterMediaSource impl (0008b) not found.\n")
    sys.exit(1)
impl = (anchor + "\n\n"
"void FiredownCaptureManager::SetCompletionListener(CompletionListener aListener) {\n"
"  MOZ_ASSERT(NS_IsMainThread());\n"
"  mCompletionListener = std::move(aListener);\n"
"}\n"
"\n"
"void FiredownCaptureManager::NotifyCompletion(const nsAString& aCaptureId,\n"
"                                              bool aComplete, uint64_t aBytes,\n"
"                                              nsresult aStatus) {\n"
"  MOZ_ASSERT(NS_IsMainThread());\n"
"  if (mCompletionListener) {\n"
"    mCompletionListener(aCaptureId, aComplete, aBytes, aStatus);\n"
"  }\n"
"}")
s = s.replace(anchor, impl, 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008c FiredownCaptureManager.cpp: completion bridge impl")
PY

echo "[ok] 0008c part-3a complete — parent-side bridge + EXPORTS. Now apply the"
echo "     central-file IPC wiring by hand per firedown/patches/0008c-WIRING.md."

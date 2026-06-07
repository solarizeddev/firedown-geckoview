#!/usr/bin/env bash
# 0008e — Magic Record, part 4: the clean end-of-stream "complete" signal.
#
# WHAT THIS DOES
#   When the page calls MediaSource.endOfStream() with NO error (the player has
#   appended the WHOLE video), finalize any armed capture sinks on that
#   MediaSource as COMPLETE — as opposed to the PARTIAL that Detach/teardown emits.
#   This is what lets the app know it captured the whole video (vs a clip cut short
#   by a tab close), and it closes the files at the earliest correct moment (the
#   instant the video finishes buffering) so the clip is ready to mux immediately.
#
#   Routed through FiredownCaptureManager (already a friend of SourceBuffer from
#   0008b) so no new friend relationship is needed and mType/mFiredownSink stay
#   encapsulated.
#
# THREADING / LIFETIME — all main-thread:
#   * MediaSource::EndOfStream runs on the content main thread; the manager method
#     and SourceBuffer::FinalizeFiredownCapture are main-thread too. No new locks.
#   * Idempotent vs Detach: FinalizeFiredownCapture nulls mFiredownSink and
#     FiredownCaptureSink::Finalize is idempotent, so a clean EOS followed by a
#     later Detach (e.g. navigation after the video ended) is a no-op the 2nd time;
#     the FIRST finalize (complete=true here) wins, so the capture stays COMPLETE.
#   * Only the NO-ERROR end-of-stream finalizes complete. An error/decode-error EOS
#     is left to Detach -> partial (the bytes are valid only up to the truncation).
#   * A player that re-opens the MediaSource after EOS and appends more (rare) won't
#     re-capture — but we already hold the whole video, which is the point.
#
# DEPENDS ON 0008b. Idempotent, marker-gated (FIREDOWN-MSE-FINALIZE), fail-loud.
set -euo pipefail

SRC="${1:?usage: 0008e-mse-capture-endofstream.sh <gecko-src-root>}"
MSDIR="$SRC/dom/media/mediasource"
MGR_H="$MSDIR/FiredownCaptureManager.h"
MGR_CPP="$MSDIR/FiredownCaptureManager.cpp"
MS_CPP="$MSDIR/MediaSource.cpp"
MARKER="FIREDOWN-MSE-FINALIZE"

for f in "$MGR_H" "$MGR_CPP" "$MS_CPP"; do
  if [ ! -f "$f" ]; then
    echo "ERROR(0008e): $f not found — apply 0008b first." >&2
    exit 1
  fi
done
if ! grep -q "FIREDOWN-MSE-CONTROL" "$MGR_H"; then
  echo "ERROR(0008e): 0008b (FIREDOWN-MSE-CONTROL) must be applied first." >&2
  exit 1
fi
if grep -q "$MARKER" "$MGR_H"; then
  echo "[skip] 0008e end-of-stream complete signal already applied"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) FiredownCaptureManager.h — declare FinalizeMediaSourceComplete (public).
# ---------------------------------------------------------------------------
python3 - "$MGR_H" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "FinalizeMediaSourceComplete" in s:
    print("[skip] 0008e FiredownCaptureManager.h already declares it")
    sys.exit(0)
anchor = ("  void OnTrackDone(const nsAString& aCaptureId, bool aComplete, uint64_t aBytes,\n"
          "                   nsresult aStatus);")
if anchor not in s:
    sys.stderr.write("ERROR(0008e): OnTrackDone decl (0008b) not found in "
                     "FiredownCaptureManager.h.\n")
    sys.exit(1)
add = (anchor + "\n\n"
       "  // FIREDOWN-MSE-FINALIZE: clean end-of-stream -> finalize this MediaSource's\n"
       "  // armed sinks as COMPLETE (manager is a friend of SourceBuffer). Main thread.\n"
       "  void FinalizeMediaSourceComplete(MediaSource* aMediaSource);")
s = s.replace(anchor, add, 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008e FiredownCaptureManager.h: FinalizeMediaSourceComplete decl")
PY

# ---------------------------------------------------------------------------
# 2) FiredownCaptureManager.cpp — implement it (before the namespace close).
# ---------------------------------------------------------------------------
python3 - "$MGR_CPP" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "FinalizeMediaSourceComplete" in s:
    print("[skip] 0008e FiredownCaptureManager.cpp already implements it")
    sys.exit(0)
anchor = "}  // namespace dom\n}  // namespace mozilla"
if anchor not in s:
    sys.stderr.write("ERROR(0008e): namespace-close anchor not found in "
                     "FiredownCaptureManager.cpp.\n")
    sys.exit(1)
impl = (
"void FiredownCaptureManager::FinalizeMediaSourceComplete(\n"
"    MediaSource* aMediaSource) {\n"
"  MOZ_ASSERT(NS_IsMainThread());\n"
"  if (!aMediaSource) {\n"
"    return;\n"
"  }\n"
"  SourceBufferList* list = aMediaSource->SourceBuffers();\n"
"  if (!list) {\n"
"    return;\n"
"  }\n"
"  for (uint32_t i = 0; i < list->Length(); ++i) {\n"
"    bool found = false;\n"
"    SourceBuffer* sb = list->IndexedGetter(i, found);\n"
"    if (found && sb) {\n"
"      sb->FinalizeFiredownCapture(/* aComplete */ true);\n"
"    }\n"
"  }\n"
"}\n"
"\n")
s = s.replace(anchor, impl + anchor, 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008e FiredownCaptureManager.cpp: FinalizeMediaSourceComplete impl")
PY

# ---------------------------------------------------------------------------
# 3) MediaSource.cpp — call it from the clean (no-error) end-of-stream path.
# ---------------------------------------------------------------------------
python3 - "$MS_CPP" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "FinalizeMediaSourceComplete" in s:
    print("[skip] 0008e MediaSource.cpp already calls it")
    sys.exit(0)
# The clean end-of-stream block opens with this, verbatim from source.
anchor = ("  if (!aError.WasPassed()) {\n"
          "    DurationChangeOnEndOfStream();")
if anchor not in s:
    sys.stderr.write("ERROR(0008e): EndOfStream no-error block anchor not found in "
                     "MediaSource.cpp.\n")
    sys.exit(1)
new = ("  if (!aError.WasPassed()) {\n"
       "    // FIREDOWN-MSE-FINALIZE: clean end-of-stream => the whole video is\n"
       "    // buffered; finalize any armed Magic Record sinks on this MediaSource as\n"
       "    // COMPLETE (vs the PARTIAL that Detach/teardown emits). Main thread; no-op\n"
       "    // if nothing is armed.\n"
       "    if (FiredownCaptureManager* m = FiredownCaptureManager::GetIfExists()) {\n"
       "      m->FinalizeMediaSourceComplete(this);\n"
       "    }\n"
       "    DurationChangeOnEndOfStream();")
s = s.replace(anchor, new, 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008e MediaSource.cpp: finalize-complete on clean end-of-stream")
PY

echo "[ok] 0008e complete — clean end-of-stream now finalizes captures as COMPLETE"

#!/usr/bin/env bash
# 0008a — Magic Record, part 1: the SourceBuffer capture sink + the tap.
#
# WHAT THIS DOES
#   Adds FiredownCaptureSink (a new content-process class) and taps
#   SourceBuffer::AppendData so that, WHEN ARMED, the raw media segments the page
#   feeds <video> via SourceBuffer.appendBuffer are written, in order, to a file
#   descriptor the embedding app opened. This part is INERT: nothing constructs a
#   sink yet (arming + the fd + completion reporting arrive in 0008b/0008c via an
#   IPC actor). It compiles and changes no behaviour until mFiredownSink is set.
#
# WHY A SEPARATE, SELF-CONTAINED PART
#   All the concurrency/lifetime hazard lives in FiredownCaptureSink, so it ships
#   and is reviewed on its own, fully, before any IPC exists to drive it.
#
# THREADING / LIFETIME / TEARDOWN — every case accounted for (see also the long
# contract comment in FiredownCaptureSink.h):
#   * SourceBuffer (and its mFiredownSink pointer) is MAIN-THREAD-ONLY. AppendData,
#     Detach, the dtor, and our Write()/Finalize() calls all run on the content
#     main thread (verified: AppendData/Detach/~SourceBuffer all assert
#     NS_IsMainThread). => the sink POINTER is never touched off-thread; no lock.
#   * The only cross-thread object is the appended MediaByteBuffer, which is
#     NS_INLINE_DECL_THREADSAFE_REFCOUNTING (verified in MediaData.h) and immutable
#     once appended — so AddRef on main / read+Release on the writer thread is a
#     data race against nothing.
#   * Blocking write()/close() run on a DEDICATED SERIAL writer thread. Serial =>
#     (a) container order preserved (init segment before media), (b) the fd is
#     closed STRICTLY AFTER every queued write, so a write can never hit a
#     closed/recycled fd. No partial-write/EBADF/wrong-file race.
#   * LEAKS: write runnables hold a strong ref to the sink, so it outlives in-
#     flight I/O; the fd is a UniqueFileHandle closed in the finalize runnable (or
#     auto-closed in the dtor when refcount==0 guarantees no writer activity); the
#     writer thread is AsyncShutdown()'d in Finalize()/dtor. No fd, thread, or
#     buffer leak on any exit path.
#   * NAVIGATION / TAB CLOSE / removeSourceBuffer: all funnel through
#     SourceBuffer::Detach() (the dtor asserts !mMediaSource, i.e. Detach always
#     ran first) -> Finalize(false) => the partial file is flushed & closed. The
#     app keeps its OWN copy of the fd, so even an abrupt content-process kill
#     leaves the already-written bytes intact for the app to finalize.
#   * BACKGROUND TAB / APP BACKGROUNDED WHILE PLAYING: no special path needed — we
#     piggyback the real append path, so as long as the page keeps appending
#     (background tabs keep running), the sink keeps writing; if the OS suspends
#     the process, appends pause and resume with it; the fd survives suspend.
#   * CRASH MID-WRITE: at most the last in-flight segment is torn; the file is a
#     valid fragmented stream up to the last complete write (muxable). We write
#     each segment immediately (no large in-memory backlog), minimising loss.
#
# KNOWN CONTENT EDGES (fidelity, NOT safety — no leak/crash/race):
#   * SourceBuffer.abort()/remove()/changeType() mid-capture can leave a fragment
#     seam or a container-type change in the captured file. ffmpeg muxes up to the
#     last good fragment; 0008c may add seam handling later. Rare for VOD playback.
#
# ANCHOR CONFIDENCE: AppendData, Detach, ~SourceBuffer, the SourceBuffer private
# member block, and the forward-decl cluster were taken VERBATIM from the FF source.
# The SourceBuffer.cpp own-header include line and the moz.build sources block are
# inferred. Every hunk below FAILS LOUD if its anchor moved (repo convention) — on
# a mismatch at `./build.sh patch`, inspect and update the one anchor.
#
# Idempotent + marker-gated (FIREDOWN-MSE-TAP). Re-running is a no-op.
set -euo pipefail

SRC="${1:?usage: 0008a-mse-capture-sink-and-tap.sh <gecko-src-root>}"
MSDIR="$SRC/dom/media/mediasource"
SB_H="$MSDIR/SourceBuffer.h"
SB_CPP="$MSDIR/SourceBuffer.cpp"
MOZBUILD="$MSDIR/moz.build"
SINK_H="$MSDIR/FiredownCaptureSink.h"
SINK_CPP="$MSDIR/FiredownCaptureSink.cpp"
MARKER="FIREDOWN-MSE-TAP"

for f in "$SB_H" "$SB_CPP" "$MOZBUILD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR(0008a): $f not found — source layout changed for this version." >&2
    exit 1
  fi
done

if grep -q "$MARKER" "$SB_CPP"; then
  echo "[skip] 0008a Magic Record sink + tap already applied"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) New file: FiredownCaptureSink.h
# ---------------------------------------------------------------------------
cat > "$SINK_H" <<'SINK_H_EOF'
/* -*- mode: c++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef DOM_MEDIA_MEDIASOURCE_FIREDOWNCAPTURESINK_H_
#define DOM_MEDIA_MEDIASOURCE_FIREDOWNCAPTURESINK_H_

// FIREDOWN-MSE-TAP
//
// FiredownCaptureSink writes the raw, in-order media segments appended to ONE
// SourceBuffer (the bytes the page hands <video> via SourceBuffer.appendBuffer)
// to a file descriptor the embedding app opened and passed down. It is the
// content-process write end of "Magic Record". Arming, the fd, and completion
// reporting are wired by the IPC layer (patch 0008b); on its own this class does
// nothing until something constructs it with an fd.
//
// THREADING / LIFETIME CONTRACT  — read before touching:
//   * Constructed, Write()-en and Finalize()-d ONLY on the content main thread
//     (the thread SourceBuffer lives on). The owning SourceBuffer holds the only
//     strong ref (SourceBuffer::mFiredownSink) and clears it in Finalize().
//   * Refcounting is THREADSAFE: write runnables hold a strong ref to keep the
//     sink alive across the hop to the writer thread, so the final Release may
//     land on either thread.
//   * Blocking write()/close() run on a DEDICATED SERIAL writer thread
//     (mWriterThread). Serial guarantees container order (init before media) and
//     that the fd is closed strictly AFTER every queued write — a write can never
//     touch a closed/recycled fd.
//   * mFd / mBytesWritten / mWriteStatus / mDone are WRITER-THREAD-ONLY; mFinalized
//     is MAIN-THREAD-ONLY. The only state shared between the two threads is the
//     threadsafe refcount and the immutable MediaByteBuffers (read-only once
//     appended). => no mutex by construction.
//   * The app keeps its own copy of the fd, so an abrupt teardown still leaves the
//     already-written bytes intact on disk for the app to finalize.

#include <functional>
#include "mozilla/RefPtr.h"
#include "mozilla/UniquePtrExtensions.h"  // UniqueFileHandle
#include "nsCOMPtr.h"
#include "nsStringFwd.h"
#include "nsString.h"

class nsIThread;

namespace mozilla {
class MediaByteBuffer;

namespace dom {

class FiredownCaptureSink final {
 public:
  // Fired exactly once, on the writer thread, when the file is finalized.
  //   aComplete : true iff finalized via a clean end-of-stream; false if cut
  //               short (navigation / close / detach) => partial-but-playable.
  //   aBytes    : total bytes written.
  //   aStatus   : NS_OK, or the first write/close error encountered.
  using DoneCallback =
      std::function<void(bool aComplete, uint64_t aBytes, nsresult aStatus)>;

  NS_INLINE_DECL_THREADSAFE_REFCOUNTING(FiredownCaptureSink)

  // Takes ownership of aFd. aMimeType is the SourceBuffer's container type
  // (SourceBuffer::mType), reported to the app so it can tell which file is which
  // track. aDone may be null. If the writer thread can't be created the sink is
  // inert (Write() no-ops) and aDone fires with the error at Finalize().
  FiredownCaptureSink(UniqueFileHandle aFd, const nsACString& aMimeType,
                      DoneCallback aDone);

  // Main thread. Queue one appended segment. Cheap: AddRefs the immutable,
  // threadsafe MediaByteBuffer and posts it; no copy, no main-thread I/O. No-op
  // once Finalize() has run.
  void Write(MediaByteBuffer* aData);

  // Main thread, idempotent. Stop accepting writes; then (after all queued writes
  // drain on the serial writer thread) flush, close the fd, fire aDone, and shut
  // the writer thread down. Non-blocking for the caller.
  void Finalize(bool aComplete);

  const nsCString& MimeType() const { return mMimeType; }

 private:
  ~FiredownCaptureSink();

  // ---- main-thread-only ----
  const nsCString mMimeType;
  bool mFinalized = false;

  // ---- writer-thread-only (no lock) ----
  UniqueFileHandle mFd;
  uint64_t mBytesWritten = 0;
  nsresult mWriteStatus = NS_OK;
  DoneCallback mDone;

  // Created on the main thread; serializes all I/O; AsyncShutdown()'d in
  // Finalize()/dtor. Null if creation failed (sink then inert).
  nsCOMPtr<nsIThread> mWriterThread;
};

}  // namespace dom
}  // namespace mozilla

#endif  // DOM_MEDIA_MEDIASOURCE_FIREDOWNCAPTURESINK_H_
SINK_H_EOF
echo "[ok] 0008a wrote $SINK_H"

# ---------------------------------------------------------------------------
# 2) New file: FiredownCaptureSink.cpp  (Android/POSIX — the GeckoView build
#    only ever cross-compiles dom/media for Android targets)
# ---------------------------------------------------------------------------
cat > "$SINK_CPP" <<'SINK_CPP_EOF'
/* -*- mode: c++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// FIREDOWN-MSE-TAP — see FiredownCaptureSink.h for the threading/lifetime contract.

#include "FiredownCaptureSink.h"

#include <errno.h>
#include <unistd.h>

#include "MediaData.h"  // MediaByteBuffer
#include "nsThreadUtils.h"

namespace mozilla {
namespace dom {

// Writer thread only. Write the whole buffer, tolerating EINTR and short writes.
// Returns NS_OK or a failure (the first error latches; later writes are skipped).
static nsresult WriteAllToFd(int aFd, const uint8_t* aData, size_t aLength,
                             uint64_t* aProgress) {
  size_t offset = 0;
  while (offset < aLength) {
    ssize_t n = write(aFd, aData + offset, aLength - offset);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return NS_ERROR_FAILURE;
    }
    if (n == 0) {
      return NS_ERROR_FAILURE;
    }
    offset += static_cast<size_t>(n);
    *aProgress += static_cast<uint64_t>(n);
  }
  return NS_OK;
}

FiredownCaptureSink::FiredownCaptureSink(UniqueFileHandle aFd,
                                         const nsACString& aMimeType,
                                         DoneCallback aDone)
    : mMimeType(aMimeType), mFd(std::move(aFd)), mDone(std::move(aDone)) {
  MOZ_ASSERT(NS_IsMainThread());
  nsresult rv =
      NS_NewNamedThread("FiredownCap", getter_AddRefs(mWriterThread));
  if (NS_FAILED(rv)) {
    // Inert: Write() will no-op, Finalize() reports the error.
    mWriterThread = nullptr;
  }
}

FiredownCaptureSink::~FiredownCaptureSink() {
  // refcount == 0 here, so no write runnable is in flight (each holds a strong
  // ref). Touching mFd/mWriterThread races nothing. Normally Finalize() already
  // closed the fd and shut the thread; this is a pure safety net for a sink that
  // was somehow dropped without Finalize().
  if (mWriterThread) {
    mWriterThread->AsyncShutdown();
    mWriterThread = nullptr;
  }
  // mFd (UniqueFileHandle) auto-closes if still open.
}

void FiredownCaptureSink::Write(MediaByteBuffer* aData) {
  MOZ_ASSERT(NS_IsMainThread());
  if (mFinalized || !mWriterThread || !aData || aData->IsEmpty()) {
    return;
  }
  RefPtr<FiredownCaptureSink> self = this;
  RefPtr<MediaByteBuffer> data = aData;  // threadsafe AddRef; bytes are immutable
  nsCOMPtr<nsIRunnable> r = NS_NewRunnableFunction(
      "FiredownCaptureSink::Write",
      [self = std::move(self), data = std::move(data)]() {
        if (NS_FAILED(self->mWriteStatus) || !self->mFd) {
          return;  // a prior write failed / fd gone — error already latched
        }
        self->mWriteStatus =
            WriteAllToFd(self->mFd.get(), data->Elements(), data->Length(),
                         &self->mBytesWritten);
      });
  mWriterThread->Dispatch(r.forget(), NS_DISPATCH_NORMAL);
}

void FiredownCaptureSink::Finalize(bool aComplete) {
  MOZ_ASSERT(NS_IsMainThread());
  if (mFinalized) {
    return;
  }
  mFinalized = true;

  if (!mWriterThread) {
    // Writer thread never came up: nothing was written. Report once, here.
    if (mDone) {
      mDone(aComplete, 0, NS_ERROR_NOT_AVAILABLE);
      mDone = nullptr;
    }
    return;
  }

  RefPtr<FiredownCaptureSink> self = this;
  nsCOMPtr<nsIRunnable> r = NS_NewRunnableFunction(
      "FiredownCaptureSink::Finalize",
      [self = std::move(self), aComplete]() {
        // Serial thread: runs after every queued Write().
        self->mFd = nullptr;  // close()
        if (self->mDone) {
          self->mDone(aComplete, self->mBytesWritten, self->mWriteStatus);
          self->mDone = nullptr;
        }
      });
  mWriterThread->Dispatch(r.forget(), NS_DISPATCH_NORMAL);
  // Flushes queued events (incl. the runnable above) then exits. Non-blocking.
  mWriterThread->AsyncShutdown();
  mWriterThread = nullptr;
}

}  // namespace dom
}  // namespace mozilla
SINK_CPP_EOF
echo "[ok] 0008a wrote $SINK_CPP"

# ---------------------------------------------------------------------------
# 3) moz.build — add FiredownCaptureSink.cpp to SOURCES (kept out of
#    UNIFIED_SOURCES to avoid any unified-build symbol collisions).
# ---------------------------------------------------------------------------
python3 - "$MOZBUILD" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "FiredownCaptureSink.cpp" in s:
    print("[skip] 0008a moz.build already lists FiredownCaptureSink.cpp")
    sys.exit(0)
anchor = "UNIFIED_SOURCES += ["
if anchor not in s:
    sys.stderr.write("ERROR(0008a): 'UNIFIED_SOURCES += [' not found in moz.build "
                     "— inspect dom/media/mediasource/moz.build and update.\n")
    sys.exit(1)
ins = ('SOURCES += [\n'
       '    "FiredownCaptureSink.cpp",\n'
       ']\n\n')
s = s.replace(anchor, ins + anchor, 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008a moz.build: added SOURCES += FiredownCaptureSink.cpp")
PY

# ---------------------------------------------------------------------------
# 4) SourceBuffer.h — forward-declare the sink + add the (null-by-default) member
# ---------------------------------------------------------------------------
python3 - "$SB_H" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
changed = False

# (a) forward declaration, beside the existing mozilla::dom 'class TimeRanges;'
fwd_anchor = "class TimeRanges;"
fwd_ins = "class TimeRanges;\nclass FiredownCaptureSink;  // FIREDOWN-MSE-TAP"
if "class FiredownCaptureSink;" not in s:
    if fwd_anchor not in s:
        sys.stderr.write("ERROR(0008a): 'class TimeRanges;' forward-decl anchor "
                         "not found in SourceBuffer.h.\n")
        sys.exit(1)
    s = s.replace(fwd_anchor, fwd_ins, 1)
    changed = True

# (b) member, right after mTrackBuffersManager
mem_anchor = "  RefPtr<TrackBuffersManager> mTrackBuffersManager;"
mem_ins = (mem_anchor + "\n"
           "  // FIREDOWN-MSE-TAP: capture sink for this SourceBuffer (Magic\n"
           "  // Record). Null unless armed; set/cleared on the main thread only.\n"
           "  RefPtr<FiredownCaptureSink> mFiredownSink;")
if "mFiredownSink" not in s:
    if mem_anchor not in s:
        sys.stderr.write("ERROR(0008a): mTrackBuffersManager member anchor not "
                         "found in SourceBuffer.h.\n")
        sys.exit(1)
    s = s.replace(mem_anchor, mem_ins, 1)
    changed = True

if changed:
    open(path, "w", encoding="utf-8").write(s)
    print("[ok] 0008a SourceBuffer.h: forward-decl + mFiredownSink member")
else:
    print("[skip] 0008a SourceBuffer.h already patched")
PY

# ---------------------------------------------------------------------------
# 5) SourceBuffer.cpp — include + AppendData tap + Detach finalize + dtor net
# ---------------------------------------------------------------------------
python3 - "$SB_CPP" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()

def need(anchor, what):
    if anchor not in s:
        sys.stderr.write("ERROR(0008a): %s anchor not found in SourceBuffer.cpp.\n" % what)
        sys.exit(1)

# (a) include the sink header right after the file's own header include.
inc_anchor = '#include "SourceBuffer.h"'
need(inc_anchor, "own-header include")
if '#include "FiredownCaptureSink.h"' not in s:
    s = s.replace(inc_anchor,
                  inc_anchor + '\n#include "FiredownCaptureSink.h"  // FIREDOWN-MSE-TAP',
                  1)

# (b) the tap in AppendData — before aData.forget() hands ownership to the TBM.
tap_anchor = ('  StartUpdating();\n\n'
              '  mTrackBuffersManager->AppendData(aData.forget(), mCurrentAttributes)')
need(tap_anchor, "AppendData StartUpdating/AppendData")
tap_new = ('  StartUpdating();\n\n'
           '  // FIREDOWN-MSE-TAP: tee the just-appended segment (init or media) to the\n'
           '  // capture sink BEFORE aData.forget() moves ownership below. Cheap: AddRefs\n'
           '  // the threadsafe MediaByteBuffer and posts it to the sink\'s serial writer\n'
           '  // thread; no copy, no main-thread I/O. Inert unless armed.\n'
           '  if (mFiredownSink) {\n'
           '    mFiredownSink->Write(aData);\n'
           '  }\n\n'
           '  mTrackBuffersManager->AppendData(aData.forget(), mCurrentAttributes)')
if 'mFiredownSink->Write(aData)' not in s:
    s = s.replace(tap_anchor, tap_new, 1)

# (c) finalize in Detach() — the single teardown funnel (navigation/close/remove).
det_anchor = '  AbortBufferAppend();\n  if (mTrackBuffersManager) {'
need(det_anchor, "Detach AbortBufferAppend/if(mTrackBuffersManager)")
det_new = ('  AbortBufferAppend();\n'
           '  // FIREDOWN-MSE-TAP: single teardown funnel — removeSourceBuffer, MediaSource\n'
           '  // going away, navigation and tab close all reach Detach() before the dtor\n'
           '  // (which asserts !mMediaSource). Finalize the capture as PARTIAL; a clean\n'
           '  // end-of-stream (0008c) will have already Finalize(true)\'d and this\n'
           '  // idempotent call is then a no-op. Main thread.\n'
           '  if (mFiredownSink) {\n'
           '    mFiredownSink->Finalize(/* aComplete */ false);\n'
           '    mFiredownSink = nullptr;\n'
           '  }\n'
           '  if (mTrackBuffersManager) {')
if 'mFiredownSink->Finalize' not in s:
    s = s.replace(det_anchor, det_new, 1)

# (d) dtor safety net — guards a hypothetical destroy-without-Detach.
dtor_anchor = '  MOZ_ASSERT(!mMediaSource);\n  MSE_DEBUG("");'
need(dtor_anchor, "~SourceBuffer body")
dtor_new = ('  MOZ_ASSERT(!mMediaSource);\n'
            '  // FIREDOWN-MSE-TAP: safety net only. Detach() (implied by !mMediaSource\n'
            '  // above) is the normal finalize funnel and clears mFiredownSink, so this\n'
            '  // is a no-op in every current path; it guards a destroy-without-Detach.\n'
            '  if (mFiredownSink) {\n'
            '    mFiredownSink->Finalize(/* aComplete */ false);\n'
            '    mFiredownSink = nullptr;\n'
            '  }\n'
            '  MSE_DEBUG("");')
# only the dtor occurrence: this exact 2-line pair is unique to ~SourceBuffer.
if s.count('mFiredownSink->Finalize') < 2:
    s = s.replace(dtor_anchor, dtor_new, 1)

open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008a SourceBuffer.cpp: include + tap + Detach finalize + dtor net")
PY

echo "[ok] 0008a complete — FiredownCaptureSink + SourceBuffer tap (inert until 0008b arms it)"

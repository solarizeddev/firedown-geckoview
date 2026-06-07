#!/usr/bin/env bash
# 0008b — Magic Record, part 2: the content-side capture engine.
#
# WHAT THIS DOES
#   Adds FiredownCaptureManager (a content-process singleton) + the SourceBuffer
#   arm/finalize hooks + MediaSource register/unregister, so a capture can be
#   ARMED from C++: given a window id and a list of fds, it attaches a
#   FiredownCaptureSink (0008a) to each live SourceBuffer in that window, writes
#   the appended segments, and reports per-capture completion once every track
#   finishes. It is reachable only from C++ for now — the IPC transport that lets
#   the parent/app call Arm()/Stop() is 0008c; the clean end-of-stream signal is
#   0008c too. Until then nothing calls Arm(), so this is still inert at runtime.
#
# DEPENDS ON 0008a (FiredownCaptureSink + SourceBuffer::mFiredownSink). Fails loud
# if 0008a hasn't been applied.
#
# THREADING / LIFETIME / TEARDOWN — every case accounted for:
#   * The manager's state (mMediaSources, mCaptures) is MAIN-THREAD-ONLY. Register/
#     Unregister (from MediaSource ctor/dtor), Arm, Stop and OnTrackDone all run on
#     the content main thread => no lock.
#   * The ONLY cross-thread event is a sink finishing: its DoneCallback runs on the
#     sink's writer thread and is BOUNCED to the main thread (NS_DispatchToMainThread)
#     before it touches the manager (OnTrackDone). So aggregation is lock-free.
#   * REGISTRY pointers are weak (raw MediaSource*); MediaSource removes itself in
#     its dtor (main thread) before it dies => never dangling. All main-thread.
#   * A Capture holds STRONG refs to its SourceBuffers, so they can't vanish between
#     arm and Stop; those refs are dropped the instant the capture finishes (all
#     tracks reported), so the hold is brief and leak-free. A detached SB is inert
#     (mMediaSource/mTrackBuffersManager nulled by Detach) so holding it is harmless.
#   * NAVIGATION / TAB CLOSE / removeSourceBuffer mid-capture: SourceBuffer::Detach()
#     (0008a) finalizes each sink as PARTIAL and nulls mFiredownSink; the sink's Done
#     bounces to OnTrackDone; when all tracks report, the capture finishes and its
#     SB refs drop. No Stop() needed — teardown self-reports.
#   * Stop() (app/user): finalizes each SB's sink as partial; same aggregation path.
#     Idempotent against a concurrent Detach (sink->Finalize is idempotent; the SB
#     pointer is nulled once).
#   * CONTENT-PROCESS SHUTDOWN: ClearOnShutdown deletes the singleton; its dtor
#     finalizes any still-active captures so fds flush. The app owns its own fd
#     copies, so even a dropped final flush leaves the written bytes intact.
#   * MediaSource torn down while one of its SBs is still held by a Capture: fine —
#     Detach nulls the SB's back-ref to the MediaSource first, and the inert SB is
#     released when the capture finishes.
#   * Arm on a window with no MSE / no SourceBuffers / fewer fds than tracks: arms
#     min(tracks, fds); returns the armed mimes (EMPTY => caller reports "nothing to
#     capture"); never creates an empty Capture.
#
# KNOWN EDGE (fidelity, not safety): a SourceBuffer ADDED AFTER arm (rare — e.g. a
#   mid-stream track addition) is not retro-armed in this part; its track is simply
#   not captured. Typical players create video+audio SBs before the first append
#   (when the button wakes), so both are present at arm. Late-SB arming can be added
#   later via an OnSourceBufferAdded hook without changing this contract.
#
# Idempotent + marker-gated (FIREDOWN-MSE-CONTROL). Fail-loud anchors.
set -euo pipefail

SRC="${1:?usage: 0008b-mse-capture-manager.sh <gecko-src-root>}"
MSDIR="$SRC/dom/media/mediasource"
SB_H="$MSDIR/SourceBuffer.h"
SB_CPP="$MSDIR/SourceBuffer.cpp"
MS_CPP="$MSDIR/MediaSource.cpp"
MOZBUILD="$MSDIR/moz.build"
MGR_H="$MSDIR/FiredownCaptureManager.h"
MGR_CPP="$MSDIR/FiredownCaptureManager.cpp"
MARKER="FIREDOWN-MSE-CONTROL"

for f in "$SB_H" "$SB_CPP" "$MS_CPP" "$MOZBUILD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR(0008b): $f not found — source layout changed for this version." >&2
    exit 1
  fi
done
if ! grep -q "FIREDOWN-MSE-TAP" "$SB_CPP"; then
  echo "ERROR(0008b): 0008a (FIREDOWN-MSE-TAP) must be applied first." >&2
  exit 1
fi
if grep -q "$MARKER" "$SB_H"; then
  echo "[skip] 0008b Magic Record capture manager already applied"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) New file: FiredownCaptureManager.h
# ---------------------------------------------------------------------------
cat > "$MGR_H" <<'MGR_H_EOF'
/* -*- mode: c++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef DOM_MEDIA_MEDIASOURCE_FIREDOWNCAPTUREMANAGER_H_
#define DOM_MEDIA_MEDIASOURCE_FIREDOWNCAPTUREMANAGER_H_

// FIREDOWN-MSE-CONTROL — content-process coordinator for "Magic Record".
//
// Holds a registry of live MediaSources and the arm/stop/aggregate logic. It is
// MAIN-THREAD-ONLY; the only cross-thread input is a sink completion, which is
// bounced from the sink's writer thread to the main thread before it reaches
// OnTrackDone() — so there is no lock. Nothing here is exposed to web content; the
// arm/stop entry points are driven by the IPC transport (0008c).

#include <functional>

#include "mozilla/RefPtr.h"
#include "mozilla/UniquePtr.h"
#include "mozilla/UniquePtrExtensions.h"  // UniqueFileHandle
#include "nsError.h"                       // NS_OK / nsresult
#include "nsTArray.h"
#include "nsString.h"

namespace mozilla {
namespace dom {

class MediaSource;
class SourceBuffer;

class FiredownCaptureManager final {
 public:
  // Fired once, on the main thread, when ALL armed tracks of a capture finish.
  using FinishCallback =
      std::function<void(bool aComplete, uint64_t aBytes, nsresult aStatus)>;

  static FiredownCaptureManager& Get();          // main thread; lazily created
  static FiredownCaptureManager* GetIfExists();   // null before first use / after shutdown

  // From MediaSource ctor/dtor (main thread). Weak registration.
  void RegisterMediaSource(MediaSource* aMediaSource);
  void UnregisterMediaSource(MediaSource* aMediaSource);

  // Arm every SourceBuffer in aInnerWindowId (in order) with the matching fd,
  // taking ownership of aFds. Returns the per-track mime list — EMPTY if the
  // window has no capturable MSE (caller then reports "nothing to capture"), so
  // no empty Capture is ever created. aFinish fires once when all tracks finish.
  nsTArray<nsCString> Arm(const nsAString& aCaptureId, uint64_t aInnerWindowId,
                          nsTArray<UniqueFileHandle>&& aFds,
                          FinishCallback aFinish);

  // App/user stop: finalize the capture's tracks as partial. No-op if unknown.
  void Stop(const nsAString& aCaptureId);

  // Main thread (bounced from a sink writer thread): one armed track finished.
  void OnTrackDone(const nsAString& aCaptureId, bool aComplete, uint64_t aBytes,
                   nsresult aStatus);

  // Public so StaticAutoPtr/ClearOnShutdown can delete the singleton; nothing
  // else constructs or owns it. Finalizes any active captures (see .cpp).
  ~FiredownCaptureManager();

 private:
  struct Capture {
    nsString mId;
    uint32_t mTrackCount = 0;
    uint32_t mCompleted = 0;
    bool mAllComplete = true;
    uint64_t mBytes = 0;
    nsresult mStatus = NS_OK;
    nsTArray<RefPtr<SourceBuffer>> mSourceBuffers;  // strong; dropped on finish
    FinishCallback mFinish;
  };
  Capture* FindCapture(const nsAString& aCaptureId);
  void RemoveCapture(const nsAString& aCaptureId);

  nsTArray<MediaSource*> mMediaSources;  // weak; (un)registered by MediaSource
  nsTArray<UniquePtr<Capture>> mCaptures;
};

}  // namespace dom
}  // namespace mozilla

#endif  // DOM_MEDIA_MEDIASOURCE_FIREDOWNCAPTUREMANAGER_H_
MGR_H_EOF
echo "[ok] 0008b wrote $MGR_H"

# ---------------------------------------------------------------------------
# 2) New file: FiredownCaptureManager.cpp
# ---------------------------------------------------------------------------
cat > "$MGR_CPP" <<'MGR_CPP_EOF'
/* -*- mode: c++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// FIREDOWN-MSE-CONTROL — see FiredownCaptureManager.h for the threading contract.

#include "FiredownCaptureManager.h"

#include <algorithm>

#include "FiredownCaptureSink.h"
#include "MediaSource.h"
#include "SourceBuffer.h"
#include "SourceBufferList.h"
#include "mozilla/ClearOnShutdown.h"
#include "mozilla/StaticPtr.h"
#include "nsPIDOMWindow.h"
#include "nsThreadUtils.h"

namespace mozilla {
namespace dom {

static StaticAutoPtr<FiredownCaptureManager> sFiredownCaptureManager;

/* static */ FiredownCaptureManager& FiredownCaptureManager::Get() {
  MOZ_ASSERT(NS_IsMainThread());
  if (!sFiredownCaptureManager) {
    sFiredownCaptureManager = new FiredownCaptureManager();
    ClearOnShutdown(&sFiredownCaptureManager);
  }
  return *sFiredownCaptureManager;
}

/* static */ FiredownCaptureManager* FiredownCaptureManager::GetIfExists() {
  return sFiredownCaptureManager;
}

FiredownCaptureManager::~FiredownCaptureManager() {
  MOZ_ASSERT(NS_IsMainThread());
  // Process shutdown: finalize any still-active captures so the fds flush/close.
  // The app owns its own fd copies, so a dropped final flush still leaves the
  // written bytes intact.
  for (auto& cap : mCaptures) {
    for (auto& sb : cap->mSourceBuffers) {
      sb->FinalizeFiredownCapture(/* aComplete */ false);
    }
  }
}

void FiredownCaptureManager::RegisterMediaSource(MediaSource* aMediaSource) {
  MOZ_ASSERT(NS_IsMainThread());
  if (!mMediaSources.Contains(aMediaSource)) {
    mMediaSources.AppendElement(aMediaSource);
  }
}

void FiredownCaptureManager::UnregisterMediaSource(MediaSource* aMediaSource) {
  MOZ_ASSERT(NS_IsMainThread());
  mMediaSources.RemoveElement(aMediaSource);
}

FiredownCaptureManager::Capture* FiredownCaptureManager::FindCapture(
    const nsAString& aCaptureId) {
  MOZ_ASSERT(NS_IsMainThread());
  for (auto& cap : mCaptures) {
    if (cap->mId.Equals(aCaptureId)) {
      return cap.get();
    }
  }
  return nullptr;
}

void FiredownCaptureManager::RemoveCapture(const nsAString& aCaptureId) {
  MOZ_ASSERT(NS_IsMainThread());
  for (uint32_t i = 0; i < mCaptures.Length(); ++i) {
    if (mCaptures[i]->mId.Equals(aCaptureId)) {
      mCaptures.RemoveElementAt(i);
      return;
    }
  }
}

nsTArray<nsCString> FiredownCaptureManager::Arm(const nsAString& aCaptureId,
                                                uint64_t aInnerWindowId,
                                                nsTArray<UniqueFileHandle>&& aFds,
                                                FinishCallback aFinish) {
  MOZ_ASSERT(NS_IsMainThread());
  nsTArray<nsCString> mimes;

  // Gather every SourceBuffer in the target window, in order.
  nsTArray<RefPtr<SourceBuffer>> sbs;
  for (MediaSource* ms : mMediaSources) {
    nsPIDOMWindowInner* win = ms->GetParentObject();
    if (!win || win->WindowID() != aInnerWindowId) {
      continue;
    }
    SourceBufferList* list = ms->SourceBuffers();
    if (!list) {
      continue;
    }
    for (uint32_t i = 0; i < list->Length(); ++i) {
      bool found = false;
      SourceBuffer* sb = list->IndexedGetter(i, found);
      if (found && sb) {
        sbs.AppendElement(sb);
      }
    }
  }

  uint32_t n = std::min<uint32_t>(sbs.Length(), aFds.Length());
  if (n == 0) {
    return mimes;  // nothing capturable in this window
  }

  auto cap = MakeUnique<Capture>();
  cap->mId = aCaptureId;
  cap->mTrackCount = n;
  cap->mFinish = std::move(aFinish);

  for (uint32_t i = 0; i < n; ++i) {
    RefPtr<SourceBuffer> sb = sbs[i];

    // Per-track completion: runs on the sink's writer thread; bounce to the main
    // thread, then aggregate. Captured by value (nsString copy) so it is safe to
    // cross threads. GetIfExists() guards a completion arriving during shutdown.
    nsString idCopy(aCaptureId);
    std::function<void(bool, uint64_t, nsresult)> done =
        [idCopy](bool aComplete, uint64_t aBytes, nsresult aStatus) {
          NS_DispatchToMainThread(NS_NewRunnableFunction(
              "FiredownCaptureManager::TrackDone",
              [idCopy, aComplete, aBytes, aStatus]() {
                FiredownCaptureManager* m = FiredownCaptureManager::GetIfExists();
                if (m) {
                  m->OnTrackDone(idCopy, aComplete, aBytes, aStatus);
                }
              }));
        };

    nsCString mime;
    sb->ArmFiredownCapture(std::move(aFds[i]), std::move(done), mime);
    mimes.AppendElement(mime);
    cap->mSourceBuffers.AppendElement(sb);
  }

  mCaptures.AppendElement(std::move(cap));
  return mimes;
}

void FiredownCaptureManager::Stop(const nsAString& aCaptureId) {
  MOZ_ASSERT(NS_IsMainThread());
  Capture* cap = FindCapture(aCaptureId);
  if (!cap) {
    return;
  }
  // Finalize each track as partial. The sinks' Done callbacks bounce to
  // OnTrackDone, which removes the capture once every track reports. Idempotent
  // against a concurrent Detach (SourceBuffer::FinalizeFiredownCapture nulls the
  // sink pointer; FiredownCaptureSink::Finalize is itself idempotent).
  for (auto& sb : cap->mSourceBuffers) {
    sb->FinalizeFiredownCapture(/* aComplete */ false);
  }
}

void FiredownCaptureManager::OnTrackDone(const nsAString& aCaptureId,
                                         bool aComplete, uint64_t aBytes,
                                         nsresult aStatus) {
  MOZ_ASSERT(NS_IsMainThread());
  Capture* cap = FindCapture(aCaptureId);
  if (!cap) {
    return;  // already finished/removed (e.g. a late bounce) — ignore
  }
  cap->mCompleted++;
  cap->mBytes += aBytes;
  if (!aComplete) {
    cap->mAllComplete = false;
  }
  if (NS_FAILED(aStatus) && NS_SUCCEEDED(cap->mStatus)) {
    cap->mStatus = aStatus;
  }
  if (cap->mCompleted < cap->mTrackCount) {
    return;
  }

  // All tracks done. Snapshot, remove (drops SB refs), THEN fire — so a
  // re-entrant call from aFinish can't observe a half-removed capture.
  FinishCallback finish = std::move(cap->mFinish);
  bool complete = cap->mAllComplete;
  uint64_t bytes = cap->mBytes;
  nsresult status = cap->mStatus;
  RemoveCapture(aCaptureId);
  if (finish) {
    finish(complete, bytes, status);
  }
}

}  // namespace dom
}  // namespace mozilla
MGR_CPP_EOF
echo "[ok] 0008b wrote $MGR_CPP"

# ---------------------------------------------------------------------------
# 3) moz.build — add FiredownCaptureManager.cpp beside FiredownCaptureSink.cpp
# ---------------------------------------------------------------------------
python3 - "$MOZBUILD" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "FiredownCaptureManager.cpp" in s:
    print("[skip] 0008b moz.build already lists FiredownCaptureManager.cpp")
    sys.exit(0)
anchor = '    "FiredownCaptureSink.cpp",'
if anchor not in s:
    sys.stderr.write("ERROR(0008b): FiredownCaptureSink.cpp SOURCES line (from 0008a) "
                     "not found in moz.build.\n")
    sys.exit(1)
s = s.replace(anchor, anchor + '\n    "FiredownCaptureManager.cpp",', 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008b moz.build: added FiredownCaptureManager.cpp")
PY

# ---------------------------------------------------------------------------
# 4) SourceBuffer.h — friend + arm/finalize/mime method declarations (private).
#    Anchored on the mFiredownSink member that 0008a inserted.
# ---------------------------------------------------------------------------
python3 - "$SB_H" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
changed = False

# forward declaration of the manager, beside 0008a's sink forward-decl.
fwd_anchor = "class FiredownCaptureSink;  // FIREDOWN-MSE-TAP"
if "class FiredownCaptureManager;" not in s:
    if fwd_anchor not in s:
        sys.stderr.write("ERROR(0008b): 0008a sink forward-decl anchor not found in "
                         "SourceBuffer.h.\n")
        sys.exit(1)
    s = s.replace(fwd_anchor,
                  fwd_anchor + "\nclass FiredownCaptureManager;  // FIREDOWN-MSE-CONTROL",
                  1)
    changed = True

# friend + method decls, right after 0008a's mFiredownSink member.
mem_anchor = "  RefPtr<FiredownCaptureSink> mFiredownSink;"
add = (mem_anchor + "\n"
       "  // FIREDOWN-MSE-CONTROL: arm/finalize driven by FiredownCaptureManager.\n"
       "  // Private; the manager is a friend. Main-thread only.\n"
       "  friend class FiredownCaptureManager;\n"
       "  void ArmFiredownCapture(UniqueFileHandle&& aFd,\n"
       "                          std::function<void(bool, uint64_t, nsresult)> aDone,\n"
       "                          nsACString& aOutMimeType);\n"
       "  void FinalizeFiredownCapture(bool aComplete);")
if "ArmFiredownCapture" not in s:
    if mem_anchor not in s:
        sys.stderr.write("ERROR(0008b): mFiredownSink member (from 0008a) not found in "
                         "SourceBuffer.h.\n")
        sys.exit(1)
    s = s.replace(mem_anchor, add, 1)
    changed = True

# ensure the includes the new signatures need are present.
for inc in ['#include <functional>',
            '#include "mozilla/UniquePtrExtensions.h"']:
    if inc not in s:
        # add after 0008a's include is risky (0008a edited the .cpp, not the .h);
        # anchor on the include guard's first existing include instead: place at
        # the top of the include block, before the first '#include "'.
        first = s.find('#include "')
        if first == -1:
            sys.stderr.write("ERROR(0008b): no #include block found in SourceBuffer.h "
                             "to add %s.\n" % inc)
            sys.exit(1)
        s = s[:first] + inc + "\n" + s[first:]
        changed = True

if changed:
    open(path, "w", encoding="utf-8").write(s)
    print("[ok] 0008b SourceBuffer.h: friend + arm/finalize decls + includes")
else:
    print("[skip] 0008b SourceBuffer.h already patched")
PY

# ---------------------------------------------------------------------------
# 5) SourceBuffer.cpp — implement Arm/Finalize/mime, before ~SourceBuffer().
# ---------------------------------------------------------------------------
python3 - "$SB_CPP" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
if "SourceBuffer::ArmFiredownCapture" in s:
    print("[skip] 0008b SourceBuffer.cpp already has the methods")
    sys.exit(0)
anchor = "SourceBuffer::~SourceBuffer() {"
if anchor not in s:
    sys.stderr.write("ERROR(0008b): ~SourceBuffer anchor not found in SourceBuffer.cpp.\n")
    sys.exit(1)
impl = (
'// FIREDOWN-MSE-CONTROL: arm/finalize, called only by FiredownCaptureManager on\n'
'// the main thread. Constructs the sink with THIS SourceBuffer\'s container type so\n'
'// mType stays encapsulated.\n'
'void SourceBuffer::ArmFiredownCapture(\n'
'    UniqueFileHandle&& aFd, std::function<void(bool, uint64_t, nsresult)> aDone,\n'
'    nsACString& aOutMimeType) {\n'
'  MOZ_ASSERT(NS_IsMainThread());\n'
'  aOutMimeType = mType.OriginalString();\n'
'  // Replace any prior sink (should not happen for a fresh arm); finalize it.\n'
'  if (mFiredownSink) {\n'
'    mFiredownSink->Finalize(/* aComplete */ false);\n'
'    mFiredownSink = nullptr;\n'
'  }\n'
'  mFiredownSink = new FiredownCaptureSink(std::move(aFd), aOutMimeType,\n'
'                                          std::move(aDone));\n'
'}\n'
'\n'
'void SourceBuffer::FinalizeFiredownCapture(bool aComplete) {\n'
'  MOZ_ASSERT(NS_IsMainThread());\n'
'  if (mFiredownSink) {\n'
'    mFiredownSink->Finalize(aComplete);\n'
'    mFiredownSink = nullptr;\n'
'  }\n'
'}\n'
'\n')
s = s.replace(anchor, impl + anchor, 1)
open(path, "w", encoding="utf-8").write(s)
print("[ok] 0008b SourceBuffer.cpp: ArmFiredownCapture + FinalizeFiredownCapture")
PY

# ---------------------------------------------------------------------------
# 6) MediaSource.cpp — register in ctor, unregister in dtor.
# ---------------------------------------------------------------------------
python3 - "$MS_CPP" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
changed = False

inc_anchor = '#include "MediaSource.h"'
if '#include "FiredownCaptureManager.h"' not in s:
    if inc_anchor not in s:
        sys.stderr.write("ERROR(0008b): '#include \"MediaSource.h\"' not found in "
                         "MediaSource.cpp — confirm the own-header include line.\n")
        sys.exit(1)
    s = s.replace(inc_anchor,
                  inc_anchor + '\n#include "FiredownCaptureManager.h"  // FIREDOWN-MSE-CONTROL',
                  1)
    changed = True

# register at the top of the ctor body (the ctor opens with this assert).
ctor_anchor = ("    mReadyState(MediaSourceReadyState::Closed) {\n"
               "  MOZ_ASSERT(NS_IsMainThread());")
if "RegisterMediaSource(this)" not in s:
    if ctor_anchor not in s:
        sys.stderr.write("ERROR(0008b): MediaSource ctor body anchor not found.\n")
        sys.exit(1)
    s = s.replace(ctor_anchor,
                  ctor_anchor +
                  "\n  // FIREDOWN-MSE-CONTROL: make this MediaSource discoverable for capture.\n"
                  "  FiredownCaptureManager::Get().RegisterMediaSource(this);",
                  1)
    changed = True

# unregister at the top of the dtor body.
dtor_anchor = ('MediaSource::~MediaSource() {\n'
               '  MOZ_ASSERT(NS_IsMainThread());\n'
               '  MSE_API("");')
if "UnregisterMediaSource(this)" not in s:
    if dtor_anchor not in s:
        sys.stderr.write("ERROR(0008b): MediaSource dtor body anchor not found.\n")
        sys.exit(1)
    s = s.replace(dtor_anchor,
                  dtor_anchor +
                  "\n  // FIREDOWN-MSE-CONTROL: drop from the capture registry. GetIfExists so\n"
                  "  // we don't resurrect the singleton during shutdown teardown.\n"
                  "  if (FiredownCaptureManager* m = FiredownCaptureManager::GetIfExists()) {\n"
                  "    m->UnregisterMediaSource(this);\n"
                  "  }",
                  1)
    changed = True

if changed:
    open(path, "w", encoding="utf-8").write(s)
    print("[ok] 0008b MediaSource.cpp: register/unregister + include")
else:
    print("[skip] 0008b MediaSource.cpp already patched")
PY

echo "[ok] 0008b complete — FiredownCaptureManager + SourceBuffer arm/finalize + MediaSource registry (armable from C++; IPC transport is 0008c)"

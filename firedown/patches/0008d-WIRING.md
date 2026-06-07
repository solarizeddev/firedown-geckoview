# 0008d-WIRING — GeckoView Java/JNI + app integration (apply on the tree)

This is the last GeckoView-side piece: get the app's request (a `GeckoSession` + a
list of `ParcelFileDescriptor`s) down to `ContentParent::SendFiredownCaptureArm`
(0008c), and route completion back up to the app. It is **all GeckoView-layer Java
+ generated JNI + the session→content-process resolution** — APIs I can't verify or
compile blind — so it's a guide, like `0008c-WIRING.md`. The content-side engine it
drives (0008a/0008b/0008c-bridge/0008e) is real and verified.

**Why the fd path is JNI, not EventDispatcher:** GeckoView's `EventDispatcher`
carries `GeckoBundle` (JSON-like) and **cannot transfer a file descriptor**. So the
*arm* (which carries fds) must go through a `@WrapForJNI` native call; only the
*completion* (plain data) can ride `EventDispatcher`.

---

## A. Native entry — resolve session → (ContentParent, innerWindowId) → SendArm

Add a `@WrapForJNI` native method reachable from the session's native object
(GeckoView's `nsWindow` / the GeckoSession `Window` native peer — confirm the exact
class on the tree; this is the part most likely to differ).

```cpp
// Pseudocode for the native side. Parent process, main thread.
// aFds: raw POSIX fds the app detached from its ParcelFileDescriptors.
void nsWindow::StartFiredownCapture(const nsString& aCaptureId,
                                    const nsTArray<int32_t>& aFds) {
  RefPtr<CanonicalBrowsingContext> bc = /* this session's top-level CBC */;
  if (!bc) return;
  RefPtr<WindowGlobalParent> wgp = bc->GetCurrentWindowGlobal();
  if (!wgp) return;
  ContentParent* cp = wgp->GetContentParent();   // null => same-process; see note
  uint64_t innerWindowId = wgp->InnerWindowId();

  nsTArray<mozilla::ipc::FileDescriptor> fds;
  fds.SetCapacity(aFds.Length());
  for (int32_t fd : aFds) {
    // Take ownership of the (already-open) fd the app handed us.
    fds.AppendElement(mozilla::ipc::FileDescriptor(UniqueFileHandle(fd)));
  }

  if (cp) {
    cp->SendFiredownCaptureArm(aCaptureId, innerWindowId, std::move(fds));
  } else {
    // Single-process / parent-hosted document: call the manager directly with
    // UniqueFileHandles (no IPC). Mirror ContentChild::RecvFiredownCaptureArm.
  }
}
```

Notes / flags:
- **The session→CanonicalBrowsingContext step** is the GeckoView-internal unknown.
  GeckoView exposes the top-level `BrowsingContext` per session; from Java this is
  reachable, and natively via the window peer. Confirm the exact accessor.
- **iframe players:** `GetCurrentWindowGlobal()` on the top-level CBC targets the
  top document. If the `<video>`/MSE lives in a subframe, walk to the subframe's
  WindowGlobalParent (or, simpler for v1, target top-level and accept that
  cross-origin-iframe players aren't captured yet).
- **`GetContentParent()` null** = the document is in the parent process (rare in
  GeckoView, but handle it by calling the manager directly).

`SendFiredownCaptureArm` / `SendFiredownCaptureComplete` are generated from the
`PContent.ipdl` messages in `0008c-WIRING.md`; confirm their arg types against the
generated `PContentParent.h`.

---

## B. Completion listener (native, registered once at runtime init)

```cpp
// At GeckoRuntime/GeckoView startup, parent process, main thread:
FiredownCaptureManager::Get().SetCompletionListener(
    [](const nsAString& aCaptureId, bool aComplete, uint64_t aBytes,
       nsresult aStatus) {
      // Dispatch to the app via the runtime EventDispatcher (plain data, no fd):
      //   "Firedown:Capture:Complete" { captureId, complete, bytes, status }
    });
```

`NotifyCompletion` (0008c bridge) invokes this on the parent main thread when a
child reports `FiredownCaptureComplete`.

---

## C. GeckoView Java surface

```java
// GeckoSession (or a small runtime helper).
public void startMediaCapture(@NonNull String captureId,
                              @NonNull ParcelFileDescriptor[] outputs) {
  int[] fds = new int[outputs.length];
  for (int i = 0; i < outputs.length; i++) {
    fds[i] = outputs[i].detachFd();   // ownership moves to native; app keeps its own dup
  }
  // @WrapForJNI native call on the session's window peer:
  mWindow.startFiredownCapture(captureId, fds);
}

public void stopMediaCapture(@NonNull String captureId) {
  mWindow.stopFiredownCapture(captureId);   // -> ContentParent::SendFiredownCaptureStop
}
```

Completion arrives as a runtime `EventDispatcher` event `Firedown:Capture:Complete`
(captureId, complete, bytes, status), which the app listens for. (A typed
`MediaCaptureDelegate` is the alternative; EventDispatcher keeps the public API
surface untouched — decision D2.)

**fd ownership:** `detachFd()` transfers the fd to native (which closes it after the
capture). The app must keep its **own** dup/handle of each output file (open the
file twice, or `dup()` before detaching) so it can finalize/mux the partial even if
the content process dies — this is the "app owns the fd" invariant the whole design
relies on.

---

## D. App integration (`firedown` repo) — see also the 0008 SPEC §5

| concern | where |
|---|---|
| Register the `Firedown:Capture:Complete` listener | once, at runtime init (`GeckoRuntimeHelper`). |
| Attach per-session capture UI | `GeckoComponents.connectSession(...)`; **foreground-gate** UI with `isCurrentGeckoState`, but never gate the capture itself. |
| Magic button (refresh slot) state machine | toolbar / `BrowserOptionFragment` — wake on the existing media-playing signal (see availability note below); on tap, open output files + `startMediaCapture`. |
| Active captures | `Map<captureId, CaptureSession>` (the app's PFD dups + window + start time). Reuse `cancelTab`/`onRemoved` to finalize the partial if the tab closes with no completion. **Do not** route through `PriorityTaskThreadPoolExecutor`. |
| On `Firedown:Capture:Complete` | the two output files = a **separate-audio pair** → build the entity `GeckoInspectTask` makes for Bilibili DASH → `DownloadTask.selectStrategy` → `FFmpegMergeStrategy` → SAF/`DocumentFile`. |
| Logging | debug-gated (release silent). |

---

## E. Availability auto-detect (DEFERRED — optional refinement)

Waking the button precisely on "a DRM-free MSE video exists here" needs a
**child→parent** signal, because only the content process sees the MediaSource. v1
does **not** need it: the app already knows when media is playing (the media
session / `MEDIA_PLAY`), so it can wake the Magic button on that and find out on
arm — if the window has no MSE, `Arm` returns no tracks and the transport reports
the empty-window completion immediately (0008c-WIRING §C), and the app shows
"can't record this one".

If you later want precise auto-wake, add (content-side, then a wiring entry):
1. a hook in `SourceBuffer::AppendData` / `MediaSource` first-append that calls a
   new `FiredownCaptureManager` method once per MediaSource;
2. a `child:`→`parent:` `FiredownCaptureAvailable(uint64_t innerWindowId)` PContent
   message + `ContentParent` recv → a second `FiredownCaptureManager` parent-side
   listener → `EventDispatcher` `Firedown:Capture:Available`.
Keep it **debounced/once-per-MediaSource** so a chatty player doesn't spam events.

---

## F. End-to-end flow (with everything wired)
```
app: open 2 cache files (keep own dups) ─► GeckoSession.startMediaCapture(id, pfds)
  └─ JNI ─► nsWindow::StartFiredownCapture ─► CBC→WGP→(ContentParent, innerWindowId)
       └─ SendFiredownCaptureArm ─► ContentChild::RecvFiredownCaptureArm
            └─ FiredownCaptureManager::Arm ─► SourceBuffer::ArmFiredownCapture (per SB)
                 └─ FiredownCaptureSink writes appended segments to the fds  (0008a)
... user watches ...
  • video ends:  MediaSource::EndOfStream ─► FinalizeMediaSourceComplete(true)  (0008e)
  • tab closes:  SourceBuffer::Detach ─► Finalize(false) partial                (0008a)
       └─ per-track done ─► OnTrackDone ─► (all tracks) capDone
            └─ ContentChild::SendFiredownCaptureComplete ─► ContentParent::Recv…
                 └─ FiredownCaptureManager::NotifyCompletion ─► EventDispatcher
                      └─ app: 2 files ─► FFmpegMergeStrategy ─► Downloads
```

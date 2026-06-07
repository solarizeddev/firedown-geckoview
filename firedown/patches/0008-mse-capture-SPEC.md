# 0008 — Magic Record (MSE source-quality capture) — SPEC / design-of-record

Status: **0008a SHIPPED (inert); 0008b/0008c DESIGNED.** This is the authoritative
design for the "Magic Record" capture, spanning the GeckoView patch set
(`firedown-geckoview`) and the app wiring (`firedown`). It supersedes the earlier
A-vs-B hedge — the sink design is now decided (see §2/§9).

---

## 1. Goal & scope

**Goal:** let the user save the DRM-free video they're watching, at **source
quality**, by teeing the media segments the page feeds `<video>` straight to files
the app owns, then muxing with the **existing** `FFmpegMergeStrategy`.

**In scope:** MSE / `blob:`-backed `<video>` whose segments arrive via
`SourceBuffer.appendBuffer` — virtually every adaptive HTML5 player (non-DRM).
Works regardless of how the page *obtained* the bytes (network, ServiceWorker,
JS-assembled, single-use/signed URL), because the tap is *after* the page holds them.

**Out of scope (by construction):**
- **DRM/EME.** At the tap the bytes are **ciphertext** (CENC); on hardware (Widevine
  L1) decoded frames never exist in software-readable memory. Cleartext-only by
  design. Firedown ships DRM-off (`media.eme.enabled=false`) — no DRM stream to tap.
- **Decoded-frame / screen-record capture** (canvas/WebGL/`<video>` with no MSE) —
  would need `captureStream()`+`MediaRecorder` (re-encode). A separate later feature.
- **Non-MSE `blob:`** (Blob from a fetched ArrayBuffer) — different mechanism
  (`BlobURLProtocolHandler`); not covered here.

---

## 2. Architecture — heavy path vs control path

The win over a JS `appendBuffer` hook is that **the bytes never touch JS or Java**.
Two independent channels:

```
  ┌─ DATA (heavy, native only) ──────────────────────────────────────────────┐
  │  SourceBuffer::AppendData(MediaByteBuffer)   [content process, main thread]│
  │       │  tee (AddRef, no copy) → FiredownCaptureSink                        │
  │       ▼  serial writer thread                                              │
  │     write()  ──►  fd the APP opened (passed down once)  ──►  *.video/*.audio│
  └────────────────────────────────────────────────────────────────────────────┘

  ┌─ CONTROL (light) ────────────────────────────────────────────────────────┐
  │  app ── startMediaCapture(window, captureId, fds[]) ──► parent ──IPDL──► child│
  │  child: arm sinks on the window's live SourceBuffers                       │
  │  app ◄── EventDispatcher: onCaptureAvailable / onCaptureComplete / onError │
  └────────────────────────────────────────────────────────────────────────────┘
```

**Sink design — DECIDED: Option B (fd into content).** A custom IPDL protocol is
required either way (MSE is content-process-only; nothing parent-side holds the
appended bytes). Given that, B sends **one fd at arm + tiny metadata**, and the
content writer writes locally — vs Option A which would ship **every segment** over
IPC. B's only "extra" is passing a writable fd into the sandbox, which is standard
(`write()` on a passed fd is allowed; we do **not** broaden the sandbox broker). So B
is lighter at runtime for ~the same code, and keeps the security posture intact.

**Process model that makes it cheap:** GeckoView's **parent process *is* the app
process**; only content processes are sandboxed children. So the app handing GeckoView
a `ParcelFileDescriptor` is a normal in-process Java call — the app never does IPC.

**Mux:** a video file + an audio file is a **separate-audio variant pair** — the shape
`GeckoInspectTask` already builds for Bilibili DASH → `FFmpegMergeStrategy`, unchanged.
A single muxed SourceBuffer → one file → existing single-file path.

---

## 3. The GeckoView patches (`firedown-geckoview`)

Same conventions as 0001–0007: idempotent, **marker-gated**, anchored, **fail loud**.
This is the heaviest patch in the set — the first to add a new data channel — so it is
split into three independently-reviewable parts.

### 3.1 `0008a` — sink + tap  ✅ SHIPPED (inert)
`firedown/patches/0008a-mse-capture-sink-and-tap.sh`. Marker `FIREDOWN-MSE-TAP`.

- New `dom/media/mediasource/FiredownCaptureSink.{h,cpp}` — the content-process
  write-end: a dedicated **serial writer thread**, `Write()` (main-thread, AddRef +
  dispatch, no copy), idempotent `Finalize(bool aComplete)`, `UniqueFileHandle` fd,
  a `DoneCallback(complete, bytes, status)` (null for now; 0008b supplies it).
- Tap in `SourceBuffer::AppendData`, **before** `aData.forget()`, gated on a new
  null-by-default `RefPtr<FiredownCaptureSink> mFiredownSink` member.
- `Detach()` (the single teardown funnel — dtor asserts `!mMediaSource`) and the dtor
  finalize the sink as **partial**.
- Verified vs FF151 source: `MediaByteBuffer` is `THREADSAFE_REFCOUNTING`; the exact
  AppendData/Detach/dtor/member anchors. **Inert until 0008b constructs a sink.**

### 3.2 `0008b` — control, transport, registry, app bridge  (NEXT)
Marker `FIREDOWN-MSE-CONTROL`. Pieces:

1. **`PFiredownCapture` IPDL** (managed by `PContent`; parent endpoint in the app
   process, child in content). Messages:
   - parent→child: `Arm(nsString captureId, uint64_t innerWindowId, nsTArray<FileDescriptor> fds, nsTArray<nsCString> mimeHints)`, `Stop(captureId)`.
   - child→parent: `Available(captureId, nsTArray<TrackInfo>)`, `Complete(captureId, bool complete, nsTArray<uint64_t> bytes, nsTArray<nsresult> status)`, `Error(captureId, nsresult)`.
2. **MediaSource registry** — the wrinkle: Arm must reach the **already-live**
   SourceBuffers (the button glows on first append, so by tap-time they exist).
   `MediaSource` (un)registers itself in a per-process map keyed by **inner-window id**
   (ctor/dtor hook). Arm looks up the window's `MediaSource`, walks its
   `SourceBufferList`, and `SetFiredownSink()`s a sink (with the matching fd +
   `mType`) on each. Reports the per-SB mime back via `Available`.
3. **App bridge — EventDispatcher** (DECISION D2: no public `GeckoSession` API churn).
   Parent actor relays `Available/Complete/Error` to `Firedown:Capture:*` events;
   `startMediaCapture(window, captureId, List<ParcelFileDescriptor>)` is a plain Java
   call into a runtime helper that opens the actor and sends `Arm` (the PFD → IPDL
   `FileDescriptor` is internal; the app just passes the PFD, same process).
4. Wire the sink's `DoneCallback` → the child actor → `Complete`.

### 3.3 `0008c` — clean-completion signal
Marker `FIREDOWN-MSE-FINALIZE`. `MediaSource::EndOfStream()` (player declares the
stream fully buffered) → `Finalize(true)` on every armed SourceBuffer in that
MediaSource → app sees **complete** (vs the **partial** that Detach/teardown emits).
Idempotent with 0008a's Detach finalize (first Finalize wins).

---

## 4. App-facing surface (EventDispatcher; `firedown`)

```
runtimeHelper.startMediaCapture(window, captureId, List<ParcelFileDescriptor> perSB);
runtimeHelper.stopMediaCapture(window, captureId);

onCaptureAvailable(window, captureId, List<TrackInfo>)         // a DRM-free MSE video exists
onCaptureComplete (window, captureId, boolean complete, List<TrackResult>) // files + bytes
onCaptureError    (window, captureId, int code)
```

`onCaptureAvailable` fires on the **first MSE append** of a DRM-free `<video>` (≈
playback start) — the signal that wakes the toolbar Magic button.

---

## 5. Firedown integration (`firedown`)

Only *new* app code is small; everything downstream is reused.

| concern | where |
|---|---|
| Attach the capture listener per session | `GeckoComponents.connectSession(...)`. UI reactions **foreground-gated** with `isCurrentGeckoState(geckoState)`; the byte sink itself is **not** gated (background capture must continue). |
| Magic button state machine | toolbar / `BrowserOptionFragment` (the refresh slot — see §6). |
| Active captures | a `Map<captureId, CaptureSession>` (PFDs + window + start time). **NOT** routed through `PriorityTaskThreadPoolExecutor` (that's queued probe tasks; a capture is a live sink) — but reuse its `cancelTab`/`onRemoved` hook to finalize on close. |
| Finalize on tab close | if a capture is active for the closing tab and no `onCaptureComplete` arrived, close the app's own fd and finalize the partial. |
| Build the entity | on complete: video file + audio file ⇒ **separate-audio pair**, as `GeckoInspectTask` makes for Bilibili DASH. |
| Mux + save | `DownloadTask.selectStrategy` ⇒ `FFmpegMergeStrategy` ⇒ SAF/`DocumentFile`. Unchanged. |
| Logging | all debug-gated (release silent). |

---

## 6. Button / UX state machine (the refresh slot)

The Magic button **is the GeckoToolbar refresh slot** — normal refresh `↻` by
default, morphs to the Magic mark when a capturable video is detected, red recording
state while capturing. (See `firedown-magic-capture-flow.html`.)

| state | when | UI |
|---|---|---|
| Inert | no MSE `<video>` | plain refresh ↻ |
| Available | `onCaptureAvailable` (≈ playback start) | refresh → pulsing coral Magic mark; first-run coachmark |
| Recording | user tapped arm | solid-coral recording state + live card (time·size·Stop); first-run "recording from here" hint |
| Background | switched tab while recording | coral chip "Recording — <host>"; continues |
| New video | a new MediaSource mid-record | prompt: keep current / record new; current finalizes |
| Forced finalize | tab closed / navigated mid-record | toast "Saved what was recorded (0:42)" (partial) |
| Trim → Saving → Done | Stop → mux → Captured/Downloads | filmstrip trim → progress → list row |

---

## 7. Lifecycle matrix (authoritative)

| event | Gecko side | App side | File result |
|---|---|---|---|
| `endOfStream()` | 0008c → Finalize **complete** | mux | whole video (if fully buffered) |
| element ended / removed | Detach → finalize | mux | up to end of playback |
| **tab closed** | Detach finalizes (clean) | `cancelTab` finalizes (crash-safe — app owns fd) | **partial, playable** to last full fragment |
| **navigation (same tab)** | old doc destroyed ⇒ Detach finalize | new doc ⇒ fresh `onCaptureAvailable`; default **no** auto-arm | old clip saved |
| **SPA new video, new MediaSource** | old MS unregisters ⇒ finalize | new `onCaptureAvailable` | old saved; new offered |
| **SPA new video, SAME MediaSource reused** | ambiguous | app-level stop/start on URL/title change — **never** infer from bytes (init-segment also changes on ABR) | per user action |
| **different tab records** | per-SB/per-doc, independent fds | concurrent `Map` entries; cap concurrency | isolated, no cross-talk |
| **background tab / app backgrounded playing** | tap keeps firing; sink keeps writing | UI button foreground-gated only | continues |
| **content-process crash/kill** | — | app owns fd; bytes on disk | partial recoverable |
| **app killed** | both processes die | orphan partial in cache; offer recovery next launch | partial recoverable |

---

## 8. Concurrency / leak / safety accounting (the 0008a core)

All hazard lives in `FiredownCaptureSink`; verified against FF151 source:
- `MediaByteBuffer` is `NS_INLINE_DECL_THREADSAFE_REFCOUNTING` → AddRef-on-main /
  read+Release-on-writer is race-free.
- `SourceBuffer` + `mFiredownSink` are **main-thread-only** → no lock on the pointer.
- **Serial** writer thread → segment order preserved AND fd closed strictly after every
  queued write (no closed/recycled-fd race).
- Leaks: write runnables hold a strong sink ref; fd is `UniqueFileHandle` (closed in
  finalize / auto-closed at refcount-0 dtor); writer thread `AsyncShutdown()`'d.
- No main-thread I/O (Write only AddRef+dispatch).
- Errors latch in `mWriteStatus`, later writes skip, reported at finalize; never crash.
- **Content edge (not safety):** `abort()`/`remove()`/`changeType()` mid-capture can
  leave a fragment seam; ffmpeg muxes up to the last good fragment.

---

## 9. Resolved decisions / still open

- **D1 sink design:** ✅ **Option B** (fd into content). See §2.
- **D2 app surface:** ✅ **EventDispatcher** side-channel (no public `GeckoSession`
  API churn; Firedown owns both ends).
- **D3 auto-arm on detect?** OPEN. v1 = **tap-to-arm** (misses pre-tap); a rolling
  buffer from detect (captures the whole video but always writes while any capturable
  video plays — storage/CPU) is an opt-in later.
- **D4 concurrency cap** (N simultaneous captures) — OPEN, policy.
- **D5 orphan-recovery** on next launch — OPEN, nice-to-have.

---

## 10. Verification plan

- `0008a/b/c` apply cleanly + idempotent against `FIREFOX_151_0_RELEASE`
  (`./build.sh patch` → `[ok]`, re-run `[skip]`); anchors fail loud on a mutated source.
- On-device: a non-DRM MSE site → Magic mark on play → record → stop → two files →
  `FFmpegMergeStrategy` → playable MP4 in Downloads.
- Lifecycle: close tab mid-record ⇒ partial MP4 still plays; switch tabs ⇒ continues;
  DRM site ⇒ button never wakes (expected).
- Release build: silent (no unconditional logs).

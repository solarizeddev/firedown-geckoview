# 0008c-WIRING — the central-file IPC half (apply by hand on the tree)

The companion `0008c-mse-capture-ipc.sh` did the verifiable half (the parent-side
completion bridge on `FiredownCaptureManager` + `EXPORTS`). This file is the other
half: three `PContent` messages + their recv handlers. These edits touch huge,
central, version-sensitive files I could **not** anchor-verify or compile, so they
are written as exact insertions to apply manually (or paste me the relevant file
sections and I'll emit anchored edits).

**Confidence flags (the parts most likely to need a tweak):**
1. **IPDL recv-handler parameter ref-style** — `const T&` vs `T&&` vs by-value is
   codegen-determined for this Firefox version. If the build says *"`RecvX` does not
   override a pure-virtual"*, copy the exact signature from the generated
   `PContentChild.h` / `PContentParent.h` in the objdir.
2. **`FileDescriptor` in `PContent.ipdl`** — if IPDL errors *"FileDescriptor
   undefined"*, add near the other `using` lines:
   `using mozilla::ipc::FileDescriptor from "mozilla/ipc/FileDescriptor.h";`
   (PContent almost certainly already imports it — it passes fds elsewhere.)
3. **Section placement** — put the parent→child messages under a `child:` section
   and the child→parent message under a `parent:` section (any existing one).

---

## A. `dom/ipc/PContent.ipdl`

Under a **`child:`** section (parent → content):
```
    // FIREDOWN-MSE-IPC: arm/stop Magic Record capture in a content window.
    async FiredownCaptureArm(nsString captureId, uint64_t innerWindowId,
                             FileDescriptor[] fds);
    async FiredownCaptureStop(nsString captureId);
```

Under a **`parent:`** section (content → parent):
```
    // FIREDOWN-MSE-IPC: a Magic Record capture finished (all tracks).
    async FiredownCaptureComplete(nsString captureId, bool complete,
                                  uint64_t bytes, nsresult status);
```

---

## B. `dom/ipc/ContentChild.h`

Add includes near the top (with the other dom includes):
```cpp
#include "mozilla/dom/FiredownCaptureManager.h"  // FIREDOWN-MSE-IPC
#include "mozilla/ipc/FileDescriptor.h"
```

Declare the recv handlers (beside the other `Recv*` declarations). **Match the
generated ref-style** (see flag 1):
```cpp
  mozilla::ipc::IPCResult RecvFiredownCaptureArm(
      const nsString& aCaptureId, const uint64_t& aInnerWindowId,
      nsTArray<mozilla::ipc::FileDescriptor>&& aFds);
  mozilla::ipc::IPCResult RecvFiredownCaptureStop(const nsString& aCaptureId);
```

---

## C. `dom/ipc/ContentChild.cpp`

```cpp
mozilla::ipc::IPCResult ContentChild::RecvFiredownCaptureArm(
    const nsString& aCaptureId, const uint64_t& aInnerWindowId,
    nsTArray<mozilla::ipc::FileDescriptor>&& aFds) {
  // Content process, main thread. Convert the passed fds to owned handles and
  // arm the window's SourceBuffers. The finish callback (fires once all tracks
  // flush) sends completion back up; ContentChild::GetSingleton() is null-checked
  // because completion can land during process shutdown.
  nsTArray<UniqueFileHandle> handles;
  handles.SetCapacity(aFds.Length());
  for (auto& fd : aFds) {
    handles.AppendElement(fd.ClonePlatformHandle());
  }

  nsString id(aCaptureId);
  nsTArray<nsCString> mimes = FiredownCaptureManager::Get().Arm(
      id, aInnerWindowId, std::move(handles),
      [id](bool aComplete, uint64_t aBytes, nsresult aStatus) {
        if (ContentChild* cc = ContentChild::GetSingleton()) {
          cc->SendFiredownCaptureComplete(id, aComplete, aBytes, aStatus);
        }
      });

  // Nothing capturable in this window (no MSE / no SourceBuffers): no Capture was
  // created and the finish callback will never fire, so report now — otherwise the
  // app waits forever for completion.
  if (mimes.IsEmpty()) {
    SendFiredownCaptureComplete(id, /* complete */ false, /* bytes */ 0,
                                NS_ERROR_NOT_AVAILABLE);
  }
  return IPC_OK();
}

mozilla::ipc::IPCResult ContentChild::RecvFiredownCaptureStop(
    const nsString& aCaptureId) {
  FiredownCaptureManager::Get().Stop(aCaptureId);
  return IPC_OK();
}
```

---

## D. `dom/ipc/ContentParent.h`

Add the include and the recv declaration:
```cpp
#include "mozilla/dom/FiredownCaptureManager.h"  // FIREDOWN-MSE-IPC
```
```cpp
  mozilla::ipc::IPCResult RecvFiredownCaptureComplete(
      const nsString& aCaptureId, const bool& aComplete, const uint64_t& aBytes,
      const nsresult& aStatus);
```

## E. `dom/ipc/ContentParent.cpp`

```cpp
mozilla::ipc::IPCResult ContentParent::RecvFiredownCaptureComplete(
    const nsString& aCaptureId, const bool& aComplete, const uint64_t& aBytes,
    const nsresult& aStatus) {
  // Parent process, main thread. Hand off to the GeckoView listener (0008d).
  FiredownCaptureManager::Get().NotifyCompletion(aCaptureId, aComplete, aBytes,
                                                 aStatus);
  return IPC_OK();
}
```

---

## F. Sending the Arm (parent side — used by 0008d)

0008d (GeckoView Java/JNI) resolves a `GeckoSession` to its
`CanonicalBrowsingContext` → current `WindowGlobalParent` →
(`ContentParent*`, `InnerWindowId()`), opens the app's output files as
`ParcelFileDescriptor`s, converts each to `mozilla::ipc::FileDescriptor`, then:
```cpp
contentParent->SendFiredownCaptureArm(captureId, innerWindowId, std::move(fds));
```
and registers the completion listener once at startup:
```cpp
FiredownCaptureManager::Get().SetCompletionListener(
    [](const nsAString& aId, bool aComplete, uint64_t aBytes, nsresult aStatus) {
      // dispatch "Firedown:Capture:Complete" via the runtime EventDispatcher
    });
```

`SendFiredownCaptureArm` / `SendFiredownCaptureComplete` are generated from the
`PContent.ipdl` messages above; their exact argument types follow the message
declarations (confirm against the generated `PContentParent.h`).

---

## G. Lifecycle / safety notes carried by this layer
- **Empty-window arm** is reported immediately (no hang) — see C.
- **Completion during shutdown**: `ContentChild::GetSingleton()` null-check (C) and
  the manager's `GetIfExists()` bounce (0008b) both no-op safely.
- **Channel/actor teardown** (content process dying): `Send*` returns false and is
  ignored; the app's `cancelTab` finalize + its owned fds cover the partial file.
- **Threading**: child recv handlers run on the content main thread (the manager's
  required thread); the parent recv + the GeckoView listener run on the parent main
  thread. No new locks.

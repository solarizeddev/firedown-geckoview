#!/usr/bin/env bash
# 0008 — Fix the Android window-activation wedge (grey text selection).
#
# WHY: Gecko paints a text selection with the accent wash only while the
# selection's document has DOM focus (nsFrameSelection::WillFocusDocument →
# SELECTION_ON); a blurred document paints TextSelectDisabledBackground — the
# opaque grey #AAAAAA. On Android, that document focus hangs off WINDOW
# ACTIVATION, which widget/android/nsWindow.cpp manages with two defects that a
# multi-session embedder (Firedown: hidden PoToken-mint and P2P-engine
# sessions) trips constantly and stock Fenix never does:
#
#   1. Show(true) unconditionally BringToFront()s a newly shown window — every
#      hidden GeckoSession that opens deactivates the visible tab's window and
#      blurs its document (transient: any touch used to heal it via
#      UserActivity()... except for #2).
#   2. Destroy() removes the window from gTopLevelWindows WITHOUT re-activating
#      anything (unlike the Show(false) path, which raises the next visible
#      window). Destroying the activation-holding window leaves the visible tab
#      "list-top but NOT active" — a WEDGED state nothing can exit:
#      UserActivity() no-ops (already list-top), GeckoView.requestFocus()
#      no-ops (view already focused), and setFocused(true) → browser.focus()
#      is dropped by nsFocusManager::SetFocusInner (sendFocusEvent requires
#      isElementInActiveWindow). Result: text selection stays grey forever.
#      Proven on-device: setting ui.textSelectDisabledBackground=#ff0000 turned
#      the "grey selection" red.
#
# FIX: track the activation holder explicitly (list order alone cannot
# represent "list-top but deactivated") and use it three ways:
#   - Destroy(): if the destroyed window held the activation, asynchronously
#     BringToFront() the next visible top-level window (mirrors Show(false));
#     async so no focus events run inside Destroy().
#   - BringToFront() guard: early-return only when THIS hierarchy's top-level
#     IS the current holder — the stock check ("some active window exists and
#     we are list-top") also matched the wedge and blocked every heal.
#   - UserActivity(): also re-raise when list-top but not the holder, so any
#     remaining wedge source self-heals on the first touch.
#
# Cannot be done app-side: no GeckoView API reaches nsWindow::Show/Destroy, and
# focus hand-back via setFocused() is structurally dropped for non-active
# windows (see SetFocusInner above).
#
# Idempotent + marker-gated. Fails LOUDLY if an anchor moved.
set -euo pipefail

SRC="${1:?usage: 0008-android-window-activation-wedge.sh <gecko-src-root>}"
F="$SRC/widget/android/nsWindow.cpp"
MARKER="FIREDOWN-WINDOW-ACTIVATION"

if [ ! -f "$F" ]; then
  echo "ERROR(0008): $F not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0008 Android window-activation wedge already applied"
  exit 0
fi

python3 - "$F" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

def replace_once(anchor, replacement, what):
    global src
    if anchor not in src:
        sys.stderr.write(
            "ERROR(0008): anchor for %s not found in nsWindow.cpp — the code "
            "moved; inspect it and update this script.\n" % what)
        sys.exit(1)
    if src.count(anchor) != 1:
        sys.stderr.write(
            "ERROR(0008): anchor for %s is not unique in nsWindow.cpp — "
            "tighten the anchor.\n" % what)
        sys.exit(1)
    src = src.replace(anchor, replacement, 1)

# ── 1. The explicit activation holder, beside the stacking list. ──────────────
anchor = (
    "// All the toplevel windows that have been created; these are in\n"
    "// stacking order, so the window at gTopLevelWindows[0] is the topmost\n"
    "// one.\n"
    "constinit static nsTArray<nsWindow*> gTopLevelWindows;\n"
)
replace_once(
    anchor,
    anchor
    + "\n"
    + "// %s: the top-level window that most recently fired\n" % marker
    + "// WindowActivated() out of BringToFront(). List order alone cannot\n"
      "// represent \"top-of-list but no longer activated\" — the state a\n"
      "// destroyed window leaves behind — so the activation holder is tracked\n"
      "// explicitly. Cleared in Destroy() and the destructor; compared (never\n"
      "// dereferenced) everywhere else.\n"
      "constinit static nsWindow* sFiredownActiveWindow = nullptr;\n",
    "activation-holder declaration")

# ── 2. Destructor: never leave a dangling holder. ─────────────────────────────
anchor = (
    "nsWindow::~nsWindow() {\n"
    "  gTopLevelWindows.RemoveElement(this);\n"
)
replace_once(
    anchor,
    "nsWindow::~nsWindow() {\n"
    "  // %s: never leave a dangling activation holder.\n" % marker
    + "  if (sFiredownActiveWindow == this) {\n"
      "    sFiredownActiveWindow = nullptr;\n"
      "  }\n"
      "  gTopLevelWindows.RemoveElement(this);\n",
    "destructor holder clear")

# ── 3. Destroy(): hand the activation to the next visible window. ─────────────
anchor = (
    "  if (IsTopLevel()) {\n"
    "    gTopLevelWindows.RemoveElement(this);\n"
    "  }\n"
    "\n"
    "  nsIWidget::OnDestroy();\n"
)
replace_once(
    anchor,
    "  if (IsTopLevel()) {\n"
    "    // %s: stock code removes the window from the list and\n" % marker
    + "    // re-activates NOTHING (unlike the Show(false) path, which raises\n"
      "    // the next visible window). Destroying the activation-holding\n"
      "    // window (a hidden GeckoSession closing) therefore left the visible\n"
      "    // tab \"list-top but not active\": its document stayed blurred, text\n"
      "    // selection painted the disabled grey, and no embedder API could\n"
      "    // recover. Hand the activation to the next visible top-level\n"
      "    // window. Dispatched async so no focus events run inside Destroy();\n"
      "    // the runnable re-resolves the list at run time, so it holds no\n"
      "    // stale pointers.\n"
      "    const bool wasActive = (sFiredownActiveWindow == this);\n"
      "    if (wasActive) {\n"
      "      sFiredownActiveWindow = nullptr;\n"
      "    }\n"
      "    gTopLevelWindows.RemoveElement(this);\n"
      "    if (wasActive) {\n"
      "      NS_DispatchToCurrentThread(\n"
      "          NS_NewRunnableFunction(\"FiredownReactivateTopWindow\", []() {\n"
      "            for (nsWindow* win : gTopLevelWindows) {\n"
      "              if (win->mIsVisible) {\n"
      "                win->BringToFront();\n"
      "                return;\n"
      "              }\n"
      "            }\n"
      "          }));\n"
      "    }\n"
      "  }\n"
      "\n"
      "  nsIWidget::OnDestroy();\n",
    "Destroy() re-activation")

# ── 4. BringToFront() guard: identity, not mere existence. ────────────────────
anchor = (
    "  nsFocusManager* fm = nsFocusManager::GetFocusManager();\n"
    "  if (fm && fm->GetActiveWindow() && FindTopLevel() == nsWindow::TopWindow()) {\n"
    "    return;\n"
    "  }\n"
)
replace_once(
    anchor,
    "  nsFocusManager* fm = nsFocusManager::GetFocusManager();\n"
    "  // %s: skip the raise only when this hierarchy's top-level\n" % marker
    + "  // IS the current activation holder. The stock condition (\"some active\n"
      "  // window exists and we are list-top\") also matched the post-Destroy\n"
      "  // wedge (list-top yet activation lost), turning every heal attempt\n"
      "  // into an early return.\n"
      "  if (fm && fm->GetActiveWindow() && sFiredownActiveWindow == FindTopLevel() &&\n"
      "      FindTopLevel() == nsWindow::TopWindow()) {\n"
      "    return;\n"
      "  }\n",
    "BringToFront() guard")

# ── 5. BringToFront() tail: record the holder. ────────────────────────────────
anchor = (
    "  if (mWidgetListener) {\n"
    "    mWidgetListener->WindowActivated();\n"
    "  }\n"
    "\n"
    "  RedrawAll();\n"
    "}\n"
)
replace_once(
    anchor,
    "  // %s: record the holder before notifying, so anything\n" % marker
    + "  // WindowActivated() runs observes the new state. (Also makes the\n"
      "  // guard above stop re-entrant self-raises, as the stock check did.)\n"
      "  sFiredownActiveWindow = this;\n"
      "\n"
      "  if (mWidgetListener) {\n"
      "    mWidgetListener->WindowActivated();\n"
      "  }\n"
      "\n"
      "  RedrawAll();\n"
      "}\n",
    "BringToFront() holder record")

# ── 6. UserActivity(): self-heal the wedge on any touch. ──────────────────────
anchor = (
    "  if (FindTopLevel() != nsWindow::TopWindow()) {\n"
    "    BringToFront();\n"
    "  }\n"
    "}\n"
)
replace_once(
    anchor,
    "  // %s: also re-raise when this hierarchy is already list-top\n" % marker
    + "  // but no longer holds the activation (the post-Destroy wedge) — the\n"
      "  // touch beginning a long-press selection then repairs document focus\n"
      "  // before the selection paints. BringToFront()'s guard makes the\n"
      "  // already-active case an early return, so ordinary touches stay cheap.\n"
      "  nsWindow* const topLevel = FindTopLevel();\n"
      "  bool needRaise = (topLevel != nsWindow::TopWindow());\n"
      "  if (!needRaise) {\n"
      "    needRaise = (sFiredownActiveWindow != topLevel);\n"
      "  }\n"
      "  if (needRaise) {\n"
      "    BringToFront();\n"
      "  }\n"
      "}\n",
    "UserActivity() self-heal")

open(path, "w", encoding="utf-8").write(src)
print("[ok] 0008 Android window-activation wedge: holder tracked, Destroy() "
      "re-activates, guard identity-checked, UserActivity() self-heals")
PY

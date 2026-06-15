# Weft roadmap

Weft is a proctored in-class essay tool. There was never a written "phase 3" —
this file makes it real. The phases:

- **Phase 1 — Electron app** (`Tessera/renderer`). The proof of concept. **Retired.**
- **Phase 2 — Native macOS app wired to Supabase** (`Weft`, branch
  `phase2-native-wiring`, shipped 0.3.4). Sign-in, classes, sessions, the locked
  exam (kiosk + autosave + submit), grading, returned work, outline upload + the
  in-exam outline view, proctoring *detection*, the locked browser, and Sparkle
  auto-update. **Essentially complete.**
- **Phase 3 — Proctoring hardening + polish.** This document.

---

## Phase 3 status

| Item | Status | Notes |
|---|---|---|
| Webcam / camera capture | ❌ **Dropped** (2026-06-14) | No `NSCameraUsageDescription`, no camera entitlement, no `AVCaptureSession`. Permission + "Camera stills" copy removed. |
| Periodic screenshots | ⏸️ **Deprioritized** | Only if it can be made to cost **zero typing performance** (see below). Unbuilt until then. |
| Content protection (capture exclusion) | ✅ **Done** | `window.sharingType = .none` in `KioskController` (saved/restored around the lock). |
| Raw-key suppression (launchers / screenshots / Spaces) | ✅ **Done** (device-tested) | `ExamKeyGuard` (CGEventTap) blocks ⌘Space / ⌥Space launchers, ⌘⇧ screenshots, ⌃-arrow Mission Control, ⌘Tab, F13–F19. Needs the Accessibility grant; fails open if denied. |
| Request Accessibility on the checks screen | ⬜ **Next** | Without the grant `ExamKeyGuard` is a no-op. The pre-exam checks should prompt/verify it (required vs best-effort — TBD). |
| `allowCapture` admin escape hatch | ⬜ Backlog | Let an admin test-driving the app bypass content-protection to screenshot for a bug report. Minor. |
| Locked-browser chrome (back/forward/reload) | ⬜ Backlog | UX polish. |
| Editor list renumbering on edit | ⬜ Backlog | Editor polish (`RichTextEditor`). |

---

## Decisions

### Webcam — dropped
Not part of the product. The app makes no camera claim of any kind. (Removed:
`INFOPLIST_KEY_NSCameraUsageDescription`, the `webcamOn` "Camera stills" ledger
row, and the future-path comments.)

### Screenshots — only at zero typing cost
A periodic screen capture during the exam is **only** acceptable if a student who
is typing cannot perceive it. That means:
- Capture off the main actor (never block the editor's run loop).
- A slow cadence (e.g. ≥20 s), and skip a tick if the previous one is still in flight.
- `ScreenCaptureKit` / `SCScreenshotManager` on macOS 14+ (the legacy
  `CGWindowListCreateImage` is deprecated), gated behind
  `CGRequestScreenCaptureAccess()`.
- Measure: type continuously while it runs and confirm **no** dropped frames /
  input latency in the editor. If it can't clear that bar, we don't ship it.

The done-screen "Screen pictures" ledger row now defaults **off**
(`StudentDoneView.screenCaptureOn = false`) so the app never promises a capture
it isn't doing. Flip it true only when screenshots actually run.

---

## Raw-key suppression — done

`NSApp.presentationOptions` already disables Cmd-Tab / Cmd-Q / Force-Quit / the
Apple menu, but not the escape / launcher / capture hotkeys a student could cheat
with. `ExamKeyGuard` (a `CGEventTap` at `.cgSessionEventTap`, wired into the kiosk
lock) closes that gap — each rule gated on a modifier so plain typing is never
touched:

- **⌘Space / ⌥Space** — Spotlight, Raycast, Alfred, the ChatGPT app, Siri
- **⌘⇧3/4/5/6** — screenshots / screen recording
- **⌃↑ ↓ ← →** — Mission Control / Spaces / App Exposé
- **⌘Tab** and **F13–F19** (launcher rebinds)

(CapsLock is intentionally *not* handled — macOS toggles it below the session tap,
so it can't be suppressed this way, and it isn't a cheat vector.)

Safe by construction: every rule in `shouldSuppress(keyCode:flags:)` needs a
modifier, so plain space / arrows / digits always pass; it **fails open** if the
app isn't trusted for Accessibility; and it's exam-scoped + self-healing.
Device-tested via the dev harness (`WEFT_SCREEN=keyguard`).

**Remaining to make it live:** the guard is a no-op without the Accessibility TCC
grant, and the real exam flow doesn't request it yet. Wire a check/prompt into the
pre-exam `StudentChecksView` (required vs best-effort is a product call).

---

## Release / signing note (verify before the next release)

`phase2-native-wiring` embeds `SUPublicEDKey = fiG4V8WKwWAm8avUBbxMvLEwN3/vPQcx5NI3h1oD4fs=`.
The live 0.3.4 appcast is signed against it, so the matching **private** key
exists somewhere. Confirm you can still sign with it (`./bin/generate_keys -p`
prints `fiG4…`) before cutting 0.3.5. If that key is truly lost, a re-key is
required and existing 0.3.4 users must download the next build manually once.

---

## Out of scope (explicitly not doing)
- Webcam / camera, audio capture, keystroke logging, continuous video.
- Anything the App Sandbox would forbid — the app ships **non-sandboxed**
  Developer-ID + notarized precisely so proctoring can enumerate processes,
  displays, and VMs.

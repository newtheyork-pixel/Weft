# Weft — Xcode Signing & Capabilities setup

Everything below is configured **in Xcode** (or the Supabase/Google dashboards) — it
can't be done from the synchronized `.swift` sources. The native code already
expects these; until they're in place, OAuth and the persistent permissions
won't work, and the app falls back to mock data.

Open `Weft.xcodeproj` → select the **Weft** target.

---

## 1. `weft://` URL scheme (required for Google sign-in)

The OAuth flow redirects to `weft://auth-callback` (see `SupabaseConfig.redirectScheme`
/ `redirectURL` in `SupabaseManager.swift`). Register the scheme so the deep link lands:

**Target → Info tab → URL Types → +**
- **Identifier:** `com.tessera.Weft.oauth`
- **URL Schemes:** `weft`
- **Role:** Editor

(This writes `CFBundleURLTypes` with `CFBundleURLSchemes = ["weft"]` into Info.plist.)

> `ASWebAuthenticationSession` actually intercepts the callback by `callbackURLScheme: "weft"`
> without needing the URL type in most cases, but registering it is the documented,
> robust setup and is needed if the deep link is ever delivered to the app directly.

### Also required, outside Xcode — Supabase + Google dashboards
1. **Supabase → Authentication → URL Configuration → Redirect URLs:** add
   `weft://auth-callback` to the allow-list (GoTrue rejects `redirect_to` values that aren't listed).
2. **Supabase → Authentication → Providers → Google:** enabled, with the Google client ID/secret.
3. **Google Cloud Console → OAuth client:** the authorized redirect URI is the Supabase
   callback `https://elrrvicxsguqstqciodn.supabase.co/auth/v1/callback` (this is unchanged;
   the `weft://` hop is between Supabase and the app, not Google and the app).
4. **(server) role lookup:** `AppState` calls a best-effort `get_my_role()` RPC
   (returns `'teacher' | 'student' | 'admin'`). If it isn't deployed the app falls back to
   the on-screen role chooser. Deploy it (or tell me the real teacher-routing source) to
   get automatic role routing.

---

## 2. Camera / webcam — not used

Webcam proctoring was **dropped** (2026-06-14). The app declares no
`NSCameraUsageDescription`, carries no camera entitlement, and never opens an
`AVCaptureSession`. Nothing to configure here.

---

## 3. Screen Recording (runtime TCC permission, not a build setting)

Screen Recording is **not** an entitlement or an Info.plist key — it's a per-user TCC grant.
`ProctoringEngine.detectScreenRecordingPermission()` reads it via `CGPreflightScreenCaptureAccess()`,
and the periodic-screenshot feature (capture wave) will request it via `CGRequestScreenCaptureAccess()`.

What you need to know:
- The user grants it in **System Settings → Privacy & Security → Screen Recording**.
- The grant is keyed to the app's **code signature**. An **unsigned dev build re-prompts
  every launch and loses the grant** — so this only behaves correctly once §5 (signing) is done.
- No plist key is required. (There is no `NSScreenCaptureUsageDescription`.)

---

## 4. Network access

The app makes outbound HTTPS calls (Supabase PostgREST/RPC/GoTrue, `api.ipify.org`) and
runs `ASWebAuthenticationSession`. As a **non-sandboxed** Developer-ID app (see §5), no
network entitlement is required — it works out of the box. (Only if you ever enable App
Sandbox would you need `com.apple.security.network.client`.)

---

## 5. Signing, Hardened Runtime, and App Sandbox

**Current project state (checked 2026-06-09):** `DEVELOPMENT_TEAM = PW2VT56789` ✅,
`ENABLE_HARDENED_RUNTIME = YES` ✅, `CODE_SIGN_STYLE = Automatic` ✅, but
**`ENABLE_APP_SANDBOX = YES` ❌ (must be turned OFF)**. No physical Info.plist or
.entitlements file (`GENERATE_INFOPLIST_FILE = YES`).

**Signing & Capabilities tab:**
- **Team:** `PW2VT56789` (Schulte) — already set. **Signing Certificate:** Developer ID
  Application for distribution (Automatic / "Sign to Run Locally" is fine for local debug).
- **Hardened Runtime** — already enabled. It's what makes `window.sharingType = .none` (the
  exam content-protection in `KioskController`) reliably exclude the window from screen capture.
- **REMOVE App Sandbox.** It is currently ON and must be turned OFF: in Signing &
  Capabilities, hover the **App Sandbox** card and click the **×** to delete it (or set
  Build Settings → `ENABLE_APP_SANDBOX = NO`). Weft is distributed via Developer ID (App
  Store was ruled out — the sandbox blocks the kiosk lockdown, the running-app proctoring
  scan, and content protection). It must stay off.
- Notarize for distribution the same way the Electron app does (`npm run build:signed`
  equivalent → here it's Xcode **Product → Archive → Distribute App → Developer ID → notarize**).

---

## 6. Accessibility — raw key suppression

`ExamKeyGuard` (wired into `KioskController`) swallows the escape / launcher / capture
hotkeys during the exam — ⌘Space / ⌥Space launchers (Spotlight, Raycast, Alfred, ChatGPT,
Siri), ⌘⇧3/4/5/6 screenshots, ⌃-arrow Mission Control / Spaces, ⌘Tab, and F13–F19 — via a
`CGEventTap` at `.cgSessionEventTap`. That tap requires the **Accessibility** TCC
grant (System Settings → Privacy & Security → Accessibility) — a runtime grant keyed to the
signature, so it depends on §5. Nothing to add in Xcode beyond signing.

Until the grant is given the guard **fails open**: the kiosk lock still runs, raw keys just
aren't suppressed. To enable it: grant Accessibility, then confirm during an exam that
⌘Space / screenshots / Mission Control are inert and that normal typing (incl. the plain spacebar) + submit are completely unaffected.

---

## Quick checklist

- [ ] URL Type `weft` added (§1)
- [ ] `weft://auth-callback` in Supabase Redirect URLs (§1)
- [ ] Google provider enabled in Supabase (§1)
- [ ] `get_my_role()` RPC deployed, or confirm role-routing source (§1)
- [x] Camera/webcam: not used — dropped, no permission needed (§2)
- [x] Hardened Runtime capability added (§5) — already on
- [x] Developer ID signing / team `PW2VT56789` (§5) — already set
- [ ] App Sandbox turned OFF (§5) — currently ON, must remove
- [ ] Accessibility granted (§6) — enables raw-key suppression (fails open without it)

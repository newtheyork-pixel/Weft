//
//  KioskController.swift
//  Weft — native macOS kiosk lockdown for the in-exam student window.
//
//  This is the AppKit port of the Electron main.js enter-kiosk / exit-kiosk
//  handlers. The Electron app drove the lock through BrowserWindow.setKiosk,
//  setAlwaysOnTop('screen-saver'), setFullScreen, setContentProtection, and a
//  globalShortcut grab plus a blur / leave-full-screen fight-back. Here we map
//  those onto the native equivalents:
//
//    Electron                              AppKit / Cocoa
//    ────────────────────────────────────  ──────────────────────────────────
//    setKiosk(true) + hide dock/menubar     NSApp.presentationOptions
//    setFullScreen(true)                    toggleFullScreen: (native fs space)
//    setAlwaysOnTop('screen-saver')         window.level (very high CGWindowLevel)
//    setContentProtection(true)             window.sharingType = .none  (TODO)
//    globalShortcut.register(...)           NSApp.presentationOptions
//                                           (.disableProcessSwitching etc.) +
//                                           a future CGEventTap (entitlement)
//    blur / leave-full-screen fight-back    window/app notification observers
//                                           with a settle window (see notes)
//
//  presentationOptions is the single most important lever: with .hideDock,
//  .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
//  .disableSessionTermination, .disableHideApplication and .disableAppleMenu
//  set, AppKit itself swallows Cmd+Tab, Cmd+Q, the Apple menu, Force-Quit, and
//  the Dock — the things the Electron globalShortcut list was reaching for. We
//  do not need a separate accelerator table for those; we DO still want an
//  event tap later for raw CapsLock / F13-F19 / launcher rebinds (see TODO).
//
//  NOTE — the macOS settle / focus quirk the Electron build fought for two
//  releases (0.2.10 / 0.2.11, the "caret death" saga):
//
//    Entering a native full-screen space plays an animation. During that
//    animation the window briefly RESIGNS key and the space transition emits
//    transient focus changes. The Electron build re-keyed the window inside the
//    blur handler (setAlwaysOnTop + show + focus + moveTop == makeKeyAndOrderFront)
//    and that re-key, fired DURING the settle window, killed the caret-blink
//    painter in the essay editor while the DOM stayed focused — the infamous
//    "cursor vanishes but I can still type" bug. The fix was: during a short
//    settle window after entering kiosk, RE-ASSERT full-screen / level only and
//    do NOT re-grab key focus; only after settle does a focus loss count as a
//    real app-switch worth re-keying + blacking out for.
//
//    The native analogue: do not call makeKeyAndOrderFront / orderFrontRegardless
//    from a didResignKey observer while `settling` is true. Re-pin the window
//    level instead, and let AppKit's own full-screen completion re-key the
//    window. Re-keying a native NSWindow mid-space-transition has historically
//    produced the same first-responder / caret churn, so the same guard applies.
//
//  Target: macOS 26 SDK, Swift 6, no external packages.
//

import AppKit

/// Drives the kiosk lockdown for a single exam window. One instance per app;
/// only one window is ever locked at a time (mirrors `_kioskWin` in main.js).
@MainActor
final class KioskController {

    // MARK: State

    /// The window currently held under kiosk lock, if any. Mirrors `_kioskWin`.
    private weak var lockedWindow: NSWindow?

    /// The window's pre-kiosk level, restored on exit so we don't leave a
    /// normal window pinned above everything if the caller reuses it.
    private var savedLevel: NSWindow.Level = .normal

    /// The window's pre-kiosk sharing type, restored on exit (see content
    /// protection TODO below).
    private var savedSharingType: NSWindow.SharingType = .readOnly

    /// True between `enterKiosk` and `exitKiosk`. Gates the fight-back so we
    /// never fight focus changes outside the exam. Mirrors `_studentInTest`.
    private var inTest = false

    /// Wall-clock instant the lock began, used by the settle window.
    private var enteredAt: Date = .distantPast

    /// Observer tokens for the window/app notifications driving the fight-back.
    /// Torn down on exit so a reused window does not stack handlers (the bug
    /// the Electron `_kioskCleanup` guarded against).
    private var observers: [NSObjectProtocol] = []

    /// Grace window after entering kiosk during which transient resign-key /
    /// full-screen-exit notifications are NOT treated as the student leaving.
    /// Kept in sync with the Electron KIOSK_SETTLE_MS so behaviour matches.
    private let settleInterval: TimeInterval = 5.0

    /// True while we are still inside the post-entry settle window.
    private var settling: Bool { Date().timeIntervalSince(enteredAt) < settleInterval }

    // MARK: Proctor hooks (the file-header TODO, wired)

    /// Fired when, PAST the settle window, the student genuinely leaves the exam
    /// window (an app switch or a forced exit from full-screen). The exam layer
    /// uses this to black the question out — the native analogue of the Electron
    /// `win.webContents.send('proctor:focus-lost')` / panicBlackout. The overlay
    /// is cleared deterministically by the student (a Resume action), NOT by a
    /// key-window notification — re-keying the window from the fight-back makes a
    /// becomeKey-based auto-clear race the very blackout it would dismiss.
    var onBlackout: (@MainActor () -> Void)?

    init() {}

    // MARK: Enter

    /// Locks `window` into kiosk mode: hides the dock and menu bar, disables
    /// process switching / force-quit / session termination, takes the window
    /// full-screen, and pins it above everything. Idempotent re-entry first
    /// tears down any previous lock so observers and saved state never stack
    /// (the Electron `if (_kioskCleanup) _kioskCleanup()` guard).
    func enterKiosk(window: NSWindow) {
        // Re-entry (e.g. resume after a transient exit) must not stack observers
        // or clobber saved state. If a DIFFERENT window is still locked, fully
        // restore it first (level/sharing/full-screen) so we never strand it
        // pinned-above-everything with content protection on; otherwise just
        // drop the stale observers.
        if let previous = lockedWindow, previous !== window {
            teardownObservers()
            previous.level = savedLevel
            previous.sharingType = savedSharingType
            if previous.styleMask.contains(.fullScreen) {
                previous.toggleFullScreen(nil)
            }
        } else if lockedWindow != nil {
            teardownObservers()
        }

        lockedWindow = window
        inTest = true
        enteredAt = Date()

        // The whole kiosk surface lives in presentationOptions. This is the
        // native equivalent of Electron's setKiosk + hide-dock/menubar AND the
        // bulk of its globalShortcut grabs: AppKit swallows Cmd+Tab (process
        // switching), Cmd+Q / Force-Quit, the Apple menu, and app hide for us.
        NSApp.presentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication,
            .disableAppleMenu,
        ]

        // Pin the window above normal windows, screen-saver-ish, matching
        // Electron's setAlwaysOnTop(true, 'screen-saver'). Save the old level
        // so exit can restore it. We use a high named level rather than a raw
        // CGWindowLevel constant so the value stays valid across SDK changes.
        savedLevel = window.level
        window.level = .screenSaver

        // Content protection: hide the window's contents from screen-capture
        // frames so an AI-launcher overlay (Raycast / Spotlight / a desktop
        // assistant) that pops over us cannot snapshot the live question. This
        // is the native NSWindowSharingType analogue of setContentProtection.
        //
        // TODO(content-protection / entitlement): sharingType = .none is the
        // documented switch but is only fully honoured for capture exclusion on
        // a window whose app is signed with a hardened runtime; under the
        // unsigned dev build it is best-effort. Gate it behind the same
        // "admin is test-driving (allowCapture)" escape hatch the Electron build
        // had so an admin can still screenshot the app to file a bug. For now we
        // save + set it unconditionally; wire the allowCapture flag in when the
        // checks view passes one through.
        savedSharingType = window.sharingType
        window.sharingType = .none

        // Take the window full-screen. toggleFullScreen drives the native
        // full-screen SPACE (its own Space), which is what we want for kiosk:
        // it removes the title bar and prevents the window from being dragged
        // out from under the lock. Only toggle if we are not already there, or
        // we would toggle straight back OUT.
        //
        // NOTE: this kicks off the settle-window animation described in the file
        // header. The resign-key handler below MUST NOT re-key during it.
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        // Bring the window to the front ONCE, now, before the animation begins.
        // We deliberately do NOT re-key from the resign handler during settle.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installFightBack(for: window)
    }

    // MARK: Exit

    /// Releases the kiosk lock on `window`: restores presentation options to
    /// empty, leaves full-screen, drops the window level and sharing type back
    /// to their pre-kiosk values, and detaches the fight-back observers.
    ///
    /// Cleanup runs FIRST and unconditionally (mirrors the Electron comment:
    /// "ALWAYS run cleanup first ... otherwise the grabs/listeners leak into a
    /// zombie kiosk until app quit") so a window that is mid-teardown still
    /// releases the observers.
    func exitKiosk(window: NSWindow) {
        inTest = false
        teardownObservers()

        // Restore the global presentation surface. Empty == normal desktop:
        // dock back, menu bar back, Cmd+Tab / Cmd+Q / Apple menu live again.
        NSApp.presentationOptions = []

        // Un-pin and un-protect, restoring the saved values rather than
        // assuming defaults so a reused window comes back exactly as it was.
        window.level = savedLevel
        window.sharingType = savedSharingType

        lockedWindow = nil

        // Leave the full-screen space — verified. macOS silently drops
        // toggleFullScreen while a fullscreen transition is in flight (e.g. a
        // submit during the entry animation), so retry until the window is
        // actually windowed.
        leaveFullScreen(window)
    }

    /// Toggle out of full screen and re-check after the animation; retry a few
    /// times if the toggle was swallowed by an in-flight transition.
    private func leaveFullScreen(_ window: NSWindow, attempt: Int = 0) {
        guard window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
        guard attempt < 5 else { return }
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let window, !self.inTest,
                  window.styleMask.contains(.fullScreen) else { return }
            self.leaveFullScreen(window, attempt: attempt + 1)
        }
    }

    // MARK: Fight-back

    /// Installs the resign-key / full-screen-exit observers that re-assert the
    /// lock when focus is stolen (an AI overlay pops up, a click lands on
    /// another app, a Mission Control swipe). Ported from the Electron
    /// `win.on('blur', ...)` / `win.on('leave-full-screen', ...)` pair.
    private func installFightBack(for window: NSWindow) {
        let nc = NotificationCenter.default

        // Window resigned key — the native analogue of Electron's 'blur'.
        let resign = nc.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleFocusLost(window: window)
            }
        }

        // App-level resign-active — a real app switch landed even though the
        // window itself may not have seen a resign-key (overlay that steals at
        // the app layer). Electron folded both into 'blur'; we observe both.
        let appResign = nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleFocusLost(window: window)
            }
        }

        // Left the full-screen space — the analogue of 'leave-full-screen'.
        let leaveFS = nc.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLeftFullScreen(window: window)
            }
        }

        observers = [resign, appResign, leaveFS]
    }

    /// Focus was lost. Re-assert the lock. During the settle window we ONLY
    /// re-pin level + presentation options and do NOT re-key the window — see
    /// the caret-death note in the file header. After settle, a focus loss is a
    /// real app-switch, so we re-grab key focus and (TODO) tell the renderer to
    /// black the exam content out.
    private func handleFocusLost(window: NSWindow) {
        guard inTest, lockedWindow === window else { return }

        // Always re-pin the level and presentation options — cheap, and it is
        // the part that does not churn the first responder / caret.
        window.level = .screenSaver
        NSApp.presentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication,
            .disableAppleMenu,
        ]

        // Settle window: the resign-key is the full-screen animation, not a
        // real theft. Re-keying here is exactly what killed the caret in the
        // Electron build. Re-assert level only and return.
        if settling { return }

        // Past settle: a genuine app switch. Raise the blackout FIRST (so it is
        // already up as the window comes forward), then re-grab and front. The
        // overlay stays until the student explicitly resumes.
        onBlackout?()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window left the full-screen space. Re-enter it. During settle this
    /// is the entry animation finishing oddly, so we only re-assert; after
    /// settle it is the student trying to escape, so (TODO) raise the violation.
    private func handleLeftFullScreen(window: NSWindow) {
        guard inTest, lockedWindow === window else { return }

        // Re-enter full-screen if we are out of it. Guard on the style mask so
        // we do not toggle ourselves back OUT of a space we are still in.
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        if settling { return }

        // TODO(proctor): past settle, leaving full-screen is a real violation —
        // raise it to the exam layer (Electron's 'proctor:focus-lost').
    }

    // MARK: Cleanup

    /// Detaches every fight-back observer. Safe to call when none are
    /// installed. Mirrors the Electron `_kioskCleanup`.
    private func teardownObservers() {
        let nc = NotificationCenter.default
        for token in observers {
            nc.removeObserver(token)
        }
        observers.removeAll()
    }

    deinit {
        // We cannot touch NotificationCenter off the main actor in a
        // non-isolated deinit, but the observer tokens are owned by this
        // instance; removing them in exitKiosk is the supported path. If we
        // reach deinit with observers still live, NotificationCenter holds only
        // a weak reference to the token target, so they lapse harmlessly.
    }
}

// MARK: - TODO (future hardening, needs entitlements / signing)
//
//  - Raw key suppression: presentationOptions does not swallow CapsLock,
//    F13-F19, or third-party launcher rebinds (the Electron before-input-event
//    + globalShortcut list). The native route is a CGEventTap at
//    .cgSessionEventTap, which requires the Accessibility entitlement and the
//    user's approval in System Settings > Privacy. Add as a separate component
//    so the kiosk lock degrades gracefully when the tap is denied.
//
//  - Content protection durability: window.sharingType = .none only reliably
//    excludes the window from capture under a hardened-runtime signed build
//    (the team is already Developer-ID signed + notarized via
//    `npm run build:signed`). Verify exclusion holds for ScreenCaptureKit
//    capturers, not just legacy CGWindowList.
//
//  - allowCapture escape hatch: thread the admin "allow capture" flag from the
//    checks view into enterKiosk so an admin test-driving the app can still
//    screenshot it, exactly as the Electron build did.

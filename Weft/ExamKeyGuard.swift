//
//  ExamKeyGuard.swift
//  Weft — raw-key suppression for the locked exam.
//
//  NSApp.presentationOptions (set in KioskController) already disables Cmd-Tab,
//  Cmd-Q, Force-Quit, and the Apple menu, but it does NOT stop the escape /
//  launcher hotkeys a student could cheat with: Spotlight & launchers
//  (⌘Space / ⌥Space → Spotlight, Raycast, Alfred, the ChatGPT app, Siri)
//  and Mission Control / Spaces (⌃↑↓←→). The native route is a CGEventTap at
//  the session level — the "separate component that degrades gracefully" the
//  KioskController TODO asks for. Screenshot / screen-recording hotkeys
//  (⌘⇧3/4/5/6) are intentionally left alone so a recording of the exam can
//  actually be taken.
//
//  (CapsLock is intentionally NOT handled: macOS toggles it below the session
//  tap, so a tap can't suppress it — and it isn't a cheating vector anyway.)
//
//  Safe by construction — four guarantees that matter for a live exam app:
//    1. NEVER EATS TYPING. Every rule in shouldSuppress(keyCode:flags:) requires
//       a modifier (or is a bare F13-F19 key never used for writing), so plain
//       space, arrows, digits, and punctuation always pass through. A bug cannot
//       swallow a student's essay.
//    2. FAIL-OPEN. If the app isn't trusted for Accessibility, or tapCreate
//       returns nil, nothing is installed and the kiosk lock simply runs without
//       raw-key suppression. No grant → no behavior change.
//    3. EXAM-SCOPED + SELF-HEALING. start() on kiosk enter, stop() on exit; the
//       tap re-enables itself if the system disables it under load (timeout).
//    4. VOICEOVER PASSES. Control+Option (the VoiceOver modifier) is never
//       swallowed, so VO-Space and VO-arrows still work in a locked exam.
//
//  Requires the Accessibility TCC grant (System Settings → Privacy & Security →
//  Accessibility) to actually intercept — see ROADMAP.md / XCODE_SETUP.md §6.
//

import AppKit
import ApplicationServices

@MainActor
final class ExamKeyGuard {
    /// Whether to drop this key event during a locked exam. Every rule requires a
    /// MODIFIER (or is a bare function key never used for writing), so plain text —
    /// space, arrows, digits, punctuation — always passes through untouched.
    /// kVK codes: Space 49, Tab 48, ←123 →124 ↓125 ↑126,
    /// F13–F19 = 105,107,113,106,64,79,80. Screenshot keys (3=20 4=21 6=22 5=23)
    /// are not suppressed.
    nonisolated static func shouldSuppress(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let cmd = flags.contains(.maskCommand)
        let opt = flags.contains(.maskAlternate)
        let ctrl = flags.contains(.maskControl)
        // VoiceOver's modifier is Control+Option. Swallowing those chords
        // (VO-Space to activate, VO-arrows to move) makes the locked exam
        // unusable with VoiceOver — a Section 508 / WCAG fail. Mission Control
        // and Spotlight never use both Control and Option together.
        if ctrl && opt { return false }
        switch keyCode {
        // Spotlight / Raycast / Alfred / ChatGPT (⌥Space) / Siri — Space + any modifier.
        case 49:                              return cmd || opt || ctrl
        // Screenshots & screen recording (⌘⇧3 / ⌘⇧4 / ⌘⇧5 / ⌘⇧6) pass through
        // on purpose. Local capture is allowed; remote-control software is
        // what pauses writing.
        // Mission Control / Spaces / App Exposé via keyboard — ⌃↑ ⌃↓ ⌃← ⌃→.
        case 123, 124, 125, 126:              return ctrl
        // App switcher — ⌘Tab (also covered by presentationOptions; belt + braces).
        case 48:                              return cmd
        // Third-party launcher rebinds on F13–F19 (bare keys, never used to type).
        case 105, 107, 113, 106, 64, 79, 80:  return true
        default:                              return false
        }
    }

    /// The single active tap. The C callback (which can't capture context) reaches
    /// it through this static to re-enable on a system-disable. Only ever touched
    /// on the main thread — start/stop and the main-run-loop callback — so the
    /// unchecked annotation is sound.
    nonisolated(unsafe) private static var activeTap: CFMachPort?

    private var runLoopSource: CFRunLoopSource?

    /// True once a tap is actually installed (i.e. Accessibility was granted).
    private(set) var active = false

    /// Whether the app may install a suppressing event tap. Reads the TCC state
    /// without prompting.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt for the Accessibility grant once (shows the system dialog). Optional:
    /// the guard works the instant the grant exists, and nothing breaks if it never
    /// does. Call this from the pre-exam checks screen, not mid-lock.
    static func requestTrust() {
        // Use the documented literal key ("AXTrustedCheckOptionPrompt") rather
        // than the global constant, which imports as Unmanaged<CFString> on some
        // SDKs and CFString on others — the literal compiles cleanly everywhere.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard Self.activeTap == nil else { return }   // idempotent
        guard Self.isTrusted else { return }           // fail-open: no grant, no tap

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                 | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        // Non-capturing C callback: references only ExamKeyGuard statics + C APIs.
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = ExamKeyGuard.activeTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if ExamKeyGuard.shouldSuppress(keyCode: code, flags: event.flags) {
                return nil   // drop the escape / launcher hotkey
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,            // .defaultTap (not .listenOnly) can drop events
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil)
        else { return }                      // fail-open (e.g. not trusted)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Self.activeTap = tap
        runLoopSource = source
        active = true
    }

    func stop() {
        if let tap = Self.activeTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        Self.activeTap = nil
        runLoopSource = nil
        active = false
    }
}

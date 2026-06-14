//
//  ExamKeyGuard.swift
//  Weft — raw-key suppression for the locked exam.
//
//  NSApp.presentationOptions (set in KioskController) already disables Cmd-Tab,
//  Cmd-Q, Force-Quit, and the Apple menu, but it does NOT swallow CapsLock, the
//  F13-F19 keys, or third-party launcher rebinds. The native route is a
//  CGEventTap at the session level. This is the "separate component that degrades
//  gracefully" the KioskController TODO asks for.
//
//  Safe by construction — three guarantees that matter for a live exam app:
//    1. ALLOWLIST ONLY. It drops a FIXED set of non-character keycodes
//       (CapsLock + F13-F19) and passes every other event through untouched. A
//       bug cannot eat a student's typing, because letters/digits/punctuation
//       are never in the set.
//    2. FAIL-OPEN. If the app isn't trusted for Accessibility, or tapCreate
//       returns nil, nothing is installed and the kiosk lock simply runs without
//       raw-key suppression. No grant → no behavior change.
//    3. EXAM-SCOPED + SELF-HEALING. start() on kiosk enter, stop() on exit; the
//       tap re-enables itself if the system disables it under load (timeout).
//
//  Requires the Accessibility TCC grant (System Settings → Privacy & Security →
//  Accessibility) to actually intercept — see ROADMAP.md / XCODE_SETUP.md §6.
//

import AppKit
import ApplicationServices

@MainActor
final class ExamKeyGuard {
    /// Virtual keycodes dropped while an exam is locked: CapsLock + F13-F19.
    /// Deliberately NOT any character or navigation key, so typing is untouched.
    /// (kVK_CapsLock = 57; kVK_F13…F19 = 105,107,113,106,64,79,80.)
    nonisolated static let blockedKeyCodes: Set<Int64> = [57, 105, 107, 113, 106, 64, 79, 80]

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
            if ExamKeyGuard.blockedKeyCodes.contains(code) {
                return nil   // drop CapsLock / F13-F19
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

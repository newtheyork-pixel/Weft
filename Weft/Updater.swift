//
//  Updater.swift
//  Weft — Sparkle in-app auto-update. Reads the appcast feed (SUFeedURL in
//  Info.plist), verifies each update against the EdDSA public key (SUPublicEDKey),
//  and NEVER checks while a student is in the locked exam, so an update can't
//  interrupt or relaunch a test.
//

import SwiftUI
import Combine
import Sparkle

/// True only while a student is inside the locked exam (set by
/// `AppState.enterExam` / `finishExam`). The Sparkle delegate reads it to block
/// update checks mid-test. Touched only on the main thread.
enum ExamGate {
    nonisolated(unsafe) static var inProgress = false
}

/// Sparkle 2's gate: throwing from `updater(_:mayPerform:)` blocks the check
/// (scheduled background check OR the manual menu item).
private final class ExamAwareUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if ExamGate.inProgress {
            throw NSError(domain: "Weft", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Updates are paused while an exam is in progress."
            ])
        }
    }
}

/// Owns the Sparkle updater for the app's lifetime (held by `WeftApp` as a
/// `@StateObject`). `startingUpdater: true` enables the scheduled background
/// check defined by SUEnableAutomaticChecks / SUScheduledCheckInterval.
final class UpdaterViewModel: ObservableObject {
    private let delegate = ExamAwareUpdaterDelegate()
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }
}

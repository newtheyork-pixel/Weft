//
//  ExamAppCloser.swift
//  Weft: closes every other app when the exam begins, and any app opened
//  during it. AI helpers (floating chat windows, launcher hotkeys, writing
//  assistants) can draw over a full-screen window; quitting them is the only
//  sure way to keep them out.
//
//  No special permission is needed: these are the student's own apps. Weft
//  asks each app to quit first (it may offer to save), then force-quits what
//  is still open after a grace period.
//
//  Debug (test) builds only LIST the apps and never close them, so testing
//  Weft on a developer's Mac doesn't quit their tools.
//

import AppKit

@MainActor
enum ExamAppCloser {

    /// Apps that are never closed: Weft itself, Finder (macOS restarts it),
    /// and accessibility tools students may depend on.
    private static func isExempt(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        let bid = (app.bundleIdentifier ?? "").lowercased()
        if bid == (Bundle.main.bundleIdentifier ?? "").lowercased() { return true }
        if bid == "com.apple.finder" { return true }
        if bid == "com.apple.voiceover" || bid.hasPrefix("com.apple.accessibility")
            || bid == "com.apple.voiceoverutility" { return true }
        return false
    }

    /// True in builds that really close apps (release builds).
    static var closesApps: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Other apps with a Dock icon (what a student thinks of as "open apps").
    static func openApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !isExempt($0)
        }
    }

    static func openAppNames() -> [String] {
        Array(Set(openApps().compactMap(\.localizedName))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Ask every other app to quit, then force-quit those still open after
    /// `grace` seconds. Returns the names of apps that could not be closed.
    @discardableResult
    static func closeAll(grace: TimeInterval = 10) async -> [String] {
        guard closesApps else { return [] }
        let apps = openApps()
        guard !apps.isEmpty else { return [] }
        for app in apps { app.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(400))
        }
        for app in apps where !app.isTerminated { app.forceTerminate() }
        try? await Task.sleep(for: .seconds(1))
        return apps.filter { !$0.isTerminated }.compactMap(\.localizedName)
    }

    // MARK: During the exam

    private static var launchObserver: NSObjectProtocol?

    /// Quit any app that opens while the exam is running.
    static func startWatching() {
        guard closesApps, launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated {
                guard app.activationPolicy == .regular, !isExempt(app) else { return }
                app.terminate()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if !app.isTerminated { app.forceTerminate() }
                }
            }
        }
    }

    static func stopWatching() {
        if let o = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            launchObserver = nil
        }
    }
}

//
//  WeftApp.swift
//  Weft — native macOS (SwiftUI) app entry.
//

import SwiftUI

@main
struct WeftApp: App {
    @State private var app = AppState()

    /// Launch overrides for QA, via environment variables:
    ///   WEFT_SCREEN=<key>   show one screen full-window (see `DevScreen`)
    ///   WEFT_SCREEN=gallery show the dev gallery sidebar
    /// With neither set, the app boots into the real sign-in → role → flow.
    private var launchOverride: LaunchMode {
        let raw = ProcessInfo.processInfo.environment["WEFT_SCREEN"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if raw.isEmpty { return .normal }
        if raw.lowercased() == "gallery" { return .gallery }
        if let screen = DevScreen.match(raw) { return .screen(screen) }
        return .normal
    }

    enum LaunchMode { case normal, gallery, screen(DevScreen) }

    var body: some Scene {
        WindowGroup {
            Group {
                switch launchOverride {
                case .normal:        RootView()
                case .gallery:       DevGalleryView()
                case .screen(let s): s.view
                }
            }
            .environment(app)
            .preferredColorScheme(.light)   // Weft's identity is light
            .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 820)
        .commands {
            // Trim Mac menus that don't apply to a single-window exam app, and
            // add an account command.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                if app.role != nil {
                    Divider()
                    Button("Sign Out") { app.signOut() }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// Top-level router between sign-in / teacher / student.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.route {
            case .signIn:  SignInView()
            case .teacher: TeacherHomeView()
            case .student: StudentFlowView()
            }
        }
        .animation(.smooth(duration: 0.28), value: app.route)
    }
}

/// Sub-router for the student role: home / join / pre-exam checks / exam /
/// done / returned work. Driven by `AppState.studentScreen`.
struct StudentFlowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.studentScreen {
            case .home:     StudentClassHomeView()
            case .join:     StudentJoinView()
            case .checks:   StudentChecksView()
            case .exam:     ExamView(lockdown: true)
            case .done:     StudentDoneView()
            case .returned: ReturnedWorkView()
            }
        }
        .animation(.smooth(duration: 0.28), value: app.studentScreen)
    }
}

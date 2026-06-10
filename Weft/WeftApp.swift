//
//  WeftApp.swift
//  Weft — native macOS (SwiftUI) app entry.
//

import SwiftUI
import AppKit

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
            .onOpenURL { url in
                // weft://exam|join|work|home links (from the /open redirector or
                // an email). The OAuth callback is filtered out inside the handler.
                NSApp.activate(ignoringOtherApps: true)
                app.handleDeepLink(url)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 820)
        .commands {
            // Trim Mac menus that don't apply to a single-window exam app, and
            // add an account command.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                if app.signedIn {
                    Divider()
                    if app.canChooseView, app.route != .signIn {
                        Button("Switch View") { app.switchView() }
                    }
                    Button("Sign Out") { app.signOut() }
                } else if app.role != nil {
                    Divider()
                    Button("Exit Preview") { app.signOut() }
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
            case .teacher: TeacherFlowView()
            case .student: StudentFlowView()
            }
        }
        .animation(.smooth(duration: 0.28), value: app.route)
    }
}

/// Sub-router for the teacher role: home (build/live), assignment editor,
/// grading, and class roster. Driven by `AppState.teacherScreen`.
struct TeacherFlowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.teacherScreen {
            case .home:    TeacherHomeView()
            case .editor:  AssignmentEditorView()
            case .grading: ReviewGradingView()
            case .roster:  TeacherRosterView()
            }
        }
        .animation(.smooth(duration: 0.28), value: app.teacherScreen)
    }
}

/// Sub-router for the student role: home / join / pre-exam checks / exam /
/// done / returned work. Driven by `AppState.studentScreen`.
struct StudentFlowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.studentScreen {
            case .home:      StudentClassHomeView()
            case .join:      StudentJoinView()
            case .checks:    StudentChecksView()
            case .exam:      ExamView(lockdown: true)
            case .done:      StudentDoneView()
            case .returned:  ReturnedWorkView()
            case .submitted: SubmittedWorkView()
            }
        }
        .animation(.smooth(duration: 0.28), value: app.studentScreen)
    }
}

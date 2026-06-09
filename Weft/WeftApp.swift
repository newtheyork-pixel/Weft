//
//  WeftApp.swift
//  Weft — native macOS (SwiftUI) app entry.
//

import SwiftUI

@main
struct WeftApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            // TEMP dev scaffolding: browse every screen while flows are wired.
            // Swap back to RootView() once navigation between screens is done.
            DevGalleryView()
                .environment(app)
                .preferredColorScheme(.light)   // Weft's identity is light
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 800)
    }
}

/// Top-level router between sign-in / teacher / student.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.route {
        case .signIn:  SignInView()
        case .teacher: TeacherHomeView()
        case .student: StudentClassHomeView()
        }
    }
}

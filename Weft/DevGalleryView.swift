//
//  DevGalleryView.swift
//  Weft — TEMPORARY dev scaffolding: a sidebar to browse every screen in the
//  running app while flows are still being wired. Replaced by RootView's real
//  routing once navigation between screens is complete.
//

import SwiftUI

struct DevGalleryView: View {
    @Environment(AppState.self) private var app

    enum Screen: String, CaseIterable, Identifiable {
        case signIn      = "Sign in"
        case studentHome = "Student · Class home"
        case join        = "Student · Join a class"
        case checks      = "Student · Pre-exam + privacy"
        case exam        = "Student · Exam (writing)"
        case done        = "Student · Done + ledger"
        case returned    = "Student · Returned work"
        case teacher     = "Teacher · Build / Live"
        case templates   = "Teacher · Templates"
        case editor      = "Teacher · Assignment editor"
        case grading     = "Teacher · Grading"
        var id: String { rawValue }
    }

    @State private var screen: Screen? = .signIn

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                Section("Weft (dev gallery)") {
                    ForEach(Screen.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .id(screen)
        }
    }

    @ViewBuilder private var detail: some View {
        switch screen ?? .signIn {
        case .signIn:      SignInView()
        case .studentHome: StudentClassHomeView()
        case .join:        StudentJoinView()
        case .checks:      StudentChecksView()
        case .exam:        ExamView()
        case .done:        StudentDoneView()
        case .returned:    ReturnedWorkView()
        case .teacher:     TeacherHomeView()
        case .templates:   TemplatePickerView()
        case .editor:      AssignmentEditorView()
        case .grading:     ReviewGradingView()
        }
    }
}

#Preview {
    DevGalleryView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

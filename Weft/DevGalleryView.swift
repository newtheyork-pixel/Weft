//
//  DevGalleryView.swift
//  Weft — TEMPORARY dev scaffolding: a sidebar to browse every screen in the
//  running app while flows are still being wired. Replaced by RootView's real
//  routing once navigation between screens is complete.
//

import SwiftUI

/// Canonical list of every screen in the app. Drives both the dev gallery
/// sidebar and the WEFT_SCREEN launch hook (see `WeftApp`).
enum DevScreen: String, CaseIterable, Identifiable {
    case signIn
    case studentHome
    case join
    case checks
    case exam
    case done
    case blocked
    case recovery
    case returned
    case teacher
    case templates
    case editor
    case grading

    var id: String { rawValue }

    /// Human label shown in the gallery sidebar.
    var title: String {
        switch self {
        case .signIn:      return "Sign in"
        case .studentHome: return "Student · Class home"
        case .join:        return "Student · Join a class"
        case .checks:      return "Student · Pre-exam + privacy"
        case .exam:        return "Student · Exam (writing)"
        case .done:        return "Student · Done + ledger"
        case .blocked:     return "Student · Blocked (sharing)"
        case .recovery:    return "Student · Recovery prompt"
        case .returned:    return "Student · Returned work"
        case .teacher:     return "Teacher · Classes"
        case .templates:   return "Teacher · Templates"
        case .editor:      return "Teacher · Assignment editor"
        case .grading:     return "Teacher · Grading"
        }
    }

    /// Extra short aliases accepted by WEFT_SCREEN (the raw case name always
    /// works too, e.g. WEFT_SCREEN=studentHome or WEFT_SCREEN=home).
    var aliases: [String] {
        switch self {
        case .signIn:      return ["signin", "login"]
        case .studentHome: return ["home", "studenthome", "classhome"]
        case .join:        return ["join"]
        case .checks:      return ["checks", "precheck", "privacy"]
        case .exam:        return ["exam", "writing", "write"]
        case .done:        return ["done", "ledger", "submitted"]
        case .blocked:     return ["blocked", "sharing"]
        case .recovery:    return ["recovery", "recover"]
        case .returned:    return ["returned", "feedback"]
        case .teacher:     return ["teacher", "build", "live"]
        case .templates:   return ["templates", "template"]
        case .editor:      return ["editor", "assignment"]
        case .grading:     return ["grading", "grade", "review"]
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .signIn:      SignInView()
        case .studentHome: StudentClassHomeView()
        case .join:        StudentJoinView()
        case .checks:      StudentChecksView()
        case .exam:        ExamView()
        case .done:        StudentDoneView()
        case .blocked:     StudentBlockedView()
        case .recovery:    RecoveryPromptView()
        case .returned:    ReturnedWorkView()
        case .teacher:     TeacherHomeView()
        case .templates:   TemplatePickerView()
        case .editor:      AssignmentEditorView()
        case .grading:     ReviewGradingView()
        }
    }

    /// Resolve a WEFT_SCREEN value (case-insensitive) to a screen.
    static func match(_ raw: String) -> DevScreen? {
        let q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return allCases.first { $0.rawValue.lowercased() == q || $0.aliases.contains(q) }
    }
}

struct DevGalleryView: View {
    @State private var screen: DevScreen? = .signIn

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                Section("Weft (dev gallery)") {
                    ForEach(DevScreen.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            (screen ?? .signIn).view
                .id(screen)
        }
    }
}

#Preview {
    DevGalleryView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

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
    case examCarried
    case breath
    case done
    case blocked
    case recovery
    case returned
    case teacher
    case templates
    case editor
    case editorDraft
    case grading
    case keyGuard

    var id: String { rawValue }

    /// Human label shown in the gallery sidebar.
    var title: String {
        switch self {
        case .signIn:      return "Sign in"
        case .studentHome: return "Student · Class home"
        case .join:        return "Student · Join a class"
        case .checks:      return "Student · Pre-exam + privacy"
        case .exam:        return "Student · Exam (writing)"
        case .examCarried: return "Student · Exam (Draft 2, carried forward)"
        case .breath: return "Student · Breathing guide"
        case .done:        return "Student · Done + ledger"
        case .blocked:     return "Student · Blocked (sharing)"
        case .recovery:    return "Student · Recovery prompt"
        case .returned:    return "Student · Returned work"
        case .teacher:     return "Teacher · Classes"
        case .templates:   return "Teacher · Templates"
        case .editor:      return "Teacher · Assignment editor"
        case .editorDraft: return "Teacher · Assignment editor (Draft 2)"
        case .grading:     return "Teacher · Grading"
        case .keyGuard:    return "Dev · Key guard tester"
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
        case .examCarried: return ["carried", "carry", "examcarried"]
        case .breath: return ["breath", "breathe", "calm"]
        case .done:        return ["done", "ledger", "submitted"]
        case .blocked:     return ["blocked", "sharing"]
        case .recovery:    return ["recovery", "recover"]
        case .returned:    return ["returned", "feedback"]
        case .teacher:     return ["teacher", "build", "live"]
        case .templates:   return ["templates", "template"]
        case .editor:      return ["editor", "assignment"]
        case .editorDraft: return ["editordraft", "draft2"]
        case .grading:     return ["grading", "grade", "review"]
        case .keyGuard:    return ["keyguard", "keys"]
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .signIn:      SignInView()
        case .studentHome: StudentClassHomeView()
        case .join:        StudentJoinView()
        case .checks:      StudentChecksView()
        case .exam:        ExamView()
        case .examCarried: ExamView(previewCarryForward: true)
        case .breath:
            ExamView().overlay {
                CalmBreathView(note: "Your time keeps running and your work is saved. Your teacher doesn't see this.") {}
            }
        case .done:        StudentDoneView()
        case .blocked:     StudentBlockedView()
        case .recovery:    RecoveryPromptView()
        case .returned:    ReturnedWorkView()
        case .teacher:     TeacherHomeView()
        case .templates:   TemplatePickerView()
        case .editor:      AssignmentEditorView()
        case .editorDraft: DraftEditorPreview()
        case .grading:     ReviewGradingView()
        case .keyGuard:    KeyGuardTesterView()
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

/// The assignment editor on a Draft 2 (SAT-5 carry-forward switch showing).
/// Stages the draft before the editor primes from `app.editingAssignment`.
private struct DraftEditorPreview: View {
    @Environment(AppState.self) private var app
    @State private var staged = false

    var body: some View {
        Group {
            if staged {
                AssignmentEditorView()
            } else {
                Color.clear.onAppear {
                    app.editingAssignment = .sampleDraft2
                    staged = true
                }
            }
        }
        .onDisappear { app.editingAssignment = nil }
    }
}

/// Dev-only harness to verify `ExamKeyGuard` in isolation — no exam, no kiosk.
/// Start the guard, then confirm: CapsLock + F13–F19 are inert while normal
/// typing is completely unaffected. Needs the Accessibility grant.
struct KeyGuardTesterView: View {
    @State private var keyGuard = ExamKeyGuard()
    @State private var running = false
    @State private var trusted = ExamKeyGuard.isTrusted
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ExamKeyGuard tester").font(.title2.bold())
            Text("Raw-key suppression in isolation (no exam needed).")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Circle().fill(trusted ? .green : .orange).frame(width: 10, height: 10)
                Text(trusted ? "Accessibility: granted" : "Accessibility: not granted")
                Button("Recheck") { trusted = ExamKeyGuard.isTrusted }
                if !trusted { Button("Request…") { ExamKeyGuard.requestTrust() } }
            }
            .font(.callout)

            HStack(spacing: 12) {
                Button(running ? "Stop guard" : "Start guard") {
                    if running { keyGuard.stop() } else { keyGuard.start() }
                    running = keyGuard.active
                    trusted = ExamKeyGuard.isTrusted
                }
                .buttonStyle(.borderedProminent)
                Text(running ? "ACTIVE — ⌘Space / Mission Control should be inert"
                             : "Stopped")
                    .foregroundStyle(running ? .green : .secondary)
            }

            Divider()
            Text("Type here — should be completely normal while the guard runs:")
            TextField("Type a sentence, toggle CapsLock, hit F13–F19…",
                      text: $typed, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3, reservesSpace: true)

            Text("""
            With the guard ACTIVE, each of these should do NOTHING:
            • ⌘Space / ⌥Space — Spotlight / Raycast / ChatGPT don't open.
            • ⌃↑ / ⌃→ — Mission Control / space-switch don't fire.
            ⌘⇧4 / ⌘⇧5 should still take a screenshot or start a recording.
            And typing stays normal: letters, numbers, the plain spacebar,
            arrows, ⌫, ⏎ all work in the box above. Stop guard → all restored.
            """)
            .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { keyGuard.stop() }   // never leave a tap installed
    }
}

#Preview {
    DevGalleryView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

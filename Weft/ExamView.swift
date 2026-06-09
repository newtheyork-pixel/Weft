//
//  ExamView.swift
//  Weft — the in-exam writing workspace. A native, resizable two-pane layout:
//  the writing surface on the left and a reference column on the right that the
//  student arranges themselves — PDFs, the approved web links, or both at once
//  (a VSplitView), or collapsed entirely for a distraction-free write-only view.
//
//  When `lockdown` is true (the real student flow) this also drives the full
//  exam lifecycle: KioskController locks the window, a ProctoringEngine monitor
//  re-sweeps every few seconds, and a blackout overlay covers the screen if
//  screen-sharing software appears or the student leaves the window. With
//  `lockdown` false (dev gallery / WEFT_SCREEN QA) it's an inert preview.
//

import SwiftUI
import AppKit

/// Reference-typed exam runtime so kiosk callbacks and the monitor task can
/// mutate UI state from escaping closures (a struct View's @State can't be
/// captured for write). Observed by SwiftUI.
@MainActor
@Observable
final class ExamRuntime {
    enum Block: Equatable { case sharing(String), focusLost }

    var block: Block?
    var saveState: SaveState = .saved

    enum SaveState: Equatable { case saving, saved }
}

struct ExamView: View {
    /// True only in the real student flow. Gates the kiosk lock + monitor so QA
    /// previews don't take over the screen.
    var lockdown: Bool = false

    @Environment(AppState.self) private var app

    @State private var controller = RichTextController()
    @State private var essay = NSAttributedString(
        string: "The interplay of light and shadow in the passage works as more than scenery. The author returns to dawn three times, each marking a shift in the narrator's certainty about what she has seen.")
    @State private var wordCount = 26
    @State private var referencesVisible = true

    @State private var runtime = ExamRuntime()
    @State private var kiosk = KioskController()
    @State private var examWindow: NSWindow?
    @State private var kioskEntered = false
    @State private var deadline: Date?
    @State private var saveDebounce: Task<Void, Never>?
    @State private var monitorTask: Task<Void, Never>?

    private var assignment: Assignment { app.activeAssignment ?? .sample }
    private var prompt: String {
        assignment.questions.first?.prompt ?? Assignment.sample.questions.first?.prompt ?? "Respond to the prompt."
    }
    private var wordLimit: Int? { assignment.questions.first?.wordLimit }

    var body: some View {
        HSplitView {
            editorColumn
                .frame(minWidth: 380)
            if referencesVisible {
                ExamReferencePanel(
                    files: app.examFiles,
                    links: app.examLinks,
                    signedIn: app.signedIn,
                    onHide: { toggleReferences() }
                )
                .frame(minWidth: 320, idealWidth: 460)
            }
        }
        .background(Color(white: 0.97))
        .overlay(alignment: .bottomTrailing) { proctoringChip.padding(20) }
        .overlay { blackout }
        .animation(.easeOut(duration: 0.2), value: runtime.block)
        .onWindow { window in
            guard lockdown, let window, examWindow !== window else { return }
            startExam(in: window)
        }
        .task {
            if deadline == nil {
                let minutes = assignment.timeLimitMinutes ?? 45
                deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
            }
        }
        .onDisappear { endExam() }
    }

    // MARK: Lifecycle

    private func startExam(in window: NSWindow) {
        examWindow = window
        kioskEntered = true
        kiosk.onBlackout = { [runtime] in
            if runtime.block == nil { runtime.block = .focusLost }
        }
        kiosk.enterKiosk(window: window)
        monitorTask?.cancel()
        monitorTask = Task { await monitorLoop() }
    }

    private func endExam() {
        monitorTask?.cancel()
        monitorTask = nil
        saveDebounce?.cancel()
        guard kioskEntered, let window = examWindow else { return }
        kiosk.exitKiosk(window: window)
        kioskEntered = false
    }

    private func resumeFromFocusLoss() {
        runtime.block = nil
        examWindow?.makeKeyAndOrderFront(nil)
    }

    /// Re-sweep proctoring every few seconds. Owned by `monitorTask`, started in
    /// startExam and cancelled in endExam so it never outlives the kiosk lock.
    /// Only the screen-share/remote signals drive the blackout here; focus loss
    /// is handled by the kiosk `onBlackout` hook and `.focusLost` takes precedence.
    private func monitorLoop() async {
        let engine = ProctoringEngine()
        while !Task.isCancelled {
            let report = await engine.runChecks(teacherIP: nil)
            if report.screenCapture || report.remote {
                let name = report.detectedApps.first ?? report.remoteReason ?? "screen-sharing software"
                if runtime.block == nil || isSharing(runtime.block) {
                    runtime.block = .sharing(name)
                }
            } else if isSharing(runtime.block) {
                runtime.block = nil
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func isSharing(_ block: ExamRuntime.Block?) -> Bool {
        if case .sharing = block { return true }
        return false
    }

    private func toggleReferences() {
        withAnimation(.easeInOut(duration: 0.22)) { referencesVisible.toggle() }
    }

    private func submit() {
        endExam()
        app.finishExam()
    }

    private func leave() {
        endExam()
        app.goToHome()
    }

    // MARK: Blackout overlay
    @ViewBuilder private var blackout: some View {
        switch runtime.block {
        case .sharing(let name):
            StudentBlockedView(
                title: "Writing paused",
                message: "Screen-sharing software was detected on this machine:",
                detail: name,
                footnote: "Close it and your writing will resume automatically. Your teacher has been notified.",
                submitTitle: "Can't close it? Submit and exit",
                onSubmit: submit
            )
            .transition(.opacity)
        case .focusLost:
            StudentBlockedView(
                title: "Return to your exam",
                message: "You left the exam window. Weft brought it back to the front.",
                detail: nil,
                footnote: "Leaving the exam is logged for your teacher. Resume when you're ready.",
                submitTitle: "Resume writing",
                onSubmit: resumeFromFocusLoss
            )
            .transition(.opacity)
        case .none:
            EmptyView()
        }
    }

    // MARK: Editor column
    private var editorColumn: some View {
        VStack(spacing: 0) {
            header
            toolbarRow
            RichTextEditor(text: $essay, wordCount: $wordCount, controller: controller)
                .background(Color.white)
                .padding(.horizontal, Theme.Space.xl)
                .onChange(of: essay) { _, _ in scheduleSave() }
            footerBar
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.96))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Kicker(text: "Writing prompt")
                Text(prompt)
                    .font(Theme.serif(20, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            countdown
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.md)
    }

    @ViewBuilder private var countdown: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
                Label {
                    Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
                .foregroundStyle(remaining < 300 ? Theme.warn : Theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background((remaining < 300 ? Theme.warn : Theme.accent).opacity(0.10), in: Capsule())
                .help("Time remaining")
            }
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: Theme.Space.md) {
            RichTextToolbar(controller: controller)
            Spacer()
            wordCountView
            Button {
                toggleReferences()
            } label: {
                Image(systemName: referencesVisible ? "sidebar.right" : "sidebar.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help(referencesVisible ? "Hide references — write only (⌘⇧R)" : "Show references (⌘⇧R)")
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.sm)
    }

    private var wordCountView: some View {
        Group {
            if let limit = wordLimit {
                let over = wordCount > limit
                Text("\(wordCount) / \(limit) words")
                    .foregroundStyle(over ? Theme.warn : Theme.muted)
            } else {
                Text("\(wordCount) words")
                    .foregroundStyle(Theme.muted)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .monospacedDigit()
        .help("Word count")
    }

    private var footerBar: some View {
        HStack {
            Button(lockdown ? "Submit and exit" : "Back") {
                if lockdown { submit() } else { leave() }
            }
            .buttonStyle(.glass)
            Spacer()
            saveStateView
            Spacer()
            Button("Submit") { submit() }
                .buttonStyle(.glassProminent).tint(Theme.accent)
                .keyboardShortcut("\r", modifiers: [.command])
        }
        .padding(Theme.Space.xl)
    }

    private var saveStateView: some View {
        HStack(spacing: 6) {
            if runtime.saveState == .saving {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Saving…")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                Text("All saved")
            }
        }
        .font(Theme.sans(12.5))
        .foregroundStyle(Theme.muted)
    }

    // MARK: Autosave (debounced stub — real PostgREST write lands with the
    // session/submission wave; this drives the honest "Saving…/All saved" label)
    private func scheduleSave() {
        runtime.saveState = .saving
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { runtime.saveState = .saved }
        }
    }

    // MARK: Proctoring chip
    private var proctoringChip: some View {
        HStack(spacing: 7) {
            Circle().fill(lockdown ? Theme.good : Theme.muted2).frame(width: 8, height: 8)
            Text(lockdown ? "Proctoring on" : "Proctoring off (preview)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

#Preview {
    ExamView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1180, height: 780)
}

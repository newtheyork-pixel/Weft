//
//  ExamView.swift
//  Weft — the in-exam writing workspace. A native, resizable two-pane layout:
//  the writing surface on the left and a reference area on the right where
//  every teacher PDF and approved website is a browser-style tab (with an
//  optional split pinning one material above another), or collapsed entirely
//  for a distraction-free write-only view.
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

    enum SaveState: Equatable { case saving, saved, failed }
}

struct ExamView: View {
    /// True only in the real student flow. Gates the kiosk lock + monitor so QA
    /// previews don't take over the screen.
    var lockdown: Bool = false

    @Environment(AppState.self) private var app

    @State private var controller = RichTextController()
    private var wordCount: Int { controller.wordCount }
    /// Owned here, not by the panel: hiding references (⌘⇧R) unmounts the
    /// panel, and the store carries the loaded PDFs, tab/pin/visited state,
    /// and divider position across that. (The web views themselves are torn
    /// down with the panel; full keep-alive would need zero-width mounting
    /// under HSplitView and isn't worth it yet.)
    @State private var refStore = ReferenceTabStore()
    @State private var referencesVisible = true
    @State private var expiryTask: Task<Void, Never>?
    @State private var didSeedPreview = false

    /// Filler text shown ONLY in the preview/gallery (lockdown == false) so the
    /// screen reads as a real writing session for QA. A real exam starts blank.
    private let previewEssay = "The interplay of light and shadow in the passage works as more than scenery. The author returns to dawn three times, each marking a shift in the narrator's certainty about what she has seen."

    @State private var runtime = ExamRuntime()
    @State private var kiosk = KioskController()
    @State private var examWindow: NSWindow?
    @State private var kioskEntered = false
    @State private var deadline: Date?
    /// Flipped at 0:00 (real exams): freezes the editor and keeps the force-
    /// submit retrying until the flush lands. The deadline must be enforced,
    /// not merely displayed.
    @State private var expired = false
    @State private var saveDebounce: Task<Void, Never>?
    /// Monotonic save-pipeline generation: each new edit (and exam teardown)
    /// bumps it, and a persist/retry whose generation is stale exits instead
    /// of spawning a successor — Task cancellation alone can't reach a
    /// non-cooperative await mid-flight, so two loops could otherwise coexist.
    @State private var saveGeneration = 0
    @State private var monitorTask: Task<Void, Never>?
    @State private var showSubmitConfirm = false
    /// Non-nil when the student tries to submit while over the word limit (manual
    /// path only). Displayed near the footer and cleared automatically when the
    /// count drops back to or below the limit. The 0:00 force-submit bypasses
    /// this — the deadline always wins.
    @State private var overLimitMessage: String?
    @AppStorage(Prefs.confirmBeforeSubmit) private var confirmBeforeSubmit = true

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
                    store: refStore,
                    onHide: { toggleReferences() }
                )
                .frame(minWidth: 320, idealWidth: 460)
            }
        }
        .background(Color(white: 0.97))
        .overlay(alignment: .bottomTrailing) { proctoringChip.padding(20) }
        .overlay { blackout }
        .animation(.easeOut(duration: 0.2), value: runtime.block)
        .confirmationDialog("Submit your exam?", isPresented: $showSubmitConfirm, titleVisibility: .visible) {
            Button("Submit exam", role: .destructive) { submit() }
            Button("Keep writing", role: .cancel) { }
        } message: {
            Text("You wrote \(wordCount) word\(wordCount == 1 ? "" : "s"). Once you submit, the exam ends and monitoring stops. You can't keep writing after this.")
        }
        .onWindow { window in
            guard lockdown, let window, examWindow !== window else { return }
            startExam(in: window)
        }
        .task {
            if deadline == nil {
                let minutes = assignment.timeLimitMinutes ?? 45
                deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
            }
            // Seed filler text in preview only; a real exam starts blank.
            if !lockdown && !didSeedPreview {
                didSeedPreview = true
                controller.setContent(NSAttributedString(
                    string: previewEssay,
                    attributes: RichTextStyle.body.attributes()))
            }
            armExpiry()
        }
        .onDisappear { endExam() }
    }

    /// Auto-submit when the clock reaches 0:00 (real exams only). A hard time
    /// limit must be enforced, not merely displayed; force-submit bypasses the
    /// confirm dialog since "keep writing" is no longer an option.
    private func armExpiry() {
        guard lockdown, let deadline, expiryTask == nil else { return }
        let interval = deadline.timeIntervalSinceNow
        expiryTask = Task {
            if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }
            if !Task.isCancelled {
                expired = true
                submit()
            }
        }
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
        armExpiry()
    }

    private func endExam() {
        monitorTask?.cancel()
        monitorTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        saveDebounce?.cancel()
        saveGeneration += 1
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

    /// Entry point for the Submit buttons: refuse while over the word limit
    /// (the 0:00 force-submit bypasses this — the deadline always wins), then
    /// confirm if the preference is on.
    private func requestSubmit() {
        if let limit = wordLimit, wordCount > limit {
            overLimitMessage = "Over the word limit (\(wordCount) / \(limit) words). Shorten your essay before submitting."
            return
        }
        overLimitMessage = nil
        if confirmBeforeSubmit {
            showSubmitConfirm = true
        } else {
            submit()
        }
    }

    /// Submit = final flush (must succeed) -> DB lock -> leave the exam. A
    /// failed flush keeps the student in the exam with the failed-save label;
    /// their work is intact and Submit can be pressed again.
    private func submit() {
        Task {
            guard await app.submitExam(html: controller.htmlSnapshot(),
                                       wordCount: controller.wordCount) else {
                runtime.saveState = .failed
                // Past the hard deadline nothing else would ever fire (the
                // expiry task has completed): keep force-submitting so the
                // exam closes the moment the network returns.
                if lockdown && expired {
                    expiryTask = Task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        submit()
                    }
                } else {
                    // Before the deadline, make the failed-save label's
                    // promise true: keep persisting so the content is durable
                    // by the time the student presses Submit again.
                    saveGeneration += 1
                    let gen = saveGeneration
                    saveDebounce?.cancel()
                    saveDebounce = Task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        await persistNow(generation: gen)
                    }
                }
                return
            }
            endExam()
            app.finishExam()
        }
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
            RichTextEditor(controller: controller, isEditable: !expired,
                           spellcheckEnabled: assignment.spellcheckEnabled,
                           onEdit: { scheduleSave() })
                .background(Color.white)
                .padding(.horizontal, Theme.Space.xl)
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
            .help(referencesVisible ? "Hide references, write only (⌘⇧R)" : "Show references (⌘⇧R)")
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
        VStack(spacing: 0) {
            // Over-limit error banner: shown between the editor and the submit
            // buttons so it reads as a direct gate on the action. Cleared
            // automatically when wordCount drops to/below the limit.
            if let msg = overLimitMessage {
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text(msg)
                        .font(Theme.sans(13, .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.bad)
                .padding(.vertical, 10)
                .padding(.horizontal, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bad.opacity(0.08))
                .transition(.opacity)
            }
            HStack {
                Button(lockdown ? "Submit and exit" : "Back") {
                    if lockdown { requestSubmit() } else { leave() }
                }
                .buttonStyle(.glass)
                Spacer()
                saveStateView
                Spacer()
                Button("Submit") { requestSubmit() }
                    .buttonStyle(.glassProminent).tint(Theme.accent)
                    .keyboardShortcut("\r", modifiers: [.command])
            }
            .padding(Theme.Space.xl)
        }
        .animation(.easeOut(duration: 0.18), value: overLimitMessage)
        .onChange(of: wordCount) { _, newCount in
            // Auto-clear the over-limit message once the student has shortened
            // their essay to at or below the limit so it doesn't linger.
            if overLimitMessage != nil, newCount <= (wordLimit ?? Int.max) {
                overLimitMessage = nil
            }
        }
    }

    private var saveStateView: some View {
        HStack(spacing: 6) {
            if runtime.saveState == .saving {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Saving…")
            } else if runtime.saveState == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text("Save failed, retrying…")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                Text("All saved")
            }
        }
        .font(Theme.sans(12.5))
        .foregroundStyle(Theme.muted)
    }

    // MARK: Autosave
    /// Debounce (0.8s) then persist. A failed save retries every 4s until a
    /// newer edit reschedules it (Electron parity); the label tells the truth.
    private func scheduleSave() {
        runtime.saveState = .saving
        saveGeneration += 1
        let gen = saveGeneration
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await persistNow(generation: gen)
        }
    }

    private func persistNow(generation: Int) async {
        let ok = await app.autosaveEssay(html: controller.htmlSnapshot(),
                                         wordCount: controller.wordCount)
        guard generation == saveGeneration else { return }   // a newer edit owns the pipeline
        if ok {
            runtime.saveState = .saved
        } else {
            runtime.saveState = .failed
            saveDebounce = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await persistNow(generation: generation)
            }
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

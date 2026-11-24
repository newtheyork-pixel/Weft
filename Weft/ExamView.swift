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
//  remote-control software appears or the student leaves the window. Local
//  screenshots and screen recordings are allowed. With `lockdown` false
//  (dev gallery / WEFT_SCREEN QA) it's an inert preview.
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
    /// Preview only (dev gallery): show a Draft 2 that starts from the
    /// student's returned Draft 1 (SAT-5) instead of the filler essay.
    var previewCarryForward: Bool = false

    @Environment(AppState.self) private var app

    @State private var controller = RichTextController()
    private var wordCount: Int { controller.wordCount }
    /// Owned here, not by the panel: hiding references (⌘⇧R) unmounts the
    /// panel, and the store carries the loaded documents, the live web tabs
    /// (with their pages and logins), tab/pin/visited state and the divider
    /// position across that, so showing the panel again reloads nothing.
    @State private var refStore = ReferenceTabStore()
    @State private var referencesVisible = true
    @State private var expiryTask: Task<Void, Never>?
    @State private var countdownAnchor = Date()
    @State private var draftReady = false
    @State private var didSeedPreview = false
    @State private var lastSavedHTML: String?
    /// One calm line about carry forward (SAT-5), shown above the editor
    /// until the student hides it.
    @State private var carryNote: String?

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
    /// True while a submit is in flight. Several independent triggers (footer
    /// Submit, ⌘Return, the confirm dialog, "Submit and exit", and the 0:00
    /// auto-submit) can otherwise fire submit() concurrently; the second call
    /// would re-enter submitExam() after the first nilled the session, see a
    /// false failure, flip to "Save failed", and schedule a non-terminating
    /// retry loop. This guard makes submit() single-flight.
    @State private var submitting = false
    @AppStorage(Prefs.confirmBeforeSubmit) private var confirmBeforeSubmit = true
    /// The student chose to hide the clock. It comes back on its own for the
    /// last five minutes, so hiding it can never catch anyone out.
    @AppStorage(Prefs.hideExamTimer) private var hideTimer = false
    /// The guided breath is covering the exam.
    @State private var showBreath = false
    /// Seconds left at which a hidden clock shows itself again.
    private static let timerReturnsAt = 300
    /// Narrowest the writing column may get (see body).
    private static let editorMinWidth: CGFloat = 720

    private var assignment: Assignment { app.activeAssignment ?? .sample }
    private var prompt: String {
        assignment.questions.first?.prompt ?? Assignment.sample.questions.first?.prompt ?? "Respond to the prompt."
    }
    private var wordLimit: Int? { assignment.questions.first?.wordLimit }

    var body: some View {
        HSplitView {
            // Wide enough for the formatting bar, word count and clock: any
            // narrower and the column's content overflows past the window
            // edges (Back and Submit were clipped, "Body" wrapped).
            editorColumn
                .frame(minWidth: Self.editorMinWidth)
            if referencesVisible {
                ExamReferencePanel(
                    files: app.examReferenceFiles,
                    links: app.examLinks,
                    signedIn: app.signedIn,
                    materialsLoading: app.examMaterialsLoading,
                    materialsFailed: app.examMaterialsFailed,
                    store: refStore,
                    onHide: { toggleReferences() },
                    onRetryMaterials: { Task { await app.retryExamMaterials() } },
                    onInsertQuote: { text, cite in
                        // Locked while submitting or after time is up: the
                        // quote must not land after the submit snapshot.
                        guard controller.insertQuote(text, citation: cite) else {
                            if expired {
                                refStore.post(notice: "Time is up. Your essay can't be changed.")
                            } else if submitting {
                                refStore.post(notice: "Your essay is locked while it's being submitted.")
                            }
                            return
                        }
                        refStore.post(notice: "Quoted into your essay.")
                        scheduleSave()
                        app.markWriting()
                    }
                )
                // Equatable: a save-state or word-count change invalidates this
                // body on every keystroke, and the panel must not be rebuilt
                // for it.
                .equatable()
                .frame(minWidth: 320, idealWidth: 460)
            }
        }
        .background(Color(white: 0.97))
        .overlay(alignment: .bottomTrailing) { proctoringChip.padding(20) }
        .overlay {
            if showBreath {
                CalmBreathView(note: "Your time keeps running and your work is saved. Your teacher doesn't see this.") {
                    closeBreath()
                }
                .transition(.opacity)
            }
        }
        .overlay { blackout }
        .animation(.easeOut(duration: 0.25), value: showBreath)
        // Time's up (or the teacher ended the session): never leave the
        // student behind the breathing guide while the exam closes.
        .onChange(of: expired) { _, isExpired in
            if isExpired { showBreath = false }
        }
        .animation(.easeOut(duration: 0.2), value: runtime.block)
        .confirmationDialog("Submit your exam?", isPresented: $showSubmitConfirm, titleVisibility: .visible) {
            Button("Submit exam", role: .destructive) { submit(enforcingWordLimit: true) }
            Button("Keep writing", role: .cancel) { }
        } message: {
            // Own view so the live count does not track on ExamView.body.
            SubmitCountMessage(controller: controller)
        }
        .onWindow { window in
            guard lockdown, let window, examWindow !== window else { return }
            startExam(in: window)
        }
        .task {
            if lockdown {
                deadline = app.examDeadline
                countdownAnchor = Date()
                let carried = app.examDraftCarried
                if let html = app.examDraftHTML, !html.isEmpty {
                    controller.setContent(RichTextHTML.attributed(fromHTML: html))
                    // A carried-forward draft isn't saved for this draft yet.
                    lastSavedHTML = carried ? "" : html
                } else {
                    lastSavedHTML = ""
                }
                carryNote = app.examCarryNote
                app.examDraftHTML = nil
                app.examDraftCarried = false
                app.examCarryNote = nil
                draftReady = true
                // Save the carried text now, through the normal sealed
                // autosave, so this draft holds it from the first second.
                if carried { scheduleSave() }
            } else if deadline == nil {
                deadline = Date().addingTimeInterval(45 * 60)
                countdownAnchor = Date()
                draftReady = true
            }
            if !lockdown && !didSeedPreview {
                didSeedPreview = true
                if previewCarryForward {
                    controller.setContent(RichTextHTML.attributed(
                        fromHTML: CarryForwardPreview.draft1HTML))
                    carryNote = AppState.carriedNote(version: 1)
                } else {
                    controller.setContent(NSAttributedString(
                        string: previewEssay,
                        attributes: RichTextStyle.body.attributes()))
                }
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
        kiosk.onBlackout = { [runtime, app] in
            if runtime.block == nil { runtime.block = .focusLost }
            app.noteExamFocusLoss()
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
        // Reference downloads and live web tabs belong to the exam, not to the
        // panel: they are only torn down here, never when references are hidden.
        refStore.endExam()
        guard kioskEntered, let window = examWindow else { return }
        kiosk.exitKiosk(window: window)
        kioskEntered = false
    }

    private func resumeFromFocusLoss() {
        runtime.block = nil
        app.resumeExamFocus()
        examWindow?.makeKeyAndOrderFront(nil)
    }

    /// Re-sweep proctoring every few seconds. Owned by `monitorTask`, started in
    /// startExam and cancelled in endExam so it never outlives the kiosk lock.
    /// Only the screen-share/remote signals drive the blackout here; focus loss
    /// is handled by the kiosk `onBlackout` hook and `.focusLost` takes precedence.
    ///
    /// The same tick asks whether the session is still open. Ending a session
    /// used to leave every student typing into a row the server would freeze
    /// (or, before the window trigger, keep accepting), with no way out of
    /// the kiosk except the 0:00 path. Force-submit is the same path as the
    /// bell, so a failed flush still retries until it lands.
    private func monitorLoop() async {
        let engine = ProctoringEngine()
        while !Task.isCancelled {
            let report = await engine.runChecks(teacherIP: nil)
            // Pause only for remote-control / live screen-sharing (someone else
            // driving or watching this Mac). Local recording and conferencing
            // apps are a teacher-facing note, not a writing blackout — otherwise
            // QuickTime, ⌘⇧5, Loom, or Slack in the background make the exam
            // untakeable.
            if report.remote {
                let name = report.detectedApps.first ?? report.remoteReason ?? "screen-sharing software"
                if runtime.block == nil || isSharing(runtime.block) {
                    runtime.block = .sharing(name)
                }
            } else if isSharing(runtime.block) {
                runtime.block = nil
            }
            app.reportProctoring(report)
            if !expired, !submitting {
                do {
                    if try await app.examSessionStillOpen() == false {
                        deadline = Date()
                        expired = true
                        submit()
                    }
                } catch {
                    // Transport blip: the next tick retries. Treating a 502
                    // as the bell would submit a class during a cold start.
                }
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
        // The published count trails typing by the recount debounce, so a
        // word added (or removed) just before Submit would be judged against
        // the old count. Recount the live document now; this also makes the
        // confirmation dialog show what will actually be submitted.
        controller.recountWords()
        // Past 0:00 the editor is frozen, so "shorten your essay" would be an
        // impossible instruction — the deadline always wins over the limit.
        if !expired, let limit = wordLimit, wordCount > limit {
            overLimitMessage = overLimitText(count: wordCount, limit: limit)
            return
        }
        overLimitMessage = nil
        if confirmBeforeSubmit {
            showSubmitConfirm = true
        } else {
            submit(enforcingWordLimit: true)
        }
    }

    private func overLimitText(count: Int, limit: Int) -> String {
        "Over the word limit (\(count) / \(limit) words). Shorten your essay before submitting."
    }

    /// Submit = freeze editor -> final flush (must succeed) -> DB lock ->
    /// leave the exam. A failed flush keeps the student in the exam with the
    /// failed-save label and unfreezes the editor (unless time is up); their
    /// work is intact and Submit can be pressed again. A retry after a lock
    /// whose reply was lost succeeds: submitExam checks the server's submitted
    /// state before flushing again (SAT-34).
    ///
    /// `enforcingWordLimit` is set by the student's Submit path: the limit is
    /// re-checked against the exact snapshot being uploaded, so text that
    /// changed after `requestSubmit` checked cannot slip past it. Deadline and
    /// session-closed submits leave it off — the deadline always wins.
    private func submit(enforcingWordLimit: Bool = false) {
        // Single-flight: only one submit may be in flight. A concurrent second
        // call (double-tap, ⌘Return + auto-submit at 0:00, etc.) would re-enter
        // submitExam() after the first nilled the session, manufacture a false
        // failure, and leak a retry loop. Stays true on the success path (the
        // view tears down); reset to false on every failure return.
        guard !submitting else { return }
        submitting = true
        // Freeze the document before the snapshot, synchronously. The editor's
        // `isEditable` also folds in `submitting`, but that only reaches the
        // text view on SwiftUI's next update, and the snapshot is taken after
        // a hop; anything typed in between would be visible on screen and
        // missing from the submission (success cancels the pending autosave).
        controller.freezeEditing()
        Task {
            let snap = await controller.htmlAndWordCountOffMain()
            // `expired` is read after the snapshot await: if the deadline fired
            // meanwhile, its own submit() was dropped by the single-flight
            // guard above, so this one must go through as the forced submit.
            if enforcingWordLimit, !expired, let limit = wordLimit, snap.wordCount > limit {
                submitting = false
                overLimitMessage = overLimitText(count: snap.wordCount, limit: limit)
                return
            }
            guard await app.submitExam(html: snap.html,
                                       wordCount: snap.wordCount) else {
                // Unfreezes the editor through `isEditable` unless `expired`.
                submitting = false
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
                opaque: true,
                onSubmit: { submit() }
            )
            .transition(.opacity)
        case .focusLost:
            StudentBlockedView(
                title: "Return to your exam",
                message: "You left the exam window. Weft brought it back to the front.",
                detail: nil,
                footnote: "Leaving the exam is logged for your teacher. Resume when you're ready.",
                submitTitle: "Resume writing",
                // Not red: red is the destructive action (Submit and exit), and
                // resuming is the calm way back to the essay.
                buttonTint: Theme.accent,
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
            if let note = carryNote { carryNoteRow(note) }
            toolbarRow
            // Locked while the breathing guide covers it, while a blackout
            // (screen-sharing detected or focus lost) is up, so "Writing
            // paused" really means paused, and while a submit is in flight,
            // so nothing typed lands after the submitted snapshot.
            RichTextEditor(controller: controller,
                           isEditable: !expired && !showBreath && runtime.block == nil && !submitting,
                           spellcheckEnabled: assignment.spellcheckEnabled,
                           onEdit: { scheduleSave(); app.markWriting() })
                .accessibilityLabel("Essay")
                .accessibilityHint(expired
                    ? "Time is up. The essay can no longer be edited."
                    : submitting
                        ? "Submitting. The essay can't be edited right now."
                        : runtime.block != nil
                            ? "Writing is paused. The essay can no longer be edited."
                            : "Write your response to the prompt.")
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
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            HStack(spacing: Theme.Space.sm) {
                breatheButton
                countdown
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.md)
    }

    /// Carry forward (SAT-5): one calm line, hidden with a click.
    private func carryNoteRow(_ note: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "doc.text")
                .foregroundStyle(Theme.accent)
            Text(note)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                carryNote = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(IconHitButtonStyle(minSize: 24))
            .help("Hide this note")
            .accessibilityLabel("Hide this note")
            .linkPointer()
        }
        .font(Theme.sans(13))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.accent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.sm)
    }

    private var breatheButton: some View {
        Button(action: openBreath) {
            Label("Breathe", systemImage: "wind")
                .font(Theme.sans(13, .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.accent.opacity(0.10), in: Capsule())
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plainHit)
        .disabled(expired || submitting)
        .help("Take 30 seconds to breathe. Your time keeps running.")
        .linkPointer()
    }

    private func openBreath() {
        guard !expired, !submitting else { return }
        // Typing must not land in the hidden editor behind the overlay.
        let window = controller.textView?.window ?? examWindow
        window?.makeFirstResponder(nil)
        showBreath = true
    }

    private func closeBreath() {
        showBreath = false
        if let tv = controller.textView, !expired {
            tv.window?.makeFirstResponder(tv)
        }
    }

    /// The clock: time left (ticking, fixed-width digits). One line only; the
    /// "Ends at" line was cut as clutter (SAT-39). VoiceOver still reads the
    /// end time.
    @ViewBuilder private var countdown: some View {
        if let deadline {
            TimelineView(.periodic(from: countdownAnchor, by: 1)) { context in
                let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
                let soon = remaining < Self.timerReturnsAt
                let hidden = hideTimer && !soon
                let tint = soon ? Theme.warn : hidden ? Theme.muted : Theme.accent
                Button {
                    // In the last five minutes the clock always shows.
                    if !soon { hideTimer.toggle() }
                } label: {
                    Group {
                        if hidden {
                            Label("Show time", systemImage: "eye")
                                .font(Theme.sans(13, .semibold))
                        } else {
                            Label {
                                Text(ExamClock.leftText(remaining: remaining))
                                    .font(.system(size: 15, weight: .semibold))
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: "clock")
                            }
                        }
                    }
                    .foregroundStyle(tint)
                    .fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(tint.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plainHit)
                .help(soon ? "Time remaining"
                      : hidden ? "Show the time left. It also comes back by itself for the last 5 minutes."
                               : "Hide the time left. It comes back by itself for the last 5 minutes.")
                .accessibilityLabel(ExamClock.spokenText(remaining: remaining, deadline: deadline,
                                                         hidden: hidden))
            }
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: Theme.Space.md) {
            RichTextToolbar(controller: controller)
                .fixedSize()
                .disabled(expired || submitting)
            Spacer()
            // Own view: a word-count publish must not rebuild this column.
            WordCountLabel(controller: controller, limit: wordLimit) { newCount in
                if overLimitMessage != nil, newCount <= (wordLimit ?? Int.max) {
                    overLimitMessage = nil
                }
            }
            Button {
                toggleReferences()
            } label: {
                Image(systemName: referencesVisible ? "sidebar.right" : "sidebar.left")
            }
            .buttonStyle(.iconHit)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help(referencesVisible ? "Hide references, write only (⌘⇧R)" : "Show references (⌘⇧R)")
            .accessibilityLabel(referencesVisible ? "Hide references" : "Show references")
            .linkPointer()
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.sm)
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
                .disabled(lockdown && submitting)
                .linkPointer()
                Spacer()
                // Own view: flipping "Saving…" must not rebuild the editor.
                SaveLabel(runtime: runtime, submitting: submitting)
                Spacer()
                Button(submitting ? "Submitting…" : "Submit") { requestSubmit() }
                    .buttonStyle(.glassProminent).tint(Theme.accent)
                    .keyboardShortcut("\r", modifiers: [.command])
                    .disabled(submitting)
                    .linkPointer()
            }
            .padding(Theme.Space.xl)
        }
        .animation(.easeOut(duration: 0.18), value: overLimitMessage)
    }

    // MARK: Autosave
    /// Debounce (0.8s) then persist. A failed save retries every 4s until a
    /// newer edit reschedules it (Electron parity); the label tells the truth.
    /// The "Saving…" flip is observed only by `SaveLabel`, so this write does
    /// not rebuild the text view.
    private func scheduleSave() {
        guard draftReady || !lockdown else { return }
        if runtime.saveState != .saving { runtime.saveState = .saving }
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
        // Count and HTML run off the main actor. The copy still happens here,
        // on the pause, not on the keystroke.
        let snap = await controller.htmlAndWordCountOffMain()
        guard generation == saveGeneration else { return }
        if snap.html == lastSavedHTML {
            runtime.saveState = .saved
            return
        }
        let ok = await app.autosaveEssay(html: snap.html, wordCount: snap.wordCount)
        guard generation == saveGeneration else { return }   // a newer edit owns the pipeline
        if ok {
            lastSavedHTML = snap.html
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

/// Word count label. Separate view so publishing `controller.wordCount` does
/// not invalidate `ExamView` (and, through it, the text view).
private struct WordCountLabel: View {
    var controller: RichTextController
    var limit: Int?
    var onCount: (Int) -> Void

    var body: some View {
        let count = controller.wordCount
        Group {
            if let limit {
                let over = count > limit
                Text("\(count) / \(limit) words")
                    .foregroundStyle(over ? Theme.warn : Theme.muted)
            } else {
                Text("\(count) words")
                    .foregroundStyle(Theme.muted)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .help("Word count")
        .accessibilityLabel("Word count")
        .accessibilityValue({
            if let limit {
                return "\(count) of \(limit) words"
            }
            return "\(count) words"
        }())
        .onChange(of: count) { _, newCount in onCount(newCount) }
    }
}

/// Save-state footer. Separate view so the keystroke that flips "Saving…"
/// redraws this label and nothing above it.
private struct SaveLabel: View {
    var runtime: ExamRuntime
    /// A submit is in flight: the editor is frozen and the student is waiting
    /// on the final save, so that is the state worth showing.
    var submitting = false

    var body: some View {
        HStack(spacing: 6) {
            if submitting {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Submitting your essay…")
            } else if runtime.saveState == .saving {
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
}

/// Live word count inside the submit confirmation. Own view so the dialog
/// text tracking `wordCount` does not land on `ExamView.body`.
private struct SubmitCountMessage: View {
    var controller: RichTextController

    var body: some View {
        let count = controller.wordCount
        Text("You wrote \(count) word\(count == 1 ? "" : "s"). Once you submit, the exam ends and monitoring stops. You can't keep writing after this.")
    }
}

#Preview {
    ExamView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1180, height: 780)
}

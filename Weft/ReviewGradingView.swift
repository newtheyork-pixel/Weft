//
//  ReviewGradingView.swift
//  Weft — the teacher grading / review screen. Ported from the Electron
//  #review-backdrop / .review-shell (renderer/teacher.html + teacher-grade.css).
//
//  Three columns on the glass foundation:
//    LEFT   roster rail — student names + status chips, one selected.
//    CENTER the essay on a clean WHITE opaque "paper" card (NOT glass), with
//           the assignment prompt floated above it.
//    RIGHT  grading rail — Score (e.g. 92 / 100), a Final comment text area,
//           and a primary "Share with student" button.
//  A top bar carries the assignment title, Back / Student N of M / Next, and a
//  close. Mock roster + essay text only; the backend lands in a later wave.
//

import SwiftUI

// MARK: - Local mock model

/// A student row in the review roster, plus the essay we read and grade.
private struct ReviewEntry: Identifiable {
    let id: String
    var name: String
    var status: Status
    var wordCount: Int
    var submitted: Bool
    var returned: Bool
    var lastEdited: String
    var score: String          // points entered, empty == not scored yet
    var finalComment: String
    var paragraphs: [String]    // the essay body, paragraph by paragraph

    enum Status {
        case writing, submitted, joined, leftFullscreen
        var label: String {
            switch self {
            case .writing:        "Writing"
            case .submitted:      "Submitted"
            case .joined:         "Joined"
            case .leftFullscreen: "Left fullscreen"
            }
        }
        var chipKind: Chip.Kind {
            switch self {
            case .writing, .submitted: .good
            case .joined:              .warn
            case .leftFullscreen:      .bad
            }
        }
    }

    var initials: String { String((name.first ?? "?")).uppercased() }

    /// An empty stand-in used only when a live load returns zero rows mid-render,
    /// so `current` is never indexed out of bounds.
    static let placeholder = ReviewEntry(
        id: "__none__", name: "No submissions", status: .joined, wordCount: 0,
        submitted: false, returned: false, lastEdited: "",
        score: "", finalComment: "", paragraphs: [])

    /// Cheap HTML → paragraphs: turn block-level closers into line breaks, strip
    /// the remaining tags, decode the few common entities, and split into blocks.
    static func paragraphs(fromHTML html: String) -> [String] {
        guard !html.isEmpty else { return [] }
        var s = html
        for tag in ["</p>", "<br>", "<br/>", "<br />", "</div>", "</h1>", "</h2>", "</h3>", "</li>"] {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        let stripped = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        var decoded = stripped
        for (k, v) in map { decoded = decoded.replacingOccurrences(of: k, with: v) }
        let blocks = decoded
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.isEmpty
            ? [decoded.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
            : blocks
    }

    static let mock: [ReviewEntry] = [
        ReviewEntry(
            id: "1", name: "Ava Chen", status: .submitted, wordCount: 612,
            submitted: true, returned: false, lastEdited: "Last edited today at 10:42 AM",
            score: "92", finalComment: "A confident, well-argued reading. Tighten the second body paragraph and you are at the top of the class.",
            paragraphs: avaEssay),
        ReviewEntry(
            id: "2", name: "Ben Ortiz", status: .submitted, wordCount: 548,
            submitted: true, returned: true, lastEdited: "Last edited yesterday at 4:11 PM",
            score: "85", finalComment: "Strong central claim. Bring in one more textual quotation to ground the conclusion.",
            paragraphs: benEssay),
        ReviewEntry(
            id: "3", name: "Maya Singh", status: .submitted, wordCount: 689,
            submitted: true, returned: false, lastEdited: "Last edited today at 9:58 AM",
            score: "", finalComment: "",
            paragraphs: mayaEssay),
        ReviewEntry(
            id: "4", name: "Liam Park", status: .writing, wordCount: 318,
            submitted: false, returned: false, lastEdited: "Writing now",
            score: "", finalComment: "",
            paragraphs: []),
        ReviewEntry(
            id: "5", name: "Sofia Rossi", status: .joined, wordCount: 0,
            submitted: false, returned: false, lastEdited: "",
            score: "", finalComment: "",
            paragraphs: []),
    ]

    private static let avaEssay: [String] = [
        "In the assigned passage, light and dark imagery does more than set a mood. It carries the argument of the chapter. Each time the narrator reaches for an image of brightness, it arrives only after a stretch of shadow, and that ordering is the point: clarity is shown to be earned, not given.",
        "Consider the opening, where the lamp is described as \"a small, stubborn coin of gold against the whole weight of the night.\" The diction insists on smallness and effort. The light is a coin, something paid out, and it is stubborn, as if it must hold its ground. The dark, by contrast, is given mass: \"the whole weight of the night.\" By making darkness heavy and light deliberate, the author frames understanding as labor.",
        "This pattern repeats at the scene's turn. When the character finally speaks the truth she has avoided, the room does not flood with light. Instead, \"a thin line of morning\" appears under the door. The restraint matters. A flood would suggest revelation handed down from outside; a thin line suggests something seeping in slowly, at the edges, the way real recognition tends to arrive.",
        "Read this way, the imagery is not decoration laid over the plot but the plot's quiet engine. Light keeps its meaning precisely because the text refuses to give it cheaply.",
    ]

    private static let benEssay: [String] = [
        "The passage uses light and dark to mark the distance between what the character knows and what she is willing to admit. Darkness is comfort here, not danger, and that inversion is the essay's most interesting move.",
        "When the narrator lingers in the unlit hall, the prose slows and softens. The shadows are described as \"forgiving,\" a word usually reserved for people. To stay in the dark is to be spared judgment. Light, then, becomes the threat: it is what would reveal her.",
        "By the close, the single shaft of light through the curtain reads less like hope and more like exposure. The author has trained us, image by image, to feel it that way.",
    ]

    private static let mayaEssay: [String] = [
        "Light and dark in this passage are never simply opposites. They bleed into each other, and the author seems most interested in the gray between them, the dusk where neither claim is fully true.",
        "The recurring image of the \"half-lit window\" is the clearest example. It is not bright and not black; it is the in-between, and it returns at exactly the moments the character is most uncertain. The imagery tracks her doubt rather than her conclusions.",
        "This is a subtler design than a clean light-equals-good scheme. The author withholds easy symbolism, and in doing so asks the reader to sit in the same uncertainty the character feels.",
        "If the essay has a thesis, it is that meaning, like light at dusk, is partial. We are given enough to see by, and no more.",
    ]
}

// MARK: - The screen

struct ReviewGradingView: View {
    @Environment(AppState.self) private var app

    /// The mock roster is the preview / no-data fallback. When real submissions
    /// exist (signed-in), `liveEntries` drives the screen instead.
    @State private var mockRoster: [ReviewEntry] = ReviewEntry.mock
    @State private var index: Int = 0
    /// True when the live score/comment buffers have unsaved edits.
    @State private var gradeDirty = false

    /// Local edit buffers for the selected submission, seeded from the live grade.
    @State private var scoreText: String = ""
    @State private var commentText: String = ""
    /// Tracks which submission the buffers were seeded for, so we reseed on move.
    @State private var seededSubmissionId: String?

    private let defaultPointsPossible: Double = 100

    /// True when we have real submissions to grade (signed-in, non-empty load).
    /// Signed in => real grading (even with zero submissions, which shows an
    /// empty roster rather than fabricated sample essays). Preview => sample.
    private var isLive: Bool { app.signedIn }

    private var assignmentTitle: String {
        isLive && !app.gradingTitle.isEmpty ? app.gradingTitle : "Lit essay 1 · AP English"
    }
    /// The prompt above the essay. Live: resolved from the graded
    /// session's assignment; nil hides the block (never show the mock
    /// prompt over a real essay). Preview: the bundled sample prompt.
    private var prompt: String? {
        if !isLive {
            return "Analyze the use of light and dark imagery in the assigned passage. Support your claim with specific textual evidence."
        }
        guard let tid = app.gradingSession?.testId,
              let p = app.assignments.first(where: { $0.id == tid })?.questions.first?.prompt,
              !p.isEmpty else { return nil }
        return p
    }

    /// The rows the screen renders — live submissions mapped into `ReviewEntry`,
    /// or the bundled mock essays when there is no real data.
    private var roster: [ReviewEntry] {
        isLive ? app.gradingSubmissions.map(liveEntry(from:)) : mockRoster
    }

    private var current: ReviewEntry {
        let rows = roster
        guard !rows.isEmpty else { return ReviewEntry.placeholder }
        return rows[min(index, rows.count - 1)]
    }
    private var submittedCount: Int { roster.filter { $0.submitted }.count }

    /// The points-possible to grade against: the existing grade's, or the default.
    private var pointsPossible: Double {
        if isLive, let g = app.grades[current.id], let pp = g.pointsPossible { return pp }
        return defaultPointsPossible
    }
    private var pointsPossibleLabel: String {
        let pp = pointsPossible
        return pp == pp.rounded() ? String(Int(pp)) : String(pp)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.black.opacity(0.08))
            HStack(spacing: 0) {
                rosterRail
                    .frame(width: 268)
                Divider().overlay(Color.black.opacity(0.08))
                reader
                    .frame(maxWidth: .infinity)
                Divider().overlay(Color.black.opacity(0.08))
                gradeRail
                    .frame(width: 320)
            }
        }
        .background(AmbientBackground())
        .task { await app.loadGrading() }
        .onChange(of: current.id) { _, _ in seedBuffers() }
        .onChange(of: isLive) { _, _ in index = 0; seedBuffers() }
        .onAppear { seedBuffers() }
    }

    // MARK: Live data ↔ ReviewEntry

    /// Build a roster row from a real submission + its grade so the existing
    /// rendering (roster rail, reader, grade rail) works unchanged on live data.
    private func liveEntry(from sub: TeacherSubmission) -> ReviewEntry {
        let grade = app.grades[sub.id]
        let words = sub.wordCount ?? 0
        let name = liveName(for: sub)
        let scoreString: String = {
            guard let p = grade?.points else { return "" }
            return p == p.rounded() ? String(Int(p)) : String(p)
        }()
        return ReviewEntry(
            id: sub.id,
            name: name,
            status: .submitted,
            wordCount: words,
            submitted: true,
            returned: grade?.isReleased ?? false,
            lastEdited: liveEdited(for: sub),
            score: scoreString,
            finalComment: grade?.feedback ?? "",
            paragraphs: ReviewEntry.paragraphs(fromHTML: sub.contentHtml ?? ""))
    }

    private func liveName(for sub: TeacherSubmission) -> String {
        if let sid = sub.studentId,
           let r = app.gradingRoster.first(where: { $0.id == sid }) {
            return r.name
        }
        return "Student"
    }

    private func liveEdited(for sub: TeacherSubmission) -> String {
        guard let when = sub.submittedAt ?? sub.updatedAt else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Submitted " + f.string(from: when)
    }

    /// Seed the local Score / Final comment buffers from the selected grade.
    private func seedBuffers() {
        let row = current
        guard isLive else {
            // Preview path keeps editing the mock entry's own fields.
            seededSubmissionId = nil
            return
        }
        guard seededSubmissionId != row.id else { return }
        seededSubmissionId = row.id
        scoreText = row.score
        commentText = row.finalComment
        gradeDirty = false
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(assignmentTitle)
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.lg)

            HStack(spacing: Theme.Space.sm) {
                navButton("Back", system: "chevron.left", disabled: index <= 0) {
                    if index > 0 { flushIfDirty(); withAnimation(.easeOut(duration: 0.18)) { index -= 1 } }
                }
                .help("Previous student")
                Text("Student \(index + 1) of \(roster.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
                    .frame(minWidth: 104)
                    .contentTransition(.numericText())
                navButton("Next", system: "chevron.right", trailingIcon: true,
                          disabled: index >= roster.count - 1) {
                    if index < roster.count - 1 { flushIfDirty(); withAnimation(.easeOut(duration: 0.18)) { index += 1 } }
                }
                .help("Next student")
            }

            Spacer(minLength: Theme.Space.lg)

            Text("\(submittedCount) of \(roster.count) submitted")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
                .fixedSize()

            Button {
                app.teacherGoHome()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .clipShape(Circle())
            .help("Close grading and return to the teacher view")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .background(.regularMaterial)
    }

    private func navButton(_ title: String, system: String, trailingIcon: Bool = false,
                           disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if !trailingIcon { Image(systemName: system).font(.system(size: 11, weight: .semibold)) }
                Text(title)
                if trailingIcon { Image(systemName: system).font(.system(size: 11, weight: .semibold)) }
            }
            .font(Theme.sans(13, .semibold))
            .foregroundStyle(disabled ? Theme.muted2 : Theme.inkSoft)
        }
        .buttonStyle(.glass)
        .disabled(disabled)
    }

    // MARK: Left — roster rail

    private var rosterRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 10, weight: .semibold))
                Text("STUDENTS")
                    .tracking(0.9)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.sm)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(roster.enumerated()), id: \.element.id) { i, s in
                        rosterRow(s, active: i == index)
                            .contentShape(Rectangle())
                            .rowHover(corner: Theme.Radius.sm, strength: i == index ? 0 : 0.05)
                            .onTapGesture { flushIfDirty(); withAnimation(.easeOut(duration: 0.18)) { index = i } }
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.bottom, Theme.Space.md)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private func rosterRow(_ s: ReviewEntry, active: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft.opacity(0.18))
                Text(s.initials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(s.name)
                        .font(Theme.sans(13, .medium))
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                    if s.returned {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Returned")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.good)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                HStack(spacing: 6) {
                    Chip(text: s.status.label, kind: s.status.chipKind)
                    Text(s.submitted ? "\(s.wordCount) words" : "Not submitted")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(active ? Theme.accent.opacity(0.10) : Color.clear)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? Theme.accent : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 4)
        }
        .animation(.easeOut(duration: 0.18), value: active)
        .animation(.easeOut(duration: 0.2), value: s.returned)
    }

    // MARK: Center — reader (prompt + white paper)

    private var reader: some View {
        VStack(alignment: .leading, spacing: 0) {
            readerHead
            Divider().overlay(Color.black.opacity(0.08))
            ScrollView {
                VStack {
                    paper
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxxl)
                .frame(maxWidth: .infinity)
                .id(current.id)
                .transition(.opacity)
            }
            .background(Color(red: 0.976, green: 0.984, blue: 0.992)) // #f9fbfd canvas
        }
    }

    private var readerHead: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(current.name)
                .font(Theme.sans(16, .semibold))
                .foregroundStyle(Theme.inkSoft)

            HStack(spacing: Theme.Space.md) {
                Chip(text: current.status.label, kind: current.status.chipKind)
                if current.submitted {
                    Chip(text: "Submitted", kind: .good)
                } else {
                    Chip(text: "In progress", kind: .warn)
                }
                Text("\(current.wordCount) words")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
                if !current.lastEdited.isEmpty {
                    Text(current.lastEdited)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }

            if let prompt {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 10, weight: .semibold))
                        Text("PROMPT")
                            .tracking(0.9)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted2)

                    Text(prompt)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                }
                .padding(.leading, Theme.Space.md)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accentSoft.opacity(0.5))
                        .frame(width: 3)
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    /// The clean WHITE opaque page. Deliberately NOT glass — this is paper.
    private var paper: some View {
        Group {
            if current.paragraphs.isEmpty {
                emptyPaper
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    ForEach(Array(current.paragraphs.enumerated()), id: \.offset) { _, para in
                        Text(para)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.black)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 56)
                .padding(.horizontal, 64)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }

    private var emptyPaper: some View {
        VStack(spacing: Theme.Space.sm) {
            Text(current.status == .writing ? "Still writing" : "No submission yet")
                .font(Theme.sans(18, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text(emptyMessage)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
        .padding(56)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 2)
    }

    private var emptyMessage: String {
        switch current.status {
        case .writing: return "This student is still writing. Nothing has been turned in yet."
        default:       return "This student has joined but has not started writing."
        }
    }

    // MARK: Right — grading rail

    private var gradeRail: some View {
        VStack(spacing: 0) {
            if current.submitted {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        if let outline = currentOutline {
                            outlineBlock(outline)
                        }
                        scoreBlock
                        finalCommentBlock
                    }
                    .padding(Theme.Space.lg)
                }
                shareBlock
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    slotHead("Grading", system: "pencil.and.list.clipboard")
                    Text("No submission yet. When this student submits, their essay appears here for grading.")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                    Spacer()
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private func slotHead(_ text: String, system: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let system {
                Image(systemName: system)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text.uppercased())
                .tracking(0.9)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.muted)
    }

    /// The outline the current student uploaded before writing, if any. Live:
    /// outline_uploads keys on user_id while submissions key on the
    /// students-row id, so the gradingRoster row bridges the two. Preview:
    /// the bundled sample outline on its matching mock student, so the block
    /// is demoable signed out. nil (no upload) renders nothing at all.
    private var currentOutline: OutlineUpload? {
        guard isLive else {
            return current.name == OutlineUpload.sample.displayName ? OutlineUpload.sample : nil
        }
        guard let sub = app.gradingSubmissions.first(where: { $0.id == current.id }),
              let sid = sub.studentId,
              let uid = app.gradingRoster.first(where: { $0.id == sid })?.userId else { return nil }
        return app.gradingOutlines.first { $0.userId == uid }
    }

    /// "Outline" block in the grading rail: the student's pre-writing outline,
    /// opened in the browser/Preview via a fresh signed URL (private bucket).
    private func outlineBlock(_ outline: OutlineUpload) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            slotHead("Outline", system: "paperclip")
            Button {
                Task { await app.openOutline(outline) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: outline.isPDF ? "doc.richtext" : "doc.text")
                        .font(.system(size: 12, weight: .semibold))
                    Text(outline.originalName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .linkPointer()
            .help("Open the outline this student uploaded before writing")
            Text("Uploaded before the student began writing.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
        }
    }

    private var scoreBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            slotHead("Score", system: "number")
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                TextField("", text: scoreBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.leading)
                    .onSubmit { saveCurrentGrade(share: false) }
                    .frame(width: 72)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Color.white.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                Text("/ \(pointsPossibleLabel) pts")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            Text("Enter a score, or leave blank to give feedback only. Half points OK.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
        }
    }

    private var finalCommentBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            slotHead("Final comment", system: "text.bubble")
            TextEditor(text: finalCommentBinding)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.inkSoft)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color.white.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Color.black.opacity(0.10), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if commentIsEmpty {
                        Text("Write one overall comment for the whole essay.")
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.muted2)
                            // Mirror the editor's exact text origin — 8 outer
                            // padding + NSTextView's 5pt line-fragment padding,
                            // zero top inset on macOS — so the caret blinks ON
                            // the placeholder's first line, not above it.
                            .padding(.horizontal, 13)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var shareBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Divider().overlay(Color.black.opacity(0.08))
                .padding(.bottom, Theme.Space.xs)

            if isLive {
                Button {
                    saveCurrentGrade(share: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Save without sharing")
                            .font(Theme.sans(14, .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(app.isLoading)
                .help("Save the score and comment privately. The student does not see it yet.")
            }

            Button {
                if isLive {
                    saveCurrentGrade(share: true)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { mockRoster[safeMockIndex].returned = true }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: current.returned ? "checkmark.circle.fill" : "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(current.returned ? "Shared" : "Share with student")
                        .font(Theme.sans(14, .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(app.isLoading)
            .help(current.returned ? "Update and re-share with this student" : "Send the score and your comment to the student")

            if let error = app.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bad)
                    .lineSpacing(2)
                    .transition(.opacity)
            }

            Text("Once shared, the student sees the score and your Shared comments. Private notes stay hidden.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
        }
        .padding(Theme.Space.lg)
    }

    // MARK: Bindings into the current entry

    private var scoreBinding: Binding<String> {
        if isLive {
            return Binding(get: { scoreText }, set: { scoreText = $0; gradeDirty = true })
        }
        return Binding(get: { mockRoster[safeMockIndex].score },
                       set: { mockRoster[safeMockIndex].score = $0 })
    }
    private var finalCommentBinding: Binding<String> {
        if isLive {
            return Binding(get: { commentText }, set: { commentText = $0; gradeDirty = true })
        }
        return Binding(get: { mockRoster[safeMockIndex].finalComment },
                       set: { mockRoster[safeMockIndex].finalComment = $0 })
    }

    /// Persist any unsaved live edits before the selection changes, so typing a
    /// score/comment and then paging to another student never loses it.
    private func flushIfDirty() {
        guard isLive, gradeDirty else { return }
        let alreadyReleased = app.grades[current.id]?.isReleased ?? false
        saveCurrentGrade(share: alreadyReleased)
    }

    /// The current entry's comment text for the placeholder check, regardless of path.
    private var commentIsEmpty: Bool {
        isLive ? commentText.isEmpty : current.finalComment.isEmpty
    }

    /// Index into the mock roster, clamped so edits never go out of bounds.
    private var safeMockIndex: Int { min(index, max(0, mockRoster.count - 1)) }

    // MARK: Grade actions (live path)

    /// Persist the current score + comment. `share` true releases to the student;
    /// false saves privately, preserving whatever released state already exists.
    private func saveCurrentGrade(share: Bool) {
        guard isLive else {
            // Preview path: keep the existing local "Shared" demo behaviour.
            if share { withAnimation(.easeOut(duration: 0.2)) { mockRoster[safeMockIndex].returned = true } }
            return
        }
        guard let submission = app.gradingSubmissions.first(where: { $0.id == current.id }) else { return }
        let trimmed = scoreText.trimmingCharacters(in: .whitespaces)
        let points = trimmed.isEmpty ? nil : Double(trimmed)
        let alreadyReleased = app.grades[submission.id]?.isReleased ?? false
        gradeDirty = false
        Task {
            await app.saveGrade(submission: submission,
                                points: points,
                                pointsPossible: pointsPossible,
                                feedback: commentText,
                                share: share || alreadyReleased)
        }
    }
}

#Preview {
    ReviewGradingView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1180, height: 820)
}

//
//  ReturnedWorkView.swift
//  Weft — the student's read-only returned-work view: their graded essay, the
//  score, the teacher's overall comment, and the inline comments. Ported from
//  the Electron #stage-review / .pe-shell screen in student.html + student.js.
//
//  Layout mirrors the web: a left list of returned essays, a centre read-only
//  essay "paper" (a clean WHITE opaque card, deliberately NOT glass so the body
//  text stays maximally legible), and a right rail with the score, the overall
//  comment, and the per-comment notes. No editor, nothing editable.
//

import SwiftUI

// MARK: - Mock model

/// A single returned (graded) essay, mirroring the released-submission shape the
/// Electron renderer reads (content_html / points / feedback / comments).
private struct ReturnedEssay: Identifiable, Hashable {
    let id: String
    var title: String          // the question prompt, or "Your essay"
    var releasedAt: Date?
    var points: Double?        // nil => "Feedback only (no score yet)"
    var pointsPossible: Double
    /// The paper as plain paragraphs, built the same way as on the
    /// teacher's Mac (PaperText), so the comments' ranges line up.
    var paragraphs: [String]
    var feedback: String       // overall comment from the teacher ("" => none)
    var feedbackUnavailable = false
    var comments: [InlineComment]

    /// Sub-label for the left list: "Returned · 92/100" or "Returned · feedback".
    var listSub: String {
        if let points {
            return "Returned · \(fmtPoints(points))/\(fmtPoints(pointsPossible))"
        }
        return "Returned · feedback"
    }

    var percent: Int {
        guard let points, pointsPossible > 0 else { return 0 }
        return max(0, min(100, Int((points / pointsPossible * 100).rounded())))
    }
}

/// One paragraph of the essay body. A run is either plain text or a span that
/// carries a comment id (the inline-highlight ranges painted in the web view).
/// One paragraph of rendered essay text. Widened to internal so
/// SubmittedWorkView can reuse the same paragraph-rendering logic.
struct EssayParagraph: Hashable {
    var runs: [EssayRun]
}

/// A single run inside an EssayParagraph. Widened to internal alongside
/// EssayParagraph so SubmittedWorkView can reuse the type.
struct EssayRun: Hashable {
    var text: String
    var commentId: String?      // non-nil => highlighted, tied to a margin note
}

/// A teacher comment anchored to a passage in the essay.
private struct InlineComment: Identifiable, Hashable {
    let id: String
    var quote: String           // the highlighted words ("" => can't be placed)
    var body: String
    var rangeStart: Int = 0
    var rangeEnd: Int = 0
    var createdAt: Date? = nil
}

/// Numbers without a trailing ".00" but keeping half points (87.5 stays 87.5).
private func fmtPoints(_ n: Double) -> String {
    let r = (n * 100).rounded() / 100
    return r == r.rounded() ? String(Int(r)) : String(r)
}

private func returnedDateLabel(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.dateFormat = "MMM d, yyyy"
    return "Returned \(f.string(from: d))"
}

// MARK: - View

struct ReturnedWorkView: View {
    @Environment(AppState.self) private var app

    @State private var selectedId: String = ""
    @State private var activeCommentId: String?

    /// Mapped essays, cached so the HTML parse runs only when the source changes
    /// (not on every render). Seeded EMPTY so a signed-in student never flashes
    /// fabricated returned work on the first frame; `recomputeEssays()` (run at
    /// the top of `.task`, before any await) fills in the rich sample only on
    /// the not-signed-in (gallery / unsigned) path.
    @State private var essays: [ReturnedEssay] = []

    private var selected: ReturnedEssay {
        essays.first(where: { $0.id == selectedId }) ?? essays.first
            ?? ReturnedWorkView.sampleEssays[0]
    }

    /// Rebuild `essays` from the source of truth: real released work when signed
    /// in, the rich sample only in the not-signed-in (gallery / unsigned) case.
    private func recomputeEssays() {
        let real = app.returnedWork.map(Self.makeEssay)
        essays = real.isEmpty ? (app.useMockData ? Self.sampleEssays : []) : real
        if !essays.contains(where: { $0.id == selectedId }) {
            selectedId = essays.first?.id ?? ""
            activeCommentId = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student", trailing: AnyView(backButton))
            topBar
            if essays.isEmpty {
                emptyState
            } else {
                body3Col
            }
        }
        .background(AmbientBackground())
        .task {
            recomputeEssays()
            await app.loadReturnedWork()
            recomputeEssays()
        }
        .onChange(of: app.returnedWork) { _, _ in recomputeEssays() }
    }

    // MARK: Top-bar (back + title + returned date)

    private var backButton: some View {
        Button {
            app.goToHome()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back to my assignments")
                    .font(Theme.sans(13, .semibold))
            }
        }
        .buttonStyle(.glass)
        .tint(Theme.accent)
        .help("Return to your assignments")
        .linkPointer()
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.lg) {
            Text(selected.title)
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.md)
            if selected.releasedAt != nil {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                    Text(returnedDateLabel(selected.releasedAt))
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
        }
    }

    // MARK: Section header (Kicker with a small leading SF Symbol)

    /// A Kicker paired with a restrained leading glyph so the rail sections read
    /// a little more native. Mirrors the muted Kicker styling.
    private func kickerRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Kicker(text: text)
        }
    }

    // MARK: 3-column body

    private var body3Col: some View {
        // The paper and its comment column need the room, so the side panes
        // narrow on a smaller window.
        GeometryReader { geo in
            let compact = geo.size.width < 1320
            // Below this the essay list moves into a picker in the rail.
            let noList = geo.size.width < 1100
            HStack(spacing: 0) {
                if !noList {
                    listPane
                        .frame(width: compact ? 200 : 260)
                    Divider().opacity(0.4)
                }
                paperCanvas
                    .frame(maxWidth: .infinity)
                Divider().opacity(0.4)
                rail(showPicker: noList)
                    .frame(width: compact ? 264 : 320)
            }
        }
    }

    // MARK: Left list — "Your essays"

    private var listPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                kickerRow("doc.text", "Your essays")
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.top, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.sm)
                ForEach(essays) { essay in
                    listItem(essay)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    private func listItem(_ essay: ReturnedEssay) -> some View {
        let isActive = essay.id == selectedId
        return Button {
            selectedId = essay.id
            activeCommentId = nil
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(essay.title)
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(essay.listSub)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(isActive ? Theme.accent.opacity(0.10) : Color.clear)
            )
            .animation(.easeOut(duration: 0.15), value: isActive)
        }
        .buttonStyle(.plainHit)
        .rowHover()
        .help(essay.title)
        .linkPointer()
    }

    // MARK: Centre: the paper with the teacher's comments beside it

    /// Read-only: the student can select and copy, and click a highlight or
    /// a card to pair them, but cannot add, edit, resolve or delete.
    private var paperCanvas: some View {
        MarginedPaper(
            paragraphs: selected.paragraphs,
            comments: marginItems,
            activeId: $activeCommentId)
            .id(selected.id)
            .background(Color(red: 0.976, green: 0.984, blue: 0.992))
    }

    private var marginItems: [MarginItem] {
        let text = PaperText.plain(selected.paragraphs)
        return selected.comments.map { c in
            MarginItem(id: c.id, body: c.body, author: "Teacher", createdAt: c.createdAt,
                       isPrivate: false, resolved: false,
                       anchor: PaperText.anchor(rangeStart: c.rangeStart, rangeEnd: c.rangeEnd,
                                                quote: c.quote, in: text))
        }
    }

    // MARK: Right rail — score, overall comment, comments

    private func rail(showPicker: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                if showPicker, essays.count > 1 { essayPicker }
                scoreCard
                finalCommentCard
                commentsNote
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    /// The essay list as a menu, for narrow windows.
    private var essayPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            kickerRow("doc.text", "Your essays")
            Menu {
                ForEach(essays) { essay in
                    Button(essay.title) {
                        selectedId = essay.id
                        activeCommentId = nil
                    }
                }
            } label: {
                Text(selected.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.button)
            .accessibilityLabel("Choose an essay")
        }
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            kickerRow("checkmark.seal", "Score")
            if let points = selected.points {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(fmtPoints(points))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.inkSoft)
                    Text(" / \(fmtPoints(selected.pointsPossible))")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                scoreBar
                Text("\(selected.percent)%")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.muted)
            } else {
                Text("Feedback only (no score yet)")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Color.black.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var scoreBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.08))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * CGFloat(selected.percent) / 100)
                    .animation(.easeOut(duration: 0.35), value: selected.percent)
            }
        }
        .frame(height: 8)
        .padding(.vertical, 2)
    }

    private var finalCommentCard: some View {
        let fb = selected.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            kickerRow("text.quote", "Overall comment from your teacher")
            Text(selected.feedbackUnavailable ? "The feedback could not be opened."
                 : (fb.isEmpty ? "No overall comment." : fb))
                .font(Theme.sans(14))
                .foregroundStyle(fb.isEmpty ? Theme.muted : Theme.inkSoft)
                .italic(fb.isEmpty)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if selected.feedbackUnavailable {
                Button("Retry feedback") { Task { await app.loadReturnedWork() } }
                    .buttonStyle(.glass)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var commentsNote: some View {
        let n = selected.comments.count
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            kickerRow("bubble.left.and.text.bubble.right", "Comments on your essay")
            Text(n == 0 ? "No comments on this essay."
                 : (n == 1 ? "1 comment, shown beside your essay." : "\(n) comments, shown beside your essay."))
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.xs)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Spacer()
            Text("Nothing returned yet")
                .font(Theme.serif(22, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text("Your teacher hasn't shared graded work. Scores and comments appear here once they do.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Back to my assignments") { app.goToHome() }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .padding(.top, Theme.Space.xs)
                .linkPointer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxxl)
    }
}

// MARK: - HTML parser (internal — shared with SubmittedWorkView)

extension ReturnedWorkView {
    /// Cheap HTML → paragraphs: turn block-level closers into line breaks, strip
    /// the remaining tags, decode the few common entities, and split into blocks.
    /// Internal so SubmittedWorkView can reuse the same parser without duplication.
    nonisolated static func paragraphs(fromHTML html: String,
                                       comments: [ReturnedComment] = []) -> [EssayParagraph] {
        var s = html
        for tag in ["</p>", "<br>", "<br/>", "<br />", "</div>", "</h1>", "</h2>", "</h3>", "</li>"] {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        let stripped = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = decodeEntities(stripped)
        let blocks = decoded
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let paras = blocks.isEmpty ? [decoded.trimmingCharacters(in: .whitespacesAndNewlines)] : blocks
        let anchors = comments.filter { !($0.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return paras
            .filter { !$0.isEmpty }
            .map { splitRuns($0, comments: anchors) }
    }

    /// Paint each margin quote as an accent run in the paragraph that contains it.
    nonisolated static func splitRuns(_ text: String, comments: [ReturnedComment]) -> EssayParagraph {
        var remaining = text
        var runs: [EssayRun] = []
        var used = Set<String>()
        while !remaining.isEmpty {
            var best: (range: Range<String.Index>, id: String)?
            for c in comments where !used.contains(c.id) {
                let quote = (c.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !quote.isEmpty, let r = remaining.range(of: quote, options: .caseInsensitive)
                else { continue }
                if best == nil || r.lowerBound < best!.range.lowerBound {
                    best = (r, c.id)
                }
            }
            guard let hit = best else {
                runs.append(EssayRun(text: remaining, commentId: nil))
                break
            }
            if hit.range.lowerBound > remaining.startIndex {
                runs.append(EssayRun(text: String(remaining[remaining.startIndex..<hit.range.lowerBound]),
                                     commentId: nil))
            }
            runs.append(EssayRun(text: String(remaining[hit.range]), commentId: hit.id))
            used.insert(hit.id)
            remaining = String(remaining[hit.range.upperBound...])
        }
        if runs.isEmpty { runs = [EssayRun(text: text, commentId: nil)] }
        return EssayParagraph(runs: runs)
    }

    nonisolated static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

// MARK: - Real data mapping (ReturnedWorkItem -> presentation model)

private extension ReturnedWorkView {
    /// Map a released-work DTO into the read-only presentation model. The body
    /// HTML is flattened to plain paragraphs exactly as the teacher's grading
    /// paper does, so each comment's stored range lands on the same words.
    nonisolated static func makeEssay(_ item: ReturnedWorkItem) -> ReturnedEssay {
        ReturnedEssay(
            id: item.submissionId,
            title: "Your essay",
            releasedAt: item.releasedAt,
            points: item.points,
            pointsPossible: item.pointsPossible,
            paragraphs: PaperText.paragraphs(fromHTML: item.contentHtml),
            feedback: item.feedback,
            feedbackUnavailable: item.feedbackUnavailable,
            // Shared only (the server returns nothing else); resolved ones are
            // hidden when the server says so.
            comments: item.comments
                .filter { ($0.visibility ?? "shared") == "shared" && $0.resolvedAt == nil }
                .map { c in
                    InlineComment(id: c.id, quote: c.quote ?? "", body: c.body,
                                  rangeStart: c.rangeStart ?? 0, rangeEnd: c.rangeEnd ?? 0,
                                  createdAt: c.createdAt)
                }
        )
    }
}

// MARK: - Mock content

private extension ReturnedWorkView {
    static let sampleEssays: [ReturnedEssay] = [
        ReturnedEssay(
            id: "s1",
            title: "Analyze the use of light and dark imagery in the assigned passage.",
            releasedAt: Calendar.current.date(byAdding: .day, value: -2, to: .now),
            points: 92,
            pointsPossible: 100,
            paragraphs: sample1,
            feedback: "A genuinely strong reading. You move past the obvious good-versus-evil framing and track how the imagery actually behaves across the passage, which is exactly the work this prompt asks for. Tighten your second paragraph so the conscience claim lands with a little more textual proof, and watch the long sentences in the close. This is honest, careful analysis.",
            comments: [
                sampleComment("c1", in: sample1,
                              quote: "The lantern in the window is never simply a source of warmth",
                              body: "Nice. This is the right place to anchor your argument. Could you name one concrete detail from the lantern's description here?",
                              daysAgo: 2),
                sampleComment("c2", in: sample1,
                              quote: "the darkness becomes a mirror of conscience rather than a threat from outside.",
                              body: "Strong claim. It would be even stronger with a short quotation showing the shared language you mention.",
                              daysAgo: 2),
                InlineComment(
                    id: "c3",
                    quote: "",
                    body: "Your conclusion is your best paragraph. Trust this kind of restraint earlier in the essay too.",
                    createdAt: Calendar.current.date(byAdding: .day, value: -2, to: .now)),
            ]
        ),
        ReturnedEssay(
            id: "s2",
            title: "Explain how the author builds the narrator's unreliability.",
            releasedAt: Calendar.current.date(byAdding: .day, value: -9, to: .now),
            points: nil,
            pointsPossible: 100,
            paragraphs: sample2,
            feedback: "I haven't put a number on this yet, but your instinct here is good. Keep going with the idea that the reader is made to do the suspecting. Bring in one more example and this becomes a real argument.",
            comments: [
                sampleComment("c1", in: sample2,
                              quote: "Twice in the first page the narrator corrects a detail they had just stated as fact",
                              body: "Good specific observation. Quote one of these two corrections directly and the point is airtight.",
                              daysAgo: 9),
            ]
        ),
    ]

    static let sample1: [String] = [
        "From its opening lines, the passage sets light and dark against each other not as opposites but as a single shifting field. The lantern in the window is never simply a source of warmth; it is the one fixed point against which the surrounding darkness is measured, and the narrator returns to it whenever the scene threatens to lose its bearings.",
        "As the chapter progresses, the imagery turns inward. The shadows that gather in the hall are described in the same language used earlier for the protagonist's doubt, so that the darkness becomes a mirror of conscience rather than a threat from outside. This doubling is what gives the passage its quiet tension: the reader is never sure whether the light is protecting the character or merely exposing what they would rather not see.",
        "By the final paragraph the two forces have collapsed into one. The dawn that breaks over the courtyard is neither pure relief nor pure loss; it is simply the moment at which the distinction stops mattering, and the character steps into a grey, undivided day.",
    ]

    static let sample2: [String] = [
        "The narrator's unreliability is built quietly, through small contradictions the reader is trusted to catch. Twice in the first page the narrator corrects a detail they had just stated as fact, and these corrections are never explained, which trains us to read everything that follows with one eyebrow raised.",
        "What makes the technique work is restraint. The author never tells us the narrator is lying; the gaps simply accumulate until we are doing the suspicion ourselves.",
    ]

    /// A sample comment with a real range into the sample paper.
    static func sampleComment(_ id: String, in paragraphs: [String], quote: String,
                              body: String, daysAgo: Int) -> InlineComment {
        let r = (PaperText.plain(paragraphs) as NSString).range(of: quote)
        return InlineComment(id: id, quote: quote, body: body,
                             rangeStart: r.location == NSNotFound ? 0 : r.location,
                             rangeEnd: r.location == NSNotFound ? 0 : NSMaxRange(r),
                             createdAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now))
    }
}

#Preview {
    ReturnedWorkView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

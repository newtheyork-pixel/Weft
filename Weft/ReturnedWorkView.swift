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
    var paragraphs: [EssayParagraph]
    var feedback: String       // overall comment from the teacher ("" => none)
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
private struct EssayParagraph: Hashable {
    var runs: [EssayRun]
}

private struct EssayRun: Hashable {
    var text: String
    var commentId: String?      // non-nil => highlighted, tied to a margin note
}

/// A teacher comment anchored to a quote in the essay.
private struct InlineComment: Identifiable, Hashable {
    let id: String
    var quote: String           // the highlighted text it points at ("" => none)
    var body: String
    var orphaned: Bool = false  // "Comment location changed" (web: orphan badge)
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

    @State private var selectedId: String = ReturnedWorkView.sampleEssays.first?.id ?? ""
    @State private var activeCommentId: String?

    /// Mapped essays, cached so the HTML parse runs only when the source changes
    /// (not on every render). Seeded with the sample for the gallery; replaced by
    /// `recomputeEssays()` once a real load resolves.
    @State private var essays: [ReturnedEssay] = ReturnedWorkView.sampleEssays

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
            Text("Back to my assignments")
                .font(Theme.sans(13, .semibold))
        }
        .buttonStyle(.glass)
        .tint(Theme.accent)
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.lg) {
            Text(selected.title)
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.md)
            Text(returnedDateLabel(selected.releasedAt))
                .font(Theme.sans(12))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
        }
    }

    // MARK: 3-column body

    private var body3Col: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 260)
            Divider().opacity(0.4)
            paperCanvas
                .frame(maxWidth: .infinity)
            Divider().opacity(0.4)
            rail
                .frame(width: 320)
        }
    }

    // MARK: Left list — "Your essays"

    private var listPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Kicker(text: "Your essays")
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
        }
        .buttonStyle(.plain)
    }

    // MARK: Centre — read-only essay "paper" (clean WHITE opaque card)

    private var paperCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(Array(selected.paragraphs.enumerated()), id: \.offset) { _, para in
                    paragraphText(para)
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 56)
            .frame(maxWidth: 760, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.xxl)
            .frame(maxWidth: .infinity)
        }
    }

    /// Build one paragraph as a single Text, inlining the comment highlights as
    /// accent-tinted, background-shaded spans (the web .ec-hl wrapper).
    private func paragraphText(_ para: EssayParagraph) -> Text {
        var out = Text("")
        for run in para.runs {
            var t = Text(run.text)
                .font(Theme.serif(16))
                .foregroundColor(Theme.inkSoft)
            if let cid = run.commentId {
                let active = cid == activeCommentId
                t = t
                    .foregroundColor(Theme.accent)
                    .underline(true, color: Theme.accent.opacity(active ? 0.6 : 0.35))
            }
            out = out + t
        }
        return out
    }

    // MARK: Right rail — score, overall comment, comments

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                scoreCard
                finalCommentCard
                Kicker(text: "Comments on your essay")
                    .padding(.top, Theme.Space.xs)
                commentsList
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Kicker(text: "Score")
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
            }
        }
        .frame(height: 8)
        .padding(.vertical, 2)
    }

    private var finalCommentCard: some View {
        let fb = selected.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Kicker(text: "Overall comment from your teacher")
            Text(fb.isEmpty ? "No overall comment." : fb)
                .font(Theme.sans(14))
                .foregroundStyle(fb.isEmpty ? Theme.muted : Theme.inkSoft)
                .italic(fb.isEmpty)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var commentsList: some View {
        if selected.comments.isEmpty {
            Text("No comments on this essay.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        } else {
            VStack(spacing: Theme.Space.sm) {
                ForEach(selected.comments) { c in
                    commentCard(c)
                }
            }
        }
    }

    private func commentCard(_ c: InlineComment) -> some View {
        let active = c.id == activeCommentId
        return Button {
            activeCommentId = (active ? nil : c.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if !c.quote.isEmpty {
                    Text(c.quote)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .padding(.leading, Theme.Space.sm)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.accent).frame(width: 3)
                        }
                }
                Text(c.body)
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.inkSoft)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if c.orphaned {
                    Text("Comment location changed")
                        .font(Theme.sans(11, .semibold))
                        .foregroundStyle(Theme.warn)
                        .padding(.top, 2)
                    Text("The teacher's note points to text you edited.")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(active ? Theme.accent : Color.black.opacity(0.08),
                            lineWidth: active ? 1.5 : 1)
            )
            .shadow(color: active ? Theme.accent.opacity(0.18) : .clear,
                    radius: active ? 8 : 0, x: 0, y: 2)
        }
        .buttonStyle(.plain)
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxxl)
    }
}

// MARK: - Real data mapping (ReturnedWorkItem -> presentation model)

private extension ReturnedWorkView {
    /// Map a released-work DTO into the read-only presentation model. The body
    /// HTML is flattened to plain paragraphs (the inline-highlight ranges from
    /// the web build aren't reconstructed here; the teacher's comments still show
    /// in the right rail).
    nonisolated static func makeEssay(_ item: ReturnedWorkItem) -> ReturnedEssay {
        ReturnedEssay(
            id: item.submissionId,
            title: "Your essay",
            releasedAt: item.releasedAt,
            points: item.points,
            pointsPossible: item.pointsPossible,
            paragraphs: paragraphs(fromHTML: item.contentHtml),
            feedback: item.feedback,
            comments: item.comments.map { c in
                InlineComment(id: c.id, quote: c.quote ?? "", body: c.body)
            }
        )
    }

    /// Cheap HTML → paragraphs: turn block-level closers into line breaks, strip
    /// the remaining tags, decode the few common entities, and split into blocks.
    nonisolated static func paragraphs(fromHTML html: String) -> [EssayParagraph] {
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
        return paras
            .filter { !$0.isEmpty }
            .map { EssayParagraph(runs: [EssayRun(text: $0, commentId: nil)]) }
    }

    nonisolated static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
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
            paragraphs: [
                EssayParagraph(runs: [
                    .init(text: "From its opening lines, the passage sets light and dark against each other not as opposites but as a single shifting field. "),
                    .init(text: "The lantern in the window is never simply a source of warmth", commentId: "c1"),
                    .init(text: "; it is the one fixed point against which the surrounding darkness is measured, and the narrator returns to it whenever the scene threatens to lose its bearings."),
                ]),
                EssayParagraph(runs: [
                    .init(text: "As the chapter progresses, the imagery turns inward. The shadows that gather in the hall are described in the same language used earlier for the protagonist's doubt, so that "),
                    .init(text: "the darkness becomes a mirror of conscience rather than a threat from outside.", commentId: "c2"),
                    .init(text: " This doubling is what gives the passage its quiet tension: the reader is never sure whether the light is protecting the character or merely exposing what they would rather not see."),
                ]),
                EssayParagraph(runs: [
                    .init(text: "By the final paragraph the two forces have collapsed into one. The dawn that breaks over the courtyard is neither pure relief nor pure loss; it is simply the moment at which the distinction stops mattering, and the character steps into a grey, undivided day."),
                ]),
            ],
            feedback: "A genuinely strong reading. You move past the obvious good-versus-evil framing and track how the imagery actually behaves across the passage, which is exactly the work this prompt asks for. Tighten your second paragraph so the conscience claim lands with a little more textual proof, and watch the long sentences in the close. This is honest, careful analysis.",
            comments: [
                InlineComment(
                    id: "c1",
                    quote: "The lantern in the window is never simply a source of warmth",
                    body: "Nice. This is the right place to anchor your argument. Could you name one concrete detail from the lantern's description here?"
                ),
                InlineComment(
                    id: "c2",
                    quote: "the darkness becomes a mirror of conscience rather than a threat from outside.",
                    body: "Strong claim. It would be even stronger with a short quotation showing the shared language you mention."
                ),
                InlineComment(
                    id: "c3",
                    quote: "",
                    body: "Your conclusion is your best paragraph. Trust this kind of restraint earlier in the essay too.",
                    orphaned: true
                ),
            ]
        ),
        ReturnedEssay(
            id: "s2",
            title: "Explain how the author builds the narrator's unreliability.",
            releasedAt: Calendar.current.date(byAdding: .day, value: -9, to: .now),
            points: nil,
            pointsPossible: 100,
            paragraphs: [
                EssayParagraph(runs: [
                    .init(text: "The narrator's unreliability is built quietly, through small contradictions the reader is trusted to catch. "),
                    .init(text: "Twice in the first page the narrator corrects a detail they had just stated as fact", commentId: "c1"),
                    .init(text: ", and these corrections are never explained, which trains us to read everything that follows with one eyebrow raised."),
                ]),
                EssayParagraph(runs: [
                    .init(text: "What makes the technique work is restraint. The author never tells us the narrator is lying; the gaps simply accumulate until we are doing the suspicion ourselves."),
                ]),
            ],
            feedback: "I haven't put a number on this yet, but your instinct here is good. Keep going with the idea that the reader is made to do the suspecting. Bring in one more example and this becomes a real argument.",
            comments: [
                InlineComment(
                    id: "c1",
                    quote: "Twice in the first page the narrator corrects a detail they had just stated as fact",
                    body: "Good specific observation. Quote one of these two corrections directly and the point is airtight."
                ),
            ]
        ),
    ]
}

#Preview {
    ReturnedWorkView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

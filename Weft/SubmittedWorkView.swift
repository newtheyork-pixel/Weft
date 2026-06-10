//
//  SubmittedWorkView.swift
//  Weft — read-only viewer for a student's own submitted (but not yet graded)
//  essay, reached from the Past row on the class home. No editing surface, no
//  timer, no kiosk. Mirrors ReturnedWorkView's white-card essay rendering and
//  reuses its HTML parser (paragraphs(fromHTML:) / EssayParagraph / EssayRun),
//  which were widened from private to internal for this purpose.
//
//  Navigation: app.openSubmittedWork(_:) sets studentScreen = .submitted and
//  begins the RPC fetch; back calls app.goToHome().
//

import SwiftUI

struct SubmittedWorkView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student", trailing: AnyView(backButton))
            content
        }
        .background(AmbientBackground())
    }

    // MARK: Back button (mirrors ReturnedWorkView's back control style)

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
    }

    // MARK: Main content (loading / error / essay)

    @ViewBuilder
    private var content: some View {
        if let error = app.submittedEssayError {
            errorCard(error)
        } else if let essay = app.submittedEssay {
            essayView(essay)
        } else {
            loadingView
        }
    }

    // MARK: Loading spinner

    private var loadingView: some View {
        VStack(spacing: Theme.Space.md) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
            Text("Loading your essay…")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Error card (house style — mirrors StudentClassHomeView's errorBanner)

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: Theme.Space.md) {
            Spacer()
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warn)
                    Text(message)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Button("Try again") {
                    guard let vgid = app.submittedVersionGroupId else {
                        // No version group id retained — fall back to home so
                        // the user can re-tap the Past row.
                        app.goToHome()
                        return
                    }
                    app.submittedEssayError = nil
                    Task { await app.loadSubmittedWork(versionGroupId: vgid) }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .font(Theme.sans(13, .semibold))
            }
            .padding(Theme.Space.lg)
            .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.warn.opacity(0.25), lineWidth: 1)
            )
            .frame(maxWidth: 480)
            .padding(.horizontal, Theme.Space.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Essay view

    private func essayView(_ essay: SubmittedEssay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header: serif title + muted meta line
                VStack(alignment: .leading, spacing: 6) {
                    Text(essay.title)
                        .font(Theme.serif(22, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metaLine(essay))
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.bottom, Theme.Space.lg)

                // White rounded "paper" card — identical treatment to
                // ReturnedWorkView's paperCanvas so the two views feel unified.
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    let paragraphs = ReturnedWorkView.paragraphs(fromHTML: essay.contentHtml)
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                        paragraphText(para)
                    }
                }
                .padding(.horizontal, 56)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.xxl)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Paragraph renderer (mirrors ReturnedWorkView.paragraphText exactly)

    /// Render one paragraph as a single SwiftUI Text. No comment highlights here
    /// (no grader annotations on a not-yet-returned essay), so all runs render in
    /// the same body style. The method mirrors ReturnedWorkView's paragraphText so
    /// the two views stay visually consistent as that method evolves.
    private func paragraphText(_ para: EssayParagraph) -> Text {
        var out = Text("")
        for run in para.runs {
            let t = Text(run.text)
                .font(Theme.serif(16))
                .foregroundColor(Theme.inkSoft)
            out = out + t
        }
        return out
    }

    // MARK: Helpers

    /// "Submitted Jan 5 · 312 words" meta line below the title.
    private func metaLine(_ essay: SubmittedEssay) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let dateStr = f.string(from: essay.submittedAt)
        let words = essay.wordCount
        return "Submitted \(dateStr) · \(words) \(words == 1 ? "word" : "words")"
    }
}

// MARK: - Preview

#Preview {
    // Seed the AppState with a submitted essay so the view renders without
    // a live backend session — same approach as ReturnedWorkView's preview.
    let state = AppState()
    state.submittedEssay = SubmittedEssay(
        title: "Analyze the use of light and dark imagery in the assigned passage.",
        contentHtml: """
            <p>From its opening lines, the passage sets light and dark against each other not \
            as opposites but as a single shifting field. The lantern in the window is never \
            simply a source of warmth; it is the one fixed point against which the surrounding \
            darkness is measured, and the narrator returns to it whenever the scene threatens \
            to lose its bearings.</p>
            <p>As the chapter progresses, the imagery turns inward. The shadows that gather in \
            the hall are described in the same language used earlier for the protagonist's doubt, \
            so that the darkness becomes a mirror of conscience rather than a threat from outside. \
            This doubling is what gives the passage its quiet tension: the reader is never sure \
            whether the light is protecting the character or merely exposing what they would \
            rather not see.</p>
            <p>By the final paragraph the two forces have collapsed into one. The dawn that breaks \
            over the courtyard is neither pure relief nor pure loss; it is simply the moment at \
            which the distinction stops mattering, and the character steps into a grey, undivided \
            day.</p>
            """,
        wordCount: 168,
        submittedAt: Calendar.current.date(byAdding: .day, value: -3, to: .now) ?? .now)
    return SubmittedWorkView()
        .environment(state)
        .preferredColorScheme(.light)
        .frame(width: 860, height: 720)
}

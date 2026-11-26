import SwiftUI

/// Quotes stay tied to the submitted paper as the student changes the new draft.
struct RevisionFeedbackPanel: View {
    @Environment(AppState.self) private var app
    let preview: Bool
    let onRetry: () -> Void

    private struct Note: Identifiable {
        let id: String
        let quote: String
        let body: String
        var quoteUnavailable = false
    }

    var body: some View {
        Group {
            if preview {
                returned(version: 1,
                         overall: "Your reading of light and shadow is clear. In your revision, connect one image to a specific change in the narrator.",
                         notes: [Note(id: "window", quote: "every lit window implies a surrounding dark",
                                      body: "What does the narrator notice through the window? Use that detail to support your reading.")])
            } else {
                switch app.examRevisionFeedback {
                case .loading:
                    ProgressView("Loading your feedback…").controlSize(.small)
                case .unavailable(let message):
                    status(message, button: "Check again")
                case .failed(let message):
                    status(message, button: "Try again")
                case .returned(let version, let work):
                    returned(version: version, overall: work.feedback,
                             overallUnavailable: work.feedbackUnavailable,
                             notes: work.sharedComments.map { comment in
                                 let quote = (comment.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                 return Note(id: comment.id, quote: quote, body: comment.body,
                                             quoteUnavailable: quote.isEmpty && comment.quoteCipher != nil)
                             })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(_ message: String, button: String) -> some View {
        VStack(spacing: Theme.Space.md) {
            Text(message)
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button(button, action: onRetry).buttonStyle(.bordered)
        }
        .padding(Theme.Space.xl)
    }

    private func returned(version: Int, overall: String, overallUnavailable: Bool = false,
                          notes: [Note]) -> some View {
        let hasOverall = !overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Feedback on Draft \(version)")
                    .font(Theme.serif(20, .semibold))
                    .accessibilityAddTraits(.isHeader)
                if hasOverall || overallUnavailable {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Kicker(text: "Overall comment")
                        Text(overallUnavailable ? "The overall comment couldn’t be opened." : overall)
                    }
                }
                if !notes.isEmpty {
                    Kicker(text: "Comments on your writing")
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            if !note.quote.isEmpty {
                                Text(verbatim: note.quote)
                                    .font(Theme.serif(14))
                                    .foregroundStyle(Theme.muted)
                                    .padding(.leading, Theme.Space.md)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(Theme.accent.opacity(0.4)).frame(width: 2)
                                    }
                            } else if note.quoteUnavailable {
                                Text("The original passage couldn’t be opened.")
                                    .foregroundStyle(Theme.muted)
                            }
                            Text(verbatim: note.body)
                        }
                        .padding(Theme.Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                } else if !hasOverall && !overallUnavailable {
                    Text("Your teacher returned this draft without comments.")
                        .foregroundStyle(Theme.muted)
                }
                if overallUnavailable || notes.contains(where: \.quoteUnavailable) {
                    Button("Try again", action: onRetry).buttonStyle(.bordered)
                }
            }
            .font(Theme.sans(14))
            .foregroundStyle(Theme.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.xl)
        }
    }
}

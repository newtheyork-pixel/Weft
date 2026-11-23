//
//  DraftPaperView.swift
//  Weft: the pieces the grading screen uses to show a student's other
//  drafts: the draft switcher, a read-only paper laid out exactly where the
//  graded paper sits (so switching never makes the page jump), and a
//  read-only text view for a compared (diffed) paper.
//

import SwiftUI
import AppKit

// MARK: - Switcher

/// "Draft 1 · Draft 2 · Draft 3" as one compact segmented control. The
/// graded draft is marked; the selected one is raised.
struct DraftSwitcher: View {
    let drafts: [StudentDraft]
    /// The draft being graded (the session's own paper).
    let gradedId: String
    let selectedId: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(drafts) { d in segment(d) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.06)))
        .fixedSize()
    }

    private func segment(_ d: StudentDraft) -> some View {
        let selected = d.id == selectedId
        let graded = d.id == gradedId
        return Button { onSelect(d.id) } label: {
            HStack(spacing: 5) {
                Text(d.label)
                    .font(.system(size: 12, weight: .semibold))
                if graded {
                    Text("Grading")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.good)
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.10), radius: 1.5, x: 0, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help(graded ? "\(d.label) is the one you are grading. \u{2318}[ and \u{2318}] move between drafts."
                     : "Show \(d.label). \u{2318}[ and \u{2318}] move between drafts.")
        .accessibilityLabel(graded ? "\(d.label), being graded" : d.label)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Read-only paper

/// The white paper at the same size and place as the graded paper, with the
/// comment column left empty. Holds an older draft, a diff, or a message.
struct DraftPaperFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let m = MarginedPaper.metrics(for: geo.size.width, canComment: true)
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    content()
                        .padding(.vertical, m.padV)
                        .padding(.horizontal, m.padH)
                        .frame(width: m.paperWidth, alignment: .topLeading)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1))
                    Color.clear.frame(width: m.gutter + m.column, height: 1)
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xxxl)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A short message in place of a paper (sealed elsewhere, empty, working).
struct DraftPaperMessage: View {
    let title: String
    let message: String
    var system: String? = nil

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            if let system {
                Image(systemName: system)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Theme.muted2)
                    .padding(.bottom, Theme.Space.xs)
            }
            Text(title)
                .font(Theme.sans(16, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text(message)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)
    }
}

// MARK: - Attributed paper (the compare view)

/// A read-only, selectable text view for a styled paper. Same wrapping as
/// PaperTextView: the live container tracks the view's width, and sizing
/// measures a copy of the text, never the live container.
struct AttributedPaperView: NSViewRepresentable {
    let text: NSAttributedString
    var accessibilityLabel: String = "Compared drafts"

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        tv.setAccessibilityLabel(accessibilityLabel)
        tv.textStorage?.setAttributedString(text)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        guard let storage = tv.textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        tv.setAccessibilityLabel(accessibilityLabel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView,
                      context: Context) -> CGSize? {
        let proposed = proposal.width ?? 640
        let width = proposed.isFinite && proposed > 0 ? proposed : 640
        let box = text.boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: max(ceil(box.height) + 4, 20))
    }
}

/// A finished comparison: the counts and the styled paper.
struct DraftComparison {
    let added: Int
    let removed: Int
    let text: NSAttributedString

    /// "+120 words, −45 words since Draft 1".
    func summary(since label: String) -> String {
        if added == 0 && removed == 0 { return "No changes to the words since \(label)" }
        func words(_ n: Int) -> String { n == 1 ? "1 word" : "\(n) words" }
        return "+\(words(added)), \u{2212}\(words(removed)) since \(label)"
    }
}

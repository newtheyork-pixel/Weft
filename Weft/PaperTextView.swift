//
//  PaperTextView.swift
//  Weft: the student's paper in the grading view, as a read-only text view
//  that reports the teacher's selection, so a margin comment quotes exactly
//  what was selected (no copy and paste). Passages that already have a
//  comment are softly highlighted.
//

import SwiftUI
import AppKit

struct PaperTextView: NSViewRepresentable {
    let paragraphs: [String]
    /// Quotes of existing comments, highlighted on the paper.
    var highlights: [String] = []
    /// The selected text, trimmed; "" when nothing is selected.
    @Binding var selection: String

    private static let font = NSFont.systemFont(ofSize: 15)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PaperTextView
        var lastText = ""
        var lastHighlights: [String] = []
        init(_ parent: PaperTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let r = tv.selectedRange()
            let text = r.length > 0 ? (tv.string as NSString).substring(with: r) : ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if parent.selection != trimmed {
                DispatchQueue.main.async { self.parent.selection = trimmed }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Student's essay")
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        let text = paragraphs.joined(separator: "\n")
        guard text != context.coordinator.lastText
                || highlights != context.coordinator.lastHighlights else { return }
        let keep = tv.selectedRange()
        tv.textStorage?.setAttributedString(Self.attributed(text, highlights: highlights))
        if text == context.coordinator.lastText, NSMaxRange(keep) <= (text as NSString).length {
            tv.setSelectedRange(keep)
        }
        context.coordinator.lastText = text
        context.coordinator.lastHighlights = highlights
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView,
                      context: Context) -> CGSize? {
        // Measure a copy of the text, never the live container: the live one
        // tracks the view's real width (widthTracksTextView), and resizing it
        // here made the text wrap in a narrow column and clip at the bottom.
        let proposed = proposal.width ?? 640
        let width = proposed.isFinite && proposed > 0 ? proposed : 640
        let text = Self.attributed(paragraphs.joined(separator: "\n"), highlights: [])
        let box = text.boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: max(ceil(box.height) + 4, 20))
    }

    private static func attributed(_ text: String, highlights: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 18
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ])
        let ns = text as NSString
        for quote in highlights where !quote.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: quote, options: [], range: search)
                guard found.location != NSNotFound else { break }
                out.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.28), range: found)
                let next = NSMaxRange(found)
                guard next < ns.length else { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return out
    }
}

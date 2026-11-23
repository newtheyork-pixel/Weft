//
//  PaperTextView.swift
//  Weft: the student's paper as a read-only text view. It reports the
//  teacher's selection (with its real UTF-16 range in the plain text), paints
//  comment highlights by range, tells the margin where each highlight sits
//  vertically, and reports clicks on a highlight. Used by the grading screen
//  and, read-only, by the student's returned-work screen.
//

import SwiftUI
import AppKit

/// One highlighted passage on the paper, tied to a comment id.
struct PaperMark: Equatable {
    enum Style: Equatable { case normal, active, draft, hidden }
    let id: String
    let range: NSRange
    var style: Style
}

/// The current selection on the paper: its range in the plain text (trimmed
/// of surrounding whitespace), the selected words, and the top of its first
/// line in the text view's coordinates.
struct PaperSelection: Equatable {
    var range: NSRange
    var text: String
    var top: CGFloat
}

/// The essay's plain text, built the same way on the teacher's and the
/// student's Mac, so a comment's stored range points at the same words.
enum PaperText {
    static func plain(_ paragraphs: [String]) -> String {
        paragraphs.joined(separator: "\n")
    }

    /// Cheap HTML to paragraphs: block closers become line breaks, the other
    /// tags go, a few entities are decoded (`&amp;` last, so the result never
    /// depends on the order), blank blocks are dropped.
    static func paragraphs(fromHTML html: String) -> [String] {
        guard !html.isEmpty else { return [] }
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
        return blocks.isEmpty
            ? [decoded.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
            : blocks
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let ordered: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"),
        ]
        for (k, v) in ordered { out = out.replacingOccurrences(of: k, with: v) }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Where a comment's passage is in `text`: its stored range when the words
    /// there still match the quote, else the match nearest the stored start,
    /// else nil ("passage not found").
    static func anchor(rangeStart: Int, rangeEnd: Int, quote: String, in text: String) -> NSRange? {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let ns = text as NSString
        if rangeStart >= 0, rangeEnd > rangeStart, rangeEnd <= ns.length {
            let r = NSRange(location: rangeStart, length: rangeEnd - rangeStart)
            if ns.substring(with: r) == q { return r }
        }
        var best: NSRange?
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: q, options: [], range: search)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - rangeStart) < abs(best!.location - rangeStart) {
                best = found
            }
            let next = found.location + 1
            guard next < ns.length else { break }
            search = NSRange(location: next, length: ns.length - next)
        }
        return best
    }
}

/// NSTextView that reports frame changes (so the margin can re-align after a
/// resize) and plain clicks (so a click on a highlight opens its comment).
final class PaperNSTextView: NSTextView {
    var onFrameChange: (() -> Void)?
    var onPlainClick: ((Int?) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onFrameChange?() }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)   // runs the selection loop until mouse up
        guard selectedRange().length == 0 else { return }
        onPlainClick?(characterIndex(atViewPoint: convert(event.locationInWindow, from: nil)))
    }

    /// The character under a point, or nil when the point is not on text.
    func characterIndex(atViewPoint p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let origin = textContainerOrigin
        let pt = NSPoint(x: p.x - origin.x, y: p.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -1, dy: -2).contains(pt) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    /// Top of the first line of `range`, in view coordinates (flipped).
    func top(of range: NSRange) -> CGFloat? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let length = (string as NSString).length
        guard range.location <= length else { return nil }
        let clamped = NSRange(location: range.location,
                              length: max(0, min(range.length, length - range.location)))
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        return rect.minY + textContainerOrigin.y
    }
}

struct PaperTextView: NSViewRepresentable {
    let paragraphs: [String]
    /// Highlighted passages (comments, the draft). `.hidden` marks paint
    /// nothing but still report their position (resolved comments).
    var marks: [PaperMark] = []
    /// Bump to clear the selection (after a comment is posted or cancelled).
    var clearSelectionToken: Int = 0
    /// The selection, or nil when nothing is selected.
    var onSelection: ((PaperSelection?) -> Void)? = nil
    /// Top of every mark, by id, in the text view's coordinates.
    var onMarkTops: (([String: CGFloat]) -> Void)? = nil
    /// A plain click: the id of the highlight under it, or nil.
    var onMarkClick: ((String?) -> Void)? = nil

    static let font = NSFont.systemFont(ofSize: 15)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PaperTextView
        var lastText = ""
        var lastMarks: [PaperMark] = []
        var lastToken = 0
        var lastTops: [String: CGFloat] = [:]
        var lastSelection: PaperSelection?
        weak var textView: PaperNSTextView?
        private var geometryQueued = false

        init(_ parent: PaperTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportSelection()
        }

        func reportSelection() {
            guard let tv = textView else { return }
            let sel = Self.selection(in: tv)
            guard sel != lastSelection else { return }
            lastSelection = sel
            let callback = parent.onSelection
            DispatchQueue.main.async { callback?(sel) }
        }

        /// Recompute tops (and the selection's top) once the layout settles.
        func queueGeometry() {
            guard !geometryQueued else { return }
            geometryQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryQueued = false
                self.reportTops()
                self.reportSelection()
            }
        }

        private func reportTops() {
            guard let tv = textView else { return }
            var tops: [String: CGFloat] = [:]
            for m in parent.marks {
                if let y = tv.top(of: m.range) { tops[m.id] = y.rounded() }
            }
            guard tops != lastTops else { return }
            lastTops = tops
            parent.onMarkTops?(tops)
        }

        func click(at index: Int?) {
            guard let cb = parent.onMarkClick else { return }
            guard let index else { cb(nil); return }
            // The smallest mark under the click wins (a short comment inside a
            // longer one stays reachable). Draft marks are not clickable.
            let hit = parent.marks
                .filter { $0.style != .draft && $0.style != .hidden
                    && index >= $0.range.location && index < NSMaxRange($0.range) }
                .min { $0.range.length < $1.range.length }
            cb(hit?.id)
        }

        private static func selection(in tv: PaperNSTextView) -> PaperSelection? {
            let ns = tv.string as NSString
            var r = tv.selectedRange()
            guard r.length > 0, NSMaxRange(r) <= ns.length else { return nil }
            let ws = CharacterSet.whitespacesAndNewlines
            func isSpace(_ c: unichar) -> Bool {
                guard let u = Unicode.Scalar(c) else { return false }
                return ws.contains(u)
            }
            while r.length > 0, isSpace(ns.character(at: r.location)) { r.location += 1; r.length -= 1 }
            while r.length > 0, isSpace(ns.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
            guard r.length > 0 else { return nil }
            return PaperSelection(range: r, text: ns.substring(with: r),
                                  top: (tv.top(of: r) ?? 0).rounded())
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PaperNSTextView {
        let tv = PaperNSTextView()
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
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Student's essay")
        let coordinator = context.coordinator
        coordinator.textView = tv
        tv.onFrameChange = { [weak coordinator] in coordinator?.queueGeometry() }
        tv.onPlainClick = { [weak coordinator] index in coordinator?.click(at: index) }
        return tv
    }

    func updateNSView(_ tv: PaperNSTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let text = PaperText.plain(paragraphs)
        if text != c.lastText || marks != c.lastMarks {
            let keep = tv.selectedRange()
            tv.textStorage?.setAttributedString(Self.attributed(text, marks: marks))
            if text == c.lastText, NSMaxRange(keep) <= (text as NSString).length {
                tv.setSelectedRange(keep)
            }
            if text != c.lastText { c.lastTops = [:] }
            c.lastText = text
            c.lastMarks = marks
            c.queueGeometry()
        }
        if clearSelectionToken != c.lastToken {
            c.lastToken = clearSelectionToken
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: PaperNSTextView,
                      context: Context) -> CGSize? {
        // Measure a copy of the text, never the live container: the live one
        // tracks the view's real width (widthTracksTextView), and resizing it
        // here made the text wrap in a narrow column and clip at the bottom.
        let proposed = proposal.width ?? 640
        let width = proposed.isFinite && proposed > 0 ? proposed : 640
        let text = Self.attributed(PaperText.plain(paragraphs), marks: [])
        let box = text.boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: max(ceil(box.height) + 4, 20))
    }

    /// Soft yellow for a comment, stronger for the open one (the Docs idiom).
    static let markColor = NSColor(srgbRed: 1.0, green: 0.83, blue: 0.25, alpha: 0.30)
    static let activeMarkColor = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.05, alpha: 0.55)
    static let draftMarkColor = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.20, alpha: 0.42)

    private static func attributed(_ text: String, marks: [PaperMark]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 18
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ])
        let length = (text as NSString).length
        // Plain marks first, then the draft, then the open one on top.
        let order: [PaperMark.Style] = [.normal, .draft, .active]
        for s in order {
            for m in marks where m.style == s {
                guard m.range.location >= 0, NSMaxRange(m.range) <= length, m.range.length > 0 else { continue }
                let color: NSColor = switch s {
                case .active: activeMarkColor
                case .draft: draftMarkColor
                default: markColor
                }
                out.addAttribute(.backgroundColor, value: color, range: m.range)
            }
        }
        return out
    }
}

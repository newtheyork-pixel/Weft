//
//  RichTextHTML.swift
//  Weft — serialize an exam essay (NSAttributedString) to the sanitized HTML
//  subset the Electron app produces and the teacher grading view + web portal
//  already render: <h1> <h2> <p> <ul> <ol> <li> <b> <i> <u> <br>.
//  Pure AppKit, no project dependencies (standalone-testable with swiftc).
//

import AppKit

enum RichTextHTML {

    /// Convert `text` to subset HTML. Paragraphs whose first character's font
    /// is at least `h1Size` / `h2Size` points become <h1> / <h2>; paragraphs
    /// whose style carries an NSTextList become <li> grouped into <ul>/<ol>;
    /// everything else is a <p>. Inline bold/italic/underline come from font
    /// traits + the underline attribute. Headings suppress <b> (they are
    /// already visually bold).
    static func html(from text: NSAttributedString,
                     h1Size: CGFloat = 28,
                     h2Size: CGFloat = 21) -> String {
        guard text.length > 0 else { return "" }
        let ns = text.string as NSString

        enum Block { case p, h1, h2, li(ordered: Bool) }
        var out = ""
        var openList: Bool? = nil   // nil = no list open; true = <ol>, false = <ul>

        func closeList() {
            if let ordered = openList { out += ordered ? "</ol>" : "</ul>" }
            openList = nil
        }

        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, pRange, _, _ in
            var contentRange = pRange
            var block = Block.p
            if pRange.length > 0 {
                let attrs = text.attributes(at: pRange.location, effectiveRange: nil)
                let style = attrs[.paragraphStyle] as? NSParagraphStyle
                let font = attrs[.font] as? NSFont
                if let list = style?.textLists.first {
                    block = .li(ordered: list.markerFormat == .decimal)
                    // Strip the "\t<marker>\t" prefix from the item content.
                    if let prefix = markerPrefixLength(of: ns.substring(with: pRange)) {
                        contentRange = NSRange(location: pRange.location + prefix,
                                               length: pRange.length - prefix)
                    }
                } else if let size = font?.pointSize {
                    if size >= h1Size { block = .h1 }
                    else if size >= h2Size { block = .h2 }
                }
            }

            let suppressBold: Bool
            switch block { case .h1, .h2: suppressBold = true; default: suppressBold = false }
            let inner = inlineHTML(of: text, in: contentRange, suppressBold: suppressBold)

            switch block {
            case .li(let ordered):
                if openList != ordered { closeList(); out += ordered ? "<ol>" : "<ul>"; openList = ordered }
                out += "<li>\(inner.isEmpty ? "<br>" : inner)</li>"
            case .h1:
                closeList(); out += "<h1>\(inner.isEmpty ? "<br>" : inner)</h1>"
            case .h2:
                closeList(); out += "<h2>\(inner.isEmpty ? "<br>" : inner)</h2>"
            case .p:
                closeList(); out += "<p>\(inner.isEmpty ? "<br>" : inner)</p>"
            }
        }
        closeList()
        return out
    }

    /// UTF-16 length of a leading "\t<marker>\t" run, or nil. (Duplicated from
    /// RichTextController so this file stays dependency-free.)
    private static func markerPrefixLength(of paragraph: String) -> Int? {
        let ns = paragraph as NSString
        guard ns.length >= 3, ns.character(at: 0) == 9 else { return nil }
        var i = 1
        while i < ns.length, ns.character(at: i) != 9 { i += 1 }
        guard i < ns.length else { return nil }
        return i + 1
    }

    /// Serialize the inline runs of one paragraph: escaped text wrapped in
    /// <b>/<i>/<u> per run.
    private static func inlineHTML(of text: NSAttributedString, in range: NSRange, suppressBold: Bool) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        text.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
            let raw = (text.string as NSString).substring(with: runRange)
            guard !raw.isEmpty else { return }
            var piece = escape(raw)
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let underlined = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            if underlined { piece = "<u>\(piece)</u>" }
            if traits.contains(.italic) { piece = "<i>\(piece)</i>" }
            if traits.contains(.bold), !suppressBold { piece = "<b>\(piece)</b>" }
            out += piece
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

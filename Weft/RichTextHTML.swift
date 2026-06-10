//
//  RichTextHTML.swift
//  Weft — serialize an exam essay (NSAttributedString) to the sanitized HTML
//  subset the Electron app produces and the teacher grading view already
//  renders: <h1> <h2> <p> <ul> <ol> <li> <b> <i> <u> <br> plus
//  <span style="…"> for font-family / font-size / color / background-color.
//  Pure AppKit, no project dependencies (standalone-testable with swiftc).
//
//  CONSUMER CAVEATS: Electron's grading-view sanitizer strips font-size and
//  line-height style values; font-family, color, and background-color
//  survive, so teachers see family+colors there but not custom sizes or
//  spacing. The web portal forbids the style attribute entirely (DOMPurify
//  FORBID_ATTR), so it renders the tag subset with no span styles at all.
//

import AppKit

enum RichTextHTML {

    /// Convert `text` to subset HTML. Paragraphs whose first character's font
    /// is at least `h1Size` / `h2Size` points become <h1> / <h2>; paragraphs
    /// whose style carries an NSTextList become <li> grouped into <ul>/<ol>;
    /// everything else is a <p>. Inline bold/italic/underline come from font
    /// traits + the underline attribute. Headings suppress <b> (they are
    /// already visually bold). Inline runs whose font-family / font-size /
    /// foreground-color / background-color differ from the defaults gain a
    /// <span style="…">. Defaults match RichTextStyle: Times New Roman 12.
    /// Note: Electron's grading sanitizer strips font-size and line-height;
    /// family/color/background-color survive.
    static func html(from text: NSAttributedString,
                     h1Size: CGFloat = 28,
                     h2Size: CGFloat = 21,
                     defaultFamily: String = "Times New Roman",
                     defaultSize: CGFloat = 12) -> String {
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
            let inner = inlineHTML(of: text, in: contentRange,
                                   suppressBold: suppressBold,
                                   defaultFamily: defaultFamily,
                                   defaultSize: defaultSize)

            // Emit line-height on block when it differs from the 2.0 default.
            let lineHeightAttr: String = {
                let attrs = pRange.length > 0
                    ? text.attributes(at: pRange.location, effectiveRange: nil)
                    : [:]
                let style = attrs[.paragraphStyle] as? NSParagraphStyle
                let multiple = style?.lineHeightMultiple ?? 0
                if multiple > 0, abs(multiple - 2.0) > 0.01 {
                    return " style=\"line-height: \(multiple)\""
                }
                return ""
            }()

            switch block {
            case .li(let ordered):
                if openList != ordered { closeList(); out += ordered ? "<ol>" : "<ul>"; openList = ordered }
                out += "<li\(lineHeightAttr)>\(inner.isEmpty ? "<br>" : inner)</li>"
            case .h1:
                // Headings carry their own canonical leading (1.15); re-stating
                // it as line-height would be default-noise, not student intent.
                closeList(); out += "<h1>\(inner.isEmpty ? "<br>" : inner)</h1>"
            case .h2:
                closeList(); out += "<h2>\(inner.isEmpty ? "<br>" : inner)</h2>"
            case .p:
                closeList(); out += "<p\(lineHeightAttr)>\(inner.isEmpty ? "<br>" : inner)</p>"
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

    // Default ink color tied to RichTextStyle.inkColor (#22201c).
    private static let defaultInkHex = "#22201c"

    /// Serialize the inline runs of one paragraph: escaped text wrapped in
    /// <b>/<i>/<u> and <span style="…"> per run. Span styles are emitted only
    /// when the run's value differs from the document defaults (family /
    /// size / ink color) so default-looking text produces no extra markup.
    private static func inlineHTML(of text: NSAttributedString,
                                   in range: NSRange,
                                   suppressBold: Bool,
                                   defaultFamily: String = "Times New Roman",
                                   defaultSize: CGFloat = 12) -> String {
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

            var styles: [String] = []
            if let font = attrs[.font] as? NSFont {
                // Defense in depth: familyName only ever reports an installed
                // font's name, but the value lands inside a quoted attribute,
                // so strip the characters that could break out of it or
                // smuggle an extra declaration past a weaker consumer.
                let family = (font.familyName ?? "").filter { !"\";<>".contains($0) }
                if !family.isEmpty, family != defaultFamily {
                    styles.append("font-family: \(family)")
                }
                if abs(font.pointSize - defaultSize) > 0.1,
                   // Headings carry their own sizes; don't re-state them.
                   !suppressBold {
                    styles.append("font-size: \(Int(round(font.pointSize)))px")
                }
            }
            if let color = attrs[.foregroundColor] as? NSColor,
               let hex = hexString(color), hex != defaultInkHex {
                styles.append("color: \(hex)")
            }
            if let bg = attrs[.backgroundColor] as? NSColor, let hex = hexString(bg) {
                styles.append("background-color: \(hex)")
            }
            if !styles.isEmpty {
                piece = "<span style=\"\(styles.joined(separator: "; "))\">\(piece)</span>"
            }

            out += piece
        }
        return out
    }

    /// sRGB hex ("#rrggbb") for a color; nil when it can't be converted.
    private static func hexString(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            // Option+Return inserts U+2028 LINE SEPARATOR, which NSTextView
            // renders as a soft break but browsers ignore entirely — without
            // this mapping the student's line break silently vanishes in the
            // grading view. Safe to inject after escaping: a user-typed "<"
            // is already &lt; by now, so this is the only "<br>" possible.
            .replacingOccurrences(of: "\u{2028}", with: "<br>")
    }
}

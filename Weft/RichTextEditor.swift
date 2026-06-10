//
//  RichTextEditor.swift
//  Weft — the clean writing surface for the essay exam window.
//
//  Native counterpart to the Electron contenteditable editor
//  (Tessera/renderer/essay-editor.js). That one is a Google-Docs-style
//  contenteditable driven by document.execCommand; here we wrap a real
//  AppKit NSTextView inside an NSScrollView via NSViewRepresentable, which
//  gives us native typing, undo, spell-check, IME, and selection for free.
//
//  This is the WHITE page — the clean writing surface, deliberately NOT glass.
//  Glass is for chrome (toolbars, cards); the page a student writes on should
//  read as opaque paper.
//
//  Public surface:
//    RichTextEditor(controller: controller, onEdit: { ... })   // view
//    RichTextToolbar(controller: controller)        // Bold/Italic/Underline/H1/H2/Bulleted list/Numbered list
//    controller.wordCount / setContent(_:) / snapshot()        // document access
//
//  The controller is the shared link between the SwiftUI toolbar and the live
//  NSTextView, and it OWNS document access: the text view holds the essay (no
//  per-keystroke SwiftUI binding round-trip), the editor registers its text
//  view on the controller, and the toolbar buttons route formatting commands
//  back to it.
//

import SwiftUI
import AppKit

// MARK: - Editor controller (shared bridge between toolbar and text view)

/// Holds a weak reference to the active NSTextView so a detached SwiftUI
/// toolbar can drive formatting on it. One controller per editor instance.
@MainActor
@Observable
final class RichTextController {
    /// The live text view, registered by the editor's Coordinator. Weak so the
    /// controller never keeps a dead view alive.
    weak var textView: NSTextView?

    /// Content handed to `setContent` before the live text view registered
    /// (e.g. the preview seed runs before makeNSView's async registration).
    private var pendingContent: NSAttributedString?

    /// Words in the document. Recomputed on every edit; @Observable, so labels
    /// update without the document itself ever crossing into SwiftUI state.
    private(set) var wordCount: Int = 0

    /// Called by the editor when the live text view appears. Applies any
    /// content that arrived early and primes the word count.
    func register(_ tv: NSTextView) {
        textView = tv
        if let pending = pendingContent {
            pendingContent = nil
            tv.textStorage?.setAttributedString(pending)
        }
        recountWords()
    }

    /// Replace the whole document (preview seeding; later, draft restore).
    func setContent(_ text: NSAttributedString) {
        guard let tv = textView, let storage = tv.textStorage else {
            pendingContent = text
            return
        }
        storage.setAttributedString(text)
        tv.typingAttributes = RichTextStyle.body.attributes()
        recountWords()
    }

    /// Snapshot for save/submit — the ONLY place the document is copied.
    /// Falls back to content staged via setContent before the view registered
    /// (the advertised draft-restore flow) so an early save is never empty.
    func snapshot() -> NSAttributedString {
        if let tv = textView {
            return (tv.attributedString().copy() as? NSAttributedString) ?? NSAttributedString()
        }
        return pendingContent ?? NSAttributedString()
    }

    /// Recompute the published word count from the live document. Matches the
    /// web editor's `trimmed.split(/\s+/)` rule; list markers are layout chrome
    /// and never counted.
    func recountWords() {
        guard let tv = textView, let storage = tv.textStorage else {
            if wordCount != 0 { wordCount = 0 }
            return
        }
        let ns = storage.string as NSString
        var count = 0
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, pRange, _, _ in
            guard pRange.length > 0 else { return }
            var text = ns.substring(with: pRange)
            if let style = storage.attribute(.paragraphStyle, at: pRange.location, effectiveRange: nil) as? NSParagraphStyle,
               !style.textLists.isEmpty,
               let prefix = RichTextController.markerPrefixLength(of: text) {
                text = (text as NSString).substring(from: prefix)
            }
            count += text.split(whereSeparator: \.isWhitespace).count
        }
        // @Observable fires on every set; only publish real changes so a
        // mid-word keystroke doesn't invalidate the host view for nothing.
        if wordCount != count { wordCount = count }
    }

    init() {}

    // MARK: Inline character formatting

    /// Bold / Italic toggle the matching symbolic trait on the selection's font
    /// (or the typing attributes when the selection is empty), so the behavior
    /// matches every other native Mac editor. We mutate the font traits directly
    /// rather than relying on the runtime-only NSResponder action selectors,
    /// which keeps this fully type-checked and dependency-free.
    func toggleBold()   { toggleTrait(.bold) }
    func toggleItalic() { toggleTrait(.italic) }

    /// Underline toggles the .underlineStyle attribute on the selection.
    func toggleUnderline() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()

        if range.length == 0 {
            // Empty selection: flip the typing attribute for the next keystrokes.
            var typing = tv.typingAttributes
            let on = (typing[.underlineStyle] as? Int) ?? 0
            typing[.underlineStyle] = on == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = typing
            return
        }

        // Apply the inverse of the first character's state across the selection.
        let firstOn = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int) ?? 0
        let newValue = firstOn == 0 ? NSUnderlineStyle.single.rawValue : 0
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.underlineStyle, value: newValue, range: range)
        storage.endEditing()
        tv.didChangeText()
    }

    /// Flip a symbolic font trait (bold/italic) across the selection or, when
    /// empty, on the typing attributes.
    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()

        if range.length == 0 {
            let base = (tv.typingAttributes[.font] as? NSFont) ?? RichTextStyle.bodyFont
            var typing = tv.typingAttributes
            typing[.font] = RichTextController.font(base, togglingTrait: trait)
            tv.typingAttributes = typing
            return
        }

        // Decide the target state from the first character, then apply uniformly.
        let firstFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            ?? RichTextStyle.bodyFont
        let shouldEnable = !firstFont.fontDescriptor.symbolicTraits.contains(trait)

        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let current = (value as? NSFont) ?? RichTextStyle.bodyFont
            let updated = RichTextController.font(current, settingTrait: trait, enabled: shouldEnable)
            storage.addAttribute(.font, value: updated, range: subRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    /// Return `font` with `trait` flipped.
    static func font(_ font: NSFont, togglingTrait trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let enabled = font.fontDescriptor.symbolicTraits.contains(trait)
        return self.font(font, settingTrait: trait, enabled: !enabled)
    }

    /// Return `font` with `trait` set to `enabled`, preserving size and family.
    static func font(_ font: NSFont,
                     settingTrait trait: NSFontDescriptor.SymbolicTraits,
                     enabled: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if enabled { traits.insert(trait) } else { traits.remove(trait) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: Block formatting

    /// Apply the H1 heading style to the paragraph(s) touching the selection.
    func applyHeading1() { applyHeading(RichTextStyle.h1) }
    /// Apply the H2 heading style to the paragraph(s) touching the selection.
    func applyHeading2() { applyHeading(RichTextStyle.h2) }
    /// Reset the paragraph(s) back to the serif body style.
    func applyBody()     { applyHeading(RichTextStyle.body) }

    func toggleBulletedList() { toggleList(.disc) }
    func toggleNumberedList() { toggleList(.decimal) }

    /// Toggle a list of `format` on the paragraph(s) touching the selection.
    /// Re-toggling the same format strips it; toggling the other format
    /// converts in place. One pass, back-to-front, with the REAL per-paragraph
    /// edits declared to shouldChangeText so undo restores the text coherently
    /// (the reapplied paragraph style rides along and the next toggle resets it).
    /// Numbering restarts at 1 for each toggle; renumber-on-edit is the
    /// key-handling task's job.
    private func toggleList(_ format: NSTextList.MarkerFormat) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        let pRange = ns.paragraphRange(for: tv.selectedRange())
        let paragraphs = Self.paragraphRanges(of: ns, in: pRange)
        guard !paragraphs.isEmpty else { return }
        let already = listFormat(at: pRange.location, in: storage) == format

        let list = NSTextList(markerFormat: format, options: 0)
        let style = RichTextStyle.listParagraphStyle(list)

        // Per paragraph: replace the existing "\t<marker>\t" prefix (length 0
        // when absent) with the new marker, or with nothing when toggling off.
        var editRanges: [NSRange] = []
        var editStrings: [String] = []
        for (n, p) in paragraphs.enumerated() {
            let isListItem = p.length > 0
                && ((storage.attribute(.paragraphStyle, at: p.location, effectiveRange: nil)
                        as? NSParagraphStyle)?.textLists.isEmpty == false)
            let prefixLen = isListItem
                ? (Self.markerPrefixLength(of: ns.substring(with: p)) ?? 0) : 0
            editRanges.append(NSRange(location: p.location, length: prefixLen))
            editStrings.append(already ? "" : "\t" + list.marker(forItemNumber: n + 1) + "\t")
        }
        guard tv.shouldChangeText(inRanges: editRanges.map { NSValue(range: $0) },
                                  replacementStrings: editStrings) else { return }

        let newParagraphStyle = already ? RichTextStyle.bodyParagraphStyle() : style
        storage.beginEditing()
        // Back-to-front so earlier paragraph locations stay valid as text
        // shifts; each paragraph's style range is recomputed post-edit.
        for i in paragraphs.indices.reversed() {
            storage.replaceCharacters(
                in: editRanges[i],
                with: NSAttributedString(string: editStrings[i], attributes: [
                    .font: RichTextStyle.bodyFont,
                    .foregroundColor: RichTextStyle.inkColor,
                    .paragraphStyle: newParagraphStyle,
                ]))
            let widened = (storage.string as NSString)
                .paragraphRange(for: NSRange(location: paragraphs[i].location, length: 0))
            storage.addAttribute(.paragraphStyle, value: newParagraphStyle, range: widened)
        }
        storage.endEditing()
        tv.didChangeText()
        if already {
            tv.typingAttributes = RichTextStyle.body.attributes()
        } else {
            var typing = tv.typingAttributes
            typing[.paragraphStyle] = style
            tv.typingAttributes = typing
        }
        recountWords()
    }

    /// The marker format of the list item at `location`, nil when not a list.
    /// A caret on the zero-length trailing paragraph has no attributes of its
    /// own; reading a clamped previous index would leak the PREVIOUS
    /// paragraph's list state (and make toggling a fresh trailing line a
    /// no-op), so anything at or past the end is simply "not a list".
    private func listFormat(at location: Int, in storage: NSTextStorage) -> NSTextList.MarkerFormat? {
        guard location < storage.length else { return nil }
        let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return style?.textLists.first?.markerFormat
    }

    /// UTF-16 length of a leading "\t<marker>\t" run, or nil when absent.
    static func markerPrefixLength(of paragraph: String) -> Int? {
        let ns = paragraph as NSString
        guard ns.length >= 3, ns.character(at: 0) == 9 else { return nil }   // 9 == \t
        var i = 1
        while i < ns.length, ns.character(at: i) != 9 { i += 1 }
        guard i < ns.length else { return nil }   // no closing tab
        return i + 1
    }

    /// Paragraph ranges covering `range`, INCLUDING the zero-length trailing
    /// paragraph (the empty line after a trailing newline), which NSString's
    /// .byParagraphs enumeration never emits -- dropping it is how a list's
    /// empty final item used to lose its marker on conversion.
    static func paragraphRanges(of ns: NSString, in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var loc = range.location
        repeat {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            result.append(p)
            loc = NSMaxRange(p) + (p.length == 0 ? 1 : 0)   // always make progress
        } while loc < NSMaxRange(range)
        return result
    }

    // MARK: List key behavior (called by WeftTextView)

    /// Return on an EMPTY list item ends the list (Google Docs). True = handled.
    func endListIfEmptyItem() -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let ns = storage.string as NSString
        let p = ns.paragraphRange(for: tv.selectedRange())
        guard p.length > 0,
              let style = storage.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle,
              !style.textLists.isEmpty else { return false }
        let text = ns.substring(with: p)
        guard let prefix = Self.markerPrefixLength(of: text) else { return false }
        let rest = (text as NSString).substring(from: prefix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.isEmpty else { return false }

        // Strip the marker as a DECLARED text edit so undo stays coherent.
        let strip = NSRange(location: p.location, length: prefix)
        guard tv.shouldChangeText(in: strip, replacementString: "") else { return true }
        storage.beginEditing()
        storage.replaceCharacters(in: strip, with: "")
        let newP = (storage.string as NSString).paragraphRange(for: NSRange(location: p.location, length: 0))
        storage.addAttribute(.paragraphStyle, value: RichTextStyle.bodyParagraphStyle(), range: newP)
        storage.endEditing()
        tv.didChangeText()
        tv.typingAttributes = RichTextStyle.body.attributes()
        recountWords()
        return true
    }

    /// After a plain newline inside a list item, carry the list onto the new
    /// paragraph with the next marker. No-ops when the previous paragraph is
    /// not a list item or when the marker is already there (AppKit carried it).
    func continueListAfterNewlineIfNeeded() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let caret = tv.selectedRange().location
        guard caret > 0 else { return }
        let ns = storage.string as NSString
        let newP = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        guard newP.location > 0 else { return }
        let prevP = ns.paragraphRange(for: NSRange(location: newP.location - 1, length: 0))
        guard prevP.length > 0,
              let prevStyle = storage.attribute(.paragraphStyle, at: prevP.location, effectiveRange: nil) as? NSParagraphStyle,
              let list = prevStyle.textLists.first else { return }
        if Self.markerPrefixLength(of: ns.substring(with: newP)) != nil { return }   // already carried

        let marker = "\t" + list.marker(forItemNumber: itemNumber(of: prevP, in: storage) + 1) + "\t"
        let insert = NSRange(location: newP.location, length: 0)
        guard tv.shouldChangeText(in: insert, replacementString: marker) else { return }
        storage.beginEditing()
        storage.replaceCharacters(
            in: insert,
            with: NSAttributedString(string: marker, attributes: [
                .font: RichTextStyle.bodyFont,
                .foregroundColor: RichTextStyle.inkColor,
                .paragraphStyle: prevStyle,
            ]))
        let widened = (storage.string as NSString).paragraphRange(for: NSRange(location: newP.location, length: 0))
        storage.addAttribute(.paragraphStyle, value: prevStyle, range: widened)
        storage.endEditing()
        tv.didChangeText()
        recountWords()
    }

    /// 1-based position of `paragraph` within its contiguous run of list items
    /// OF THE SAME marker format — a bulleted list sitting right above a
    /// numbered one must not inflate the numbered list's count.
    private func itemNumber(of paragraph: NSRange, in storage: NSTextStorage) -> Int {
        let ns = storage.string as NSString
        let format = (paragraph.length > 0
            ? (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle)
            : nil)?.textLists.first?.markerFormat
        var n = 1
        var loc = paragraph.location
        while loc > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            guard prev.length > 0,
                  let s = storage.attribute(.paragraphStyle, at: prev.location, effectiveRange: nil) as? NSParagraphStyle,
                  let f = s.textLists.first?.markerFormat,
                  f == format else { break }
            n += 1
            loc = prev.location
        }
        return n
    }

    /// Indent (+1) / outdent (-1) the list item(s) under the selection.
    /// True = the selection was in a list and the Tab was consumed. Pure
    /// attribute change, so the nil replacementString declaration is correct.
    func changeListLevel(by delta: Int) -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let range = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        guard range.length > 0,
              let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              !style.textLists.isEmpty else { return false }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return true }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, sub, _ in
            guard let s = value as? NSParagraphStyle, !s.textLists.isEmpty,
                  let m = s.mutableCopy() as? NSMutableParagraphStyle else { return }
            let level = Int(round((s.headIndent - RichTextStyle.listHeadIndent) / RichTextStyle.listIndentStep))
            let newLevel = max(0, min(RichTextStyle.listMaxLevel, level + delta))
            guard newLevel != level else { return }
            let bump = CGFloat(newLevel) * RichTextStyle.listIndentStep
            m.firstLineHeadIndent = RichTextStyle.listFirstLineHeadIndent + bump
            m.headIndent = RichTextStyle.listHeadIndent + bump
            m.tabStops = [NSTextTab(textAlignment: .left, location: RichTextStyle.listHeadIndent + bump)]
            storage.addAttribute(.paragraphStyle, value: m, range: sub)
        }
        storage.endEditing()
        tv.didChangeText()
        return true
    }

    // MARK: Private

    /// Apply a heading/body run of attributes to the selected paragraph(s).
    /// Headings are not list items: any literal "\t<marker>\t" prefixes are
    /// stripped in the same declared edit, or the marker text would survive
    /// restyling as countable words. The whole paragraph range is replaced in
    /// one shouldChangeText-declared edit so undo stays coherent (headings
    /// wholesale-restyle the paragraph anyway, exactly like the previous
    /// setAttributes did).
    private func applyHeading(_ style: RichTextStyle) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        let range = ns.paragraphRange(for: tv.selectedRange())
        guard range.length > 0 || tv.string.isEmpty else {
            // Empty paragraph: set typing attributes so the next keystrokes get
            // the heading style.
            tv.typingAttributes = style.attributes()
            return
        }

        // Rebuild the paragraph text with marker prefixes dropped.
        var stripped = ""
        for p in Self.paragraphRanges(of: ns, in: range) where p.length > 0 {
            var text = ns.substring(with: p)
            if let s = storage.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle,
               !s.textLists.isEmpty,
               let prefix = Self.markerPrefixLength(of: text) {
                text = (text as NSString).substring(from: prefix)
            }
            stripped += text
        }

        guard tv.shouldChangeText(in: range, replacementString: stripped) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range,
                                  with: NSAttributedString(string: stripped,
                                                           attributes: style.attributes()))
        storage.endEditing()
        tv.didChangeText()
        tv.typingAttributes = style.attributes()
        recountWords()
    }
}

// MARK: - Style definitions

/// The small set of paragraph/character styles the editor exposes. Serif body
/// at ~16pt (New York), larger serif headings, matching Weft's editorial type.
enum RichTextStyle {
    case body, h1, h2

    static let bodyFontSize: CGFloat = 16
    static let h1FontSize: CGFloat = 28
    static let h2FontSize: CGFloat = 21

    // List geometry. Level 0 markers sit at `listFirstLineHeadIndent`; the item
    // text starts at `listHeadIndent`. The upcoming key-handling pass moves whole levels with Tab/Shift+Tab.
    static let listFirstLineHeadIndent: CGFloat = 8
    static let listHeadIndent: CGFloat = 30
    static let listIndentStep: CGFloat = 24
    static let listMaxLevel = 3

    /// Ink color for body text, matching Theme.inkSoft (#22201c).
    static let inkColor = NSColor(red: 0.133, green: 0.125, blue: 0.110, alpha: 1.0)

    /// The serif body font (New York on macOS). Falls back to the system serif
    /// design if the named face is unavailable.
    static let bodyFont: NSFont = {
        let descriptor = NSFont.systemFont(ofSize: bodyFontSize)
            .fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: bodyFontSize).fontDescriptor
        return NSFont(descriptor: descriptor, size: bodyFontSize) ?? NSFont.systemFont(ofSize: bodyFontSize)
    }()

    static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Default body paragraph style: comfortable line height, no list indent.
    static func bodyParagraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.4
        p.paragraphSpacing = 6
        return p
    }

    /// Paragraph style for a list item at `level` (0-based), carrying the
    /// NSTextList so AppKit treats the paragraph as a real list item.
    static func listParagraphStyle(_ list: NSTextList, level: Int = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.4
        p.paragraphSpacing = 4
        let bump = CGFloat(level) * listIndentStep
        p.firstLineHeadIndent = listFirstLineHeadIndent + bump
        p.headIndent = listHeadIndent + bump
        p.tabStops = [NSTextTab(textAlignment: .left, location: listHeadIndent + bump)]
        p.textLists = [list]
        return p
    }

    /// Heading paragraph style: tighter leading, space above and below.
    static func headingParagraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacingBefore = 10
        p.paragraphSpacing = 4
        return p
    }

    /// The attribute dictionary applied to a run of this style.
    func attributes() -> [NSAttributedString.Key: Any] {
        switch self {
        case .body:
            return [.font: RichTextStyle.bodyFont,
                    .foregroundColor: RichTextStyle.inkColor,
                    .paragraphStyle: RichTextStyle.bodyParagraphStyle()]
        case .h1:
            return [.font: RichTextStyle.serifFont(size: RichTextStyle.h1FontSize, weight: .semibold),
                    .foregroundColor: RichTextStyle.inkColor,
                    .paragraphStyle: RichTextStyle.headingParagraphStyle()]
        case .h2:
            return [.font: RichTextStyle.serifFont(size: RichTextStyle.h2FontSize, weight: .medium),
                    .foregroundColor: RichTextStyle.inkColor,
                    .paragraphStyle: RichTextStyle.headingParagraphStyle()]
        }
    }
}

// MARK: - RichTextEditor (NSViewRepresentable)

/// An editable, selectable rich-text surface. White opaque page, serif body.
/// The NSTextView OWNS the document; SwiftUI gets `controller.wordCount` and an
/// `onEdit` ping. Read content via `controller.snapshot()`, write via
/// `controller.setContent(_:)`.
struct RichTextEditor: NSViewRepresentable {
    var controller: RichTextController
    var isEditable: Bool = true
    /// Inset around the text so the white page has a comfortable margin.
    var pagePadding: CGFloat = 28
    /// Fired on every edit (cheap; drives the autosave debounce upstream).
    var onEdit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onEdit: onEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white

        let textView = WeftTextView()
        textView.formatting = controller
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.font = RichTextStyle.bodyFont
        textView.textColor = RichTextStyle.inkColor

        // White opaque page (NOT glass) — the clean writing surface.
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.insertionPointColor = RichTextStyle.inkColor

        // Comfortable page margins inside the white surface.
        textView.textContainerInset = NSSize(width: pagePadding, height: pagePadding)

        // Default typing style is serif body.
        textView.typingAttributes = RichTextStyle.body.attributes()

        // Lay out so the text view tracks the scroll view's width and grows
        // vertically with content.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        // Register the live text view with the controller so the toolbar can
        // drive it. Defer to avoid mutating observable state during view build.
        DispatchQueue.main.async {
            controller.register(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        // Keep the controller pointed at the current view. Deferred for the
        // same reason as in makeNSView: the first updateNSView runs inside the
        // same SwiftUI transaction, and register() mutates observable state
        // the body already read. register is idempotent, so the overlap with
        // makeNSView's deferred block is harmless.
        if controller.textView !== textView {
            DispatchQueue.main.async { controller.register(textView) }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let controller: RichTextController
        private let onEdit: (() -> Void)?

        init(controller: RichTextController, onEdit: (() -> Void)?) {
            self.controller = controller
            self.onEdit = onEdit
        }

        func textDidChange(_ notification: Notification) {
            controller.recountWords()
            onEdit?()
        }
    }
}

// MARK: - RichTextToolbar (SwiftUI companion)

/// A compact formatting bar: Bold / Italic / Underline / H1 / H2 / Bulleted list / Numbered list.
/// Routes every action through the shared RichTextController to the live editor.
struct RichTextToolbar: View {
    var controller: RichTextController

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            toolbarButton("bold", label: "Bold (⌘B)") { controller.toggleBold() }
            toolbarButton("italic", label: "Italic (⌘I)") { controller.toggleItalic() }
            toolbarButton("underline", label: "Underline (⌘U)") { controller.toggleUnderline() }

            divider

            textButton("H1", label: "Heading 1 (⌘⌥1)") { controller.applyHeading1() }
            textButton("H2", label: "Heading 2 (⌘⌥2)") { controller.applyHeading2() }
            textButton("Body", label: "Body text (⌘⌥0)") { controller.applyBody() }

            divider

            toolbarButton("list.bullet", label: "Bulleted list (⌘⇧8)") { controller.toggleBulletedList() }
            toolbarButton("list.number", label: "Numbered list (⌘⇧7)") { controller.toggleNumberedList() }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.regularMaterial, in: Capsule())
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.10))
            .frame(width: 1, height: 18)
            .padding(.horizontal, Theme.Space.xs)
    }

    /// An SF Symbol icon button.
    private func toolbarButton(_ systemName: String,
                               label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(Theme.inkSoft)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(label)
    }

    /// A text-label button (H1 / H2 / Body).
    private func textButton(_ title: String,
                            label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 26, minHeight: 26)
                .padding(.horizontal, 4)
                .foregroundStyle(Theme.inkSoft)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(label)
    }
}

// MARK: - Preview / demo host

/// A self-contained host wiring the editor to its toolbar, for previews and as
/// a usage example for the essay-writing surface.
struct RichTextEditorDemo: View {
    @State private var controller = RichTextController()

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            HStack {
                RichTextToolbar(controller: controller)
                Spacer()
                Text("\(controller.wordCount) \(controller.wordCount == 1 ? "word" : "words")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }

            RichTextEditor(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        }
        .padding(Theme.Space.xl)
        .frame(minWidth: 640, minHeight: 520)
        .task {
            controller.setContent(NSAttributedString(
                string: "Start writing your essay…",
                attributes: RichTextStyle.body.attributes()))
        }
    }
}

#Preview {
    RichTextEditorDemo()
}

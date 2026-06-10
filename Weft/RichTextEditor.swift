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
    /// converts in place.
    private func toggleList(_ format: NSTextList.MarkerFormat) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        let pRange = ns.paragraphRange(for: tv.selectedRange())
        let already = listFormat(at: pRange.location, in: storage) == format
        guard tv.shouldChangeText(in: pRange, replacementString: nil) else { return }
        storage.beginEditing()
        let cleared = removeListMarkers(in: pRange, storage: storage)
        if !already {
            applyListMarkers(format, in: cleared, storage: storage)
        }
        storage.endEditing()
        tv.didChangeText()
        if already { tv.typingAttributes = RichTextStyle.body.attributes() }
        recountWords()
    }

    /// The marker format of the list item at `location`, nil when not a list.
    private func listFormat(at location: Int, in storage: NSTextStorage) -> NSTextList.MarkerFormat? {
        guard storage.length > 0 else { return nil }
        let loc = min(location, storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
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

    /// Strip "\t<marker>\t" prefixes + list paragraph styles from every list
    /// paragraph in `range`. Returns the range covering the same paragraphs
    /// after the removals. Caller wraps in begin/endEditing.
    @discardableResult
    private func removeListMarkers(in range: NSRange, storage: NSTextStorage) -> NSRange {
        var paragraphs: [NSRange] = []
        (storage.string as NSString).enumerateSubstrings(
            in: range, options: [.byParagraphs, .substringNotRequired]
        ) { _, _, enclosing, _ in paragraphs.append(enclosing) }
        if paragraphs.isEmpty { paragraphs = [range] }

        var removed = 0
        for p in paragraphs.reversed() {
            guard p.length > 0,
                  let style = storage.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle,
                  !style.textLists.isEmpty else { continue }
            let text = (storage.string as NSString).substring(with: p)
            if let prefix = Self.markerPrefixLength(of: text) {
                storage.replaceCharacters(in: NSRange(location: p.location, length: prefix), with: "")
                removed += prefix
            }
            let newP = (storage.string as NSString).paragraphRange(for: NSRange(location: p.location, length: 0))
            storage.addAttribute(.paragraphStyle, value: RichTextStyle.bodyParagraphStyle(), range: newP)
        }
        return NSRange(location: range.location, length: max(0, range.length - removed))
    }

    /// Insert "\t<marker>\t" prefixes + list paragraph styles across `range`.
    /// One shared NSTextList per call so numbering is continuous. Caller wraps
    /// in begin/endEditing.
    private func applyListMarkers(_ format: NSTextList.MarkerFormat, in range: NSRange, storage: NSTextStorage) {
        let list = NSTextList(markerFormat: format, options: 0)
        let style = RichTextStyle.listParagraphStyle(list)
        var paragraphs: [NSRange] = []
        (storage.string as NSString).enumerateSubstrings(
            in: range, options: [.byParagraphs, .substringNotRequired]
        ) { _, _, enclosing, _ in paragraphs.append(enclosing) }
        if paragraphs.isEmpty { paragraphs = [(storage.string as NSString).paragraphRange(for: range)] }

        for (n, p) in paragraphs.enumerated().reversed() {
            let marker = "\t" + list.marker(forItemNumber: n + 1) + "\t"
            storage.replaceCharacters(
                in: NSRange(location: p.location, length: 0),
                with: NSAttributedString(string: marker, attributes: [
                    .font: RichTextStyle.bodyFont,
                    .foregroundColor: RichTextStyle.inkColor,
                    .paragraphStyle: style,
                ]))
            let widened = (storage.string as NSString).paragraphRange(for: NSRange(location: p.location, length: 0))
            storage.addAttribute(.paragraphStyle, value: style, range: widened)
        }
        if let tv = textView {
            var typing = tv.typingAttributes
            typing[.paragraphStyle] = style
            tv.typingAttributes = typing
        }
    }

    // MARK: Private

    /// Apply a heading/body run of attributes to the selected paragraph(s).
    private func applyHeading(_ style: RichTextStyle) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
        guard range.length > 0 || tv.string.isEmpty else {
            // Empty paragraph: set typing attributes so the next keystrokes get
            // the heading style.
            tv.typingAttributes = style.attributes()
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.setAttributes(style.attributes(), range: range)
        storage.endEditing()
        tv.didChangeText()
        tv.typingAttributes = style.attributes()
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
    // text starts at `listHeadIndent`. Tab/Shift+Tab move whole levels.
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

        let textView = NSTextView()
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

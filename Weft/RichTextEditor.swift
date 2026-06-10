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
//    RichTextEditor(text: $attr, wordCount: $count, controller: controller)
//    RichTextToolbar(controller: controller)        // Bold/Italic/Underline/H1/H2/Bulleted list
//
//  The controller is the shared link between the SwiftUI toolbar and the live
//  NSTextView: the editor registers its text view on the controller, and the
//  toolbar buttons route formatting commands back to it.
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
    func snapshot() -> NSAttributedString {
        (textView?.attributedString().copy() as? NSAttributedString) ?? NSAttributedString()
    }

    /// Recompute the published word count from the live document. Matches the
    /// web editor's `trimmed.split(/\s+/)` rule; the bullet prefix is display
    /// chrome, not countable text.
    func recountWords() {
        guard let tv = textView else { wordCount = 0; return }
        let plain = tv.string.replacingOccurrences(of: RichTextStyle.bulletPrefix, with: " ")
        wordCount = plain.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { !$0.isEmpty }.count
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

    /// Toggle a bulleted list on the paragraph(s) touching the selection.
    func toggleBulletedList() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let paragraphRange = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
        guard paragraphRange.length >= 0 else { return }

        // Detect whether the first line is already bulleted; if so, strip,
        // otherwise add. Keeps the toggle behavior of the web editor.
        let nsText = storage.string as NSString
        let firstLineRange = nsText.lineRange(for: NSRange(location: paragraphRange.location, length: 0))
        let firstLine = nsText.substring(with: firstLineRange)
        let alreadyBulleted = firstLine.hasPrefix(RichTextStyle.bulletPrefix)

        guard tv.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }
        storage.beginEditing()

        // Walk each line in the selected paragraph range, back to front so the
        // ranges we mutate stay valid as we insert/remove the bullet prefix.
        var lineStarts: [Int] = []
        var idx = paragraphRange.location
        let end = paragraphRange.location + max(paragraphRange.length, 1)
        while idx < end && idx < nsText.length {
            let lr = nsText.lineRange(for: NSRange(location: idx, length: 0))
            lineStarts.append(lr.location)
            idx = lr.location + max(lr.length, 1)
        }

        let bullet = RichTextStyle.bulletPrefix
        let bulletLen = (bullet as NSString).length
        let indent = RichTextStyle.listParagraphStyle()
        let bodyStyle = RichTextStyle.bodyParagraphStyle()

        for start in lineStarts.reversed() {
            let lineRange = (storage.string as NSString).lineRange(for: NSRange(location: start, length: 0))
            let lineText = (storage.string as NSString).substring(with: lineRange)
            if alreadyBulleted {
                if lineText.hasPrefix(bullet) {
                    storage.replaceCharacters(in: NSRange(location: start, length: bulletLen), with: "")
                    let cleared = (storage.string as NSString).lineRange(for: NSRange(location: start, length: 0))
                    storage.addAttribute(.paragraphStyle, value: bodyStyle, range: cleared)
                }
            } else {
                storage.replaceCharacters(in: NSRange(location: start, length: 0),
                                          with: NSAttributedString(string: bullet,
                                                                   attributes: [.font: RichTextStyle.bodyFont,
                                                                                .foregroundColor: RichTextStyle.inkColor]))
                let widened = (storage.string as NSString).lineRange(for: NSRange(location: start, length: 0))
                storage.addAttribute(.paragraphStyle, value: indent, range: widened)
            }
        }

        storage.endEditing()
        tv.didChangeText()
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
    static let bulletPrefix = "\u{2022}\u{00A0}" // "•" + non-breaking space

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

    /// Hanging-indent paragraph style for bulleted lines.
    static func listParagraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.4
        p.paragraphSpacing = 4
        p.firstLineHeadIndent = 0
        p.headIndent = 22
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
        // Keep the controller pointed at the current view (cheap, idempotent).
        if controller.textView !== textView {
            controller.register(textView)
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

/// A compact formatting bar: Bold / Italic / Underline / H1 / H2 / Bulleted list.
/// Routes every action through the shared RichTextController to the live editor.
struct RichTextToolbar: View {
    var controller: RichTextController

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            toolbarButton("bold", label: "Bold") { controller.toggleBold() }
            toolbarButton("italic", label: "Italic") { controller.toggleItalic() }
            toolbarButton("underline", label: "Underline") { controller.toggleUnderline() }

            divider

            textButton("H1", label: "Heading 1") { controller.applyHeading1() }
            textButton("H2", label: "Heading 2") { controller.applyHeading2() }
            textButton("Body", label: "Body text") { controller.applyBody() }

            divider

            toolbarButton("list.bullet", label: "Bulleted list") { controller.toggleBulletedList() }
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

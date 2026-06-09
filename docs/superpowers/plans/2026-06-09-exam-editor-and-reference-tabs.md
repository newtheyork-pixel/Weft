# Exam Editor Rework + Reference Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the exam editor's typing/formatting lag, add Google Docs keyboard shortcuts and real (NSTextList) lists, rebuild the reference panel as browser-style tabs with persistent live views, and make the post-submit fullscreen exit reliable.

**Architecture:** The NSTextView becomes the sole owner of the essay document; SwiftUI receives only a word count and an "edited" ping (no more per-keystroke attributed-string round-trip). A `WeftTextView` subclass adds key equivalents. The reference panel keeps every visited material's view mounted in one ZStack and switches visibility, so tab switches are instant and state survives. Kiosk exit retries `toggleFullScreen` until the window is actually windowed (macOS drops the call mid-transition).

**Tech Stack:** Swift 6, SwiftUI + AppKit (NSTextView, NSTextList, PDFKit, WKWebView), Xcode project at `~/Weft` (filesystem-synchronized groups: new files under `Weft/` are picked up automatically; no pbxproj editing).

**Spec:** `docs/superpowers/specs/2026-06-09-exam-editor-and-reference-tabs-design.md`

**Canonical build command** (used by every task; deterministic output path):

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

**Canonical QA run** (dev-gallery exam screen, no sign-in needed):

```bash
WEFT_SCREEN=exam ~/Weft/build/Build/Products/Debug/Weft.app/Contents/MacOS/Weft
```

Before the first build, make sure `build/` is ignored:

```bash
cd ~/Weft && grep -qx 'build/' .gitignore 2>/dev/null || echo 'build/' >> .gitignore
```

---

### Task 1: Controller-owned document (kill the binding round-trip)

The editor currently copies the whole essay into a SwiftUI `@Binding` on every keystroke and deep-compares it up to three times per render. After this task the document lives only in the NSTextView; SwiftUI sees an `Int` word count and an `onEdit` ping.

**Files:**
- Modify: `Weft/RichTextEditor.swift` (controller + representable + coordinator + demo)
- Modify: `Weft/ExamView.swift` (drop `@State essay`/`wordCount`, new editor call)

- [ ] **Step 1: Add document ownership to RichTextController**

In `Weft/RichTextEditor.swift`, inside `final class RichTextController`, directly after `weak var textView: NSTextView?` and before `init() {}`, add:

```swift
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
```

- [ ] **Step 2: Rework the representable (no bindings)**

Replace the whole `struct RichTextEditor: NSViewRepresentable { ... }` (struct only, not the styles or controller) with:

```swift
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
```

- [ ] **Step 3: Update the demo host at the bottom of RichTextEditor.swift**

Replace `struct RichTextEditorDemo: View { ... }` with:

```swift
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
```

- [ ] **Step 4: Update ExamView**

In `Weft/ExamView.swift`:

a) Delete these two `@State` lines:

```swift
    @State private var essay = NSAttributedString(string: "")
    @State private var wordCount = 0
```

b) Add a computed pass-through right after `@State private var controller = RichTextController()`:

```swift
    private var wordCount: Int { controller.wordCount }
```

c) In `editorColumn`, replace

```swift
            RichTextEditor(text: $essay, wordCount: $wordCount, controller: controller)
                .background(Color.white)
                .padding(.horizontal, Theme.Space.xl)
                .onChange(of: essay) { _, _ in scheduleSave() }
```

with

```swift
            RichTextEditor(controller: controller, onEdit: { scheduleSave() })
                .background(Color.white)
                .padding(.horizontal, Theme.Space.xl)
```

d) In the `.task`, replace the preview seeding

```swift
            if !lockdown && !didSeedPreview {
                didSeedPreview = true
                essay = NSAttributedString(string: previewEssay)
            }
```

with

```swift
            if !lockdown && !didSeedPreview {
                didSeedPreview = true
                controller.setContent(NSAttributedString(
                    string: previewEssay,
                    attributes: RichTextStyle.body.attributes()))
            }
```

(`wordCountView` and the submit-confirm message keep reading `wordCount`; the computed property feeds them now.)

- [ ] **Step 5: Build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: QA — typing latency**

```bash
WEFT_SCREEN=exam ~/Weft/build/Build/Products/Debug/Weft.app/Contents/MacOS/Weft
```

1. Paste a long text (copy a few thousand words from anywhere) into the editor.
2. Type at the end of the document: keystrokes must echo with zero perceptible lag.
3. Select a sentence, click Bold in the toolbar: applies instantly.
4. Word count label updates while typing; preview filler text appears on open.

- [ ] **Step 7: Commit**

```bash
cd ~/Weft && git add Weft/RichTextEditor.swift Weft/ExamView.swift .gitignore && git commit -m "Editor: controller-owned document, no per-keystroke binding round-trip"
```

---

### Task 2: Real lists (NSTextList) + numbered list

Replace the "• " character-prefix hack with native NSTextList paragraph styles. List items carry a `"\t<marker>\t"` text prefix plus a paragraph style whose `textLists` is set (the TextEdit model). Word count becomes attribute-aware and never counts markers.

**Files:**
- Modify: `Weft/RichTextEditor.swift` (RichTextStyle, RichTextController list methods, recountWords, toolbar)

- [ ] **Step 1: Replace the list style definitions in RichTextStyle**

Delete the `bulletPrefix` constant:

```swift
    static let bulletPrefix = "\u{2022}\u{00A0}" // "•" + non-breaking space
```

Delete the old `static func listParagraphStyle() -> NSParagraphStyle { ... }` and add in its place:

```swift
    // List geometry. Level 0 markers sit at `listFirstLineHeadIndent`; the item
    // text starts at `listHeadIndent`. Tab/Shift+Tab move whole levels.
    static let listFirstLineHeadIndent: CGFloat = 8
    static let listHeadIndent: CGFloat = 30
    static let listIndentStep: CGFloat = 24
    static let listMaxLevel = 3

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
```

- [ ] **Step 2: Replace the list machinery in RichTextController**

Delete the whole existing `func toggleBulletedList() { ... }` and add:

```swift
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
```

- [ ] **Step 3: Attribute-aware word count**

Replace the body of `func recountWords()` (added in Task 1) with:

```swift
    func recountWords() {
        guard let tv = textView, let storage = tv.textStorage else { wordCount = 0; return }
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
               let prefix = Self.markerPrefixLength(of: text) {
                text = (text as NSString).substring(from: prefix)
            }
            count += text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .filter { !$0.isEmpty }.count
        }
        wordCount = count
    }
```

- [ ] **Step 4: Toolbar — numbered list button + shortcut tooltips**

In `RichTextToolbar.body`, replace the whole `HStack` content with:

```swift
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
```

- [ ] **Step 5: Build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: QA — list behavior (and record the Return result for Task 3)**

```bash
WEFT_SCREEN=exam ~/Weft/build/Build/Products/Debug/Weft.app/Contents/MacOS/Weft
```

1. Type a line, click the bulleted-list button: a "•" marker appears, text indents.
2. Click it again: marker and indent removed.
3. Type three lines, select all three, click numbered list: items 1. 2. 3.
4. With the caret at the end of a list item, press Return. **Record whether
   AppKit automatically continued the list (inserted the next marker).** This
   decides a branch in Task 3.
5. Word count: a one-word bulleted item counts as 1 word, not 2.

- [ ] **Step 7: Commit**

```bash
cd ~/Weft && git add Weft/RichTextEditor.swift && git commit -m "Editor: native NSTextList bulleted + numbered lists"
```

---

### Task 3: WeftTextView — Google Docs shortcuts + list keys

A focused NSTextView subclass owns all key handling: Cmd+B/I/U, Cmd+Alt+1/2/0, Cmd+Shift+8/7, Tab/Shift+Tab list indenting, and Return-in-list behavior.

**Files:**
- Create: `Weft/WeftTextView.swift`
- Modify: `Weft/RichTextEditor.swift` (instantiate the subclass; add the three list-key helpers to RichTextController)

- [ ] **Step 1: Add the list-key helpers to RichTextController**

In `Weft/RichTextEditor.swift`, add to `RichTextController` (after `applyListMarkers`):

```swift
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

        guard tv.shouldChangeText(in: p, replacementString: nil) else { return true }
        storage.beginEditing()
        removeListMarkers(in: p, storage: storage)
        storage.endEditing()
        tv.didChangeText()
        tv.typingAttributes = RichTextStyle.body.attributes()
        recountWords()
        return true
    }

    /// After a plain newline inside a list item, carry the list onto the new
    /// paragraph with the next marker. No-ops when the previous paragraph is
    /// not a list item or when the marker is already there (AppKit did it).
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
        storage.replaceCharacters(
            in: NSRange(location: newP.location, length: 0),
            with: NSAttributedString(string: marker, attributes: [
                .font: RichTextStyle.bodyFont,
                .foregroundColor: RichTextStyle.inkColor,
                .paragraphStyle: prevStyle,
            ]))
        let widened = (storage.string as NSString).paragraphRange(for: NSRange(location: newP.location, length: 0))
        storage.addAttribute(.paragraphStyle, value: prevStyle, range: widened)
        tv.didChangeText()
        recountWords()
    }

    /// 1-based position of `paragraph` within its contiguous run of list items.
    private func itemNumber(of paragraph: NSRange, in storage: NSTextStorage) -> Int {
        let ns = storage.string as NSString
        var n = 1
        var loc = paragraph.location
        while loc > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            guard prev.length > 0,
                  let s = storage.attribute(.paragraphStyle, at: prev.location, effectiveRange: nil) as? NSParagraphStyle,
                  !s.textLists.isEmpty else { break }
            n += 1
            loc = prev.location
        }
        return n
    }

    /// Indent (+1) / outdent (-1) the list item(s) under the selection.
    /// True = the selection was in a list and the Tab was consumed.
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
```

- [ ] **Step 2: Create Weft/WeftTextView.swift**

```swift
//
//  WeftTextView.swift
//  Weft — the exam's text view: NSTextView plus the Google Docs keyboard
//  shortcuts students expect. The app intentionally has no Format menu (the
//  exam window is kiosk-locked), so key equivalents are handled here and
//  routed through the shared RichTextController.
//

import AppKit

final class WeftTextView: NSTextView {
    /// Set by RichTextEditor right after creation.
    weak var formatting: RichTextController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let formatting else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        // Cmd+B / Cmd+I / Cmd+U — bold / italic / underline.
        if flags == .command {
            switch key {
            case "b": formatting.toggleBold(); return true
            case "i": formatting.toggleItalic(); return true
            case "u": formatting.toggleUnderline(); return true
            default: break
            }
        }
        // Cmd+Alt+1 / 2 / 0 — heading 1 / heading 2 / body (Google Docs).
        if flags == [.command, .option] {
            switch key {
            case "1": formatting.applyHeading1(); return true
            case "2": formatting.applyHeading2(); return true
            case "0": formatting.applyBody(); return true
            default: break
            }
        }
        // Cmd+Shift+8 / 7 — bulleted / numbered list (Google Docs). Shift on a
        // number row may surface as the shifted character, so accept both.
        if flags == [.command, .shift] {
            switch key {
            case "8", "*": formatting.toggleBulletedList(); return true
            case "7", "&": formatting.toggleNumberedList(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // Return inside a list: empty item ends the list; otherwise make sure the
    // list continues with the next marker.
    override func insertNewline(_ sender: Any?) {
        if formatting?.endListIfEmptyItem() == true { return }
        super.insertNewline(sender)
        formatting?.continueListAfterNewlineIfNeeded()
    }

    // Tab / Shift+Tab indent and outdent list items (Google Docs).
    override func insertTab(_ sender: Any?) {
        if formatting?.changeListLevel(by: 1) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if formatting?.changeListLevel(by: -1) == true { return }
        super.insertBacktab(sender)
    }
}
```

NOTE (from Task 2 Step 6 QA): `continueListAfterNewlineIfNeeded` is written to
no-op when AppKit already carried the marker over (it checks for an existing
prefix), so it is safe in BOTH outcomes of that QA check. No branch to choose;
the check just documents which path is active.

- [ ] **Step 3: Instantiate the subclass in RichTextEditor.makeNSView**

Replace

```swift
        let textView = NSTextView()
        textView.delegate = context.coordinator
```

with

```swift
        let textView = WeftTextView()
        textView.formatting = controller
        textView.delegate = context.coordinator
```

- [ ] **Step 4: Build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: QA — every shortcut**

```bash
WEFT_SCREEN=exam ~/Weft/build/Build/Products/Debug/Weft.app/Contents/MacOS/Weft
```

1. Select text: Cmd+B bolds, again unbolds. Same for Cmd+I, Cmd+U.
2. Empty selection: Cmd+B then type — new text is bold.
3. Cmd+Alt+1 / Cmd+Alt+2 / Cmd+Alt+0 restyle the current paragraph.
4. Cmd+Shift+8 toggles a bulleted list; Cmd+Shift+7 numbered.
5. In a list item with text: Return creates the next item with a marker
   (exactly ONE marker, not two). On an empty item: Return ends the list.
6. Tab indents a list item (up to 3 levels), Shift+Tab outdents. Outside a
   list, Tab still inserts a tab.
7. Cmd+Shift+R (hide references) and Cmd+Return (submit) still work; the
   subclass must not swallow them.

- [ ] **Step 6: Commit**

```bash
cd ~/Weft && git add Weft/WeftTextView.swift Weft/RichTextEditor.swift && git commit -m "Editor: Google Docs shortcuts + list key behavior (WeftTextView)"
```

---

### Task 4: HTML export (Electron-compatible subset)

`RichTextHTML` serializes an essay to the exact subset the Electron sanitizer
allows and the grading view + portal already render: `<h1> <h2> <p> <ul> <ol>
<li> <b> <i> <u> <br>`. Pure AppKit, zero project dependencies, so it is
verified by a standalone compiled test — written FIRST.

**Files:**
- Create: `Weft/RichTextHTML.swift`
- Modify: `Weft/RichTextEditor.swift` (add `htmlSnapshot()` to the controller)
- Test: `/tmp/weft_html_test.swift` (standalone, not committed)

- [ ] **Step 1: Write the failing test**

Write `/tmp/weft_html_test.swift`:

```swift
import AppKit

// Mirrors RichTextStyle geometry without importing the app module.
func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    let d = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: d, size: size) ?? NSFont.systemFont(ofSize: size)
}

func para(_ runs: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
    let m = NSMutableAttributedString()
    for (s, a) in runs { m.append(NSAttributedString(string: s, attributes: a)) }
    return m
}

func listStyle(ordered: Bool) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
    return p
}

var failures = 0
func expect(_ name: String, _ got: String, _ want: String) {
    if got == want { print("ok \(name)") }
    else { print("FAIL \(name)\n  got  \(got)\n  want \(want)"); failures += 1 }
}

let body: [NSAttributedString.Key: Any] = [.font: font(size: 16)]
let bold: [NSAttributedString.Key: Any] = [.font: font(size: 16, bold: true)]
let italic: [NSAttributedString.Key: Any] = [.font: font(size: 16, italic: true)]
let under: [NSAttributedString.Key: Any] = [.font: font(size: 16), .underlineStyle: NSUnderlineStyle.single.rawValue]
let h1: [NSAttributedString.Key: Any] = [.font: font(size: 28, bold: true)]
let bullet: [NSAttributedString.Key: Any] = [.font: font(size: 16), .paragraphStyle: listStyle(ordered: false)]
let number: [NSAttributedString.Key: Any] = [.font: font(size: 16), .paragraphStyle: listStyle(ordered: true)]

expect("empty", RichTextHTML.html(from: NSAttributedString()), "")

expect("plain", RichTextHTML.html(from: para([("Hello world", body)])),
       "<p>Hello world</p>")

expect("escapes", RichTextHTML.html(from: para([("a < b & c", body)])),
       "<p>a &lt; b &amp; c</p>")

expect("bold run", RichTextHTML.html(from: para([("a ", body), ("big", bold), (" cat", body)])),
       "<p>a <b>big</b> cat</p>")

expect("italic+underline", RichTextHTML.html(from: para([("x", italic), ("y", under)])),
       "<p><i>x</i><u>y</u></p>")

expect("heading", RichTextHTML.html(from: para([("Title", h1), ("\n", h1), ("Body", body)])),
       "<h1>Title</h1><p>Body</p>")

expect("bullets", RichTextHTML.html(from: para([("\t\u{2022}\tOne", bullet), ("\n", bullet), ("\t\u{2022}\tTwo", bullet)])),
       "<ul><li>One</li><li>Two</li></ul>")

expect("numbered", RichTextHTML.html(from: para([("\t1.\tOne", number), ("\n", number), ("\t2.\tTwo", number)])),
       "<ol><li>One</li><li>Two</li></ol>")

expect("blank line", RichTextHTML.html(from: para([("a", body), ("\n", body), ("\n", body), ("b", body)])),
       "<p>a</p><p><br></p><p>b</p>")

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/Weft && swiftc Weft/RichTextHTML.swift /tmp/weft_html_test.swift -o /tmp/weft_html_test 2>&1 | head -3
```
Expected: `error: ... no such file ... RichTextHTML.swift` (file doesn't exist yet).

- [ ] **Step 3: Write Weft/RichTextHTML.swift**

```swift
//
//  RichTextHTML.swift
//  Weft — serialize an exam essay (NSAttributedString) to the sanitized HTML
//  subset the Electron app produces and the teacher grading view + web portal
//  already render: <h1> <h2> <p> <ul> <ol> <li> <b> <i> <u> <br>.
//  Pure AppKit, no project dependencies (standalone-testable).
//

import AppKit

enum RichTextHTML {

    /// Convert `text` to subset HTML. Paragraphs whose first character's font
    /// is at least `h1Size` / `h2Size` points become <h1> / <h2>; paragraphs
    /// whose style carries an NSTextList become <li> grouped into <ul>/<ol>;
    /// everything else is a <p>. Inline bold/italic/underline come from font
    /// traits + the underline attribute.
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
                    let para = ns.substring(with: pRange)
                    if let prefix = markerPrefixLength(of: para) {
                        contentRange = NSRange(location: pRange.location + prefix,
                                               length: pRange.length - prefix)
                    }
                } else if let size = font?.pointSize {
                    if size >= h1Size { block = .h1 }
                    else if size >= h2Size { block = .h2 }
                }
            }

            let inner = inlineHTML(of: text, in: contentRange, suppressBold: {
                if case .li = block { return false }
                if case .p = block { return false }
                return true   // headings are already visually bold
            }())

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
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/Weft && swiftc Weft/RichTextHTML.swift /tmp/weft_html_test.swift -o /tmp/weft_html_test && /tmp/weft_html_test
```
Expected: `ALL TESTS PASSED`, exit 0. If a case fails, fix RichTextHTML (not the
test) until all pass.

- [ ] **Step 5: Wire htmlSnapshot into the controller**

In `Weft/RichTextEditor.swift`, add to `RichTextController` after `snapshot()`:

```swift
    /// The document as Electron-compatible subset HTML (for submission writes).
    func htmlSnapshot() -> String {
        RichTextHTML.html(from: snapshot(),
                          h1Size: RichTextStyle.h1FontSize,
                          h2Size: RichTextStyle.h2FontSize)
    }
```

- [ ] **Step 6: Build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
cd ~/Weft && git add Weft/RichTextHTML.swift Weft/RichTextEditor.swift && git commit -m "Editor: Electron-compatible HTML export (RichTextHTML)"
```

---

### Task 5: Reference materials model + tab store

**Files:**
- Create: `Weft/ReferenceTabs.swift`

- [ ] **Step 1: Create Weft/ReferenceTabs.swift**

```swift
//
//  ReferenceTabs.swift
//  Weft — the exam reference area's model: one unified list of materials
//  (teacher PDFs + approved websites), which tab is selected / pinned (split),
//  and per-PDF load state. Documents prefetch once at exam start; the panel
//  keeps every visited view alive, so switching tabs never reloads anything.
//

import SwiftUI
import PDFKit

/// One openable reference material: a teacher PDF or an approved website.
enum ReferenceMaterial: Identifiable, Hashable {
    case pdf(ExamFile)
    case web(ExamLink)

    var id: String {
        switch self {
        case .pdf(let f): return "pdf-\(f.id)"
        case .web(let l): return "web-\(l.id)"
        }
    }

    var title: String {
        switch self {
        case .pdf(let f): return f.originalName
        case .web(let l): return l.displayName
        }
    }

    var icon: String {
        switch self {
        case .pdf: return "doc.text.fill"
        case .web: return "globe"
        }
    }
}

@MainActor
@Observable
final class ReferenceTabStore {
    enum PDFState: Equatable { case loading, loaded(PDFDocument), failed }

    private(set) var materials: [ReferenceMaterial] = []
    private(set) var selectedID: String?
    /// Split mode: the material pinned to the top pane (nil = single pane).
    private(set) var pinnedID: String?
    /// Every material shown at least once; their views stay mounted for the
    /// rest of the exam (instant switching, scroll/zoom/web state preserved).
    private(set) var visitedIDs: Set<String> = []
    private(set) var pdfStates: [String: PDFState] = [:]   // keyed by ExamFile.id

    private var signedIn = false
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    var allowedHosts: [String] {
        materials.compactMap { if case .web(let l) = $0 { return l.host } else { return nil } }
    }
    var splitActive: Bool { pinnedID != nil }

    /// (Re)build the material list. Real materials can arrive after the panel
    /// is shown (loadExamMaterials resolves async), so this keeps the user's
    /// selection when it still exists and prefetches only new files.
    func configure(files: [ExamFile], links: [ExamLink], signedIn: Bool) {
        self.signedIn = signedIn
        materials = files.map { .pdf($0) } + links.map { .web($0) }
        if selectedID == nil || !materials.contains(where: { $0.id == selectedID }) {
            selectedID = materials.first?.id
        }
        if let pinned = pinnedID, !materials.contains(where: { $0.id == pinned }) {
            pinnedID = nil
        }
        if let selectedID { visitedIDs.insert(selectedID) }
        for file in files where pdfStates[file.id] == nil { prefetch(file) }
    }

    func select(_ id: String) {
        selectedID = id
        visitedIDs.insert(id)
    }

    /// Toggle split: pin the current material on top and move the active tab
    /// to the next material so the two panes start on different things.
    func toggleSplit() {
        if pinnedID != nil { pinnedID = nil; return }
        guard let current = selectedID, materials.count > 1 else { return }
        pinnedID = current
        if let i = materials.firstIndex(where: { $0.id == current }) {
            select(materials[(i + 1) % materials.count].id)
        }
    }

    func retry(file: ExamFile) {
        prefetchTasks[file.id]?.cancel()
        pdfStates[file.id] = nil
        prefetch(file)
    }

    /// Load a file's PDF once (fresh signed URL each attempt). Sample
    /// materials (no storage path) and signed-out QA use the bundled sample
    /// document, exactly like the old panel.
    private func prefetch(_ file: ExamFile) {
        guard signedIn, !file.storagePath.isEmpty else {
            pdfStates[file.id] = .loaded(SamplePDF.shared)
            return
        }
        pdfStates[file.id] = .loading
        prefetchTasks[file.id] = Task {
            var doc: PDFDocument?
            do {
                let url = try await SupabaseManager.shared.signedURL(bucket: "essay-files",
                                                                     path: file.storagePath)
                doc = await PDFLoader.load(from: url)
            } catch { doc = nil }
            if Task.isCancelled { return }
            pdfStates[file.id] = doc.map { .loaded($0) } ?? .failed
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` (the store is not referenced yet; this just
proves it compiles against ExamFile / ExamLink / SamplePDF / PDFLoader /
SupabaseManager).

- [ ] **Step 3: Commit**

```bash
cd ~/Weft && git add Weft/ReferenceTabs.swift && git commit -m "References: unified material model + tab store with PDF prefetch"
```

---

### Task 6: Rebuild ExamReferencePanel as tabs + Settings cleanup

**Files:**
- Modify: `Weft/ExamReferencePanel.swift` (full rewrite of the view)
- Modify: `Weft/SettingsView.swift` (remove the obsolete layout preference)

- [ ] **Step 1: Replace the entire contents of Weft/ExamReferencePanel.swift**

```swift
//
//  ExamReferencePanel.swift
//  Weft — the exam's reference area, browser-style: every teacher PDF and
//  approved website is a TAB. Click to switch instantly; views are created on
//  first visit and kept alive for the whole exam, so scroll / zoom / page /
//  web-navigation state survives and nothing ever reloads. A Split toggle
//  pins the current material above while the tabs drive the lower pane.
//

import SwiftUI
import PDFKit

struct ExamReferencePanel: View {
    let files: [ExamFile]
    let links: [ExamLink]
    let signedIn: Bool
    var onHide: () -> Void

    @State private var store = ReferenceTabStore()
    @State private var blockedHost: String?
    /// Top pane's share of the height in split mode (drag the divider).
    @State private var splitFraction: CGFloat = 0.5

    private let dividerThickness: CGFloat = 7

    /// Build a loadable URL from an approved link, prepending https:// when the
    /// teacher stored a bare host (otherwise the locked browser silently blocks
    /// the schemeless URL and nothing renders).
    private func normalizedURL(_ raw: String) -> URL? {
        let s = raw.contains("://") ? raw : "https://" + raw
        return URL(string: s)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            if store.materials.isEmpty {
                emptyState
            } else {
                materialCanvas
            }
        }
        .background(Color(white: 0.96))
        .task { store.configure(files: files, links: links, signedIn: signedIn) }
        .onChange(of: files) { _, f in store.configure(files: f, links: links, signedIn: signedIn) }
        .onChange(of: links) { _, l in store.configure(files: files, links: l, signedIn: signedIn) }
        .overlay(alignment: .top) {
            if let host = blockedHost {
                Text("Blocked: \(host) is not on your teacher's list.")
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
                    .background(Theme.bad, in: Capsule())
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { blockedHost = nil }
                    }
            }
        }
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: Theme.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.materials) { m in tabChip(m) }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            if store.materials.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { store.toggleSplit() }
                } label: {
                    Image(systemName: store.splitActive ? "rectangle" : "rectangle.split.1x2")
                }
                .buttonStyle(.borderless)
                .help(store.splitActive ? "Back to one pane"
                                        : "Split: pin this on top, browse another below")
            }
            Button(action: onHide) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Hide references, write only (⌘⇧R)")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.regularMaterial)
    }

    private func tabChip(_ m: ReferenceMaterial) -> some View {
        let active = store.selectedID == m.id || store.pinnedID == m.id
        return Button { store.select(m.id) } label: {
            HStack(spacing: 5) {
                if store.pinnedID == m.id {
                    Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold))
                } else if case .pdf(let f) = m, store.pdfStates[f.id] == .loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: m.icon).font(.system(size: 10, weight: .semibold))
                }
                Text(m.title)
                    .font(Theme.sans(12, active ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? Theme.accent.opacity(0.14) : Color.black.opacity(0.04),
                        in: Capsule())
            .foregroundStyle(active ? Theme.accent : Theme.ink)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(m.title)
    }

    // MARK: Material canvas (every visited view stays mounted; frames switch)

    private var visitedMaterials: [ReferenceMaterial] {
        store.materials.filter { store.visitedIDs.contains($0.id) }
    }

    private enum PaneRole { case pinned, active, hidden }

    private func role(of m: ReferenceMaterial) -> PaneRole {
        if store.splitActive, store.pinnedID == m.id { return .pinned }
        if store.selectedID == m.id { return .active }
        return .hidden
    }

    private var materialCanvas: some View {
        GeometryReader { geo in
            let split = store.splitActive
            let topH = split ? min(max(120, geo.size.height * splitFraction),
                                   max(120, geo.size.height - 120 - dividerThickness)) : 0
            let bottomH = split ? max(0, geo.size.height - topH - dividerThickness)
                                : geo.size.height

            ZStack(alignment: .topLeading) {
                ForEach(visitedMaterials) { m in
                    let r = role(of: m)
                    materialView(m)
                        .frame(width: geo.size.width, height: r == .pinned ? topH : bottomH)
                        .offset(y: r == .pinned ? 0 : (split ? topH + dividerThickness : 0))
                        .opacity(r == .hidden ? 0 : 1)
                        .allowsHitTesting(r != .hidden)
                        .accessibilityHidden(r == .hidden)
                }

                // Same material pinned AND selected: the lower pane is empty.
                if split, store.pinnedID == store.selectedID {
                    Text("Pick another tab to show here")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.muted)
                        .frame(width: geo.size.width, height: bottomH)
                        .background(Color(white: 0.95))
                        .offset(y: topH + dividerThickness)
                }

                if split {
                    ZStack {
                        Rectangle().fill(Color.black.opacity(0.08))
                        Capsule().fill(Color.black.opacity(0.25)).frame(width: 36, height: 3)
                    }
                    .frame(width: geo.size.width, height: dividerThickness)
                    .offset(y: topH)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                splitFraction = min(0.8, max(0.2, v.location.y / max(geo.size.height, 1)))
                            }
                    )
                }
            }
        }
    }

    @ViewBuilder private func materialView(_ m: ReferenceMaterial) -> some View {
        switch m {
        case .pdf(let file): pdfView(file)
        case .web(let link): webView(link)
        }
    }

    @ViewBuilder private func pdfView(_ file: ExamFile) -> some View {
        switch store.pdfStates[file.id] {
        case .loaded(let doc):
            PDFKitView(document: doc)
        case .failed:
            VStack(spacing: Theme.Space.md) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 26)).foregroundStyle(Theme.muted2)
                Text("Couldn't load \(file.originalName).")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                Button("Try again") { store.retry(file: file) }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))
        case .loading, nil:
            ProgressView("Loading document…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.93))
        }
    }

    @ViewBuilder private func webView(_ link: ExamLink) -> some View {
        if let url = normalizedURL(link.url) {
            LockedBrowserView(url: url, allowedHosts: store.allowedHosts) { blocked in
                withAnimation { blockedHost = blocked.host ?? "that site" }
            }
        } else {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "globe").font(.system(size: 26)).foregroundStyle(Theme.muted2)
                Text("This link couldn't be opened.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "books.vertical").font(.system(size: 26)).foregroundStyle(Theme.muted2)
            Text("Your teacher didn't attach any reference materials.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.95))
    }
}
```

(The old `ReferenceMode` enum, mode bar, pane headers, dropdown menus,
`primeSelection`, `reloadPDF`, and `loadDocument` are all deleted with this
rewrite; loading moved into `ReferenceTabStore`.)

- [ ] **Step 2: Remove the obsolete layout preference from SettingsView**

In `Weft/SettingsView.swift`:

a) Delete the key from `enum Prefs`:

```swift
    static let referenceDefaultMode = "weft.referenceDefaultMode" // "split"|"pdf"|"web"
```

b) Delete from `GeneralSettings`:

```swift
    @AppStorage(Prefs.referenceDefaultMode) private var referenceMode = "split"
```

c) In the `Section("Writing")`, delete the picker:

```swift
                Picker("Default reference layout", selection: $referenceMode) {
                    Text("Split (PDF + web)").tag("split")
                    Text("PDF only").tag("pdf")
                    Text("Web only").tag("web")
                }
```

(The "Confirm before submitting an exam" toggle stays.)

- [ ] **Step 3: Build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. If anything else still references
`Prefs.referenceDefaultMode` or `ReferenceMode`, the compiler will list it;
delete those references too (the only known consumers were this panel and
SettingsView).

- [ ] **Step 4: QA — tabs, persistence, split**

```bash
WEFT_SCREEN=exam ~/Weft/build/Build/Products/Debug/Weft.app/Contents/MacOS/Weft
```

The QA build is signed out, so PDFs show the bundled sample document and the
sample links load in the locked browser.

1. Tabs render for every sample file + link; first material selected.
2. Click a web tab, scroll the page, navigate one click deep (allowed host).
   Click a PDF tab, scroll a few pages. Click back to the web tab: the page is
   exactly where you left it (no reload), and back to the PDF: same scroll spot.
3. Split: click the split button; the current material pins on top with a pin
   marker, the next material opens below; drag the divider; toggle split off.
4. With split on, select the pinned tab: the lower pane shows the
   "Pick another tab" hint.
5. In the web pane, try navigating to an off-list site (type nothing; click an
   external link on the page if present): the red "Blocked:" toast appears.
6. Settings (Cmd+,): the "Default reference layout" picker is gone; the
   submit-confirm toggle remains.
7. Hide/show references with the toolbar button and ⌘⇧R still works.

- [ ] **Step 5: Commit**

```bash
cd ~/Weft && git add Weft/ExamReferencePanel.swift Weft/SettingsView.swift && git commit -m "References: browser-style tabs with persistent live views + split pin"
```

---

### Task 7: Verified fullscreen exit on submit

`exitKiosk` already calls `toggleFullScreen(nil)`, but macOS silently DROPS
that call while a fullscreen transition is in flight, which leaves the student
stranded fullscreen on the Done screen. Make the exit verified-with-retry.

**Files:**
- Modify: `Weft/KioskController.swift:202-221` (`exitKiosk`)

- [ ] **Step 1: Replace exitKiosk with a verified exit**

Replace the existing `func exitKiosk(window: NSWindow) { ... }` with:

```swift
    func exitKiosk(window: NSWindow) {
        inTest = false
        teardownObservers()

        // Restore the global presentation surface. Empty == normal desktop:
        // dock back, menu bar back, Cmd+Tab / Cmd+Q / Apple menu live again.
        NSApp.presentationOptions = []

        // Un-pin and un-protect, restoring the saved values rather than
        // assuming defaults so a reused window comes back exactly as it was.
        window.level = savedLevel
        window.sharingType = savedSharingType

        lockedWindow = nil

        // Leave the full-screen space — verified. macOS silently drops
        // toggleFullScreen while a fullscreen transition is in flight (e.g. a
        // submit during the entry animation), so retry until the window is
        // actually windowed.
        leaveFullScreen(window)
    }

    /// Toggle out of full screen and re-check after the animation; retry a few
    /// times if the toggle was swallowed by an in-flight transition.
    private func leaveFullScreen(_ window: NSWindow, attempt: Int = 0) {
        guard window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
        guard attempt < 5 else { return }
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let window, !self.inTest,
                  window.styleMask.contains(.fullScreen) else { return }
            self.leaveFullScreen(window, attempt: attempt + 1)
        }
    }
```

(The `!self.inTest` guard means a re-entered kiosk — student resumed a new
exam — is never fought by a stale retry.)

- [ ] **Step 2: Build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: QA (logic review + note for live test)**

The dev-gallery exam (`WEFT_SCREEN=exam`) runs with `lockdown: false` and never
enters kiosk, so the full path needs a real signed-in student exam. Verify now
by code review that: every return path out of the exam (`submit()`, `leave()`,
time-expiry force submit, `.onDisappear`) funnels through
`endExam() -> exitKiosk`. Flag the live check ("submit a real exam, window
drops out of full screen onto the Done screen") for the user's next real run.

- [ ] **Step 4: Commit**

```bash
cd ~/Weft && git add Weft/KioskController.swift && git commit -m "Kiosk: verified fullscreen exit (retry around in-flight transitions)"
```

---

### Task 8: Integration pass

**Files:** none new — verification only.

- [ ] **Step 1: Full clean build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build clean build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: End-to-end QA sweep in the dev gallery**

```bash
WEFT_SCREEN=exam ~/Weft/build/Build/Products/Debug/Weft.app/Contents/MacOS/Weft
```

Run the full exam-screen checklist in one session:

1. Long-document typing stays instant; Bold/Italic/Underline apply instantly
   from both toolbar and Cmd+B/I/U.
2. Headings via Cmd+Alt+1/2/0 and toolbar.
3. Bulleted + numbered lists: toggle on/off, Return continuation, empty-item
   exit, Tab/Shift+Tab levels, sane word count.
4. Reference tabs: instant switching, preserved PDF scroll + web state, split
   pin + divider drag, blocked-site toast, hide/show panel (⌘⇧R).
5. Submit flow (preview): Submit button asks for confirmation, lands on Done.

- [ ] **Step 3: HTML export regression**

```bash
cd ~/Weft && swiftc Weft/RichTextHTML.swift /tmp/weft_html_test.swift -o /tmp/weft_html_test && /tmp/weft_html_test
```
Expected: `ALL TESTS PASSED`

- [ ] **Step 4: Hand off for live verification**

Remind the user: the fullscreen-exit fix and kiosk behavior need one real
signed-in student exam run (lockdown path) to confirm: enter exam (window goes
fullscreen + kiosk), submit, window returns to normal on the Done screen.

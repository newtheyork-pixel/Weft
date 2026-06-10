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
        // Key equivalents traverse the whole window's view tree; without the
        // first-responder guard an UNFOCUSED editor would steal Cmd+B/I/U from
        // whatever the student is actually typing in (the reference panel's
        // web forms, for one) and silently mutate the essay.
        guard event.type == .keyDown,
              window?.firstResponder === self,
              !hasMarkedText(),               // never reformat mid-IME composition
              let formatting else {
            return super.performKeyEquivalent(with: event)
        }
        // Compare against just the four modifiers we mean: the device mask
        // also carries .function (number-row keys on some keyboards),
        // .capsLock, and .numericPad, any of which would break strict
        // equality and silently kill the shortcut.
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
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

    // Return inside a list: an empty item ends the list; otherwise the
    // controller inserts newline + next marker as one edit (super must NOT
    // run for list paragraphs — TextKit 2's native list handling underneath
    // it inserts stray newlines and fights the caret).
    override func insertNewline(_ sender: Any?) {
        if formatting?.endListIfEmptyItem() == true { return }
        if formatting?.insertListNewline() == true { return }
        super.insertNewline(sender)
    }

    // Tab / Shift+Tab indent and outdent list items (Google Docs). Outside a
    // list they keep their normal text-editing meaning.
    override func insertTab(_ sender: Any?) {
        if formatting?.changeListLevel(by: 1) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if formatting?.changeListLevel(by: -1) == true { return }
        super.insertBacktab(sender)
    }

    // MARK: Caret sizing

    /// Pin the insertion indicator to the typing font's cap height and disable
    /// the bounce/animation effects so the caret reads as a normal document
    /// cursor at ALL paragraph line spacings (double-spaced paragraphs otherwise
    /// produce a double-height bouncing caret via NSTextInsertionIndicator).
    ///
    /// Implementation: on macOS 14+ NSTextInsertionIndicator is the subview
    /// AppKit injects. We locate it after every layout pass, kill its automatic
    /// mode options (which drive the bounce), then clamp the frame height to the
    /// typing font's line height when the caret has grown taller than 130% of
    /// that — the 1.3× slack absorbs sub-pixel rounding without false triggers.
    override func layout() {
        super.layout()
        guard let font = typingAttributes[.font] as? NSFont else { return }
        let lineHeight = font.ascender - font.descender
        for case let indicator as NSTextInsertionIndicator in subviews {
            indicator.automaticModeOptions = []
            if indicator.frame.height > lineHeight * 1.3 {
                var f = indicator.frame
                let inset = (f.height - lineHeight) / 2
                f.origin.y += inset
                f.size.height = lineHeight
                indicator.frame = f
            }
        }
    }
}

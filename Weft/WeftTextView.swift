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
        // Strip .function too: number-row keys set it on some keyboards and it
        // survives deviceIndependentFlagsMask, which would silently break the
        // Cmd+Alt+1 / Cmd+Shift+7 equality checks below.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.function)
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

    // Return inside a list: an empty item ends the list; otherwise make sure
    // the list continues with the next marker (no-op if AppKit carried it).
    override func insertNewline(_ sender: Any?) {
        if formatting?.endListIfEmptyItem() == true { return }
        super.insertNewline(sender)
        formatting?.continueListAfterNewlineIfNeeded()
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
}

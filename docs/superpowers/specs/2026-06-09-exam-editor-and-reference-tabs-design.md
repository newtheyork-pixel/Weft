# Exam editor rework + reference tabs

**Date:** 2026-06-09
**Status:** Approved
**Area:** Weft native macOS app (`~/Weft`), exam writing experience

## Why

Three student-facing problems in the exam window:

1. **Typing and formatting lag.** Pressing Bold can take around a second to apply.
   Root cause: `RichTextEditor` round-trips the entire `NSAttributedString` through
   a SwiftUI `@Binding` on every keystroke. Each edit performs a full attributed
   copy (`textDidChange`), then up to three deep compares per render pass
   (`updateNSView`'s `isEqual`, `ExamView.onChange(of: essay)`, SwiftUI's own diff).
   Cost grows with essay length. The push-back path in `updateNSView` is also a
   standing caret-clobber risk while typing.
2. **Missing Google Docs muscle memory.** Students transition from Google Docs.
   Cmd+B/I/U do nothing today (the app menu has no Format menu, and the text view
   gets no key equivalents). The Electron editor had full shortcuts.
3. **The reference system feels bolted together.** The Split/PDF/Web segmented
   switcher plus one dropdown per pane is a different mental model from anything
   students use. Switching materials reloads them: PDFs refetch (signed URL +
   download per switch) and web views reload, losing scroll and page state.

One smaller fix rides along: after submit, the window stays in full screen even
though the kiosk lock is released. Students should land on the Done screen in a
normal window.

## Decisions (user-confirmed)

- Reference model: **browser tabs**. Every PDF and approved website is a tab in
  one reference area. Optional split pins one material above another.
- Editor scope: **lag fix + Google Docs shortcuts + real lists only.**
  Explicitly out of scope: strikethrough, text/highlight color, alignment,
  line spacing, undo/redo toolbar buttons, active-state toolbar highlighting,
  font/size pickers, view modes.
- Editor architecture: **remove the binding round-trip** (Approach A), not a
  throttle bandaid, not a SwiftUI TextEditor rewrite.
- Reference architecture: **persistent live views** (Approach A). Views are kept
  alive for the whole exam; the tab strip switches visibility.

## Design

### 1. Editor core (RichTextEditor.swift, ExamView.swift)

The NSTextView owns the document. SwiftUI never holds the essay text.

- `RichTextEditor` drops `@Binding var text` and `@Binding var wordCount`.
  New surface: `RichTextEditor(controller:, isEditable:, onEdit:)`.
- The coordinator's `textDidChange` does two cheap things only:
  recompute the word count and call `onEdit()`. No attributed copy, no binding
  write, no deep compares.
- `RichTextController` (already `@Observable`) gains:
  - `private(set) var wordCount: Int` (toolbar/ExamView read this),
  - `func setContent(_ text: NSAttributedString)` for seeding (preview text,
    later: draft restore),
  - `func snapshot() -> NSAttributedString` for save/submit,
  - `func htmlSnapshot() -> String` exporting the Electron sanitizer subset
    (`b/i/u`, `h1/h2`, `ul/ol/li`, `p/br`) so future submission writes render
    identically in the teacher grading view and the web portal, which already
    consume Electron-produced HTML.
- `ExamView` removes `@State essay` and `onChange(of: essay)`. The autosave
  debounce is driven by `onEdit`. Submit reads `controller.snapshot()`
  (and `htmlSnapshot()` once real persistence lands; the autosave network write
  remains a stub and is out of scope here).

### 2. Shortcuts (new NSTextView subclass)

`WeftTextView: NSTextView` overrides `performKeyEquivalent(with:)` and routes
to the existing controller methods. Mappings (Google Docs):

| Keys | Action |
|---|---|
| Cmd+B / Cmd+I / Cmd+U | bold / italic / underline |
| Cmd+Alt+1 / Cmd+Alt+2 / Cmd+Alt+0 | heading 1 / heading 2 / body |
| Cmd+Shift+8 / Cmd+Shift+7 | bulleted list / numbered list |

Unhandled keys fall through to `super`. Toolbar tooltips gain shortcut hints
(for example "Bold (⌘B)").

### 3. Real lists (NSTextList)

Replace the "• " character-prefix hack with native `NSTextList` paragraph
styles:

- Bulleted (`.disc`) and numbered (`.decimal`) lists, applied per paragraph
  range, toggling off cleanly.
- Enter continues the list; Enter on an empty item ends the list
  (via `insertNewline` handling in `WeftTextView` where AppKit's default does
  not already do the right thing).
- Tab / Shift+Tab indent and outdent list items.
- A numbered-list button joins the toolbar next to the bulleted one.
- Word count drops the bullet-prefix stripping hack; markers are not part of
  the countable text.

### 4. Reference tabs (ExamReferencePanel.swift)

- `ReferenceMaterial`: one unified model, `.pdf(ExamFile)` or `.web(ExamLink)`,
  with id, display title, and icon.
- `ReferenceTabStore` (`@Observable`): the material list, `selectedID`,
  `pinnedID` (split), per-material load state, and the live-view registry.
- **Tab strip** (replaces the mode switcher + both dropdowns): a horizontally
  scrollable row of chips (icon + name), active tab highlighted, a Split toggle,
  and the existing hide-panel button. Overflow scrolls; no tab is ever dropped.
- **Persistent views:** each material's view is created on first open and kept
  alive for the rest of the exam in an always-mounted container; tab clicks
  switch visibility only. Scroll, zoom, page position, and web navigation state
  survive switching. Websites never reload (the old Electron pain where
  switching back from a website failed).
- **Prefetch:** at exam start, all PDF signed URLs and documents load
  concurrently; a tab whose document is still loading shows a small spinner.
- **Split:** toggling Split pins the currently selected material to the top
  pane; the tab strip then drives the bottom pane. Toggling off returns to a
  single pane showing the tab-strip selection. (Pinned tab gets a pin marker.)
- **Locked browser unchanged:** `LockedBrowserView`, the host allowlist, and
  the blocked-host toast keep today's behavior exactly.
- **Failure states:** a failed PDF shows tap-to-retry inside the pane; retry
  requests a fresh signed URL (covers signed-URL expiry mid-exam).
- **Defaults cleanup:** `Prefs.referenceDefaultMode` and the Settings
  "Default reference layout" picker are removed (obsolete with tabs).
- Empty states ("no files", "no links", neither) keep today's copy, adapted to
  the single-area layout.

### 5. Fullscreen exit on submit

When the exam ends (submit, time expiry, or leave-in-preview), after
`kiosk.exitKiosk(window:)` the window also leaves macOS full screen if active
(`window.styleMask.contains(.fullScreen)` then `toggleFullScreen(nil)`) and
returns to its pre-exam frame, so the Done screen appears as a normal window.

## Error handling

- PDF load/prefetch failure: per-tab retry state, fresh signed URL on retry.
- Web load failure: existing LockedBrowserView behavior (unchanged).
- Editor: no network surface; snapshot calls are synchronous main-actor reads.

## Out of scope

- Real autosave/submission network writes (existing stub stays).
- Any editor feature not listed (colors, alignment, suggesting mode, etc.).
- Teacher-side screens and the Electron app.
- Word-count semantics changes (same whitespace-split rule).

## Testing

- Dev gallery exam screen (`WEFT_SCREEN`): paste a several-thousand-word
  document; verify no per-keystroke lag and instant Bold on selection.
- Every shortcut in the table above, plus toolbar buttons, on empty selection
  and on ranges.
- Lists: Enter continuation, empty-item exit, Tab/Shift+Tab, toggle off,
  mixed bullet/numbered, word count correctness.
- References: exam with 2+ PDFs and 2+ links. Tab switching is instant; PDF
  page/zoom and web scroll/navigation survive round trips; split pin works;
  blocked-host toast still fires; retry works after a forced failure.
- Lockdown run: submit exits full screen and lands on Done as a normal window;
  time-expiry force-submit does the same.
- `xcodebuild` clean build.

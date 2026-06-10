# Editor Wave 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read-only viewer for submitted essays, a normal-sized steady caret, student formatting (fonts/size/spacing/colors, default Times New Roman 12 double-spaced), per-assignment teacher spell-check control, and the over-word-limit submit refusal.

**Architecture:** One SECURITY DEFINER RPC returns the caller's own newest submitted essay per assignment family; a new read-only screen renders it through ReturnedWorkView's existing HTML parser. Formatting lands as attribute-only controller methods + compact toolbar menus, with the HTML exporter gaining sanitizer-compatible span styles. Spell check is a `tests` column flowing Assignment -> editor toggle -> RichTextEditor.

**Tech Stack:** Swift 6 / SwiftUI + AppKit (project `~/Weft`, branch `phase2-native-wiring`), Supabase via SupabaseManager, two SQL migrations on `elrrvicxsguqstqciodn`.

**Spec:** `docs/superpowers/specs/2026-06-10-editor-wave-2-design.md`

**Canonical build command** (per-lane derivedDataPath as assigned in each task):

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath <build-dir> build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. GUI QA is deferred to the human.

**Lanes:** Task 1 controller-executed. Tasks 2 (Models+SupabaseManager), 3 (RichTextEditor+WeftTextView), 4 (RichTextHTML+harness) own disjoint files and run in PARALLEL (build dirs build-a/build-b/build-c; a failing build naming another lane's file = wait 30s, rebuild). Task 5 then Task 6 run SEQUENTIALLY after (both touch AppState). Task 7 integrates.

---

### Task 1: Migrations (CONTROLLER-EXECUTED)

- [ ] **Step 1: `get_my_submission`** (migration `get_my_submission_rpc`):

```sql
-- Read-only viewer: the caller's NEWEST submitted essay across an assignment
-- family's sessions. SECURITY DEFINER + keyed on auth.uid()'s own students
-- rows, so it can return nobody else's work by construction.
create or replace function public.get_my_submission(p_version_group_id uuid)
returns table(title text, content_html text, word_count integer,
              submitted_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select t.title, es.content_html, es.word_count, es.submitted_at
  from sessions s
  join tests t            on t.id = s.test_id
  join students st        on st.session_id = s.id and st.user_id = auth.uid()
  join essay_submissions es on es.session_id = s.id and es.student_id = st.id
  where coalesce(t.version_group_id, t.id) = p_version_group_id
    and es.submitted_at is not null
  order by es.submitted_at desc
  limit 1;
$function$;

grant execute on function public.get_my_submission(uuid) to authenticated;
```

- [ ] **Step 2: `tests.spellcheck_enabled`** (migration `tests_spellcheck_enabled`):

```sql
-- Per-assignment teacher control for student spell check. Default true keeps
-- every existing assignment and the Electron editor (which never sends the
-- column) unchanged.
alter table public.tests
  add column if not exists spellcheck_enabled boolean not null default true;
```

- [ ] **Step 3: Smoke checks** (`execute_sql`): `select pg_get_function_result('public.get_my_submission(uuid)'::regprocedure);` ends in `submitted_at timestamp with time zone`; `select * from public.get_my_submission(gen_random_uuid());` returns 0 rows no error; `select column_default, is_nullable from information_schema.columns where table_name='tests' and column_name='spellcheck_enabled';` shows `true` / `NO`.

---

### Task 2: Data layer (Models + SupabaseManager) — lane A (build-a)

**Files:** Modify `Weft/Models.swift`, `Weft/SupabaseManager.swift`.

- [ ] **Step 1: Assignment.spellcheckEnabled** (Models.swift)

Add `var spellcheckEnabled: Bool` after `timeLimitMinutes`; CodingKeys `case spellcheckEnabled = "spellcheck_enabled"`; memberwise init gains `spellcheckEnabled: Bool = true` (LAST parameter, defaulted, so existing call sites compile); tolerant `init(from:)` gains `spellcheckEnabled = (try? c.decode(Bool.self, forKey: .spellcheckEnabled)) ?? true`. Samples unchanged (default covers them).

- [ ] **Step 2: SubmittedEssay DTO** (Models.swift, near ReturnedWorkItem)

```swift
// MARK: - A submitted (not necessarily graded) essay, via get_my_submission

struct SubmittedEssay: Decodable, Sendable {
    let title: String
    let contentHtml: String
    let wordCount: Int
    let submittedAt: Date

    enum CodingKeys: String, CodingKey {
        case title
        case contentHtml = "content_html"
        case wordCount = "word_count"
        case submittedAt = "submitted_at"
    }
}
```

- [ ] **Step 3: SupabaseManager additions**

In the student lifecycle MARK section:

```swift
    /// The caller's newest SUBMITTED essay for an assignment family (the
    /// read-only viewer behind the Past row). RLS-safe by construction:
    /// the RPC keys on auth.uid()'s own students rows.
    func getMySubmission(versionGroupId: String) async throws -> SubmittedEssay? {
        let rows: [SubmittedEssay] = try await rpc("get_my_submission",
                                                   params: ["p_version_group_id": versionGroupId])
        return rows.first
    }
```

(Match the existing `rpc` helper's exact signature, as used by `lookupSession`.)

In `createTest` and `updateTest` payloads add `let spellcheck_enabled: Bool` wired from a new `spellcheckEnabled: Bool` parameter (defaulted `= true` on `createTest` so existing call sites compile; `updateTest` gets it as a required param and the one caller is updated in Task 6 — for THIS task give it a default `= true` too so the build stays green, Task 6 threads the real value). In `createDraftTest`'s payload add `let spellcheck_enabled: Bool` set from `source.spellcheckEnabled` (drafts inherit).

- [ ] **Step 4: Build (build-a), commit**

```bash
cd ~/Weft && git add Weft/Models.swift Weft/SupabaseManager.swift && git commit -m "Data layer: spellcheck_enabled on assignments, get_my_submission RPC"
```

---

### Task 3: Editor engine (RichTextEditor + WeftTextView) — lane B (build-b)

**Files:** Modify `Weft/RichTextEditor.swift`, `Weft/WeftTextView.swift`.

- [ ] **Step 1: New defaults in RichTextStyle**

```swift
    static let bodyFontSize: CGFloat = 12
    static let defaultFontFamily = "Times New Roman"
    /// Double spacing is the school-essay default; the spacing menu writes
    /// other multiples per paragraph.
    static let defaultLineHeightMultiple: CGFloat = 2.0
```

`bodyFont` becomes `NSFont(name: defaultFontFamily, size: bodyFontSize)` with the existing serif-design fallback. `bodyParagraphStyle()` and `listParagraphStyle(_:level:)` use `defaultLineHeightMultiple`. Heading sizes/styles unchanged. The demo seed and ExamView preview text inherit automatically.

- [ ] **Step 2: Formatting setters on RichTextController**

Add a `// MARK: Fonts / colors / spacing` section. Each follows the toggleTrait shape (empty selection -> typing attributes; else enumerate runs; `shouldChangeText(in:replacementString: nil)` — attribute-only is correct here; `begin/endEditing` + `didChangeText`). Complete code:

```swift
    /// Change the font FAMILY across the selection, preserving each run's
    /// size and bold/italic traits (Google Docs semantics).
    func setFontFamily(_ family: String) {
        mutateFonts { current in
            let traits = current.fontDescriptor.symbolicTraits
            let base = NSFont(name: family, size: current.pointSize) ?? current
            let d = base.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: d, size: current.pointSize) ?? base
        }
    }

    /// Change the font SIZE across the selection, preserving family + traits.
    func setFontSize(_ size: CGFloat) {
        mutateFonts { current in
            NSFont(descriptor: current.fontDescriptor, size: size) ?? current
        }
    }

    /// Shared font-run mutator (selection or typing attributes).
    private func mutateFonts(_ transform: (NSFont) -> NSFont) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var typing = tv.typingAttributes
            let base = (typing[.font] as? NSFont) ?? RichTextStyle.bodyFont
            typing[.font] = transform(base)
            tv.typingAttributes = typing
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let current = (value as? NSFont) ?? RichTextStyle.bodyFont
            storage.addAttribute(.font, value: transform(current), range: sub)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    /// Text color across the selection (or typing attributes).
    func setTextColor(_ color: NSColor) {
        mutateAttribute(.foregroundColor, value: color)
    }

    /// Highlight across the selection; nil clears it.
    func setHighlight(_ color: NSColor?) {
        mutateAttribute(.backgroundColor, value: color)
    }

    private func mutateAttribute(_ key: NSAttributedString.Key, value: Any?) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var typing = tv.typingAttributes
            typing[key] = value
            tv.typingAttributes = typing
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if let value {
            storage.addAttribute(key, value: value, range: range)
        } else {
            storage.removeAttribute(key, range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    /// Line spacing (paragraph-level, like Google Docs): applies the multiple
    /// to every paragraph touching the selection and to typing attributes.
    func setLineSpacing(_ multiple: CGFloat) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        let apply: (NSParagraphStyle) -> NSParagraphStyle = { s in
            let m = (s.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            m.lineHeightMultiple = multiple
            return m
        }
        var typing = tv.typingAttributes
        let typingStyle = (typing[.paragraphStyle] as? NSParagraphStyle) ?? RichTextStyle.bodyParagraphStyle()
        typing[.paragraphStyle] = apply(typingStyle)
        tv.typingAttributes = typing
        guard range.length > 0 else { return }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, sub, _ in
            let s = (value as? NSParagraphStyle) ?? RichTextStyle.bodyParagraphStyle()
            storage.addAttribute(.paragraphStyle, value: apply(s), range: sub)
        }
        storage.endEditing()
        tv.didChangeText()
    }
```

- [ ] **Step 3: Toolbar menus**

Add constants near the toolbar:

```swift
/// Curated, macOS-standard families that also render in the grading view.
let weftFontFamilies = ["Times New Roman", "Arial", "Georgia", "Helvetica Neue",
                        "Verdana", "Courier New", "Palatino", "Baskerville",
                        "Trebuchet MS", "Comic Sans MS", "American Typewriter", "Menlo"]
let weftFontSizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 24, 30, 36]
let weftTextColors: [(String, NSColor)] = [
    ("Ink", RichTextStyle.inkColor), ("Gray", .systemGray), ("Red", .systemRed),
    ("Orange", .systemOrange), ("Green", .systemGreen), ("Blue", .systemBlue),
    ("Purple", .systemPurple), ("Brown", .systemBrown)]
let weftHighlights: [(String, NSColor?)] = [
    ("None", nil), ("Yellow", .systemYellow), ("Green", .systemGreen),
    ("Cyan", .systemCyan), ("Pink", .systemPink), ("Orange", .systemOrange)]
let weftSpacings: [(String, CGFloat)] = [("Single", 1.0), ("1.15", 1.15),
                                         ("1.5", 1.5), ("Double", 2.0)]
```

Append to `RichTextToolbar.body` after the list buttons (`divider` between groups), as compact SwiftUI `Menu`s matching the existing toolbar visual language (12pt semibold labels, `.menuStyle(.borderlessButton)`, `.fixedSize()`, `.help(...)`):
- Font menu labeled "Aa" (`.help("Font")`) — items call `controller.setFontFamily(f)`.
- Size menu labeled "12"-style static "Size" glyph `textformat.size` icon — items call `controller.setFontSize(s)`.
- Color menu (icon `paintpalette`) with a "Text" section of `weftTextColors` and a "Highlight" section of `weftHighlights`, calling `setTextColor` / `setHighlight`.
- Spacing menu (icon `arrow.up.and.down.text.horizontal`) calling `setLineSpacing`.

(If the capsule gets cramped at the exam's minimum editor width of 380pt, allow the toolbar HStack to wrap the new menus into the same capsule with tighter spacing — implementer judgment, keep it visually quiet.)

- [ ] **Step 4: Spell-check parameter**

`RichTextEditor` gains `var spellcheckEnabled: Bool = true`; in `makeNSView` set `textView.isContinuousSpellCheckingEnabled = spellcheckEnabled` (replacing the hardcoded true) and keep `isAutomaticSpellingCorrectionEnabled = false`; in `updateNSView` sync it when changed. Doc comment: teacher-controlled per assignment; autocorrect stays off unconditionally (an exam editor must never rewrite words).

- [ ] **Step 5: Caret fix (WeftTextView)**

In `Weft/WeftTextView.swift`, configure the TextKit 2 insertion indicator so the caret is font-height and does not bounce. Implementation approach (verify exact API at build time; macOS 14+ has `NSTextInsertionIndicator`):

```swift
    // The macOS animated insertion indicator inherits the paragraph's inflated
    // line box (double spacing -> double-height caret) and bounces. Pin it to
    // the typing font's line height and disable the effects so it reads as a
    // normal document caret.
    override func layout() {
        super.layout()
        for case let indicator as NSTextInsertionIndicator in subviews {
            indicator.automaticModeOptions = []
            if let font = typingAttributes[.font] as? NSFont {
                let lineHeight = font.ascender - font.descender
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
```

If `automaticModeOptions = []` alone produces the desired steady, line-height caret, drop the manual frame surgery (prefer the least code that meets the acceptance criterion: caret ~= font line height at ALL spacings, no bounce). If the indicator subview never appears (API moved), fall back to `insertionPointColor`-era behavior and report DONE_WITH_CONCERNS describing what the API offered.

- [ ] **Step 6: Build (build-b), commit**

```bash
cd ~/Weft && git add Weft/RichTextEditor.swift Weft/WeftTextView.swift && git commit -m "Editor: TNR 12 double-spaced defaults, font/size/color/spacing menus, teacher spellcheck param, steady caret"
```

---

### Task 4: HTML export styles (RichTextHTML + harness) — lane C (build-c)

**Files:** Modify `Weft/RichTextHTML.swift`; test `/tmp/weft_html_test.swift`.

- [ ] **Step 1: Extend the harness FIRST** (append before the final print, keeping all existing cases):

```swift
let tnr12: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 12)!]
let arial: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Arial", size: 12)!]
let big: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 18)!]
let red: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 12)!,
                                          .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)]
let hl: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 12)!,
                                         .backgroundColor: NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)]

expect("default font suppressed", RichTextHTML.html(from: para([("plain", tnr12)])),
       "<p>plain</p>")
expect("family span", RichTextHTML.html(from: para([("a", arial)])),
       "<p><span style=\"font-family: Arial\">a</span></p>")
expect("size span", RichTextHTML.html(from: para([("a", big)])),
       "<p><span style=\"font-size: 18px\">a</span></p>")
expect("color span", RichTextHTML.html(from: para([("a", red)])),
       "<p><span style=\"color: #ff0000\">a</span></p>")
expect("highlight span", RichTextHTML.html(from: para([("a", hl)])),
       "<p><span style=\"background-color: #ffff00\">a</span></p>")
```

Also UPDATE the existing harness's `font(size:bold:italic:)` helper to build from `NSFont(name: "Times New Roman", size: size)` (falling back to system) so the legacy cases still represent "default family" and keep passing unchanged. The legacy cases used size 16 for body — change their sizes to 12 (body) so they stay default-suppressed; the `h1` case keeps 28.

- [ ] **Step 2: Run to see the new cases FAIL**, then implement in RichTextHTML.swift:

In `inlineHTML`, after computing `piece` (escaped + u/i/b wrapped), build a style string from non-defaults and wrap once:

```swift
            var styles: [String] = []
            if let font = attrs[.font] as? NSFont {
                let family = font.familyName ?? ""
                if !family.isEmpty, family != defaultFamily {
                    styles.append("font-family: \(family)")
                }
                if abs(font.pointSize - defaultSize) > 0.1,
                   // Headings carry their own sizes; don't re-state them.
                   !suppressBold {
                    styles.append("font-size: \(Int(font.pointSize))px")
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
```

Supporting pieces (complete): `html(from:h1Size:h2Size:)` gains `defaultFamily: String = "Times New Roman"`, `defaultSize: CGFloat = 12` parameters (threaded into inlineHTML); `defaultInkHex` = the hex of RichTextStyle's ink — hardcode `"#22201c"` with a comment tying it to RichTextStyle.inkColor; and:

```swift
    /// sRGB hex ("#rrggbb") for a color; nil when it can't be converted.
    private static func hexString(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
```

Paragraph spacing: in the block emission, when the paragraph's style has a
lineHeightMultiple differing from 2.0 (the default) and > 0, emit
`<p style="line-height: <multiple>">` (and same for li). KNOWN: Electron's
grading sanitizer strips font-size/line-height; family/color/background
survive. State this in a file comment.

`htmlSnapshot()` in RichTextEditor.swift is lane B's file — do NOT touch it;
the new parameters have defaults matching RichTextStyle, so the existing call
keeps working. (Update the doc comment on `html(from:)` to mention the
defaults instead.)

- [ ] **Step 3: Run harness to ALL TESTS PASSED** (`cp /tmp/weft_html_test.swift /tmp/main.swift && swiftc Weft/RichTextHTML.swift /tmp/main.swift -o /tmp/weft_html_test && /tmp/weft_html_test`), build (build-c), commit:

```bash
cd ~/Weft && git add Weft/RichTextHTML.swift && git commit -m "HTML export: sanitizer-compatible span styles for family/size/color/highlight + line-height"
```

---

### Task 5: Read-only viewer — AFTER tasks 2-4 (build-a)

**Files:** Create `Weft/SubmittedWorkView.swift`; modify `Weft/AppState.swift`, `Weft/WeftApp.swift` (StudentFlowView switch), `Weft/StudentClassHomeView.swift`, `Weft/ReturnedWorkView.swift` (only if its HTML parser needs access widening).

- [ ] **Step 1: AppState navigation + load**

`StudentScreen` gains case `submitted`. New state + methods:

```swift
    /// The Past-row essay being viewed read-only (nil = loading/none).
    var submittedEssay: SubmittedEssay?
    var submittedEssayError: String?

    /// Open the read-only viewer for a Past row and fetch the essay.
    func openSubmittedWork(_ item: ClassWorkItem) {
        errorMessage = nil
        submittedEssay = nil
        submittedEssayError = nil
        studentScreen = .submitted
        guard signedIn else {
            // Preview: render the sample essay so the screen is demoable.
            submittedEssay = SubmittedEssay(title: item.title,
                contentHtml: "<p>The interplay of light and shadow works as more than scenery.</p>",
                wordCount: 11, submittedAt: item.mySubmittedAt ?? Date())
            return
        }
        Task { await loadSubmittedWork(versionGroupId: item.versionGroupId) }
    }

    func loadSubmittedWork(versionGroupId: String) async {
        do {
            if let essay = try await supabase.getMySubmission(versionGroupId: versionGroupId) {
                submittedEssay = essay
            } else {
                submittedEssayError = "Couldn't find your submitted essay."
            }
        } catch {
            submittedEssayError = describe(error)
        }
    }
```

(`SubmittedEssay` needs a memberwise init usable here — if the synthesized one
is blocked by Decodable, add an explicit init in Models.swift.) Wire
`case .submitted: SubmittedWorkView()` into StudentFlowView's switch
(WeftApp.swift) and `goToHome()` remains the back path.

- [ ] **Step 2: SubmittedWorkView (new file)**

Layout: `WeftTopBar(role: "Student")`; back button ("chevron.left" + the
class-home back style from StudentClassHomeView's detailHeader, action
`app.goToHome()`); serif title; "Submitted <date> · N words" muted line; the
essay on a white rounded page rendering
`ReturnedWorkView.paragraphs(fromHTML:)` output the same way ReturnedWorkView
renders its paragraphs (READ that view first and reuse its paragraph view
pattern; if the parser or paragraph view is `private`, widen to internal
rather than duplicating). States: spinner while `submittedEssay == nil &&
submittedEssayError == nil`; error card with "Try again" re-calling
`loadSubmittedWork` when error non-nil. No editing surface, no timer, no
kiosk. Add a `#Preview` with a seeded AppState.

- [ ] **Step 3: Past row becomes a button** (StudentClassHomeView.swift)

In the row builder's `.past` case, replace the inert `Chip(text: "Read-only", kind: .neutral)` with a button styled like the graded row's action (read the `.graded` case and mirror its control style), label "Read-only", `.help("Read your submitted essay")`, action `app.openSubmittedWork(item)`. Make the surrounding row tap target consistent with how the active/graded rows handle row-level clicks (match existing behavior; do not invent a new pattern).

- [ ] **Step 4: Build (build-a), commit**

```bash
cd ~/Weft && git add Weft/SubmittedWorkView.swift Weft/AppState.swift Weft/WeftApp.swift Weft/StudentClassHomeView.swift Weft/ReturnedWorkView.swift && git commit -m "Read-only viewer for submitted essays behind the Past row"
```

---

### Task 6: Teacher toggle + exam wiring + word-limit rider — AFTER task 5 (build-a)

**Files:** Modify `Weft/AssignmentEditorView.swift`, `Weft/AppState.swift`, `Weft/ExamView.swift`.

- [ ] **Step 1: Thread spellcheck through save** (AppState.swift)

`saveAssignment(title:prompt:wordLimit:timeLimitMinutes:links:)` gains
`spellcheckEnabled: Bool = true` (after timeLimitMinutes). The signed-in
branch passes it to `updateTest`/`createTest`; the preview branch stores it on
the local Assignment (memberwise init's new defaulted param). `updateTest`'s
default from Task 2 can now be removed or kept — keep the default, pass
explicitly here.

- [ ] **Step 2: Editor toggle** (AssignmentEditorView.swift)

Read the view; it primes local @State from `app.editingAssignment` in
`prime()`/onAppear and calls `app.saveAssignment(...)` on save. Add
`@State private var spellcheckEnabled = true`, primed from
`existing.spellcheckEnabled`; a `Toggle("Allow spell check while writing", isOn: $spellcheckEnabled)`
placed with the other assignment options (word limit / time limit row), with
`.help("When off, students see no spelling squiggles during this assignment")`;
pass it through the save call.

- [ ] **Step 3: ExamView wiring + word-limit rider**

a) The editor call gains the staged assignment's setting:
```swift
            RichTextEditor(controller: controller,
                           isEditable: !expired,
                           spellcheckEnabled: assignment.spellcheckEnabled,
                           onEdit: { scheduleSave() })
```

b) Word-limit refusal in `requestSubmit()` (manual path ONLY — `armExpiry`
and the failure-retry call `submit()` directly and stay exempt):

```swift
    /// Entry point for the Submit buttons: refuse while over the word limit
    /// (the 0:00 force-submit bypasses this — the deadline always wins), then
    /// confirm if the preference is on.
    private func requestSubmit() {
        if let limit = wordLimit, wordCount > limit {
            overLimitMessage = "Over the word limit (\(wordCount) / \(limit) words). Shorten your essay before submitting."
            return
        }
        overLimitMessage = nil
        if confirmBeforeSubmit {
            showSubmitConfirm = true
        } else {
            submit()
        }
    }
```

with `@State private var overLimitMessage: String?` rendered near the footer
in the house error style (mirror the checks screen's error banner), cleared
when the count drops to/below the limit (`.onChange(of: wordCount)` clearing
it when `wordCount <= (wordLimit ?? Int.max)`).

- [ ] **Step 4: Build (build-a), commit**

```bash
cd ~/Weft && git add Weft/AssignmentEditorView.swift Weft/AppState.swift Weft/ExamView.swift && git commit -m "Teacher spellcheck toggle, exam wiring, over-limit submit refusal"
```

---

### Task 7: Integration pass

- [ ] **Step 1:** Full clean build (`-derivedDataPath build-a clean build`) — `** BUILD SUCCEEDED **`.
- [ ] **Step 2:** HTML harness regression — `ALL TESTS PASSED` (now ~15 cases).
- [ ] **Step 3:** Final whole-range review (controller dispatches; range starts after the spec commit `96a703a`).
- [ ] **Step 4:** Live QA handoff: open a Past row and read the essay; caret small/steady at every spacing; font/size/color/highlight/spacing apply to selection AND new typing, survive submit, family+colors visible in the teacher grading view; spell-check toggle off on one assignment kills squiggles for it only (and drafts inherit it); over-limit manual submit refused with the message, clears when shortened; 0:00 force-submit still fires regardless.

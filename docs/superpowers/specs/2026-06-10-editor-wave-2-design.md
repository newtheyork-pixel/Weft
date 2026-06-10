# Editor wave 2: read-only viewer, caret, formatting, spell-check control

**Date:** 2026-06-10
**Status:** Approved
**Area:** Weft native macOS app (`~/Weft`) + two small Supabase migrations

## Why

Live QA after the submissions wave surfaced four asks:

1. The Past row's "Read-only" chip is dead — a student cannot reopen and read
   what they submitted (Electron has the same gap; this is new capability).
2. The insertion caret is oversized and bounces while typing (macOS's animated
   insertion indicator inherits the editor's inflated line box).
3. Students need real formatting: font choice (default Times New Roman 12),
   size, line spacing, text color/highlight.
4. Teachers need a per-assignment spell-check switch.

## Decisions (user-confirmed)

- Default editor style: **Times New Roman 12, double spacing** (menu offers
  Single / 1.15 / 1.5 / Double).
- Spell check **on by default**; the teacher can disable it per assignment.
- Fonts come from a **curated dropdown** (~12 macOS-standard families), not
  the system font panel.
- Rider approved: manual submit is refused while over the word limit; the
  0:00 force-submit bypasses the check.

## Design

### 1. Read-only viewer for submitted work

- **Server:** one new SECURITY DEFINER function (migration), mirroring the
  house style of `list_class_work`:

  `get_my_submission(p_version_group_id uuid) -> table(title text,
  content_html text, word_count int, submitted_at timestamptz)` — the
  caller's NEWEST submitted (`submitted_at is not null`) essay across the
  group's sessions, found via the caller's `students` rows. Returns zero rows
  for anyone else's work by construction. `STABLE`, `SET search_path TO
  'public'`, EXECUTE granted to `authenticated`.
- **Client:** the Past row (and its Read-only chip) becomes a button. It opens
  a new `SubmittedWorkView` (new `StudentScreen` case `submitted`): back
  control, assignment title, "Submitted <date>", and the essay rendered
  read-only on the white page. The HTML-to-display conversion REUSES the
  rendering path ReturnedWorkView already uses for `content_html` (extracting
  it into a shared helper if it is currently private to that view). Loading
  and "couldn't load" states follow the house patterns. Graded rows keep
  their existing returned-work behavior, untouched.
- No kiosk, no timer, no editing surface anywhere in the view.

### 2. Caret fix

The exam editor's insertion indicator must read as a normal document caret:

- Height pinned to the current typing font's line height, not the paragraph's
  inflated line box (double spacing must not double the caret).
- The bounce/glow animation disabled.

Mechanism: configure the TextKit 2 `NSTextInsertionIndicator` that NSTextView
installs (clear its `automaticModeOptions` effects and constrain its frame
height), inside `WeftTextView` so the dev-gallery preview gets it too. The
implementer verifies the exact API surface at build time; the acceptance
criterion is the rendered result above.

### 3. Student formatting controls

- **Defaults:** `RichTextStyle.body` becomes Times New Roman 12 (fallback:
  serif system font), paragraph spacing double (lineHeightMultiple 2.0).
  Headings keep their current serif sizes. List styles adopt the document's
  active spacing.
- **Toolbar additions** (compact menus appended to the existing capsule):
  - Font: Times New Roman, Arial, Georgia, Helvetica Neue, Verdana,
    Courier New, Palatino, Baskerville, Trebuchet MS, Comic Sans MS,
    American Typewriter, Menlo.
  - Size: 8, 9, 10, 11, 12, 14, 16, 18, 24, 30, 36.
  - Color: text palette (ink, gray, red, orange, green, blue, purple, brown)
    and highlight palette (none, yellow, green, cyan, pink, orange).
  - Spacing: Single, 1.15, 1.5, Double.
- **Semantics (Google Docs):** with a selection, apply to the selection; with
  none, set the typing attributes. Family and size changes PRESERVE the run's
  bold/italic traits. Spacing applies per paragraph (paragraphRange of the
  selection). All edits are attribute-only (`shouldChangeText` with nil
  replacement is correct) except none change text.
- **Controller surface:** `setFontFamily(_:)`, `setFontSize(_:)`,
  `setTextColor(_:)`, `setHighlight(_:)` (nil clears), `setLineSpacing(_:)`
  on `RichTextController`, mirroring the existing toggleTrait structure.
- **HTML export:** inline runs gain a `<span style="...">` wrapper carrying
  only non-default properties: `font-family`, `color`, `background-color`
  (all three survive the Electron grading sanitizer), plus `font-size`
  (px) for future Swift-side rendering. Paragraph spacing exports as
  `line-height` on the block where non-default. KNOWN + ACCEPTED: the
  Electron grading view strips `font-size` and `line-height` (its
  SAFE_STYLE_PROPS whitelist), so size/spacing are native-fidelity only;
  family and colors render everywhere. The standalone HTML harness gains
  cases for styled runs and the span/default-suppression rules.

### 4. Teacher spell-check control

- **Server:** migration `alter table tests add column spellcheck_enabled
  boolean not null default true`. Electron never sends the column; the
  default covers it and every existing row.
- **Model:** `Assignment.spellcheckEnabled: Bool` with tolerant decode
  (missing key -> true). Sent by `createTest`, `updateTest`, and
  `createDraftTest` (drafts inherit the source's setting).
- **Teacher UI:** an "Allow spell check" toggle in the assignment editor,
  default on, saved with the assignment.
- **Student editor:** `RichTextEditor` gains `spellcheckEnabled: Bool = true`
  wired to `isContinuousSpellCheckingEnabled`; ExamView passes the staged
  assignment's value. `isAutomaticSpellingCorrectionEnabled` stays FALSE
  unconditionally (an exam editor must never rewrite words). The dev-gallery
  preview keeps spell check on.

### 5. Word-limit rider

`requestSubmit()` refuses when `wordLimit` is set and `wordCount > limit`,
showing "Over the word limit (X / Y words). Shorten your essay before
submitting." near the footer (transient, house error style). The expiry
force-submit path calls `submit()` directly and bypasses the check (the
deadline always wins). Electron parity.

## Error handling

- `get_my_submission` empty/throws: SubmittedWorkView shows a "couldn't load"
  state with retry; the row remains usable.
- Formatting on an empty document: typing attributes only (existing pattern).
- Spell-check column missing (migration not applied): tolerant decode keeps
  the toggle functional locally; saves include the column only after the
  migration (implementer verifies insert behavior against the live schema, as
  registerStudent's 23502 taught us).

## Out of scope

- Electron app changes.
- Teacher comments/annotations in the read-only viewer (returned-work wave
  owns feedback display).
- Alignment, indent, strikethrough, font panel, suggesting mode.
- Server-anchored clock, crash recovery, offline escape hatch (tracked from
  the previous wave's deferred list).

## Testing

- Migrations applied + smoke-checked (function result type; column default).
- HTML harness: extended cases pass (styled spans, default suppression).
- Build green per task.
- Live QA: open a Past row and read the submitted essay; caret is small and
  steady while typing at all spacings; set font/size/color/highlight/spacing
  and confirm they apply to selection and to new typing, survive submit, and
  the teacher's grading view shows family/colors; teacher disables spell
  check on one assignment and squiggles disappear for it only; over-limit
  manual submit is refused, expiry still force-submits.

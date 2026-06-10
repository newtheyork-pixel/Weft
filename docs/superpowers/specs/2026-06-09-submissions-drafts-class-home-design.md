# Student submissions, assignment drafts, class-first home

**Date:** 2026-06-09
**Status:** Approved
**Area:** Weft native macOS app (`~/Weft`) + one additive Supabase RPC change

## Why

1. **Submitted work bounces back into Active.** The Swift app never persists a
   submission: the exam autosave is a stub and submit writes nothing, so
   `list_class_work` keeps reporting the assignment as open and unsubmitted.
   The local move-out-of-Active patch is overwritten on the next server load.
2. **Even with persistence, the bucket can't be computed.** `list_class_work`
   returns `my_submitted_at` as the max across the whole version group and
   `active_session_id` as the latest open session, so the client cannot
   distinguish "I submitted the currently open draft" from "I submitted draft
   1 and draft 2 is now open."
3. **No teacher flow for drafts** (second/third/final) exists in the Swift app,
   although the DB model (`tests.version_group_id` / `version_number`) and the
   Electron reference implementation both exist.
4. **The student home reads as one flat list** under an odd "CLASS" chip; the
   user wants class-first navigation: pick a class, then see that class's
   Active / Past / Graded work.

## Decisions (user-confirmed)

- "New draft" clones the assignment and OPENS THE EDITOR first (Electron
  parity); the teacher tweaks the prompt, then launches normally.
- The teacher grading draft-compare toggle is a LATER phase.
- The additive `list_class_work` migration on the live project
  (`elrrvicxsguqstqciodn`) is approved.
- Class-first home: classes list -> class detail with the three buckets.
- No special "final draft" concept; the last draft is simply the last.

## Design

### 1. Server: `list_class_work` v2 (additive)

Add one column to the RETURNS TABLE: `my_active_submitted_at timestamptz` —
the caller's `essay_submissions.submitted_at` for the CURRENTLY OPEN session
of the group (null when there is no open session, no submission to it, or the
submission is unsubmitted). All existing columns and semantics unchanged.
Because the row type changes, the migration drops and recreates the function
in one transaction, preserving `SECURITY DEFINER`, `STABLE`,
`SET search_path TO 'public'`, and the EXECUTE grant to `authenticated`.
Electron ignores the extra column (verified: its `renderClassWork` reads named
fields only).

### 2. Swift: real submission lifecycle

The Electron contract, ported:

- **Real test staging.** `startWriting` stops staging a placeholder prompt.
  Before the exam begins, the app resolves the open session by code
  (`lookupSession`) and fetches the real test (`getTest`), staging the real
  title / prompt / word limit / time limit and the REAL question id (today the
  question id is the literal "q", which would corrupt submissions).
- **Student registration.** When the pre-exam checks pass and the student
  begins, upsert the `students` row (`onConflict: session_id,user_id`) with
  email, display name, status `joined`, and whatever proctoring facts the
  checks screen already computed (public IP, screen-capture/remote flags,
  display count, VM flag; fields it doesn't have are simply omitted). Keep
  `students.id` in AppState for the session.
- **Autosave becomes real.** ExamView's existing debounce calls a new
  AppState path that upserts `essay_submissions`
  (`onConflict: session_id,student_id,question_id`) with `content_html` from
  `controller.htmlSnapshot()` (the Electron-subset exporter), `word_count`,
  and a client-stamped `updated_at` (the table has no server trigger; this
  matches Electron). The returned row id is kept for the submit lock. The
  "Saving… / All saved" label now reflects the actual network result; a failed
  save shows "Save failed, retrying" and retries after 4 seconds.
- **Submit.** Final flush of the current content, then the SECURITY DEFINER
  `submit_essay(p_submission_id)` RPC stamps `submitted_at` and locks the row
  at the RLS layer, then `students.status` is set to `submitted`, then the
  class work reloads (the server now reports the truth). Submit is blocked on
  a failed final flush, exactly like Electron (the student must not lose work).
- **Signed-out preview** keeps today's mock behavior end to end.

### 3. Swift: bucketing that matches reality

`ClassWorkItem` gains `myActiveSubmittedAt`, `activeVersion`, and
`latestVersion` (all returned by the RPC today or after v2). New section rule:

- **Active**: `activeSessionId != nil && myActiveSubmittedAt == nil`
  (an open draft I have not submitted). Labeled "Draft N" when
  `activeVersion > 1`.
- **Graded**: not Active and `myReleasedAt != nil`.
- **Past**: not Active, submitted, not graded — including
  "submitted the open draft, session still open" (shows "Submitted <date>").

So one assignment flows Active (Draft 1) -> Past -> Active (Draft 2) -> Past
-> ... -> Graded. `finishExam` keeps its optimistic local move (instant
feedback) and the server reload now agrees with it.

### 4. Swift: class-first student home

`StudentClassHomeView` becomes two levels driven by `selectedClassId`:

- **Level 1 — "Your classes"**: one card per enrolled class (class name +
  an "N open" badge computed from that class's work), plus Join another class.
  Work rows for all classes load concurrently at home load (class counts are
  small).
- **Level 2 — class detail**: the class name as the header, the
  Active / Graded / Past sections beneath (existing section UI), and a back
  control to the classes list. Deep links (`weft://exam|join`) keep working:
  they select the class and land on level 2.
- Exactly one enrolled class: level 2 opens directly (back still reachable).

### 5. Swift: teacher drafts

- The Build tab's assignment list shows ONE row per version group (the latest
  version), tagged "v2" / "v3" when the group has more than one draft.
- A **New draft** action on an assignment row clones it into the next version:
  same `version_group_id` (or the source id when the group is null), `version_number = max(group) + 1`, a fresh essay-question id, the prompt /
  word limit / time limit / reference file ids and url ids carried over. The
  clone opens in the assignment editor for tweaking; launching it is the
  normal launch path (sessions are per-test, so nothing else changes).
- The launch picker also lists one entry per group (latest version).
- Editing a draft never mutates version fields (already true of `updateTest`).

## Error handling

- Registration failure at checks-pass: surfaced on the checks screen; the
  student does not enter the exam (Electron parity).
- Autosave failure: non-blocking, label + 4s retry; submit REQUIRES a final
  successful flush.
- `submit_essay` failure after a successful flush: best-effort like Electron
  (content is durably saved; the lock is retried on the next submit tap, and
  the student still exits to Done).
- RPC v2 missing (migration not applied): `myActiveSubmittedAt` decodes as
  nil and the bucket rule degrades to today's behavior, never crashes.

## Out of scope

- Teacher grading draft-compare toggle (deferred by decision).
- Electron app changes.
- Crash-recovery local copies of in-progress essays (Electron has them; a
  later wave).
- Webcam snapshot / status-pulse proctoring writes during the exam
  (`students.status` transitions beyond joined/submitted).
- Multi-question exams (the model supports one essay question today).

## Testing

- Migration: apply, then `execute_sql` smoke checks: function exists with the
  new column; a synthetic call as a test user returns sane rows.
- Build: clean `xcodebuild` per task.
- Live end-to-end (user, signed in): submit an essay -> the row leaves Active
  immediately and STAYS out after reload; teacher shares the grade -> Graded;
  teacher creates Draft 2 (editor opens, tweak, launch) -> the row returns to
  Active labeled "Draft 2"; submit Draft 2 -> Past again. Class list shows
  the class card with the open-count badge; single-class auto-entry works.
- Grading view: the submitted essay's HTML renders correctly for the teacher
  (exercises htmlSnapshot end to end).

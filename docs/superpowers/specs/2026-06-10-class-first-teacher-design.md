# Class-first teacher home

**Date:** 2026-06-10
**Status:** Approved (concept user-approved; spec pending user review)
**Area:** Weft native macOS app (`~/Weft`), teacher side only

## Why

The teacher home is organized by MODE (Build / Live tabs) instead of by CLASS.
The user's instinct, confirmed by a real defect: grading hangs off the LIVE
session, so the moment a session ends its essays become unreachable in the
app. Teachers think in classes ("DTC's essays"), not in global modes.

## Decisions (user-confirmed concept)

- Everything OPERATIONAL becomes class-first: click a class to see its live
  session, launch for it, its roster, and its session history with grading.
- The assignment LIBRARY stays global ("Library", today's Build content):
  assignments belong to the teacher and bind to a class only at launch.
- One live session at a time remains the invariant (the end-session sweep
  enforces it); other classes show a pointer to where the live session is.

## Design

### 1. Navigation

Mirrors the student home. `TeacherHomeView` becomes two levels driven by a new
`teacherSelectedClassId: String?` on AppState:

- **Level 1 — "Your classes"**: one card per teacher class (name, student
  count if cheap, a LIVE badge on the class with the open session, and an
  "N past sessions" hint), plus New class (existing action) and a segmented
  or secondary entry to **Library** (the global assignment list, unchanged
  contents: grouped rows, v-tags, New draft, Edit, Delete).
- **Level 2 — class detail** (back control + class name header):
  - **Live now** card when this class owns the open session: code, roster
    count, Review essays, End session (sweep). When ANOTHER class owns it: a
    quiet one-line pointer ("A session is live in <class>"). When none: the
    launch row.
  - **Launch**: assignment picker (the grouped global library) + Start live
    assignment, with `pickedClassId` implied by the class being viewed.
  - **Sessions**: history list for this class, newest first — title, vN tag,
    date, OPEN/closed chip, per-row "Review essays". This is what makes
    closed-session essays reachable again.
  - **Roster**: entry into the existing TeacherRosterView (unchanged).
- `TeacherTab` (build/live) is RETIRED. `TeacherScreen` keeps
  editor/grading/roster; home renders the two levels internally.

### 2. Grading by session (the defect fix)

`openGrading()`/`loadGrading()` currently read `liveSession`. They take an
explicit session instead: `openGrading(session: ExamSession, title: String)`
sets a `gradingSession` (new state) and loads submissions/grades/roster for
THAT session id. ReviewGradingView reads `gradingSession`; the live card and
every history row pass their own session. Sharing grades and the
first-release email flow are unchanged (they already key on submission ids).

### 3. Data

New `SupabaseManager.listClassSessions(classId:)`: sessions for the class
(any status), newest first, selecting `id,code,test_id,class_id,status,created_at`
(add `created_at` to `ExamSession` as an optional with a tolerant decode so
existing call sites are unaffected). Titles resolve client-side from the
already-loaded `assignments` (test_id -> title; fall back to "Assignment").
Per-class state on AppState: `classSessions: [ExamSession]`, loaded when a
class detail opens and after launch/end. Student counts per session are OUT
of scope for v1 (the grading screen shows the real roster).

### 4. Launch + live behavior

`launchSession` keeps its current guard ("End the current live session
first..."), now also naming the class that owns it. After a successful
launch, the class detail's Live card appears in place (no tab jump).
`loadTeacherHome` keeps restoring an open session; it also primes
`teacherSelectedClassId` to the live session's class when nothing is selected
yet, so relaunching the app lands the teacher next to their live exam.

### 5. Preview / signed-out

Mock classes render two cards; mock sessions populate one open + one closed
history row so the whole surface is demoable, following the established
mock-when-signed-out pattern.

## Error handling

- `listClassSessions` failure: house error banner in the class detail with
  retry; the rest of the detail stays usable.
- Grading load failures keep ReviewGradingView's existing behavior.

## Out of scope

- Per-class simultaneous live sessions (one-at-a-time stays).
- Session deletion/archiving; submission counts on history rows.
- Electron app changes; student side untouched.
- The grading draft-compare toggle (still parked).

## Testing

- Build green per task; signed-out preview shows both levels + history.
- Live QA: classes list shows the LIVE badge on the right class; launch from
  a class detail; end it (sweep) and the card clears for good; the session
  appears in history as closed and "Review essays" still opens its
  submissions (THE defect case); grade + share from a closed session works;
  Library still authors/edits/drafts; roster entry works; relaunching the
  app lands on the class with the live session.

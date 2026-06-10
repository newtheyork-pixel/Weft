# Submissions, Drafts, Class-First Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real student submission persistence (submitted work leaves Active and stays out), assignment drafts for teachers (v2/v3 clones launched like any assignment), and a class-first student home.

**Architecture:** One additive change to the `list_class_work` RPC adds the per-open-draft submission timestamp the bucket rule needs. The Swift app ports Electron's submission contract: a `students` row registered at checks-pass, debounced upserts into `essay_submissions` (the row IS the submission, content as the already-built Electron-subset HTML), and the `submit_essay` SECURITY DEFINER lock on submit. The student home becomes classes list -> class detail. Teacher drafts are test clones within a `version_group_id`, opened in the editor before launch.

**Tech Stack:** Swift 6 / SwiftUI (project `~/Weft`, branch `phase2-native-wiring`), Supabase PostgREST + RPCs via the existing `SupabaseManager` URLSession layer, one SQL migration on project `elrrvicxsguqstqciodn`.

**Spec:** `docs/superpowers/specs/2026-06-09-submissions-drafts-class-home-design.md`

**Canonical build command** (every task's gate; GUI QA is deferred to the human):

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build-a build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

Tasks are SEQUENTIAL (2 -> 3 -> 4 -> 5 share AppState.swift). Task 1 is executed
by the controller directly (MCP migration authorization is session-bound).

---

### Task 1: `list_class_work` v2 migration (CONTROLLER-EXECUTED, not a subagent)

**Target:** Supabase project `elrrvicxsguqstqciodn` via MCP `apply_migration`.

- [ ] **Step 1: Apply the migration** (name `list_class_work_v2_active_submission`):

```sql
-- list_class_work v2: adds my_active_submitted_at (the caller's submission
-- time for the CURRENTLY OPEN session of the group) so clients can tell
-- "I submitted this open draft" from "an older draft". Additive: existing
-- columns and semantics unchanged; new column appended last. The row type
-- changes, so drop + recreate in this one transaction.

drop function if exists public.list_class_work(uuid);

create function public.list_class_work(p_class_id uuid)
returns table(
  version_group_id uuid,
  title text,
  latest_version integer,
  n_versions integer,
  active_session_id uuid,
  active_code text,
  active_version integer,
  launched_at timestamptz,
  my_submitted_at timestamptz,
  my_released_at timestamptz,
  my_points numeric,
  my_points_possible numeric,
  last_activity_at timestamptz,
  my_active_submitted_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cls as (
    select s.id as session_id, s.code, s.status, s.created_at,
           coalesce(t.version_group_id, t.id) as vg,
           coalesce(t.version_number, 1)      as vnum,
           t.title
    from sessions s
    join tests t on t.id = s.test_id
    where s.class_id = p_class_id
      and exists (
        select 1 from class_enrollments e
        where e.class_id = p_class_id
          and e.user_id = auth.uid()
          and e.removed_at is null
      )
  ),
  mine as (
    select c.vg, c.session_id, es.submitted_at, g.released_at, g.points, g.points_possible
    from cls c
    join students st          on st.session_id = c.session_id and st.user_id = auth.uid()
    join essay_submissions es on es.session_id = c.session_id and es.student_id = st.id
    left join essay_grades g  on g.submission_id = es.id
  ),
  grouped as (
    select
      c.vg,
      (array_agg(c.title order by c.vnum desc))[1]      as title,
      max(c.vnum)                                       as latest_version,
      count(distinct c.vnum)::int                       as n_versions,
      (array_agg(c.session_id order by c.vnum desc, c.created_at desc)
         filter (where c.status = 'open'))[1]           as active_session_id,
      (array_agg(c.code order by c.vnum desc, c.created_at desc)
         filter (where c.status = 'open'))[1]           as active_code,
      (array_agg(c.vnum order by c.vnum desc, c.created_at desc)
         filter (where c.status = 'open'))[1]           as active_version,
      max(c.created_at)                                 as launched_at
    from cls c
    group by c.vg
  )
  select
    g.vg as version_group_id,
    g.title,
    g.latest_version,
    g.n_versions,
    g.active_session_id,
    g.active_code,
    g.active_version,
    g.launched_at,
    (select max(m.submitted_at) from mine m where m.vg = g.vg)  as my_submitted_at,
    (select max(m.released_at)  from mine m where m.vg = g.vg)  as my_released_at,
    (select m.points from mine m where m.vg = g.vg and m.released_at is not null
       order by m.released_at desc limit 1)                     as my_points,
    (select m.points_possible from mine m where m.vg = g.vg and m.released_at is not null
       order by m.released_at desc limit 1)                     as my_points_possible,
    greatest(
      g.launched_at,
      (select max(m.submitted_at) from mine m where m.vg = g.vg),
      (select max(m.released_at)  from mine m where m.vg = g.vg)
    )                                                           as last_activity_at,
    (select max(m.submitted_at) from mine m
       where m.session_id = g.active_session_id)                as my_active_submitted_at
  from grouped g
  order by last_activity_at desc nulls last;
$function$;

grant execute on function public.list_class_work(uuid) to authenticated;
```

- [ ] **Step 2: Smoke checks** (MCP `execute_sql`):

```sql
select count(*) as fn from pg_proc where proname = 'list_class_work';
-- expect fn = 1
select pg_get_function_result('public.list_class_work(uuid)'::regprocedure);
-- expect the RETURNS TABLE text ending in: my_active_submitted_at timestamp with time zone
select * from public.list_class_work('00000000-0000-0000-0000-000000000000'::uuid);
-- expect 0 rows, no error (auth.uid() is null here, so the enrollment gate
-- yields nothing — proves the SQL executes)
```

---

### Task 2: Data layer (Models + SupabaseManager)

**Files:**
- Modify: `Weft/Models.swift` (ClassWorkItem fields + section rule)
- Modify: `Weft/SupabaseManager.swift` (student lifecycle + draft clone methods)

- [ ] **Step 1: ClassWorkItem v2 fields + bucket rule** (`Weft/Models.swift`)

Add three stored properties after `myPointsPossible`:

```swift
    var myPoints: Double?
    var myPointsPossible: Double?
    /// My submission time for the CURRENTLY OPEN draft (list_class_work v2);
    /// nil when the RPC is v1, there is no open draft, or I haven't submitted it.
    var myActiveSubmittedAt: Date?
    /// Version number of the open draft / highest version in the group.
    var activeVersion: Int?
    var latestVersion: Int?
```

Extend `CodingKeys` with:

```swift
        case myActiveSubmittedAt = "my_active_submitted_at"
        case activeVersion = "active_version"
        case latestVersion = "latest_version"
```

Replace `var section: Section { ... }` with (note the OPTIONAL return — rows
with nothing of mine and no open draft disappear, Electron parity):

```swift
    /// Which bucket this assignment belongs in for the student class home.
    /// Active means "there is an open draft I have NOT submitted" — submitting
    /// the open draft drops the row to Past immediately, and it returns to
    /// Active when the teacher launches the next draft. nil = nothing for the
    /// student to act on (closed session, no submission of their own).
    var section: Section? {
        if activeSessionId != nil && myActiveSubmittedAt == nil { return .active }
        if myReleasedAt != nil { return .graded }
        if mySubmittedAt != nil { return .past }
        return nil
    }

    /// "Draft N" chip for the Active row; nil on the first draft.
    var draftLabel: String? {
        guard let v = activeVersion, v > 1 else { return nil }
        return "Draft \(v)"
    }
```

Update the three `static let` samples by appending `myActiveSubmittedAt: nil, activeVersion: nil, latestVersion: nil` to each memberwise init (the `.active` sample gets `activeVersion: 2` so the Draft chip is previewable, `latestVersion: 2`). `StudentClassHomeView`'s filters (`$0.section == .active`) compile unchanged against the optional.

- [ ] **Step 2: SupabaseManager student lifecycle methods**

Add a new MARK section after the existing grading methods. IMPORTANT
adaptation rule: `rpc`-style calls must use this file's EXISTING RPC helper
(the one `joinClass`/`resolveRole` use — read those first and match its
name/signature exactly); the generic `upsert(_:values:onConflict:returning:)`,
`update`, and `insert` helpers already exist.

```swift
    // MARK: - Student exam lifecycle (register / autosave / submit)

    struct StudentRowID: Decodable, Sendable { let id: String }

    /// Register (or refresh) the caller's `students` row for a session at
    /// checks-pass, carrying the proctoring facts the checks screen computed.
    /// Mirrors student.js runChecks (onConflict session_id,user_id).
    func registerStudent(sessionId: String, userId: String, email: String?,
                         name: String?, ip: String?, screenCapture: Bool,
                         remote: Bool, displayCount: Int?, isVM: Bool?) async throws -> String? {
        struct Payload: Encodable {
            let session_id: String; let user_id: String
            let email: String?; let name: String?
            let ip: String?
            let remote_session: Bool; let screen_capture: Bool
            let display_count: Int?; let is_vm: Bool?
            let status: String
        }
        let rows: [StudentRowID] = try await upsert("students",
            values: Payload(session_id: sessionId, user_id: userId, email: email,
                            name: name, ip: ip, remote_session: remote,
                            screen_capture: screenCapture, display_count: displayCount,
                            is_vm: isVM, status: "joined"),
            onConflict: "session_id,user_id")
        return rows.first?.id
    }

    /// Autosave/flush one essay (upsert: the row IS the submission). Returns
    /// the row id for the submit lock. updated_at is client-stamped: the table
    /// has no server now() trigger (Electron does the same).
    func upsertEssaySubmission(sessionId: String, studentId: String, questionId: String,
                               contentHTML: String, wordCount: Int) async throws -> String? {
        struct Payload: Encodable {
            let session_id: String; let student_id: String; let question_id: String
            let content_html: String; let word_count: Int; let updated_at: String
        }
        let rows: [StudentRowID] = try await upsert("essay_submissions",
            values: Payload(session_id: sessionId, student_id: studentId,
                            question_id: questionId, content_html: contentHTML,
                            word_count: wordCount, updated_at: Self.nowISO()),
            onConflict: "session_id,student_id,question_id")
        return rows.first?.id
    }

    /// Lock a submitted essay at the DB layer (SECURITY DEFINER submit_essay:
    /// stamps submitted_at; RLS then refuses student edits). Best-effort.
    func submitEssay(submissionId: String) async -> Bool {
        // Use the file's existing RPC helper here (same one joinClass uses).
        do { _ = try await rpcRaw("submit_essay", body: ["p_submission_id": submissionId]); return true }
        catch { return false }
    }

    /// students.status transition (joined -> submitted). Best-effort.
    func updateStudentStatus(id: String, status: String) async {
        struct Payload: Encodable { let status: String }
        let _: [StudentRowID]? = try? await update("students", values: Payload(status: status),
            query: [URLQueryItem(name: "id", value: "eq.\(id)")], returning: false)
    }
```

(`rpcRaw` is a stand-in name: replace it with the actual existing RPC helper.
If the existing helper decodes a typed result, add a thin Data-returning
variant next to it rather than forcing a decode of `submit_essay`'s scalar.)

- [ ] **Step 3: SupabaseManager draft clone**

Add next to `createTest`:

```swift
    /// Clone `source` into the next draft of its version group: same group id,
    /// version_number = nextVersion, a FRESH essay-question id (each draft's
    /// submissions key on their own question), prompt/limits/files/links
    /// carried over. Launching the clone is the normal launch path.
    func createDraftTest(from source: Assignment, teacherUserId: String,
                         nextVersion: Int) async throws -> Assignment? {
        struct Payload: Encodable {
            let teacher_user_id: String; let title: String
            let questions: [Question]; let time_limit_minutes: Int?
            let version_group_id: String; let version_number: Int
        }
        var questions = source.questions
        if let q = questions.first {
            questions[0] = Question(id: "q-\(UUID().uuidString.prefix(8))", kind: q.kind,
                                    prompt: q.prompt, wordLimit: q.wordLimit,
                                    fileIds: q.fileIds, urlIds: q.urlIds)
        }
        let rows: [Assignment] = try await insert("tests", values: Payload(
            teacher_user_id: teacherUserId, title: source.title, questions: questions,
            time_limit_minutes: source.timeLimitMinutes,
            version_group_id: source.versionGroupId, version_number: nextVersion))
        return rows.first
    }
```

(Check `Question`'s memberwise init parameter order in Models.swift and match
it; `AppState.saveAssignment` shows the call shape. Check `insert`'s actual
signature in this file and match.)

- [ ] **Step 4: Build** (canonical command). Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd ~/Weft && git add Weft/Models.swift Weft/SupabaseManager.swift && git commit -m "Data layer: student submission lifecycle, draft clone, class-work v2 fields"
```

---

### Task 3: Student lifecycle wiring (AppState + ExamView + StudentChecksView)

**Files:**
- Modify: `Weft/AppState.swift`
- Modify: `Weft/ExamView.swift`
- Modify: `Weft/StudentChecksView.swift`

- [ ] **Step 1: AppState live-attempt state + methods**

Add near the other student-navigation state:

```swift
    // MARK: Live exam attempt (set during checks -> exam -> submit)
    /// The students-row id for the attempt in progress (set at checks-pass).
    var activeStudentId: String?
    /// The open session being written in (resolved from the work row's code).
    var activeExamSession: ExamSession?
    /// The essay_submissions row id captured from the first durable save.
    var activeSubmissionId: String?
```

In `signOut()`, alongside the other resets add:

```swift
        activeStudentId = nil; activeExamSession = nil; activeSubmissionId = nil
```

In `startWriting(_:)`, replace the existing

```swift
        if signedIn, let code = item.activeCode {
            Task { await loadExamMaterials(code: code) }
        }
```

with

```swift
        activeExamSession = nil
        activeStudentId = nil
        activeSubmissionId = nil
        if signedIn, let code = item.activeCode {
            Task {
                await resolveActiveExam(code: code)
                await loadExamMaterials(code: code)
            }
        }
```

Add the new methods after `loadExamMaterials`:

```swift
    /// Resolve the open session + REAL test for `code`, replacing the staged
    /// placeholder. Submissions must carry the real question id, so the exam
    /// cannot meaningfully save until this lands (autosave guards on it).
    func resolveActiveExam(code: String) async {
        guard signedIn else { return }
        do {
            guard let session = try await supabase.lookupSession(code: code),
                  session.status == "open" else {
                errorMessage = "This assignment isn't open anymore."
                return
            }
            activeExamSession = session
            if let testId = session.testId,
               let test = try await supabase.getTest(id: testId) {
                activeAssignment = test
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Begin button on the checks screen: register the students row (the
    /// proctoring contract) and only then enter the locked exam. False (with
    /// errorMessage set) means stay on the checks screen.
    func beginExam(screenCapture: Bool, remote: Bool, displayCount: Int?,
                   isVM: Bool?, ip: String?) async -> Bool {
        guard signedIn else { enterExam(); return true }   // preview path
        guard let session = activeExamSession else {
            errorMessage = "Couldn't reach this assignment's session. Go back and try again."
            return false
        }
        do {
            guard let sid = try await supabase.registerStudent(
                sessionId: session.id, userId: userId,
                email: email.isEmpty ? nil : email,
                name: displayName.isEmpty ? nil : displayName,
                ip: ip, screenCapture: screenCapture, remote: remote,
                displayCount: displayCount, isVM: isVM)
            else {
                errorMessage = "Could not register for this exam."
                return false
            }
            activeStudentId = sid
            activeSubmissionId = nil
            errorMessage = nil
            enterExam()
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// One durable save of the essay (debounced upstream). True = saved.
    func autosaveEssay(html: String, wordCount: Int) async -> Bool {
        guard signedIn else { return true }   // preview: nothing to persist
        guard let session = activeExamSession,
              let studentId = activeStudentId,
              let questionId = activeAssignment?.questions.first?.id else { return false }
        do {
            if let id = try await supabase.upsertEssaySubmission(
                sessionId: session.id, studentId: studentId, questionId: questionId,
                contentHTML: html, wordCount: wordCount) {
                activeSubmissionId = id
            }
            return true
        } catch {
            return false
        }
    }

    /// Final flush + DB lock + status. False = the flush failed and the
    /// caller must NOT exit the exam (the work would be lost). Does NOT
    /// route; the exam view orchestrates kiosk exit + finishExam on success.
    func submitExam(html: String, wordCount: Int) async -> Bool {
        if signedIn {
            guard await autosaveEssay(html: html, wordCount: wordCount) else { return false }
            if let submissionId = activeSubmissionId {
                _ = await supabase.submitEssay(submissionId: submissionId)   // best-effort lock
            }
            if let studentId = activeStudentId {
                await supabase.updateStudentStatus(id: studentId, status: "submitted")
            }
        }
        activeStudentId = nil
        activeSubmissionId = nil
        activeExamSession = nil
        return true
    }
```

Also in `finishExam()`'s optimistic local patch, additionally stamp
`classWork[idx].myActiveSubmittedAt = Date()` next to the existing
`mySubmittedAt` stamp (keeps the local bucket rule consistent pre-reload).

- [ ] **Step 2: ExamView — real autosave with retry + gated submit**

In `ExamRuntime`, extend the save state:

```swift
    enum SaveState: Equatable { case saving, saved, failed }
```

Replace `scheduleSave()` with:

```swift
    /// Debounce (0.8s) then persist. A failed save retries every 4s until a
    /// newer edit reschedules it (Electron parity); the label tells the truth.
    private func scheduleSave() {
        runtime.saveState = .saving
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await persistNow()
        }
    }

    private func persistNow() async {
        let ok = await app.autosaveEssay(html: controller.htmlSnapshot(),
                                         wordCount: controller.wordCount)
        guard !Task.isCancelled else { return }
        if ok {
            runtime.saveState = .saved
        } else {
            runtime.saveState = .failed
            saveDebounce = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await persistNow()
            }
        }
    }
```

Replace `submit()` with:

```swift
    /// Submit = final flush (must succeed) -> DB lock -> leave the exam. A
    /// failed flush keeps the student in the exam with the failed-save label;
    /// their work is intact and Submit can be pressed again.
    private func submit() {
        Task {
            guard await app.submitExam(html: controller.htmlSnapshot(),
                                       wordCount: controller.wordCount) else {
                runtime.saveState = .failed
                return
            }
            endExam()
            app.finishExam()
        }
    }
```

In `saveStateView`, handle the new case (match the existing two visually):

```swift
            if runtime.saveState == .saving {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Saving…")
            } else if runtime.saveState == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text("Save failed, retrying…")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                Text("All saved")
            }
```

- [ ] **Step 3: StudentChecksView — register before entering**

Read the view first. It runs `ProctoringEngine().runChecks(teacherIP: nil)`
into a `report` around line 58 and calls `app.enterExam()` around line 210.
Replace that call so the begin action awaits registration, mapping whatever
fields the report type actually exposes (read ProctoringEngine.swift; the
known ones are screen-capture and remote detection — pass `nil` for
display count / VM / ip if the checks view does not already have them; do
NOT add new proctoring probes):

```swift
                Task {
                    _ = await app.beginExam(
                        screenCapture: report?.screenCapture ?? false,
                        remote: report?.remote ?? false,
                        displayCount: nil,   // map from report if the field exists
                        isVM: nil,           // map from report if the field exists
                        ip: nil)             // map if the view already fetched it
                }
```

A `false` return leaves the student on the checks screen; surface
`app.errorMessage` there if the view does not already render it (it renders
error banners on other screens via the same property — follow that pattern).
The button should show a brief busy state while awaiting (disable + spinner,
matching the sign-in button's busy pattern in SignInView).

- [ ] **Step 4: Build** (canonical command). Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd ~/Weft && git add Weft/AppState.swift Weft/ExamView.swift Weft/StudentChecksView.swift && git commit -m "Student lifecycle: register at checks, real autosave + locked submit"
```

---

### Task 4: Class-first student home

**Files:**
- Modify: `Weft/StudentClassHomeView.swift` (two-level restructure)
- Modify: `Weft/AppState.swift` (open counts + selection behavior)

- [ ] **Step 1: AppState — open counts + no forced selection**

Add near the student data properties:

```swift
    /// Active-assignment count per class id (the classes-list badges).
    var classOpenCounts: [String: Int] = [:]
```

In `loadStudentHome()`, replace the auto-selection block

```swift
            if selectedClassId == nil || !classes.contains(where: { $0.id == selectedClassId }) {
                selectedClassId = classes.first?.id
            }
            await loadClassWork()
```

with

```swift
            // Class-first home: only auto-enter when there is exactly one
            // class; otherwise land on the classes list (selectedClassId nil).
            if let selected = selectedClassId,
               !classes.contains(where: { $0.id == selected }) {
                selectedClassId = nil
            }
            if selectedClassId == nil && classes.count == 1 {
                selectedClassId = classes.first?.id
            }
            await loadClassWork()
            await loadOpenCounts()
```

Add after `loadClassWork()`:

```swift
    /// Refresh the per-class Active counts for the classes list. Classes are
    /// few; one small RPC per class, concurrently.
    func loadOpenCounts() async {
        guard signedIn else { return }
        let classes = enrolledClasses
        await withTaskGroup(of: (String, Int).self) { group in
            for c in classes {
                group.addTask {
                    let work: [ClassWorkItem] =
                        (try? await SupabaseManager.shared.listClassWork(classId: c.id)) ?? []
                    return (c.id, work.filter { $0.section == .active }.count)
                }
            }
            for await (id, n) in group { classOpenCounts[id] = n }
        }
    }
```

(Adapt the call to this file's actual class-work fetch method name — it is the
one `loadClassWork()` uses; read it first.) Add a back path:

```swift
    /// Back from a class detail to the classes list.
    func leaveClass() {
        selectedClassId = nil
        classWork = []
        Task { await loadOpenCounts() }
    }
```

In `selectClass(_:)`, no change (selecting loads work).

- [ ] **Step 2: StudentClassHomeView — two levels**

Restructure the body: when `app.selectedClassId == nil`, render the classes
level; otherwise the class detail. Keep the existing `sectionCard`, row
builders, error banner, and `joinAnother` link.

Classes level (replaces the old `classPicker` chip row):

```swift
    private var classesLevel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Kicker(text: "Your classes")
            ForEach(app.enrolledClasses) { c in
                Button { app.selectClass(c.id) } label: {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                                .font(Theme.sans(15, .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(openBadge(for: c.id))
                                .font(Theme.sans(12.5))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.muted2)
                    }
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .weftGlass(Theme.Radius.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
    }

    private func openBadge(for classId: String) -> String {
        let n = app.classOpenCounts[classId] ?? 0
        if n == 0 { return "Nothing due right now" }
        return n == 1 ? "1 open assignment" : "\(n) open assignments"
    }
```

Class detail level: a back control + class-name header above the existing
sections:

```swift
    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button { app.leaveClass() } label: {
                Label("Your classes", systemImage: "chevron.left")
                    .font(Theme.sans(13, .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .pointerStyle(.link)
            Text(app.enrolledClasses.first(where: { $0.id == app.selectedClassId })?.name ?? "Class")
                .font(Theme.serif(24, .semibold))
                .foregroundStyle(Theme.inkSoft)
        }
    }
```

Body composition (`intro` stays at the top in both levels; the empty state for
no classes at all keeps today's copy):

```swift
                    intro
                    if let error = app.errorMessage { errorBanner(error) }
                    if app.selectedClassId == nil {
                        if app.enrolledClasses.isEmpty {
                            emptyState
                        } else {
                            classesLevel
                        }
                    } else {
                        detailHeader
                        if !active.isEmpty { sectionCard("Active", active) }
                        if !graded.isEmpty { sectionCard("Graded", graded) }
                        if !past.isEmpty { sectionCard("Past", past) }
                        if active.isEmpty && graded.isEmpty && past.isEmpty { detailEmpty }
                    }
                    joinAnother
```

with a small detail-level empty state:

```swift
    private var detailEmpty: some View {
        Text("No assignments in this class yet.")
            .font(Theme.sans(13))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, Theme.Space.md)
    }
```

Active rows: where the row renders its status line ("Open now"), append the
draft chip when present:

```swift
        if let draft = item.draftLabel {
            Text(draft)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accent.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.accent)
        }
```

(Place it in the row's HStack next to the title; read the existing row builder
and match its layout. The old `classPicker` chip row is deleted.) Deep links
keep working: `handleDeepLink` selects a class via `selectedClassId` already,
which now lands on the detail level by construction.

- [ ] **Step 3: Build** (canonical command). Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd ~/Weft && git add Weft/StudentClassHomeView.swift Weft/AppState.swift && git commit -m "Student home: class-first navigation with open-count badges + draft chips"
```

---

### Task 5: Teacher drafts

**Files:**
- Modify: `Weft/AppState.swift` (grouping + createNextDraft)
- Modify: `Weft/TeacherHomeView.swift` (one row per group, version tag, New draft action, grouped launch picker)

- [ ] **Step 1: AppState grouping + clone action**

Add near the teacher state:

```swift
    /// One row per assignment family: the LATEST draft of each version group.
    /// The Build list and the launch picker both present these.
    var groupedAssignments: [Assignment] {
        Dictionary(grouping: assignments, by: \.versionGroupId)
            .values
            .compactMap { $0.max(by: { $0.versionNumber < $1.versionNumber }) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
```

Add after `deleteAssignment`:

```swift
    /// Clone `source` into the next draft of its group and open the editor on
    /// it (the teacher tweaks the prompt, then launches it normally).
    func createNextDraft(of source: Assignment) async {
        errorMessage = nil
        let next = (assignments
            .filter { $0.versionGroupId == source.versionGroupId }
            .map(\.versionNumber).max() ?? source.versionNumber) + 1
        if !signedIn {
            // Preview: local clone so the flow is demoable without a backend.
            let clone = Assignment(id: "local-\(UUID().uuidString.prefix(6))",
                                   title: source.title,
                                   versionGroupId: source.versionGroupId,
                                   versionNumber: next,
                                   questions: source.questions,
                                   timeLimitMinutes: source.timeLimitMinutes)
            assignments.append(clone)
            openEditAssignment(clone)
            return
        }
        do {
            guard let clone = try await supabase.createDraftTest(
                from: source, teacherUserId: userId, nextVersion: next) else {
                errorMessage = "Could not create the next draft."
                return
            }
            await loadTeacherHome()
            openEditAssignment(clone)
        } catch {
            errorMessage = describe(error)
        }
    }
```

In `loadTeacherHome()`, the default `pickedAssignmentId` should come from the
grouped list: replace `assignments.first?.id` with `groupedAssignments.first?.id`
in that selection-priming block (and the `contains` check against
`groupedAssignments`).

- [ ] **Step 2: TeacherHomeView wiring**

Read the view first; then:

a) Wherever the Build tab iterates `app.assignments` for the assignment rows,
iterate `app.groupedAssignments` instead.

b) In the assignment row, next to the title add a version tag when the row is
a later draft:

```swift
            if assignment.versionNumber > 1 {
                Text("v\(assignment.versionNumber)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
```

c) Add a "New draft" action alongside the row's existing Edit/Delete actions
(match their control style exactly — if they are borderless icon buttons, use
one; if a context menu, add a menu item):

```swift
            Button {
                Task { await app.createNextDraft(of: assignment) }
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .help("New draft (v\(assignment.versionNumber + 1)): copy this assignment, tweak, launch")
```

d) Wherever the launch picker iterates `app.assignments`, iterate
`app.groupedAssignments`, and suffix later drafts in the option label:
`assignment.versionNumber > 1 ? "\(assignment.title) · v\(assignment.versionNumber)" : assignment.title`.

- [ ] **Step 3: Build** (canonical command). Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd ~/Weft && git add Weft/AppState.swift Weft/TeacherHomeView.swift && git commit -m "Teacher drafts: grouped assignment rows, New draft clone into editor"
```

---

### Task 6: Integration pass

**Files:** none new — verification only.

- [ ] **Step 1: Full clean build**

```bash
cd ~/Weft && xcodebuild -project Weft.xcodeproj -scheme Weft -configuration Debug -derivedDataPath build-a clean build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Final whole-range code review** (controller dispatches the
final reviewer per subagent-driven-development; range starts at the commit
after `751322a`).

- [ ] **Step 3: Live QA handoff (human, signed in — nothing headless covers this):**

1. Open the app as a student in 2+ classes: classes list with open-count
   badges; click in/out; single-class account lands directly in the class.
2. Start the assignment: checks screen registers (teacher roster shows the
   student as joined), exam shows the REAL prompt.
3. Type; watch "Saving… / All saved"; kill the network briefly: label says
   "Save failed, retrying…" and recovers.
4. Submit: row leaves Active immediately, STAYS out after relaunch
   (server-truth test — the original bug).
5. Teacher: grade + share -> row turns Graded for the student.
6. Teacher: New draft on the assignment -> editor opens pre-filled -> tweak ->
   launch -> student's row returns to Active with the "Draft 2" chip; submit
   draft 2 -> Past again. Build list shows one row tagged v2.
7. Teacher grading view renders the submitted essay's HTML (bold/lists etc.).

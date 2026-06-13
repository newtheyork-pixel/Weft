//
//  AppState.swift
//  Weft — observable app-wide state: who's signed in, which role/screen is up,
//  and the data the UI renders. Real Supabase loads populate it once a session
//  exists; until then (dev gallery / unsigned build) the bundled mock samples
//  keep every screen populated. `useMockData` is the switch.
//

import SwiftUI
import Observation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class AppState {
    enum Route: Equatable { case signIn, teacher, student }

    /// Sub-navigation inside the student role (the native analogue of the
    /// Electron #stage-* swap). RootView → StudentFlowView reads this.
    enum StudentScreen: Equatable { case home, join, checks, exam, done, returned, submitted }

    // MARK: Session / identity
    var route: Route = .signIn
    var role: UserRole?
    /// The account's role as resolved at sign-in (Teachers sheet / server).
    /// Unlike `role` (the view currently in use), this never changes when a
    /// teacher steps into the student view, so it gates the view chooser.
    var accountRole: UserRole?
    var displayName: String = ""
    var email: String = ""
    var userId: String = ""
    var isAdmin: Bool = false
    var signedIn: Bool = false

    /// Render the bundled mock samples until a real session loads. Flipped false
    /// after a successful sign-in + first load so the screens show live data.
    var useMockData: Bool = true

    // MARK: Live exam attempt (set during checks -> exam -> submit)
    /// The students-row id for the attempt in progress (set at checks-pass).
    var activeStudentId: String?
    /// The open session being written in (resolved from the work row's code).
    var activeExamSession: ExamSession?
    /// The essay_submissions row id captured from the first durable save.
    var activeSubmissionId: String?

    // MARK: Student in-role navigation
    var studentScreen: StudentScreen = .home
    /// A class join code carried in from a `weft://join?code=...` deep link, so
    /// the join screen can pre-fill it. Cleared once consumed.
    var prefilledJoinCode: String?
    /// A session code carried in from a `weft://exam?code=...` deep link; the
    /// student home tries to auto-open the matching live assignment.
    var pendingExamCode: String?
    /// A deep link that arrived before sign-in; resolved once a session exists.
    private var pendingDeepLink: URL?
    /// Reentrancy guard so overlapping callers (sign-in, deep link, the home
    /// view's own .task) don't run duplicate concurrent student-home loads.
    private var studentHomeInFlight = false
    /// Reentrancy guard (mirrors studentHomeInFlight): the home .task refires
    /// on every return from editor/roster/grading and overlaps with enterTeacher.
    private var teacherHomeInFlight = false
    /// Reentrancy guard: a double-clicked New draft would mint two clones with
    /// the same version number, one of them unreachable in the grouped UI.
    private var draftCloneInFlight = false
    /// Reentrancy guard: launchSession suspends twice (public IP, server
    /// insert) before liveSession is assigned, so a double-clicked Start
    /// could pass the `liveSession == nil` guard twice and mint two open
    /// server sessions — breaking the one-live-session invariant.
    private var launchInFlight = false
    /// True only after a *successful* grading load, so a first-release email is
    /// never sent off a stale/failed grades cache (which would duplicate).
    private var gradesFresh = false

    // MARK: Data (mock defaults; replaced by real loads when signed in)
    var enrolledClasses: [ClassRoom] = [.sample, .sample2]
    var classWork: [ClassWorkItem] = ClassWorkItem.sampleList
    var assignments: [Assignment] = [.sample, .sample2]
    var teacherClasses: [ClassRoom] = [.sample, .sample2]
    var roster: [RosterStudent] = RosterStudent.sample
    var returnedWork: [ReturnedWorkItem] = []

    /// The Past-row essay being viewed read-only (nil = loading / none yet).
    var submittedEssay: SubmittedEssay?
    var submittedEssayError: String?
    /// The assignment family being viewed; retained so "Try again" can retry
    /// without the original ClassWorkItem being in scope.
    var submittedVersionGroupId: String?

    var selectedClassId: String?
    /// Active-assignment count per class id (the classes-list badges).
    var classOpenCounts: [String: Int] = [ClassRoom.sample.id: 1, ClassRoom.sample2.id: 0]
    /// The assignment a student is about to take / is taking (drives ExamView).
    var activeAssignment: Assignment?

    // MARK: Student outlines (per Active row)
    /// `tests.outline_allowed` per ACTIVE SESSION id. ClassWorkItem doesn't
    /// carry the flag, so it's resolved per active row (lookupSession + getTest).
    /// Keyed by the session — not the assignment family — because the family is
    /// too coarse: a relaunch is a new session, possibly of a new draft with the
    /// flag flipped, and a family-keyed cache would serve the old draft's answer
    /// for the rest of the run. Repeat home reloads of the same session still
    /// hit the cache, so they never refetch in a loop.
    /// Preview seeds the sample active session so the affordance demos signed out.
    var outlineAllowedBySession: [String: Bool] = [OutlineUpload.sample.sessionId: true]
    /// The signed-in student's own outline per ACTIVE session id (at most one
    /// each — outline_uploads is unique on session_id+user_id). Preview seeds
    /// the sample outline on the sample active session.
    var myOutlines: [String: OutlineUpload] = [OutlineUpload.sample.sessionId: .sample]
    /// Sessions whose outline is server-locked (the student's `students` row
    /// exists — they began writing — so RLS refuses outline writes). Local
    /// begins mark this eagerly; a begin on another device surfaces here the
    /// moment the server refuses an outline write.
    var outlineLockedSessionIds: Set<String> = []
    /// Reentrancy guard (mirrors draftCloneInFlight): a double-clicked
    /// Replace/Remove must not race two storage writes for the same row.
    var outlineBusy = false
    /// Reference materials for the active exam (sample defaults; replaced by the
    /// real test_files / test_urls when an active session resolves).
    var examFiles: [ExamFile] = ExamFile.sample
    var examLinks: [ExamLink] = ExamLink.sample

    // MARK: Teacher in-role navigation + state
    enum TeacherScreen: Equatable { case home, editor, grading, roster }
    var teacherScreen: TeacherScreen = .home
    /// Class-first navigation: nil = "Your classes" level (1), non-nil = that
    /// class's detail (level 2). Mirrors the student home's selectedClassId;
    /// AppState-held so roster/grading round-trips return to the same class.
    var teacherSelectedClassId: String?
    /// The selected class's session history, newest first. nil = not loaded
    /// yet (the UI claims nothing it hasn't confirmed), [] = confirmed empty.
    var classSessions: [ExamSession]?
    /// Signed-out preview history backing store (ALL classes; loadClassSessions
    /// filters per class). launchSession/endSession mutate it, so a demo
    /// session that was launched and ended survives leaving and re-entering
    /// the class instead of vanishing on the next rebuild.
    private var previewSessions: [ExamSession] = ExamSession.sampleHistory
    /// The assignment being edited; nil means a brand-new assignment.
    var editingAssignment: Assignment?
    /// The currently live session (after Start live assignment). Signed out
    /// it seeds the open demo session (matching ExamSession.sampleHistory's
    /// Open row) so the LIVE chip / monitor / Open chip render at rest;
    /// dropMockData clears it the moment a real session begins.
    var liveSession: ExamSession? = ExamSession.sampleOpen
    var pickedAssignmentId: String?

    /// One row per assignment family: the LATEST draft of each version group.
    /// The Build list and the launch picker both present these.
    var groupedAssignments: [Assignment] {
        Dictionary(grouping: assignments, by: \.versionGroupId)
            .values
            .compactMap { $0.max(by: { $0.versionNumber < $1.versionNumber }) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    // Class roster (for the Roster screen)
    var classRoster: [ClassEnrollment] = []
    var rosterClassId: String?
    var rosterClassName: String = ""
    // Grading
    var gradingSubmissions: [TeacherSubmission] = []
    var grades: [String: EssayGrade] = [:]   // submissionId -> grade
    var gradingTitle: String = ""
    /// THE grading key. Grading is always for this EXPLICIT session: live,
    /// just-closed, or weeks old. NEVER read liveSession in a grading path;
    /// that coupling is the defect that made closed sessions unreachable.
    var gradingSession: ExamSession?
    /// Student names for the session being GRADED. Separate from `roster`
    /// (the live proctoring monitor) so grading an old session can never
    /// clobber the monitor of a session that is live right now.
    var gradingRoster: [RosterStudent] = []
    /// Every outline uploaded for the session being graded (keyed by user_id;
    /// gradingRoster bridges that to a submission's students-row id).
    var gradingOutlines: [OutlineUpload] = []
    /// Transient status for the roster "Invite students" action.
    var inviteStatus: String?
    // School-approved websites (from the published Google Sheet), for the editor.
    var approvedSites: [ApprovedSite] = []
    var approvedSitesLoading = false

    // MARK: Async UI state
    var isLoading = false
    var errorMessage: String?
    /// True only while a sign-in attempt is waiting on the browser redirect.
    /// Cancel is meaningful only in this window; once the `weft://auth-callback`
    /// deep link arrives the parked continuation is resumed and Cancel can no
    /// longer abort the token-exchange tail, so the affordance is hidden.
    var awaitingBrowserCallback = false

    private var supabase: SupabaseManager { .shared }

    // MARK: - Routing (used by the signed-in view chooser; the no-auth paths
    //         keep mocks for the dev gallery / screen overrides)

    /// Teachers and admins may use either view; students may not.
    var canChooseView: Bool { signedIn && (accountRole == .teacher || accountRole == .admin) }

    /// Return a signed-in teacher/admin to the view chooser. The chooser lives
    /// on the sign-in route; once signed in it shows only the two views.
    func switchView() {
        guard canChooseView else { return }
        errorMessage = nil
        route = .signIn
    }

    func enterTeacher() {
        role = .teacher
        if displayName.isEmpty { displayName = "Thomas Seirer" }
        teacherScreen = .home
        route = .teacher
        if signedIn { resolvePendingDeepLink(); Task { await loadTeacherHome() } }
    }

    func enterStudent() {
        role = .student
        if displayName.isEmpty { displayName = "Ava Chen" }
        studentScreen = .home
        route = .student
        if signedIn { resolvePendingDeepLink(); Task { await loadStudentHome() } }
    }

    func signOut() {
        supabase.signOut()
        role = nil
        accountRole = nil
        signedIn = false
        isAdmin = false
        useMockData = true
        userId = ""; email = ""; displayName = ""
        errorMessage = nil
        awaitingBrowserCallback = false
        // Restore the not-signed-in (mock) state so no account's data leaks into
        // the next sign-in, and the dev/sign-in screens demo with samples again.
        selectedClassId = nil
        activeAssignment = nil
        studentScreen = .home
        pendingDeepLink = nil; pendingExamCode = nil; prefilledJoinCode = nil
        activeStudentId = nil; activeExamSession = nil; activeSubmissionId = nil
        gradesFresh = false
        enrolledClasses = [.sample, .sample2]
        classWork = ClassWorkItem.sampleList
        classOpenCounts = [ClassRoom.sample.id: 1, ClassRoom.sample2.id: 0]
        returnedWork = []
        submittedEssay = nil; submittedEssayError = nil; submittedVersionGroupId = nil
        outlineAllowedBySession = [OutlineUpload.sample.sessionId: true]
        myOutlines = [OutlineUpload.sample.sessionId: .sample]
        outlineLockedSessionIds = []
        outlineBusy = false
        // Exam reference materials back to the preview samples.
        examFiles = ExamFile.sample
        examLinks = ExamLink.sample
        // Teacher state back to defaults.
        teacherScreen = .home
        editingAssignment = nil
        liveSession = ExamSession.sampleOpen
        previewSessions = ExamSession.sampleHistory
        pickedAssignmentId = nil
        teacherSelectedClassId = nil
        classSessions = nil
        gradingSession = nil
        gradingRoster = []
        gradingOutlines = []
        gradingTitle = ""
        classRoster = []; rosterClassId = nil; rosterClassName = ""
        gradingSubmissions = []; grades = [:]
        teacherClasses = [.sample, .sample2]
        assignments = [.sample, .sample2]
        roster = RosterStudent.sample
        route = .signIn
    }

    /// Drop the bundled mock data the moment a real session begins, so a
    /// signed-in user with no assignments sees the empty state — not fake rows —
    /// and stale data from a previous account never shows.
    private func dropMockData() {
        enrolledClasses = []
        classWork = []
        classOpenCounts = [:]
        returnedWork = []
        submittedEssay = nil; submittedEssayError = nil; submittedVersionGroupId = nil
        outlineAllowedBySession = [:]
        myOutlines = [:]
        outlineLockedSessionIds = []
        // No fake reference files/links for a signed-in exam (they would also
        // leak their hosts into the locked browser's approved-host whitelist).
        examFiles = []
        examLinks = []
        selectedClassId = nil
        activeAssignment = nil
        roster = []
        teacherClasses = []
        assignments = []
        pickedAssignmentId = nil
        liveSession = nil
        teacherSelectedClassId = nil
        classSessions = nil
        gradingSession = nil
        gradingRoster = []
        gradingOutlines = []
        gradingSubmissions = []
        grades = [:]
    }

    // MARK: - Auth

    /// Run Google OAuth, fetch the signed-in user, resolve their role, and route.
    /// On any failure the error is surfaced and we stay on the sign-in screen.
    func signInWithGoogle() async {
        errorMessage = nil
        isLoading = true
        awaitingBrowserCallback = true
        defer { isLoading = false; awaitingBrowserCallback = false }
        do {
            try await supabase.signInWithGoogle()
            let user = try await supabase.fetchUser()
            userId = user.id
            email = user.email ?? ""
            displayName = user.displayName ?? user.email ?? "Signed in"
            signedIn = true
            useMockData = false
            dropMockData()

            // Route by the school's Teachers sheet: on the list => teacher,
            // everyone else => student (automatically).
            let resolved = await resolveRole(email: email)
            accountRole = resolved
            role = resolved
            isAdmin = (resolved == .admin)
            switch resolved {
            case .teacher, .admin:
                // Teachers (and admins) pick Teacher or Student view. Stay on
                // the sign-in route, which now shows only the chooser; any
                // pending deep link replays when they pick a view.
                route = .signIn
            case .student:
                studentScreen = .home
                route = .student
                await loadStudentHome()
                // Replay any deep link that arrived on the sign-in screen.
                resolvePendingDeepLink()
            }
        } catch is CancellationError {
            // The user backed out (Cancel, or a superseding attempt) — the
            // sign-in screen just returns to rest, no error banner.
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Abandon a sign-in attempt that is waiting on the browser redirect (the
    /// user may have closed the tab, after which no callback will ever arrive).
    func cancelSignIn() {
        awaitingBrowserCallback = false
        supabase.cancelPendingSignIn()
    }

    /// Teacher if the email is on the school's Teachers sheet; otherwise student.
    /// If the sheet can't be reached, fall back to the server role function so a
    /// teacher isn't wrongly demoted, then default to student.
    private func resolveRole(email: String) async -> UserRole {
        let directory = await TeacherDirectory.fetch()
        if directory.ok {
            return directory.emails.contains(email.lowercased()) ? .teacher : .student
        }
        if let serverRole = await supabase.resolveRole() { return serverRole }
        return .student
    }

    // MARK: - Loads (student)

    /// Load the signed-in student's classes, then the work for the selected one.
    /// No-ops (keeps mocks) when not signed in.
    func loadStudentHome() async {
        guard signedIn, !studentHomeInFlight else { return }
        studentHomeInFlight = true
        defer { studentHomeInFlight = false }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let classes = try await supabase.myClasses(userId: userId)
            enrolledClasses = classes
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
            if let cid = selectedClassId {
                classOpenCounts[cid] = classWork.filter { $0.section == .active }.count
            }
            await loadOpenCounts(skipping: selectedClassId)
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Load the work rows for the currently selected class.
    func loadClassWork() async {
        guard signedIn, let cid = selectedClassId else { return }
        do {
            let work = try await supabase.listClassWork(classId: cid)
            // Signed out (or switched class) while suspended: don't write a real
            // account's rows over restored mock state / the new class.
            guard signedIn, selectedClassId == cid else { return }
            classWork = work
            await loadOutlineState()
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Student outlines

    /// 10 MB cap on outline uploads (PDF/Word outlines are small documents).
    static let outlineMaxBytes = 10 * 1024 * 1024

    /// Resolve outline permission + the student's own outline for each Active
    /// row, alongside loadClassWork. Best-effort by design: outlines are an
    /// enhancement, so a failed hop hides the affordance rather than putting
    /// an error banner over the class home.
    func loadOutlineState() async {
        guard signedIn else { return }
        for item in classWork {
            guard item.section == .active, let sid = item.activeSessionId else { continue }
            // list_class_work doesn't carry outline_allowed, so resolve it via
            // the active session's test — once per session, then cached (a new
            // launch is a new session id, so the next draft's flag is re-read;
            // see outlineAllowedBySession).
            if outlineAllowedBySession[sid] == nil, let code = item.activeCode {
                let session = try? await supabase.lookupSession(code: code)
                if let testId = session?.testId,
                   let test = try? await supabase.getTest(id: testId) {
                    // Signed out while suspended: signOut() restored the mock
                    // state, so never write a real account's flag over it
                    // (the loadTeacherHome pattern).
                    guard signedIn else { return }
                    outlineAllowedBySession[sid] = test.outlineAllowed
                }
            }
            guard outlineAllowedBySession[sid] == true else { continue }
            do {
                // A confirmed "no row" (nil) clears the cache — the student may
                // have removed the outline on another device.
                let mine = try await supabase.getMyOutline(sessionId: sid, userId: userId)
                guard signedIn else { return }
                myOutlines[sid] = mine
            } catch {
                // Failed fetch: keep whatever is cached rather than flickering
                // a real outline away.
            }
        }
    }

    /// Upload (or replace) the student's outline for an Active row: bytes into
    /// the private bucket first, then the row upsert — the row is what the
    /// teacher lists, so it must never exist before its bytes do.
    func uploadOutline(for item: ClassWorkItem, fileURL: URL) async {
        guard let sid = item.activeSessionId, !outlineBusy else { return }
        outlineBusy = true
        defer { outlineBusy = false }
        errorMessage = nil
        let name = fileURL.lastPathComponent
        if !signedIn {
            // Preview: register the picked file locally so Replace/Remove demo.
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            myOutlines[sid] = OutlineUpload(
                id: "local-\(UUID().uuidString.prefix(6))", sessionId: sid, userId: "u1",
                displayName: displayName, originalName: name,
                mimeType: outlineMime(for: fileURL), sizeBytes: size,
                storagePath: "", createdAt: .now)
            return
        }
        // The picker's URL is security-scoped; harmless when not sandboxed.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        // Replacing under a new filename leaves the old object behind in the
        // private bucket; capture its path now so it can be cleaned up — but
        // only after the new bytes AND row are in place (deleting it first
        // would leave the teacher's listed row pointing at destroyed bytes
        // whenever the upload is then refused).
        let previousPath = myOutlines[sid]?.storagePath
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.outlineMaxBytes else {
                errorMessage = "Outlines can be up to 10 MB. Choose a smaller file."
                return
            }
            let mime = outlineMime(for: fileURL)
            let path = "\(userId)/\(sid)/\(name)"
            try await supabase.uploadOutlineFile(data: data, path: path, contentType: mime)
            let row = try await supabase.upsertOutline(
                sessionId: sid, displayName: displayName, originalName: name,
                mimeType: mime, sizeBytes: data.count, storagePath: path)
            // The row's UPDATE-half is RLS-refused once the student has begun
            // writing, and PostgREST surfaces that as a 2xx with zero rows — so
            // upsertOutline returns nil WITHOUT throwing (the same gotcha
            // deleteOutline guards against). A non-throwing upsert therefore
            // does NOT prove the row now points at the new bytes. Confirm the
            // returned row actually moved to `path` before doing anything
            // destructive; otherwise treat it as the begin-writing lock, keep
            // the old row/bytes, and skip the old-object cleanup.
            guard let row, row.storagePath == path else {
                guard signedIn else { return }
                outlineLockedSessionIds.insert(sid)
                // Keep whatever is cached (the old, still-valid outline); never
                // remove the old object or overwrite the row with a stale fetch.
                return
            }
            // The replace is confirmed: clear the renamed-away object,
            // best-effort (mirrors deleteOutline's cleanup; a failure merely
            // orphans an unreadable object).
            if let old = previousPath, !old.isEmpty, old != path {
                await supabase.removeOutlineObject(path: old)
            }
            // Signed out while the writes were in flight: signOut() restored
            // the mock state, so never write a real account's row over it
            // (the loadTeacherHome pattern).
            guard signedIn else { return }
            myOutlines[sid] = row
        } catch {
            // A post-signOut failure must not banner the sign-in screen.
            guard signedIn else { return }
            if isOutlineLock(error) { outlineLockedSessionIds.insert(sid) }
            else { errorMessage = describe(error) }
        }
    }

    /// Remove the student's outline for an Active row. A refused delete is the
    /// RLS begin-writing lock: the row (and the teacher's copy) survives, and
    /// the affordance flips to the inline locked note. The refusal arrives as
    /// a verified zero-row delete (deleteOutline returns false), NOT an error:
    /// PostgREST hides locked rows from DELETE and reports success.
    func removeOutline(for item: ClassWorkItem) async {
        guard let sid = item.activeSessionId, !outlineBusy else { return }
        outlineBusy = true
        defer { outlineBusy = false }
        errorMessage = nil
        if !signedIn { myOutlines[sid] = nil; return }
        do {
            let deleted = try await supabase.deleteOutline(sessionId: sid, userId: userId)
            // Signed out while the delete was in flight: signOut() restored the
            // mock state, so never write over it (the loadTeacherHome pattern).
            guard signedIn else { return }
            if deleted {
                myOutlines[sid] = nil
            } else {
                // The row survived the delete: the student began writing,
                // possibly on another device. Keep the outline on screen and
                // show the locked note — the stored bytes were never touched.
                outlineLockedSessionIds.insert(sid)
            }
        } catch {
            // A post-signOut failure must not banner the sign-in screen.
            guard signedIn else { return }
            if isOutlineLock(error) { outlineLockedSessionIds.insert(sid) }
            else { errorMessage = describe(error) }
        }
    }

    /// Open a student's outline (teacher-side, while grading) in the default
    /// app via a fresh signed URL — the bucket is private, so every read is
    /// time-limited (the essay-files pattern).
    func openOutline(_ outline: OutlineUpload) async {
        guard signedIn, !outline.storagePath.isEmpty else { return }
        do {
            let url = try await supabase.signedOutlineURL(path: outline.storagePath)
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
        } catch {
            errorMessage = describe(error)
        }
    }

    /// True when the server refused an outline write because the student
    /// began writing (their `students` row exists): PostgREST and storage
    /// both surface that RLS refusal as a 403. Not every 403 on these paths
    /// is the lock, though — a missing enrollment or a storage policy gap
    /// answers 403 too — so the body must carry the RLS-refusal wording
    /// before a row flips to the sticky locked note; anything else surfaces
    /// through errorMessage, where it can be read and retried. (Refused
    /// DELETEs never reach here at all: PostgREST hides locked rows and
    /// reports zero deleted rows — see deleteOutline.)
    private func isOutlineLock(_ error: Error) -> Bool {
        guard case let SupabaseError.badResponse(status, body) = error, status == 403 else {
            return false
        }
        let wording = body.lowercased()
        return wording.contains("row-level security") || wording.contains("policy")
            || wording.contains("violates") || wording.contains("42501")
    }

    /// The two formats students may upload; the picker already restricts to
    /// .pdf/.docx, so the extension is authoritative here.
    private func outlineMime(for url: URL) -> String {
        url.pathExtension.lowercased() == "pdf"
            ? "application/pdf"
            : "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    }

    /// Refresh the per-class Active counts for the classes list. Classes are
    /// few; one small RPC per class, concurrently. `skipId` lets the caller
    /// skip the class whose count was already seeded from a just-loaded
    /// classWork (avoids a redundant network hop for the current class).
    func loadOpenCounts(skipping skipId: String? = nil) async {
        guard signedIn else { return }
        let classes = enrolledClasses
        await withTaskGroup(of: (String, Int).self) { group in
            for c in classes where c.id != skipId {
                group.addTask {
                    let work: [ClassWorkItem] =
                        (try? await SupabaseManager.shared.listClassWork(classId: c.id)) ?? []
                    return (c.id, work.filter { $0.section == .active }.count)
                }
            }
            for await (id, n) in group { classOpenCounts[id] = n }
        }
    }

    /// Back from a class detail to the classes list.
    func leaveClass() {
        // Clear any stale error from the class we're leaving so it can't linger
        // over the classes list (mirrors leaveTeacherClass).
        errorMessage = nil
        selectedClassId = nil
        if signedIn { classWork = [] }
        Task { await loadOpenCounts() }
    }

    func selectClass(_ id: String) {
        // A stale error from a prior class must not show under the new header.
        errorMessage = nil
        selectedClassId = id
        // Previous class's rows must never render under the new header.
        if signedIn { classWork = []; Task { await loadClassWork() } }
    }

    /// Pull the signed-in student's released (graded) work for ReturnedWorkView.
    func loadReturnedWork() async {
        guard signedIn else { return }
        do {
            returnedWork = try await supabase.getMyReturnedWork()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Join a class by code; on success refresh the home and return to it.
    /// Returns the joined class name (for the confirmation copy) or nil.
    @discardableResult
    func joinClass(code: String) async -> ClassRoom? {
        guard signedIn else {
            // Mock path (dev / unsigned): pretend the join worked.
            return ClassRoom(id: "mock", name: "Your class", joinCode: code, archivedAt: nil)
        }
        errorMessage = nil
        do {
            let joined = try await supabase.joinClass(code: code, displayName: displayName)
            await loadStudentHome()
            if let joined { selectClass(joined.id) }
            return joined
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    // MARK: - Teacher: data load
    //
    // Real Supabase when signed in; local mock mutations when previewing (not
    // signed in) so every teacher button is demoable without a backend session.

    func loadTeacherHome() async {
        guard signedIn, !teacherHomeInFlight else { return }
        teacherHomeInFlight = true
        defer { teacherHomeInFlight = false }
        errorMessage = nil
        do {
            let classes = try await supabase.listTeacherClasses()
            let tests = try await supabase.listTeacherTests(userId: userId)
            // Signed out while a fetch was in flight: signOut() already restored
            // the mock state, so never write the old account's data over it
            // (it would leak into the NEXT sign-in's pre-load frame).
            guard signedIn else { return }
            teacherClasses = classes
            assignments = tests
            if pickedAssignmentId == nil || !groupedAssignments.contains(where: { $0.id == pickedAssignmentId }) {
                pickedAssignmentId = groupedAssignments.first?.id
            }
            // A selection pointing at a class that no longer exists is dropped.
            if let sel = teacherSelectedClassId, !teacherClasses.contains(where: { $0.id == sel }) {
                leaveTeacherClass()
            }
            // Restore an already-open session (app relaunch / another device) so
            // the home reflects reality and we never launch a duplicate.
            if liveSession == nil, let open = try? await supabase.listOpenSessions(userId: userId).first {
                guard signedIn else { return }   // signed out during the fetch
                liveSession = open
                await loadLiveRoster()
                guard signedIn else { return }   // signed out during the roster load
                // Prime the selection ONLY here, inside the restore branch:
                // a genuine relaunch lands the teacher next to their live exam,
                // but returning from the editor or grading never yanks a
                // teacher who deliberately went back to the classes list.
                if teacherSelectedClassId == nil, let cid = open.classId,
                   teacherClasses.contains(where: { $0.id == cid }) {
                    teacherSelectedClassId = cid
                    classSessions = nil
                }
            }
            // Refresh an open detail (covers priming and post-mutation reloads).
            if teacherSelectedClassId != nil { await loadClassSessions() }
        } catch {
            guard signedIn else { return }   // a post-signOut failure must not banner the sign-in screen
            errorMessage = describe(error)
        }
    }

    /// Load the school's approved-website list from the published Google Sheet
    /// (cached after first success). Used by the assignment editor's picker.
    func loadApprovedSites() async {
        guard approvedSites.isEmpty, !approvedSitesLoading else { return }
        approvedSitesLoading = true
        defer { approvedSitesLoading = false }
        approvedSites = await ApprovedSitesService.fetch()
    }

    // MARK: - Teacher: navigation
    func teacherGoHome() { errorMessage = nil; teacherScreen = .home }
    func openNewAssignment() { errorMessage = nil; editingAssignment = nil; teacherScreen = .editor }
    func openEditAssignment(_ a: Assignment) { errorMessage = nil; editingAssignment = a; teacherScreen = .editor }

    // MARK: - Teacher: classes
    var selectedTeacherClass: ClassRoom? {
        teacherClasses.first { $0.id == teacherSelectedClassId }
    }
    /// Name of the class that owns the live session; nil for legacy rows
    /// with no class_id (callers must cope).
    var liveClassName: String? {
        guard let cid = liveSession?.classId else { return nil }
        return teacherClasses.first { $0.id == cid }?.name
    }
    /// SINGLE title-resolution path: test_id -> title (+ vN when > 1) from the
    /// already-loaded `assignments` (ALL versions, so old drafts resolve too).
    /// Fallback covers deleted tests and the pre-load window.
    func sessionTitle(_ s: ExamSession) -> String {
        guard let tid = s.testId,
              let a = assignments.first(where: { $0.id == tid }) else { return "Assignment" }
        return a.versionNumber > 1 ? "\(a.title) · v\(a.versionNumber)" : a.title
    }

    /// Enter a class's detail (level 2). Clears the previous class's history
    /// FIRST so stale rows never flash under the new header (mirrors selectClass).
    func selectTeacherClass(_ id: String) {
        errorMessage = nil
        teacherSelectedClassId = id
        classSessions = nil
        Task { await loadClassSessions() }
    }

    /// Back to the classes list (level 1).
    func leaveTeacherClass() {
        errorMessage = nil
        teacherSelectedClassId = nil
        classSessions = nil
    }

    /// Session history for the selected class, any status, newest first.
    func loadClassSessions() async {
        guard let cid = teacherSelectedClassId else { return }
        if !signedIn {
            // The mutable preview store is the single source of truth here:
            // launched and ended demo sessions live in it, so history is
            // stable across leaving and re-entering the class.
            classSessions = previewSessions.filter { $0.classId == cid }
            return
        }
        do {
            let sessions = try await supabase.listClassSessions(classId: cid, teacherUserId: userId)
            guard teacherSelectedClassId == cid else { return }   // switched class mid-flight; drop stale payload
            classSessions = sessions
        } catch {
            guard teacherSelectedClassId == cid else { return }
            errorMessage = describe(error)
        }
    }

    func createClass(name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if !signedIn {
            teacherClasses.append(ClassRoom(id: "local-\(UUID().uuidString.prefix(6))",
                name: clean, joinCode: SupabaseManager.classCode(), archivedAt: nil))
            return
        }
        do { _ = try await supabase.createClass(name: clean); await loadTeacherHome() }
        catch { errorMessage = describe(error) }
    }

    func openRoster(_ c: ClassRoom) {
        errorMessage = nil; inviteStatus = nil
        rosterClassId = c.id; rosterClassName = c.name; teacherScreen = .roster
        Task { await loadRoster() }
    }

    func loadRoster() async {
        guard let cid = rosterClassId else { return }
        if !signedIn {
            classRoster = [
                ClassEnrollment(displayName: "Ava Chen", userId: "u1", createdAt: .now, removedAt: nil),
                ClassEnrollment(displayName: "Ben Ortiz", userId: "u2", createdAt: .now, removedAt: nil),
                ClassEnrollment(displayName: "Maya Singh", userId: "u3", createdAt: .now, removedAt: nil),
            ]
            return
        }
        do { classRoster = try await supabase.listClassEnrollments(classId: cid) }
        catch { errorMessage = describe(error) }
    }

    // MARK: - Teacher: assignments
    func saveAssignment(title: String, prompt: String, wordLimit: Int?, timeLimitMinutes: Int?,
                        spellcheckEnabled: Bool = true, outlineAllowed: Bool = false,
                        links: [(name: String, href: String)] = []) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !p.isEmpty else {
            errorMessage = "An assignment needs a title and a prompt."
            return
        }
        errorMessage = nil
        let qid = editingAssignment?.questions.first?.id ?? "q-\(UUID().uuidString.prefix(8))"
        let existingFileIds = editingAssignment?.questions.first?.fileIds ?? []
        if !signedIn {
            // Preview keeps the links on the question so the editor round-trips,
            // but no backend pool ids exist; store the hrefs as the "ids" stand-in.
            // spellcheckEnabled is stored on the local Assignment so ExamView can
            // read it back in preview (no backend session required).
            let q = Question(id: qid, kind: "essay", prompt: p, wordLimit: wordLimit,
                             fileIds: existingFileIds, urlIds: links.map(\.href))
            if let id = editingAssignment?.id, let idx = assignments.firstIndex(where: { $0.id == id }) {
                assignments[idx] = Assignment(id: id, title: t,
                    versionGroupId: assignments[idx].versionGroupId,
                    versionNumber: assignments[idx].versionNumber,
                    questions: [q], timeLimitMinutes: timeLimitMinutes,
                    spellcheckEnabled: spellcheckEnabled, outlineAllowed: outlineAllowed)
            } else {
                assignments.append(Assignment(id: "local-\(UUID().uuidString.prefix(6))", title: t,
                    versionGroupId: "g-\(UUID().uuidString.prefix(6))", versionNumber: 1,
                    questions: [q], timeLimitMinutes: timeLimitMinutes,
                    spellcheckEnabled: spellcheckEnabled, outlineAllowed: outlineAllowed))
            }
            teacherScreen = .home
            return
        }
        do {
            // Persist the approved links into the test_urls pool, then reference
            // their ids from the question (there is no test_id FK on test_urls).
            let urlIds = try await supabase.createTestURLs(userId: userId, links: links)
            let q = Question(id: qid, kind: "essay", prompt: p, wordLimit: wordLimit,
                             fileIds: existingFileIds, urlIds: urlIds)
            if let id = editingAssignment?.id {
                try await supabase.updateTest(id: id, title: t, questions: [q],
                                             timeLimitMinutes: timeLimitMinutes,
                                             spellcheckEnabled: spellcheckEnabled,
                                             outlineAllowed: outlineAllowed)
            } else {
                _ = try await supabase.createTest(teacherUserId: userId, title: t,
                                                  questions: [q],
                                                  timeLimitMinutes: timeLimitMinutes,
                                                  spellcheckEnabled: spellcheckEnabled,
                                                  outlineAllowed: outlineAllowed)
            }
            await loadTeacherHome()
            teacherScreen = .home
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Load the saved approved links for an assignment being edited, so the
    /// editor shows them (and re-saving preserves them). Scope isn't persisted
    /// yet, so it defaults to domain on reload.
    func editorLinks(for assignment: Assignment?) async -> [(name: String, href: String)] {
        guard signedIn, let ids = assignment?.questions.first?.urlIds, !ids.isEmpty else { return [] }
        let urls = (try? await supabase.listTestURLs(ids: ids)) ?? []
        return urls.map { (name: $0.displayName, href: $0.url) }
    }

    func deleteAssignment(_ a: Assignment) async {
        if !signedIn { assignments.removeAll { $0.id == a.id }; return }
        do { try await supabase.deleteTest(id: a.id); await loadTeacherHome() }
        catch { errorMessage = describe(error) }
    }

    /// Clone `source` into the next draft of its group and open the editor on
    /// it (the teacher tweaks the prompt, then launches it normally).
    func createNextDraft(of source: Assignment) async {
        guard !draftCloneInFlight else { return }
        draftCloneInFlight = true
        defer { draftCloneInFlight = false }
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
                                   timeLimitMinutes: source.timeLimitMinutes,
                                   spellcheckEnabled: source.spellcheckEnabled,
                                   outlineAllowed: source.outlineAllowed)
            assignments.append(clone)
            pickedAssignmentId = clone.id
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
            pickedAssignmentId = clone.id
            openEditAssignment(clone)
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Teacher: live session
    func launchSession() async {
        guard !launchInFlight else { return }
        launchInFlight = true
        defer { launchInFlight = false }
        errorMessage = nil
        guard liveSession == nil else {
            errorMessage = liveClassName.map {
                "End the live session in \($0) first, then launch this assignment."
            } ?? "End the current live session first, then launch this assignment."
            return
        }
        guard let testId = pickedAssignmentId else {
            errorMessage = "Pick an assignment to launch."
            return
        }
        guard let classId = teacherSelectedClassId else {
            errorMessage = "Open a class to launch for."
            return
        }
        if !signedIn {
            // Unique id per preview launch: relaunching after End session must
            // never duplicate a ForEach identifier in the Sessions list.
            let s = ExamSession(id: "local-\(UUID().uuidString.prefix(6))",
                                code: SupabaseManager.sessionCode(),
                                testId: testId, classId: classId, status: "open", createdAt: Date())
            liveSession = s
            roster = RosterStudent.sample
            previewSessions.insert(s, at: 0)
            classSessions = previewSessions.filter { $0.classId == classId }   // history shows the open row immediately
            return
        }
        isLoading = true
        defer { isLoading = false }
        let ip = await ProctoringEngine().fetchPublicIP()
        do {
            liveSession = try await supabase.launchSession(testId: testId, classId: classId,
                                                           teacherUserId: userId, teacherIP: ip)
            await loadLiveRoster()
            await loadClassSessions()      // the new open session appears as history row 1; NO tab jump
            // Email every enrolled student that the assignment is live. Best
            // effort; never blocks the launch.
            if let sid = liveSession?.id {
                Task { await supabase.notify("assignment_launched", body: ["session_id": sid]) }
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    func loadLiveRoster() async {
        guard signedIn, let sid = liveSession?.id else { return }
        do {
            let students = try await supabase.listSessionStudents(sessionId: sid)
            // Signed out (or session swapped) mid-flight: don't clobber the
            // just-restored mock roster with the old account's students.
            guard signedIn, liveSession?.id == sid else { return }
            roster = students
        } catch {
            guard signedIn else { return }
            errorMessage = describe(error)
        }
    }

    func endSession() async {
        // Signed-in: close EVERY open session this teacher owns, not just the
        // one displayed in the Live card. The app's invariant is one live session
        // at a time, so any extra open rows are stale leftovers from crashes or
        // old builds; loadTeacherHome would otherwise resurrect them one by one.
        // On network failure we surface the error and KEEP the local Live card —
        // the session is still open on the server, so hiding it would be a lie.
        if signedIn {
            do {
                try await supabase.endAllOpenSessions(teacherUserId: userId)
            } catch {
                errorMessage = "Couldn't end the session. Check your connection and try again."
                return
            }
        }
        // Preview path (not signed in), or successful server close: clear local state.
        let ended = liveSession
        liveSession = nil
        roster = []        // the live MONITOR roster only
        // Grading state is deliberately NOT cleared. Grading keys on
        // gradingSession now; the just-closed session's essays are the very
        // thing the teacher comes back to grade. Clearing them here was the
        // old defect's second half.
        if signedIn {
            await loadClassSessions()      // the row reappears as Closed in place
        } else if let s = ended {
            // Preview: flip the row in the BACKING store (not just the visible
            // list) so the defect case stays demoable after leaving and
            // re-entering the class — the closed row must never vanish.
            if let i = previewSessions.firstIndex(where: { $0.id == s.id }) {
                previewSessions[i].status = "closed"
            }
            if let cid = teacherSelectedClassId {
                classSessions = previewSessions.filter { $0.classId == cid }
            }
        }
    }

    // MARK: - Teacher: grading

    /// Open grading for an EXPLICIT session: the open one or any history row,
    /// including sessions closed days ago. Never keyed to liveSession.
    /// Callers MUST pass title: sessionTitle(session); no other source.
    func openGrading(session: ExamSession, title: String) {
        errorMessage = nil
        gradingSession = session
        gradingTitle = title
        // Pre-clear the PREVIOUS session's caches before navigating so its
        // essays never render under the new title while the load is in
        // flight, and a failed load can't leave the wrong session on screen.
        gradingSubmissions = []
        grades = [:]
        gradingRoster = []
        gradingOutlines = []
        gradesFresh = false
        teacherScreen = .grading
        Task { await loadGrading() }
    }

    func loadGrading() async {
        // Keyed to the EXPLICIT grading session, never liveSession: closed
        // sessions stay gradeable forever. nil (dev gallery / #Preview) keeps
        // the silent no-op so the grading screen's mock fallback renders.
        guard let sid = gradingSession?.id else { return }
        gradesFresh = false
        if !signedIn {
            gradingSubmissions = []
            grades = [:]
            gradingOutlines = []
            return
        }
        errorMessage = nil
        do {
            let subs = try await supabase.listSessionSubmissions(sessionId: sid)
            let ros  = try await supabase.listSessionStudents(sessionId: sid)
            let g    = try await supabase.listGrades(submissionIds: subs.map(\.id))
            // Outlines are auxiliary grading context: best-effort, so a
            // refused/failed fetch never makes the essays themselves
            // unreachable (they're the point of this screen).
            let outlines = (try? await supabase.listSessionOutlines(sessionId: sid)) ?? []
            // The teacher may have opened a DIFFERENT session while we loaded;
            // a stale payload must never overwrite it or set gradesFresh.
            guard gradingSession?.id == sid else { return }
            gradingSubmissions = subs
            gradingRoster = ros
            gradingOutlines = outlines
            grades = Dictionary(uniqueKeysWithValues: g.map { ($0.submissionId, $0) })
            gradesFresh = true   // grades cache now reflects the DB for THIS session
        } catch {
            guard gradingSession?.id == sid else { return }
            errorMessage = describe(error)
        }
    }

    /// Save (and optionally share) a grade. essay_grades requires session_id +
    /// student_id, taken from the submission. Sharing keeps the original release
    /// timestamp if already shared; saving-without-sharing never un-shares.
    func saveGrade(submission: TeacherSubmission, points: Double?, pointsPossible: Double,
                   feedback: String, share: Bool) async {
        guard signedIn else { return }
        guard let sid = submission.sessionId, let stid = submission.studentId else {
            errorMessage = "This submission is missing its session or student."
            return
        }
        errorMessage = nil
        let cached = grades[submission.id]?.releasedAt
        // Trust the "first release" decision only if the grades cache we're
        // reading from was loaded successfully (not stale/failed).
        let wasFresh = gradesFresh
        // upsertGrade writes released_at verbatim (no DB-side COALESCE), so the
        // value we send IS the new server state. The in-memory cache can be
        // stale (e.g. the grade was released on another device/session since we
        // loaded), and clearing released_at would silently retract a grade the
        // student already sees. Make the non-share path server-authoritative:
        // re-fetch this submission's current released_at right before the write
        // so a save-without-sharing can never un-share. Fall back to the cache
        // only if the fetch fails (then we keep whatever we last knew, never a
        // worse-than-cache nil).
        let existing: Date?
        if share {
            existing = cached
        } else if let fetched = try? await supabase.listGrades(submissionIds: [submission.id]).first {
            existing = fetched.releasedAt
        } else {
            existing = cached
        }
        let releasedAt: String?
        if share {
            releasedAt = SupabaseDate.fractional.string(from: existing ?? Date())
        } else {
            releasedAt = existing.map { SupabaseDate.fractional.string(from: $0) }
        }
        do {
            try await supabase.upsertGrade(submissionId: submission.id, sessionId: sid, studentId: stid,
                                           points: points, pointsPossible: pointsPossible,
                                           feedback: feedback, releasedAt: releasedAt)
            await loadGrading()
            // Notify the student only on the first release (sharing for the first
            // time, off a known-fresh cache), never on re-saves of already-shared
            // work, and never with the score in the email.
            if share, existing == nil, wasFresh {
                Task { await supabase.notify("grades_published", body: ["submission_id": submission.id]) }
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Student flow transitions

    /// Begin an attempt at `item`: stage the assignment and go to the pre-exam
    /// checks. Fetching the real test/questions for the active session is the one
    /// remaining backend hop; until then we stage a faithful placeholder built
    /// from the work row so the exam screen reads correctly.
    func startWriting(_ item: ClassWorkItem) {
        errorMessage = nil
        activeAssignment = Assignment(
            id: item.activeSessionId ?? item.id,
            title: item.title,
            versionGroupId: item.versionGroupId,
            versionNumber: 1,
            questions: [Question(id: "q", kind: "essay",
                                 prompt: Assignment.sample.questions.first?.prompt
                                     ?? "Respond to the prompt your teacher set.",
                                 wordLimit: 600)],
            timeLimitMinutes: 45)
        // Seed empty when signed in (loadExamMaterials fills in the teacher's
        // real files/links); the bundled samples are for the not-signed-in
        // preview only. Seeding samples for a signed-in student would leak fake
        // reference tabs AND inject their hosts into the locked browser's
        // approved-host whitelist when the teacher whitelisted nothing.
        examFiles = signedIn ? [] : ExamFile.sample
        examLinks = signedIn ? [] : ExamLink.sample
        activeExamSession = nil
        activeStudentId = nil
        activeSubmissionId = nil
        if signedIn, let code = item.activeCode {
            Task {
                await resolveActiveExam(code: code)
                await loadExamMaterials(code: code)
            }
        }
        studentScreen = .checks
    }

    /// Resolve the active session's test, then load its reference files + links.
    /// Best-effort: on any failure we keep the sample materials.
    func loadExamMaterials(code: String) async {
        guard signedIn else { return }
        do {
            guard let session = try await supabase.lookupSession(code: code),
                  let testId = session.testId,
                  let test = try await supabase.getTest(id: testId) else { return }
            let q = test.questions.first
            let files = try await supabase.listTestFiles(ids: q?.fileIds ?? [])
            let links = try await supabase.listTestURLs(ids: q?.urlIds ?? [])
            // The real fetch is authoritative for a signed-in exam: assign it
            // verbatim (the lists started empty for signed-in students), so a
            // test with no files/links shows none rather than retaining samples.
            examFiles = files
            examLinks = links
        } catch {
            // keep whatever was seeded; this is a non-blocking enhancement
        }
    }

    /// Resolve the open session + REAL test for `code`, replacing the staged
    /// placeholder. Submissions must carry the real question id, so the
    /// session is exposed ONLY after the real test is staged — autosave gates
    /// on `activeExamSession`, and a session paired with the placeholder
    /// question id would write a corrupt submission row.
    func resolveActiveExam(code: String) async {
        guard signedIn else { return }
        do {
            guard let session = try await supabase.lookupSession(code: code),
                  session.status == "open" else {
                errorMessage = "This assignment isn't open anymore."
                return
            }
            guard let testId = session.testId,
                  let test = try await supabase.getTest(id: testId) else {
                errorMessage = "Couldn't load this assignment's prompt. Go back and try again."
                return
            }
            activeAssignment = test
            activeExamSession = session
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Begin button on the checks screen: register the students row (the
    /// proctoring contract) and only then enter the locked exam. False (with
    /// errorMessage set) means stay on the checks screen.
    func beginExam(screenCapture: Bool, remote: Bool, displayCount: Int?,
                   isVM: Bool?) async -> Bool {
        guard signedIn else { enterExam(); return true }   // preview path
        guard let session = activeExamSession else {
            errorMessage = "Couldn't reach this assignment's session. Go back and try again."
            return false
        }
        do {
            // The students schema requires the proctoring facts (NOT NULL, no
            // defaults), so unknowns get explicit fallbacks rather than
            // omitted keys. No IP/network matching: product call.
            guard let sid = try await supabase.registerStudent(
                sessionId: session.id, userId: userId,
                email: email.isEmpty ? nil : email,
                name: displayName.isEmpty ? (email.isEmpty ? "Student" : email) : displayName,
                screenCapture: screenCapture, remote: remote,
                displayCount: displayCount ?? 1, isVM: isVM ?? false)
            else {
                errorMessage = "Could not register for this exam."
                return false
            }
            // The students row now exists, so the server's RLS refuses outline
            // changes for this session from here on — reflect that immediately
            // (even if the late-success guard below bails out of entering).
            outlineLockedSessionIds.insert(session.id)
            // The registration round-trip is long enough for the student to
            // have left checks (deep link, sign-out, back). A late success
            // must not shove them into the kiosk — or worse, cross-wire a
            // stale students-row id with a newer session (every autosave
            // would then fail RLS inside a locked exam).
            guard studentScreen == .checks, activeExamSession?.id == session.id else {
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

    func openReturnedWork() {
        // ReturnedWorkView owns the load via its own `.task` (auto-cancelled with
        // the view); don't fire a second, detached load here.
        studentScreen = .returned
    }

    /// Open the read-only viewer for a Past row and begin fetching the essay.
    /// When not signed in (preview / gallery), seeds a demo essay immediately so
    /// the screen is fully demoable without a backend session.
    func openSubmittedWork(_ item: ClassWorkItem) {
        errorMessage = nil
        submittedEssay = nil
        submittedEssayError = nil
        submittedVersionGroupId = item.versionGroupId
        studentScreen = .submitted
        guard signedIn else {
            // Preview path: render a sample essay so the screen is demoable.
            submittedEssay = SubmittedEssay(
                title: item.title,
                contentHtml: "<p>The interplay of light and shadow works as more than scenery in the passage. The author never lets one exist without the other: every lit window implies a surrounding dark, and every shadow is measured against the nearest lamp.</p><p>What makes this technique effective is its restraint. The imagery is never labelled or explained; it accumulates until the reader is doing the interpretation themselves.</p>",
                wordCount: 53,
                submittedAt: item.mySubmittedAt ?? Date())
            return
        }
        Task { await loadSubmittedWork(versionGroupId: item.versionGroupId) }
    }

    /// Fetch the caller's newest submitted essay for an assignment family.
    /// Populates `submittedEssay` on success, `submittedEssayError` on failure.
    func loadSubmittedWork(versionGroupId: String) async {
        do {
            let essay = try await supabase.getMySubmission(versionGroupId: versionGroupId)
            // A newer open owns the screen now; drop this stale result.
            guard versionGroupId == submittedVersionGroupId else { return }
            if let essay {
                submittedEssay = essay
            } else {
                submittedEssayError = "Couldn't find your submitted essay."
            }
        } catch {
            guard versionGroupId == submittedVersionGroupId else { return }
            submittedEssayError = describe(error)
        }
    }

    func goToJoin()  { studentScreen = .join }
    func goToHome()  { studentScreen = .home }
    func enterExam() { studentScreen = .exam }

    func finishExam() {
        // Move the just-submitted assignment out of "Active": clear its live
        // session and stamp a submission time so it drops into the submitted/past
        // bucket. (In the real flow the backend reload also reflects this; this
        // gives immediate, correct feedback, especially in preview.)
        if let vgid = activeAssignment?.versionGroupId,
           let idx = classWork.firstIndex(where: { $0.versionGroupId == vgid }) {
            classWork[idx].activeSessionId = nil
            classWork[idx].activeCode = nil
            classWork[idx].mySubmittedAt = Date()
            classWork[idx].myActiveSubmittedAt = Date()
        }
        activeAssignment = nil
        studentScreen = .done
        if signedIn { Task { await loadClassWork() } }
    }

    // MARK: - Teacher: invite students to a class

    /// Email a class invitation (with the join code) to one or more addresses.
    /// The notify function authorizes that the caller owns the class. Sets a
    /// transient `inviteStatus` for the roster UI.
    func inviteStudents(emails: [String]) async {
        guard let cid = rosterClassId else { return }
        let clean = Array(Set(emails
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.contains("@") && $0.contains(".") }))
        guard !clean.isEmpty else { inviteStatus = "Enter at least one valid email address."; return }
        if !signedIn {
            inviteStatus = "Would invite \(clean.count) student\(clean.count == 1 ? "" : "s")."
            return
        }
        inviteStatus = "Sending invitations…"
        do {
            let data = try await supabase.callFunction("notify",
                body: ["event": "class_invite", "class_id": cid, "emails": clean])
            struct R: Decodable { let sent: Int?; let skipped: String? }
            let r = try? JSONDecoder().decode(R.self, from: data)
            if r?.skipped == "email_not_configured" {
                inviteStatus = "Email isn't set up on the server yet."
            } else {
                let n = r?.sent ?? clean.count
                inviteStatus = "Invitation\(n == 1 ? "" : "s") sent to \(n) student\(n == 1 ? "" : "s")."
            }
        } catch {
            inviteStatus = "Could not send invitations right now."
        }
    }

    // MARK: - Deep links (weft://…)

    /// Handle an incoming custom-scheme URL. Exam/join links route a student to
    /// the right place; work/home links jump within the student flow. The OAuth
    /// callback (weft://auth-callback) is handed to the sign-in attempt waiting
    /// on it. A link that arrives before sign-in is stashed and replayed once a
    /// session exists.
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "weft" else { return }
        let host = (url.host ?? "").lowercased()
        // The browser redirect arrives pre-signedIn by definition, so it must be
        // routed BEFORE the stash-and-replay guard below — stashing it would
        // deadlock sign-in (replay only happens after a session exists).
        if host == "auth-callback" {
            // The callback resumes the parked continuation; from here the flow is
            // an uncancellable token-exchange tail, so retire the Cancel control.
            awaitingBrowserCallback = false
            supabase.resumeAuthCallback(url); return
        }
        guard signedIn else { pendingDeepLink = url; return }
        // NEVER reroute during a locked exam: a pre-scheduled `open weft://...`
        // would otherwise unmount ExamView, exit the kiosk, and skip the final
        // flush — a premeditated escape hatch in a proctoring product. The
        // link is dropped, not queued: by the time the exam ends it is stale.
        if role == .student, studentScreen == .exam { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first(where: { $0.name == "code" })?.value
        // These links are student-only. Never silently demote a signed-in
        // teacher/admin into a student flow they have no enrollment for; the role
        // was resolved authoritatively at sign-in.
        switch host {
        case "exam":
            guard role == .student else { return }
            route = .student
            pendingExamCode = code
            studentScreen = .home
            Task { await resolvePendingExam(code: code) }
        case "join":
            guard role == .student else { return }
            route = .student
            prefilledJoinCode = code
            studentScreen = .join
        case "work":
            guard role == .student else { return }
            route = .student
            studentScreen = .returned
        case "home", "":
            if role == .student { studentScreen = .home }
        default:
            break
        }
    }

    /// Replay a deep link that arrived before the user signed in.
    func resolvePendingDeepLink() {
        guard let url = pendingDeepLink else { return }
        pendingDeepLink = nil
        handleDeepLink(url)
    }

    /// Resolve a `weft://exam?code=` link: find the session's class, select it,
    /// load its work, and begin the matching live assignment. The code is passed
    /// in (not read from shared state) and consumed immediately, so a second
    /// link mid-resolve can't be dropped. Falls back to leaving the student on
    /// home with the assignment visible.
    private func resolvePendingExam(code: String?) async {
        guard signedIn, let code, !code.isEmpty else { return }
        pendingExamCode = nil   // consume immediately
        if let session = try? await supabase.lookupSession(code: code), let cid = session.classId {
            selectedClassId = cid
            classWork = []   // awaits its own loadClassWork next; stops class A's rows flashing under class B
            await loadClassWork()
            if let item = classWork.first(where: { $0.activeCode == code }) {
                startWriting(item)
            }
        }
    }

    // MARK: - Helpers

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

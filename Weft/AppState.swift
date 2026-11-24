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
    /// When this attempt's writing window ends, in local time, offset from
    /// the server clock `start_essay` returned. nil = the teacher left the
    /// time limit blank (unlimited). Seeded in beginExam, never from Date()
    /// at ExamView appearance: that reset the clock on every re-entry.
    var examDeadline: Date?

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
    /// Reentrancy guard: launchSession suspends on the server insert
    /// before liveSession is assigned, so a double-clicked Start
    /// could pass the `liveSession == nil` guard twice and mint two open
    /// server sessions — breaking the one-live-session invariant.
    private var launchInFlight = false
    /// True only after a *successful* grading load, so a first-release email is
    /// never sent off a stale/failed grades cache (which would duplicate).
    /// The grading screen also reads this: an empty roster before the load
    /// returns is "still loading", not a fake student called "No submissions".
    private(set) var gradesFresh = false
    /// The live-roster sweep (see startRosterPolling). nil when nothing is live.
    private var rosterPollTask: Task<Void, Never>?
    /// Monotonic sweep generation (the ExamView saveGeneration idiom): a tick
    /// whose generation is stale returns instead of polling, so a restart can
    /// never leave two sweeps hitting the server every five seconds.
    private var rosterPollGeneration = 0
    /// Student-home sweep so a live exam appears on enrolled Macs without a code.
    private var homePollTask: Task<Void, Never>?
    private var homePollGeneration = 0
    /// True once this attempt's `students` row has been moved to "writing", so
    /// the transition costs ONE update per exam and not one per keystroke.
    private var markedWriting = false

    // MARK: Data (mock defaults; replaced by real loads when signed in)
    var enrolledClasses: [ClassRoom] = [.sample, .sample2]
    var classWork: [ClassWorkItem] = ClassWorkItem.sampleList
    var assignments: [Assignment] = [.sample, .sample2]
    var teacherClasses: [ClassRoom] = [.sample, .sample2]
    var roster: [RosterStudent] = RosterStudent.sample
    /// Live-exam writing pulse, keyed by students-row id. Never the essay.
    var essayPulse: [String: EssayPulse] = EssayPulse.sample
    /// An open exam the signed-in student can enter without typing a code.
    var liveExamOffer: LiveExamOffer? = .sample
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
    /// True while a signed-in exam's real test_files / test_urls are still
    /// resolving. The reference panel must show a loading state while this is
    /// true: "your teacher didn't attach any materials" is a positive claim the
    /// app cannot make until the fetch has actually come back.
    var examMaterialsLoading = false
    /// True when the last materials fetch threw. The panel must offer Retry,
    /// not claim the teacher attached nothing.
    var examMaterialsFailed = false
    /// HTML of an in-progress draft to restore into ExamView. Consumed once.
    var examDraftHTML: String?
    /// True when examDraftHTML is the student's previous draft carried
    /// forward (SAT-5), not saved work for this draft: ExamView saves it at
    /// once through the normal sealed autosave. Consumed with examDraftHTML.
    var examDraftCarried = false
    /// One calm line for the top of the editor about carry forward ("Your
    /// Draft 1 is in the editor..."). Consumed once by ExamView.
    var examCarryNote: String?
    /// Session code used to resolve the active exam (retry after a failed lookup).
    var examResolveCode: String?
    /// Last flags written to the students row, so the 5s monitor does not PATCH
    /// identical values.
    private var lastProctorFlags: (screen: Bool, remote: Bool, displays: Int, vm: Bool)?

    /// Per-class work cache so the classes-list badges do not refetch every
    /// assignment list just to count Active rows.
    private var classWorkByClass: [String: [ClassWorkItem]] = [:]

    /// Materials shown in the exam reference panel: the student's own outline
    /// first (whenever the assignment allowed one: the panel renders PDFs,
    /// images, Word, RTF and plain text, and says so honestly for anything
    /// else), then the teacher's files. Falls back to just the teacher files.
    var examReferenceFiles: [ExamFile] {
        guard let sid = activeExamSession?.id,
              outlineAllowedBySession[sid] == true,
              let outline = myOutlines[sid]
        else { return examFiles }
        let outlineFile = ExamFile(
            id: "outline-\(outline.id)",
            originalName: outline.originalName,
            mimeType: outline.mimeType,
            storagePath: outline.storagePath,
            bucket: "outlines",
            isOutline: true,
            sealedForUserId: userId,
            sealedAAD: WeftContentSeal.outlineAAD(sessionId: sid, userId: outline.userId))
        return [outlineFile] + examFiles
    }

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
    /// Teacher: schedule the exam for a future bell instead of opening now.
    var scheduleLaunch = false
    var scheduledLaunchAt = Date().addingTimeInterval(3600)

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
    /// Margin comments for the session being graded, keyed by submission id.
    var gradingComments: [String: [EssayComment]] = [:]
    /// A student's drafts across the graded assignment's version group,
    /// keyed by "<student user id>|<version group id>" (DraftHistory.swift).
    var draftHistories: [String: DraftHistoryState] = [:]
    /// Which draftHistories key a graded submission resolved to.
    var draftKeyBySubmission: [String: String] = [:]
    /// The graded session's version group and its class sessions, keyed by
    /// the graded session id. Same for every student, so resolved once.
    var draftGroups: [String: DraftGroup] = [:]
    /// The teacher's essay key this exam's essay is sealed to (the
    /// student's own key is added by sealHTML).
    var examRecipientKeys: [DevicePublicKey] = []
    /// Whether this exam can be sealed to the teacher.
    var examLockState: ExamLockState?
    /// A teacher key that differs from the one this Mac remembered for the
    /// class, waiting for the student to trust it (SAT-21).
    var pendingTeacherKey: (classId: String, key: DevicePublicKey)?
    /// Whether this Mac holds the signed-in person's essay key. nil = not
    /// checked yet (or the check couldn't reach the server).
    var essayKeyState: EssayKeyState?
    /// The server holds a sealed draft this Mac cannot open (written on
    /// another Mac). Begin stops until the student chooses to start a new
    /// copy, so the first autosave can't silently replace work the teacher
    /// could still read.
    var examUnreadableDraft = false
    private var allowFreshOverUnreadable = false
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
        guard !ExamGate.inProgress else {
            errorMessage = "Finish the exam before switching views."
            return
        }
        errorMessage = nil
        route = .signIn
    }

    func enterTeacher() {
        guard !ExamGate.inProgress else {
            errorMessage = "Finish the exam before leaving it."
            return
        }
        role = .teacher
        if displayName.isEmpty { displayName = "Thomas Seirer" }
        teacherScreen = .home
        route = .teacher
        stopStudentHomePolling()
        if signedIn { resolvePendingDeepLink(); Task { await loadTeacherHome(); await checkEssayKey() } }
    }

    func enterStudent() {
        guard !ExamGate.inProgress else {
            errorMessage = "Finish the exam before leaving it."
            return
        }
        stopRosterPolling()   // the teacher monitor is off screen
        role = .student
        if displayName.isEmpty { displayName = "Ava Chen" }
        studentScreen = .home
        route = .student
        startStudentHomePolling()
        if signedIn {
            resolvePendingDeepLink()
            Task {
                await checkEssayKey()
                await loadStudentHome()
            }
        }
    }

    func signOut() {
        if ExamGate.inProgress {
            errorMessage = "Submit or finish the exam before signing out."
            return
        }
        ExamGate.inProgress = false
        supabase.signOut()
        // Opened outlines are decrypted copies; don't leave them behind.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("weft-outlines", isDirectory: true))
        stopRosterPolling()
        stopStudentHomePolling()
        markedWriting = false
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
        examDeadline = nil
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
        examMaterialsLoading = false
        examMaterialsFailed = false
        examDraftHTML = nil
        examDraftCarried = false
        examCarryNote = nil
        examResolveCode = nil
        lastProctorFlags = nil
        classWorkByClass = [:]
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
        gradingComments = [:]
        clearDraftHistory()
        examRecipientKeys = []
        examLockState = nil
        pendingTeacherKey = nil
        examUnreadableDraft = false; allowFreshOverUnreadable = false
        essayKeyState = nil
        teacherClasses = [.sample, .sample2]
        assignments = [.sample, .sample2]
        roster = RosterStudent.sample
        essayPulse = EssayPulse.sample
        liveExamOffer = .sample
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
        examMaterialsFailed = false
        examDraftHTML = nil
        examDraftCarried = false
        examCarryNote = nil
        examResolveCode = nil
        lastProctorFlags = nil
        classWorkByClass = [:]
        selectedClassId = nil
        activeAssignment = nil
        roster = []
        essayPulse = [:]
        liveExamOffer = nil
        examRecipientKeys = []
        examLockState = nil
        pendingTeacherKey = nil
        examUnreadableDraft = false; allowFreshOverUnreadable = false
        essayKeyState = nil
        gradingComments = [:]
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
        clearDraftHistory()
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
                await checkEssayKey()
            case .student:
                studentScreen = .home
                route = .student
                await checkEssayKey()
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
            refreshLiveExamOffer()
            startStudentHomePolling()
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
            classWorkByClass[cid] = work
            await loadOutlineState()
            refreshLiveExamOffer()
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
        let items = classWork.filter { $0.section == .active && $0.activeSessionId != nil }
        var sessionToTest: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for item in items {
                guard let sid = item.activeSessionId,
                      outlineAllowedBySession[sid] == nil,
                      let code = item.activeCode else { continue }
                group.addTask {
                    let session = try? await SupabaseManager.shared.lookupSession(code: code)
                    return (sid, session?.testId)
                }
            }
            for await (sid, tid) in group {
                if let tid { sessionToTest[sid] = tid }
            }
        }
        let testIds = Array(Set(sessionToTest.values))
        if !testIds.isEmpty,
           let allowed = try? await supabase.outlineAllowedByTestIds(testIds) {
            for (sid, tid) in sessionToTest {
                outlineAllowedBySession[sid] = allowed[tid] ?? false
            }
        }
        let allowedSids = items.compactMap { item -> String? in
            guard let sid = item.activeSessionId,
                  outlineAllowedBySession[sid] == true else { return nil }
            return sid
        }
        if let mine = try? await supabase.getMyOutlines(sessionIds: allowedSids, userId: userId) {
            for row in mine { myOutlines[row.sessionId] = row }
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
        // Set once the sealed bytes are stored; removed again if no row
        // ends up pointing at them (each upload has a fresh name).
        var uploadedPath: String?
        do {
            let data: Data
            do {
                data = try await Self.readPickedFile(fileURL, maxBytes: Self.outlineMaxBytes)
            } catch is FileTooLarge {
                errorMessage = "Outlines can be up to 10 MB. Choose a smaller file."
                return
            }
            let mime = outlineMime(for: fileURL)
            // Outlines are sealed like essays: to the teacher and to the
            // student. No keys, nothing is sent.
            if essayKeyState != .ready { await checkEssayKey() }
            guard essayKeyState == .ready,
                  WeftContentSeal.localRecipient(userId: userId) != nil else {
                errorMessage = accountRole == .student
                    ? "Couldn't set up your Weft key. Check your connection and try again."
                    : "Enter your essay password first, then add your outline."
                return
            }
            pendingTeacherKey = nil
            guard let teacherKeys = await outlineTeacherKeys(code: item.activeCode) else {
                errorMessage = pendingTeacherKey != nil
                    ? Self.teacherKeyChangedMessage
                    : "Couldn't reach Weft to lock your outline. Check your connection and try again."
                return
            }
            guard let sealed = WeftContentSeal.sealedFileBytes(
                data, userId: userId, teacherKeys: teacherKeys,
                aad: WeftContentSeal.outlineAAD(sessionId: sid, userId: userId)) else {
                errorMessage = "Your teacher needs to set their essay password in Weft before you can add an outline."
                return
            }
            let path = "\(userId)/\(sid)/\(UUID().uuidString.lowercased())\(WeftContentSeal.sealedFileSuffix)"
            try await supabase.uploadOutlineFile(data: sealed, path: path,
                                                 contentType: "application/octet-stream")
            uploadedPath = path
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
                await supabase.removeOutlineObject(path: path)
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
            if let orphan = uploadedPath { await supabase.removeOutlineObject(path: orphan) }
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
            let (stored, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SupabaseError.badResponse(status: http.statusCode, body: "")
            }
            // Outlines are sealed: open on this Mac with the teacher's key.
            let aad = WeftContentSeal.outlineAAD(sessionId: outline.sessionId,
                                                 userId: outline.userId)
            guard let plain = WeftContentSeal.openSealedFile(stored, userId: userId,
                                                             expectedAAD: aad) else {
                errorMessage = "This outline can't be opened on this Mac. It was locked to a different essay password."
                return
            }
            // A private temp folder (only this user can read it; macOS clears
            // old temp files on its own).
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("weft-outlines", isDirectory: true)
                .appendingPathComponent(outline.id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // The student controls original_name, so its extension is never
            // used: only a PDF or a Word file can open, decided by the bytes.
            let isPDF = plain.starts(with: Array("%PDF-".utf8))
            let isZip = plain.starts(with: [0x50, 0x4B, 0x03, 0x04])
            let ext: String
            if outline.mimeType == "application/pdf", isPDF { ext = "pdf" }
            else if outline.mimeType.contains("wordprocessingml"), isZip { ext = "docx" }
            else {
                errorMessage = "This outline isn't a PDF or Word file, so Weft won't open it."
                return
            }
            let base = (outline.originalName as NSString).deletingPathExtension
                .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let file = dir.appendingPathComponent(
                "\(base.isEmpty || base.hasPrefix(".") ? "Outline" : String(base.prefix(80))).\(ext)")
            try plain.write(to: file, options: [.atomic])
            Self.markQuarantined(file)
            #if canImport(AppKit)
            NSWorkspace.shared.open(file)
            #endif
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Mark a file Weft wrote from downloaded bytes as downloaded, so macOS
    /// treats it like any other file from the internet.
    nonisolated static func markQuarantined(_ url: URL) {
        let value = String(format: "0081;%08lx;Weft;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { ptr in
            setxattr(url.path, "com.apple.quarantine", ptr, strlen(ptr), 0, 0)
        }
    }

    /// The student's wrap for a returned essay: this Mac (the teacher's) opens
    /// the essay key and wraps it for the student's published key.
    private func returnWrap(envelope env: WeftEnvelope, studentId: String) async -> WeftEnvelopeWrap? {
        guard let uid = try? await supabase.studentUserId(studentId: studentId),
              let keys = try? await supabase.listDeviceKeys(userIds: [uid]),
              let key = keys.first(where: { $0.userId == uid && WeftContentSeal.isGenuine($0) })
        else { return nil }
        return WeftContentSeal.extraWrap(for: key, envelope: env, userId: userId)
    }

    /// Keys of the teacher of the class this session belongs to (the same
    /// person essays are sealed to). nil when the session or its class can't
    /// be resolved; empty when the teacher has no essay key yet.
    private func outlineTeacherKeys(code: String?) async -> [DevicePublicKey]? {
        guard let code,
              let session = try? await supabase.lookupSession(code: code),
              let cid = session.classId,
              let tid = enrolledClasses.first(where: { $0.id == cid })?.teacherUserId,
              !tid.isEmpty else { return nil }
        guard let listed = try? await supabase.listDeviceKeys(userIds: [tid]) else { return nil }
        let keys = listed.filter { $0.userId == tid && WeftContentSeal.isGenuine($0) && !$0.isStudentKind }
        let checked = TeacherKeyPins.check(keys, me: userId, classId: cid)
        if let changed = checked.changedTo {
            pendingTeacherKey = (cid, changed)
            return nil
        }
        return checked.ok
    }

    /// Before Begin: if the outline was sealed to a teacher key that has since
    /// changed (the teacher reset their essay password), reseal it to the
    /// current key while the student can still replace it. Best effort.
    private func resealOutlineIfNeeded(sessionId sid: String) async {
        guard outlineAllowedBySession[sid] == true, let outline = myOutlines[sid],
              !outline.storagePath.isEmpty, !examRecipientKeys.isEmpty,
              let url = try? await supabase.signedOutlineURL(path: outline.storagePath),
              let (stored, _) = try? await URLSession.shared.data(from: url),
              let env = try? JSONDecoder().decode(WeftEnvelope.self, from: stored)
        else { return }
        let current = Set(examRecipientKeys.map(\.kid))
        if env.wraps.contains(where: { current.contains($0.recipientKid) }) { return }
        let aad = WeftContentSeal.outlineAAD(sessionId: sid, userId: userId)
        guard let plain = WeftContentSeal.openSealedFile(stored, userId: userId, expectedAAD: aad),
              let resealed = WeftContentSeal.sealedFileBytes(
                plain, userId: userId, teacherKeys: examRecipientKeys, aad: aad)
        else { return }
        let path = "\(userId)/\(sid)/\(UUID().uuidString.lowercased())\(WeftContentSeal.sealedFileSuffix)"
        do {
            try await supabase.uploadOutlineFile(data: resealed, path: path,
                                                 contentType: "application/octet-stream")
            let row = try? await supabase.upsertOutline(
                sessionId: sid, displayName: outline.displayName,
                originalName: outline.originalName, mimeType: outline.mimeType,
                sizeBytes: outline.sizeBytes, storagePath: path)
            if let row, row.storagePath == path {
                await supabase.removeOutlineObject(path: outline.storagePath)
                if signedIn { myOutlines[sid] = row }
            } else {
                await supabase.removeOutlineObject(path: path)
            }
        } catch {
            print("outline reseal failed: \(error)")
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
        await withTaskGroup(of: (String, [ClassWorkItem]).self) { group in
            for c in classes where c.id != skipId {
                if let cached = classWorkByClass[c.id] {
                    classOpenCounts[c.id] = cached.filter { $0.section == .active }.count
                    continue
                }
                group.addTask {
                    let work: [ClassWorkItem] =
                        (try? await SupabaseManager.shared.listClassWork(classId: c.id)) ?? []
                    return (c.id, work)
                }
            }
            for await (id, work) in group {
                classWorkByClass[id] = work
                classOpenCounts[id] = work.filter { $0.section == .active }.count
            }
        }
        refreshLiveExamOffer()
    }

    /// Pick the open assignment a signed-in Mac can enter without a code.
    /// Prefers the class the student is looking at.
    func refreshLiveExamOffer() {
        guard signedIn else { return }
        var offers: [LiveExamOffer] = []
        for c in enrolledClasses {
            let work = (c.id == selectedClassId) ? classWork : (classWorkByClass[c.id] ?? [])
            if let item = work.first(where: { $0.section == .active && $0.activeCode != nil }) {
                offers.append(LiveExamOffer(item: item, classId: c.id, className: c.name))
            }
        }
        if let cid = selectedClassId, let match = offers.first(where: { $0.classId == cid }) {
            liveExamOffer = match
        } else {
            liveExamOffer = offers.first
        }
    }

    /// Begin the live exam from the home banner — no code, no class drill-in.
    func enterLiveExam(_ offer: LiveExamOffer) {
        if selectedClassId != offer.classId {
            selectedClassId = offer.classId
            classWork = classWorkByClass[offer.classId] ?? [offer.item]
        }
        startWriting(offer.item)
    }

    /// Quiet refresh of every class's work so a bell-time launch shows up on
    /// enrolled Macs sitting on home. Does not flip isLoading (that would
    /// flash the whole home every eight seconds).
    func refreshStudentHomeQuiet() async {
        guard signedIn, route == .student, !studentHomeInFlight else { return }
        guard studentScreen != .exam, studentScreen != .checks else { return }
        let classes = enrolledClasses
        await withTaskGroup(of: (String, [ClassWorkItem]).self) { group in
            for c in classes {
                group.addTask {
                    let work: [ClassWorkItem] =
                        (try? await SupabaseManager.shared.listClassWork(classId: c.id)) ?? []
                    return (c.id, work)
                }
            }
            for await (id, work) in group {
                guard signedIn else { return }
                classWorkByClass[id] = work
                classOpenCounts[id] = work.filter { $0.section == .active }.count
                if selectedClassId == id { classWork = work }
            }
        }
        refreshLiveExamOffer()
    }

    func startStudentHomePolling() {
        guard signedIn, route == .student else { return }
        homePollGeneration += 1
        let generation = homePollGeneration
        homePollTask?.cancel()
        homePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self,
                      generation == self.homePollGeneration,
                      self.signedIn, self.route == .student,
                      self.studentScreen != .exam, self.studentScreen != .checks
                else { return }
                await self.refreshStudentHomeQuiet()
            }
        }
    }

    func stopStudentHomePolling() {
        homePollGeneration += 1
        homePollTask?.cancel()
        homePollTask = nil
    }

    // MARK: Essay password

    /// Work out whether this Mac holds the signed-in person's essay key.
    /// The server keeps one public key per person; this Mac's copy is only
    /// good if it matches that key (a reset on another Mac replaces it).
    func checkEssayKey() async {
        let me = userId
        guard signedIn, !me.isEmpty else { return }
        if accountRole == .student { await ensureStudentKey(); return }
        guard let listed = try? await supabase.listDeviceKeys(userIds: [me]) else { return }
        guard signedIn, userId == me else { return }
        var published = listed.first { $0.userId == me && WeftContentSeal.isGenuine($0) }
        if published?.isStudentKind == true {
            // This account was once set up as a student (a key the server can
            // rebuild). A teacher must pick an essay password instead.
            if ExamGate.inProgress { return }
            WeftContentSeal.forgetKey(userId: me)
            published = nil
            essayKeyState = .needsSetup
            return
        }
        if let local = WeftContentSeal.publishableKey(userId: me) {
            if published?.kid == local.kid { essayKeyState = .ready; return }
            if published == nil {
                // Saved here but never reached the server: publish it now.
                if (try? await supabase.upsertDeviceKey(userId: me, kid: local.kid,
                                                         publicX963: local.publicX963)) != nil,
                   signedIn, userId == me {
                    essayKeyState = .ready
                }
                return
            }
            // Never yank the key out from under a running exam.
            if ExamGate.inProgress { return }
            // The password was changed on another Mac: this copy is stale.
            WeftContentSeal.forgetKey(userId: me)
        }
        essayKeyState = published == nil ? .needsSetup : .needsUnlock
    }

    /// Students have no essay password (SAT-24): their key is rebuilt from a
    /// seed the server gives only to them, so Google sign-in is enough on any
    /// Mac. Publishes the public half if the server doesn't have it yet. On a
    /// network error the state stays unknown (never a password screen).
    private func ensureStudentKey() async {
        let me = userId
        guard let seed = try? await supabase.getMyStudentKeySeed(),
              let key = WeftContentSeal.studentKey(fromSeed: seed)
        else { return }
        guard signedIn, userId == me else { return }
        let pub = WeftContentSeal.publicRecord(of: key, userId: me)
        if WeftContentSeal.publishableKey(userId: me)?.kid != pub.kid {
            guard WeftContentSeal.saveKey(key, userId: me) else { return }
        }
        if let listed = try? await supabase.listDeviceKeys(userIds: [me]),
           !listed.contains(where: { $0.userId == me && $0.kid == pub.kid && $0.isStudentKind }) {
            guard (try? await supabase.upsertDeviceKey(userId: me, kid: pub.kid,
                                                         publicX963: pub.publicX963,
                                                         kind: "student")) != nil
            else { return }
        }
        guard signedIn, userId == me else { return }
        essayKeyState = .ready
    }

    /// First time: pick the essay password. nil = done, else the problem.
    func setEssayPassword(_ password: String) async -> String? {
        await saveNewEssayKey(password)
    }

    /// Forgot it: start over with a new password. Essays locked with the
    /// old one can't be opened by this person anymore.
    func resetEssayPassword(_ password: String) async -> String? {
        await saveNewEssayKey(password)
    }

    private func saveNewEssayKey(_ password: String) async -> String? {
        guard password.count >= WeftContentSeal.minPasswordLength else {
            return "Use at least \(WeftContentSeal.minPasswordLength) characters."
        }
        let me = userId
        guard signedIn, !me.isEmpty else { return "Sign in first." }
        let key = await Task.detached(priority: .userInitiated) {
            WeftContentSeal.deriveKey(password: password, userId: me)
        }.value
        guard let key else { return "Couldn't make your key. Try again." }
        let pub = WeftContentSeal.publicRecord(of: key, userId: me)
        do {
            try await supabase.upsertDeviceKey(userId: me, kid: pub.kid, publicX963: pub.publicX963)
        } catch {
            return describe(error)
        }
        guard signedIn, userId == me else { return "Signed out." }
        guard WeftContentSeal.saveKey(key, userId: me) else {
            return "Couldn't save your key on this Mac."
        }
        essayKeyState = .ready
        return nil
    }

    /// Type the essay password on this Mac. nil = unlocked, else the problem.
    func unlockEssays(_ password: String) async -> String? {
        let me = userId
        guard signedIn, !me.isEmpty else { return "Sign in first." }
        let key = await Task.detached(priority: .userInitiated) {
            WeftContentSeal.deriveKey(password: password, userId: me)
        }.value
        guard let key else { return "Couldn't make your key. Try again." }
        let pub = WeftContentSeal.publicRecord(of: key, userId: me)
        let listed: [DevicePublicKey]
        do { listed = try await supabase.listDeviceKeys(userIds: [me]) }
        catch { return describe(error) }
        guard signedIn, userId == me else { return "Signed out." }
        guard listed.contains(where: { $0.userId == me && $0.kid == pub.kid }) else {
            return "That's not your essay password."
        }
        guard WeftContentSeal.saveKey(key, userId: me) else {
            return "Couldn't save your key on this Mac."
        }
        essayKeyState = .ready
        return nil
    }

    /// Reveal sealed HTML when content_html is empty. Unreadable ciphertext
    /// stays empty so the caller can show an honest sealed-paper state.
    private func revealHTML(_ html: String, cipher: WeftEnvelope?) -> String {
        if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return html }
        guard let cipher else { return html }
        return WeftContentSeal.openHTML(cipher, userId: userId) ?? ""
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
    /// Score and comments come from the RPC; the paper is loaded separately
    /// so the student portal never has to fetch it.
    func loadReturnedWork() async {
        guard signedIn else { return }
        let actor = userId
        if essayKeyState != .ready { await checkEssayKey() }
        do {
            var items = try await supabase.getMyReturnedWork()
            if let bodies = try? await supabase.listOwnSubmissionBodies(ids: items.map(\.submissionId)) {
                let byId = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0) })
                for i in items.indices {
                    guard let body = byId[items[i].submissionId] else { continue }
                    if items[i].contentHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items[i].contentHtml = body.contentHtml
                    }
                    if items[i].contentCipher == nil {
                        items[i].contentCipher = body.contentCipher
                    }
                }
            }
            // The essay was sealed to the teacher; on return the teacher's
            // Mac added a wrap for this student's key (SAT-24).
            if let wraps = try? await supabase.listMyReturnWraps(submissionIds: items.map(\.submissionId)) {
                for i in items.indices {
                    guard let w = wraps[items[i].submissionId], var env = items[i].contentCipher,
                          !env.wraps.contains(where: { $0.recipientKid == w.recipientKid })
                    else { continue }
                    env.wraps.append(w)
                    items[i].contentCipher = env
                }
            }
            let feedbackIds = items.compactMap { item in
                item.feedbackStudentWrap == nil ? nil : item.submissionId
            }
            let feedbackKeys = (try? await supabase.gradeFeedbackReturnKeys(submissionIds: feedbackIds)) ?? [:]
            guard signedIn, userId == actor, !Task.isCancelled else { return }
            returnedWork = items.map { item in
                var copy = item
                copy.contentHtml = revealHTML(item.contentHtml, cipher: item.contentCipher)
                if copy.contentHtml.isEmpty, item.contentCipher != nil {
                    copy.contentHtml = "<p><em>This paper can't open on your account yet. Ask your teacher to share it again.</em></p>"
                }
                if let essay = item.contentCipher {
                    let aad = WeftContentSeal.quoteAAD(submissionId: item.submissionId)
                    for i in copy.comments.indices {
                        guard (copy.comments[i].quote ?? "").isEmpty,
                              let qc = copy.comments[i].quoteCipher else { continue }
                        copy.comments[i].quote = WeftContentSeal.openText(
                            qc, underEssay: essay, userId: userId, aad: aad)
                    }
                }
                if let cipher = item.feedbackCipher {
                    var opened: String?
                    if let wrap = item.feedbackStudentWrap, let key = feedbackKeys[item.submissionId] {
                        opened = try? WeftContentSeal.openReturnedGradeFeedback(
                            cipher, studentWrap: wrap, submissionId: item.submissionId, studentReturnKey: key)
                    }
                    copy.feedback = opened ?? ""
                    copy.feedbackUnavailable = opened == nil
                }
                return copy
            }
        } catch {
            guard signedIn, userId == actor, !Task.isCancelled else { return }
            errorMessage = describe(error)
        }
    }

    /// Join a class by code; on success refresh the home so the new class is
    /// selected. Returns the joined class, or nil with errorMessage set.
    @discardableResult
    func joinClass(code: String) async -> ClassRoom? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard signedIn else {
            // Mock path (dev / unsigned): pretend the join worked.
            return ClassRoom(id: "mock", name: "Your class", joinCode: normalized, archivedAt: nil)
        }
        errorMessage = nil
        do {
            let joined = try await supabase.joinClass(code: normalized, displayName: displayName)
            // Don't wait for the home refresh: the join screen used to sit on
            // "Joining…" until myClasses returned, so a successful enroll never
            // showed the success card. Home's .task reloads when we land there.
            selectedClassId = joined.id
            classWork = []
            let joinedId = joined.id
            Task {
                await loadStudentHome()
                if enrolledClasses.contains(where: { $0.id == joinedId }) {
                    selectedClassId = joinedId
                }
            }
            return joined
        } catch {
            let raw = describe(error).lowercased()
            if raw.contains("class not found") || raw.contains("no data") {
                errorMessage = "That class code wasn't found. Check the code and try again."
            } else {
                errorMessage = describe(error)
            }
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
            // The live card IS the proctoring monitor, so the roster is loaded
            // on EVERY home load (returning from grading or the editor must
            // never leave a roster frozen at launch time) and the five-second
            // sweep runs for as long as the session is live.
            if liveSession != nil {
                await loadLiveRoster()
                guard signedIn else { return }   // signed out during the roster load
                startRosterPolling()
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
            classSessions = previewSessions.filter { $0.classId == cid && $0.status != "archived" }
            return
        }
        do {
            let sessions = try await supabase.listClassSessions(classId: cid, teacherUserId: userId)
            guard teacherSelectedClassId == cid else { return }   // switched class mid-flight; drop stale payload
            classSessions = sessions.filter { $0.status != "archived" }
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
    /// `fileIds` is the editor's attached-file list (nil = leave the question's
    /// existing files alone, for callers that don't manage attachments).
    /// `removedFiles` are files the teacher detached: destroyed only once the
    /// saved question no longer references them.
    /// `carryForward` is nil for draft 1 and new assignments (the switch is
    /// only shown from draft 2 on); nil leaves the stored value alone.
    func saveAssignment(title: String, prompt: String, wordLimit: Int?, timeLimitMinutes: Int?,
                        spellcheckEnabled: Bool = true, outlineAllowed: Bool = false,
                        carryForward: Bool? = nil,
                        links: [(name: String, href: String)] = [],
                        fileIds: [String]? = nil,
                        removedFiles: [TeacherFile] = []) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !p.isEmpty else {
            errorMessage = "An assignment needs a title and a prompt."
            return
        }
        errorMessage = nil
        let qid = editingAssignment?.questions.first?.id ?? "q-\(UUID().uuidString.prefix(8))"
        let existingFileIds = editingAssignment?.questions.first?.fileIds ?? []
        let savedFileIds = fileIds ?? existingFileIds
        if !signedIn {
            // Preview keeps the links on the question so the editor round-trips,
            // but no backend pool ids exist; store the hrefs as the "ids" stand-in.
            // spellcheckEnabled is stored on the local Assignment so ExamView can
            // read it back in preview (no backend session required).
            let q = Question(id: qid, kind: "essay", prompt: p, wordLimit: wordLimit,
                             fileIds: savedFileIds, urlIds: links.map(\.href))
            if let id = editingAssignment?.id, let idx = assignments.firstIndex(where: { $0.id == id }) {
                assignments[idx] = Assignment(id: id, title: t,
                    versionGroupId: assignments[idx].versionGroupId,
                    versionNumber: assignments[idx].versionNumber,
                    questions: [q], timeLimitMinutes: timeLimitMinutes,
                    spellcheckEnabled: spellcheckEnabled, outlineAllowed: outlineAllowed,
                    carryForward: carryForward ?? assignments[idx].carryForward)
            } else {
                assignments.append(Assignment(id: "local-\(UUID().uuidString.prefix(6))", title: t,
                    versionGroupId: "g-\(UUID().uuidString.prefix(6))", versionNumber: 1,
                    questions: [q], timeLimitMinutes: timeLimitMinutes,
                    spellcheckEnabled: spellcheckEnabled, outlineAllowed: outlineAllowed))
            }
            previewRemoveFiles(removedFiles)
            teacherScreen = .home
            return
        }
        do {
            // Reconcile the approved links against the rows this question
            // already owns instead of inserting a fresh set on every save: that
            // duplicated the test_urls pool each time and orphaned the rows the
            // question stopped referencing.
            let plan = try await supabase.planTestURLs(
                userId: userId,
                existingIds: editingAssignment?.questions.first?.urlIds ?? [],
                links: links)
            let q = Question(id: qid, kind: "essay", prompt: p, wordLimit: wordLimit,
                             fileIds: savedFileIds, urlIds: plan.ids)
            if let id = editingAssignment?.id {
                try await supabase.updateTest(id: id, title: t, questions: [q],
                                             timeLimitMinutes: timeLimitMinutes,
                                             spellcheckEnabled: spellcheckEnabled,
                                             outlineAllowed: outlineAllowed,
                                             carryForward: carryForward)
            } else {
                _ = try await supabase.createTest(teacherUserId: userId, title: t,
                                                  questions: [q],
                                                  timeLimitMinutes: timeLimitMinutes,
                                                  spellcheckEnabled: spellcheckEnabled,
                                                  outlineAllowed: outlineAllowed)
            }
            // Refresh FIRST: the cleanup below reads the teacher's live set of
            // questions to decide what nothing references any more.
            await loadTeacherHome()
            await cleanUpUnreferencedAttachments(urlIds: plan.orphanIds, files: removedFiles)
            teacherScreen = .home
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Teacher: assignment attachments (the editor's files + links)

    /// 50 MB cap on one reference file, matching the Electron editor's
    /// uploadEssayFile (teachers attach passages and scans, not media).
    static let referenceFileMaxBytes = 50 * 1024 * 1024

    /// Reference files picked in the signed-out preview, so the dev gallery's
    /// editor round-trips a real pick without a backend.
    var previewFiles: [String: TeacherFile] = [:]

    /// An existing assignment's saved attachments, as the editor needs them.
    /// nil means the load FAILED, as distinct from "this assignment has none":
    /// the editor keeps Save disabled on nil rather than writing an empty allow
    /// list over a whitelist it never managed to read.
    func editorAttachments(for assignment: Assignment?) async -> EditorAttachments? {
        guard let q = assignment?.questions.first else { return EditorAttachments() }
        if !signedIn {
            // Preview stores the hrefs themselves as the "ids" (see saveAssignment).
            return EditorAttachments(links: q.urlIds.map { (name: $0, href: $0) },
                                     files: q.fileIds.compactMap { previewFiles[$0] })
        }
        do {
            let links = try await supabase.listTeacherLinks(ids: q.urlIds)
            let files = try await supabase.listTeacherFiles(ids: q.fileIds)
            return EditorAttachments(
                links: links.map { (name: $0.displayName.isEmpty ? $0.url : $0.displayName,
                                    href: $0.url) },
                files: files)
        } catch {
            return nil
        }
    }

    /// Upload one reference file into the private `essay-files` bucket and
    /// record it in `test_files`, returning the new row for the editor to list.
    /// The bytes go up FIRST: the row is what the exam reads, so it must never
    /// exist before the bytes do (the uploadOutline ordering). A row insert that
    /// fails takes the just-uploaded object back out. nil = nothing was
    /// attached, with the reason in errorMessage.
    func attachReferenceFile(fileURL: URL, contentType: String) async -> TeacherFile? {
        errorMessage = nil
        let name = fileURL.lastPathComponent
        // The picker's URL is security-scoped; harmless when not sandboxed.
        let data: Data
        do {
            data = try await Self.readPickedFile(fileURL, maxBytes: Self.referenceFileMaxBytes)
        } catch is FileTooLarge {
            errorMessage = "Reference files can be up to 50 MB. \(name) is larger than that."
            return nil
        } catch {
            errorMessage = "Couldn't read \(name). \(describe(error))"
            return nil
        }
        guard !data.isEmpty else {
            errorMessage = "\(name) is empty, so there is nothing for students to read."
            return nil
        }
        if !signedIn {
            let local = TeacherFile(id: "local-\(UUID().uuidString.prefix(6))",
                                    originalName: name, mimeType: contentType,
                                    sizeBytes: data.count, storagePath: "")
            previewFiles[local.id] = local
            return local
        }
        let path = "\(userId)/\(SupabaseManager.safeReferenceFileName(name))"
        do {
            try await supabase.uploadEssayFile(data: data, path: path, contentType: contentType)
        } catch {
            errorMessage = "Couldn't upload \(name). \(describe(error))"
            return nil
        }
        do {
            guard let row = try await supabase.createTestFile(
                userId: userId, originalName: name, mimeType: contentType,
                sizeBytes: data.count, storagePath: path) else {
                // Uploaded but unrecorded: nothing can ever reference those
                // bytes, so take them back out (the Electron editor's cleanup).
                await supabase.removeEssayFileObject(path: path)
                errorMessage = "Couldn't record \(name). Try attaching it again."
                return nil
            }
            return row
        } catch {
            await supabase.removeEssayFileObject(path: path)
            errorMessage = "Couldn't record \(name). \(describe(error))"
            return nil
        }
    }

    /// Cancelling an editor sitting: destroy the reference files it uploaded
    /// that no saved assignment references. Attaching uploads immediately (the
    /// bytes must exist before the row), so without this a cancelled edit would
    /// leave unreachable objects in the bucket forever.
    func discardUnsavedAttachments(_ files: [TeacherFile]) async {
        guard !files.isEmpty else { return }
        await cleanUpUnreferencedAttachments(urlIds: [], files: files)
    }

    /// Delete pool rows nothing references any more. `assignments` must already
    /// be current (loadTeacherHome) so the just-saved question counts. Anything
    /// still referenced by ANY version survives: createDraftTest copies its
    /// parent's fileIds and urlIds, so a blind cleanup here would strip the
    /// other draft's reference files and website whitelist.
    private func cleanUpUnreferencedAttachments(urlIds: [String], files: [TeacherFile]) async {
        var referencedLinks: Set<String> = []
        var referencedFiles: Set<String> = []
        for a in assignments {
            for q in a.questions {
                referencedLinks.formUnion(q.urlIds)
                referencedFiles.formUnion(q.fileIds)
            }
        }
        let staleFiles = files.filter { !referencedFiles.contains($0.id) }
        if signedIn {
            await supabase.deleteTestURLs(ids: urlIds.filter { !referencedLinks.contains($0) })
            for file in staleFiles where !file.id.hasPrefix("local-") {
                do {
                    // A refused row delete leaves the bytes alone: the row is
                    // what a question resolves, so bytes must never outlive it
                    // the other way round (the deleteOutline ordering).
                    if try await supabase.deleteTestFile(id: file.id), !file.storagePath.isEmpty {
                        await supabase.removeEssayFileObject(path: file.storagePath)
                    }
                } catch {
                    print("reference file delete failed: \(error)")
                }
            }
        } else {
            previewRemoveFiles(staleFiles)
        }
    }

    /// Preview-only: forget locally attached files (no backend rows exist).
    private func previewRemoveFiles(_ files: [TeacherFile]) {
        for f in files { previewFiles[f.id] = nil }
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
                                   outlineAllowed: source.outlineAllowed,
                                   carryForward: true)
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
                                testId: testId, classId: classId, status: "open",
                                createdAt: Date(),
                                opensAt: scheduleLaunch ? scheduledLaunchAt : nil)
            liveSession = s
            roster = RosterStudent.sample
            previewSessions.insert(s, at: 0)
            classSessions = previewSessions.filter { $0.classId == classId }   // history shows the open row immediately
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let opens = scheduleLaunch ? scheduledLaunchAt : nil
            liveSession = try await supabase.launchSession(testId: testId, classId: classId,
                                                           teacherUserId: userId, teacherIP: nil,
                                                           opensAt: opens)
            await loadLiveRoster()
            startRosterPolling()           // students join AFTER the launch; the card must follow them
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

    /// Load the live monitor's roster. `quiet` is for the five-second sweep: a
    /// blip on one tick must not throw a banner over the teacher's screen (or
    /// wipe an unrelated one), and the next tick is five seconds away.
    func loadLiveRoster(quiet: Bool = false) async {
        guard signedIn, let sid = liveSession?.id else { return }
        do {
            let students = try await supabase.listSessionStudents(sessionId: sid)
            let pulses = (try? await supabase.listSessionPulse(sessionId: sid)) ?? []
            guard signedIn, liveSession?.id == sid else { return }
            var byStudent: [String: EssayPulse] = [:]
            for p in pulses {
                if let existing = byStudent[p.studentId],
                   let existingAt = existing.updatedAt, let nextAt = p.updatedAt,
                   existingAt >= nextAt { continue }
                byStudent[p.studentId] = p
            }
            if roster != students { roster = students }
            if essayPulse != byStudent { essayPulse = byStudent }
        } catch {
            guard signedIn, !quiet else { return }
            errorMessage = describe(error)
        }
    }

    /// Start (or restart) the live-roster sweep: every five seconds while a
    /// session is open and the teacher is in the teacher view. This is the
    /// proctoring monitor, so it has to move on its own; without it a student
    /// who joins or starts writing after launch never appears at all (the
    /// retired Electron build subscribed to postgres_changes on `students`,
    /// which the native client has no channel for, so a poll at the cadence
    /// the marketing pages promise is the honest equivalent).
    ///
    /// Self-terminating: every tick re-checks the conditions, so ending the
    /// session, signing out or leaving the teacher view stops the sweep without
    /// another call site.
    func startRosterPolling() {
        guard signedIn, liveSession != nil else { return }
        rosterPollGeneration += 1
        let generation = rosterPollGeneration
        rosterPollTask?.cancel()
        rosterPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self,
                      generation == self.rosterPollGeneration,
                      self.signedIn, self.route == .teacher,
                      self.liveSession != nil else { return }
                await self.loadLiveRoster(quiet: true)
            }
        }
    }

    /// Stop the sweep (session ended, signed out, left the teacher view).
    func stopRosterPolling() {
        rosterPollGeneration += 1
        rosterPollTask?.cancel()
        rosterPollTask = nil
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
        stopRosterPolling()   // nothing live to sweep
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
                classSessions = previewSessions.filter { $0.classId == cid && $0.status != "archived" }
            }
        }
    }

    /// Hide a session from the history list. Essays stay on the server; the
    /// row just stops appearing. An open session is closed as part of this.
    func archiveSession(_ session: ExamSession) async {
        errorMessage = nil
        if signedIn {
            do {
                try await supabase.archiveSession(id: session.id)
            } catch {
                errorMessage = describe(error)
                return
            }
        } else if let i = previewSessions.firstIndex(where: { $0.id == session.id }) {
            previewSessions[i].status = "archived"
        }
        classSessions?.removeAll { $0.id == session.id }
        if liveSession?.id == session.id {
            liveSession = nil
            stopRosterPolling()
            roster = []
        }
        if gradingSession?.id == session.id {
            gradingSession = nil
        }
    }

    /// Permanently delete a session and everything keyed to it (essays, roster,
    /// grades, comments, outlines). Closed/archived only — end a live session
    /// first. Falls back to a clear error if RLS refuses the DELETE.
    func deleteSession(_ session: ExamSession) async {
        errorMessage = nil
        guard session.status != "open" else {
            errorMessage = "End the session before deleting it."
            return
        }
        if signedIn {
            do {
                try await supabase.deleteSession(id: session.id)
            } catch {
                errorMessage = describe(error)
                return
            }
        } else {
            previewSessions.removeAll { $0.id == session.id }
        }
        classSessions?.removeAll { $0.id == session.id }
        if gradingSession?.id == session.id {
            gradingSession = nil
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
        gradingComments = [:]
        clearDraftHistory()
        gradesFresh = false
        teacherScreen = .grading
        // ReviewGradingView's .task owns the load (auto-cancelled with the
        // view), the same shape as openReturnedWork. Firing one here as
        // well ran the four queries twice on every open.
    }

    func loadGrading() async {
        // Keyed to the EXPLICIT grading session, never liveSession: closed
        // sessions stay gradeable forever. nil (dev gallery / #Preview) keeps
        // the silent no-op so the grading screen's mock fallback renders.
        guard let sid = gradingSession?.id else { return }
        // openGrading already clears gradesFresh on the first load.
        if !signedIn {
            gradingSubmissions = []
            grades = [:]
            gradingOutlines = []
            gradingComments = [:]
            return
        }
        let actor = userId
        errorMessage = nil
        do {
            let subs = try await supabase.listSessionSubmissions(sessionId: sid)
            let ros  = try await supabase.listSessionStudents(sessionId: sid)
            let g    = try await supabase.listGrades(submissionIds: subs.map(\.id))
            // Outlines are auxiliary grading context: best-effort, so a
            // refused/failed fetch never makes the essays themselves
            // unreachable (they're the point of this screen).
            let outlines = (try? await supabase.listSessionOutlines(sessionId: sid)) ?? []
            let comments = (try? await supabase.listEssayComments(sessionId: sid)) ?? []
            // The teacher may have opened a DIFFERENT session while we loaded;
            // a stale payload must never overwrite it or set gradesFresh.
            guard gradingSession?.id == sid, signedIn, userId == actor, !Task.isCancelled else { return }
            gradingSubmissions = subs.map { sub in
                var copy = sub
                copy.contentHtml = revealHTML(sub.contentHtml ?? "", cipher: sub.contentCipher)
                if copy.contentHtml?.isEmpty == true, sub.contentCipher != nil {
                    copy.contentHtml = "<p>This essay is sealed to another Mac. Open Weft on the Mac that holds the class keys to read it.</p>"
                }
                return copy
            }
            gradingRoster = ros
            gradingOutlines = outlines
            let cipherBySub = Dictionary(subs.compactMap { s in s.contentCipher.map { (s.id, $0) } },
                                         uniquingKeysWith: { a, _ in a })
            var bySub: [String: [EssayComment]] = [:]
            for var c in comments {
                let sid = c.submissionId ?? ""
                if c.quote.isEmpty, let qc = c.quoteCipher, let essay = cipherBySub[sid] {
                    c.quote = WeftContentSeal.openText(
                        qc, underEssay: essay, userId: userId,
                        aad: WeftContentSeal.quoteAAD(submissionId: sid)) ?? ""
                }
                bySub[sid, default: []].append(c)
            }
            gradingComments = bySub
            grades = Dictionary(uniqueKeysWithValues: g.map { grade in
                var copy = grade
                if let cipher = grade.feedbackCipher {
                    copy.feedback = try? WeftContentSeal.openGradeFeedback(
                        cipher, submissionId: grade.submissionId, userId: actor)
                }
                return (copy.submissionId, copy)
            })
            gradesFresh = true   // grades cache now reflects the DB for THIS session
        } catch {
            guard gradingSession?.id == sid, signedIn, userId == actor, !Task.isCancelled else { return }
            errorMessage = describe(error)
        }
    }

    /// Save (and optionally share) a grade. essay_grades requires session_id +
    /// student_id, taken from the submission. Sharing keeps the original release
    /// timestamp if already shared; saving-without-sharing never un-shares.
    ///
    /// Returns whether the write was ACCEPTED. The grading screen holds the
    /// teacher's typing (and its dirty flag) until it sees true, so a failed
    /// save can never be mistaken for a saved one.
    @discardableResult
    func saveGrade(submission: TeacherSubmission, points: Double?, pointsPossible: Double,
                   feedback: String, share: Bool) async -> Bool {
        // Not signed in there is nothing to write, so report it as not saved
        // rather than letting a caller clear its unsaved state on a no-op.
        guard signedIn else { return false }
        guard let sid = submission.sessionId, let stid = submission.studentId else {
            errorMessage = "This submission is missing its session or student."
            return false
        }
        guard gradesFresh, gradingSession?.id == sid else {
            errorMessage = "Reopen grading to load the current grade before saving."
            return false
        }
        let actor = userId
        let existing = grades[submission.id]
        let firstRelease = share && existing?.isReleased != true
        let isReturning = share || existing?.isReleased == true
        let feedbackLocked = existing?.isFeedbackLocked == true
        // A score edit can preserve locked feedback. First release must also
        // wrap the feedback key for the student, which requires an unlocked key.
        guard !feedbackLocked || (feedback.isEmpty && !firstRelease) else {
            errorMessage = "Unlock your essay key and reopen grading to edit or return the saved feedback."
            return false
        }
        errorMessage = nil
        do {
            var feedbackCipher: WeftEnvelope?
            var feedbackStudentWrap: WeftSealedText?
            if !feedback.isEmpty {
                let staff = try await supabase.gradeFeedbackStaffKeys(submissionId: submission.id)
                guard let local = WeftContentSeal.publishableKey(userId: actor),
                      staff.contains(where: { $0.userId == actor && $0.kid == local.kid }) else {
                    throw SupabaseError.auth("Unlock your essay key on this Mac to seal the feedback.")
                }
                var feedbackReturnKey: Data?
                if isReturning {
                    guard let keys = try? await supabase.gradeFeedbackReturnKeys(submissionIds: [submission.id]),
                          let key = keys[submission.id] else {
                        throw SupabaseError.auth("The student’s feedback key is unavailable. Try sharing again.")
                    }
                    feedbackReturnKey = key
                }
                do {
                    (feedbackCipher, feedbackStudentWrap) = try WeftContentSeal.sealGradeFeedback(
                        feedback, submissionId: submission.id, staffKeys: staff, studentReturnKey: feedbackReturnKey)
                } catch {
                    // A staff key that isn't a genuine essay-password key, or a
                    // malformed student key. Never seal past it; keep the text.
                    throw SupabaseError.auth("Weft couldn't seal this feedback to the class's staff keys, so nothing was saved. Your comment is still here; try again, or ask your school admin to check the staff keys.")
                }
            }
            // The return wrap for the essay is independent of the feedback.
            var essayStudentWrap: WeftEnvelopeWrap?
            if isReturning, let envelope = submission.contentCipher {
                essayStudentWrap = await returnWrap(envelope: envelope, studentId: stid)
            }
            guard signedIn, userId == actor else { return false }
            var saved = try await supabase.saveGrade(
                submissionId: submission.id, sessionId: sid, studentId: stid, points: points,
                pointsPossible: pointsPossible, feedbackCipher: feedbackCipher,
                feedbackStudentWrap: feedbackStudentWrap, replaceFeedback: !feedbackLocked,
                releasedAt: firstRelease ? SupabaseManager.nowISO() : nil,
                studentWrap: essayStudentWrap, expectedUpdatedAt: existing?.updatedAt)
            guard signedIn, userId == actor else { return true }
            if gradingSession?.id == sid {
                saved.feedback = feedbackLocked ? nil : feedback
                grades[submission.id] = saved
            }
            if share, submission.contentCipher != nil, essayStudentWrap == nil, gradingSession?.id == sid {
                errorMessage = "Shared. Weft couldn't unlock the paper for the student yet, so they'll see the grade but not the essay. Share again in a moment; if it keeps happening, the student needs to sign in to Weft once."
            }
            if firstRelease {
                Task { await supabase.notify("grades_published", body: ["submission_id": submission.id]) }
            }
            return true
        } catch {
            if signedIn, userId == actor { errorMessage = describe(error) }
            return false
        }
    }

    /// Pin a margin note to a passage in the student's paper. `rangeStart` /
    /// `rangeEnd` are the passage's UTF-16 offsets in the paper's plain text
    /// (PaperText.plain). Shared comments reach the student when the grade
    /// is released; private ones never do.
    @discardableResult
    func addEssayComment(submission: TeacherSubmission, quote: String, body: String,
                         rangeStart: Int, rangeEnd: Int, isPrivate: Bool = false) async -> Bool {
        guard signedIn else { return false }
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !note.isEmpty,
              rangeStart >= 0, rangeEnd > rangeStart,
              let sessionId = submission.sessionId ?? gradingSession?.id,
              let studentId = submission.studentId
        else { return false }
        // The quote is the student's own words, so it is sealed with the
        // essay's key (teacher + student only). No key, no comment: a readable
        // quote is never sent.
        guard let essay = submission.contentCipher,
              let sealed = WeftContentSeal.sealText(
                q, underEssay: essay, userId: userId,
                aad: WeftContentSeal.quoteAAD(submissionId: submission.id))
        else {
            errorMessage = "This essay is locked to another Mac, so a quote can't be locked to it here."
            return false
        }
        do {
            guard var row = try await supabase.createEssayComment(
                submissionId: submission.id, sessionId: sessionId,
                studentId: studentId, rangeStart: rangeStart, rangeEnd: rangeEnd,
                quoteCipher: sealed, body: note,
                visibility: isPrivate ? "private" : "shared")
            else { return false }
            row.quote = q
            if row.author == nil { row.author = userId }
            if row.createdAt == nil { row.createdAt = Date() }
            gradingComments[submission.id, default: []].append(row)
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// Change a margin note's text. The sealed quote is left alone.
    @discardableResult
    func updateEssayCommentBody(_ comment: EssayComment, body: String) async -> Bool {
        let note = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return false }
        return await patchComment(comment) { try await self.supabase.updateEssayCommentBody(id: comment.id, body: note) }
    }

    /// Make a margin note private (teachers only) or shared with the student.
    @discardableResult
    func setEssayCommentPrivate(_ comment: EssayComment, isPrivate: Bool) async -> Bool {
        await patchComment(comment) { try await self.supabase.setEssayCommentVisibility(id: comment.id, isPrivate: isPrivate) }
    }

    /// Resolve (hide from the margin) or reopen a margin note.
    @discardableResult
    func setEssayCommentResolved(_ comment: EssayComment, resolved: Bool) async -> Bool {
        await patchComment(comment) { try await self.supabase.setEssayCommentResolved(id: comment.id, resolved: resolved) }
    }

    @discardableResult
    func deleteEssayComment(_ comment: EssayComment) async -> Bool {
        guard signedIn, let sub = comment.submissionId else { return false }
        do {
            guard try await supabase.deleteEssayComment(id: comment.id) else {
                errorMessage = "This comment couldn't be deleted. It may belong to a session you don't run."
                return false
            }
            gradingComments[sub]?.removeAll { $0.id == comment.id }
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// Run one comment PATCH and fold the returned state into the cache.
    private func patchComment(_ comment: EssayComment,
                              _ write: () async throws -> SupabaseManager.EssayCommentState?) async -> Bool {
        guard signedIn, let sub = comment.submissionId else { return false }
        do {
            guard let state = try await write() else {
                errorMessage = "This comment couldn't be changed. It may belong to a session you don't run."
                return false
            }
            if let i = gradingComments[sub]?.firstIndex(where: { $0.id == comment.id }) {
                gradingComments[sub]?[i].body = state.body
                gradingComments[sub]?[i].visibility = state.visibility
                gradingComments[sub]?[i].resolvedAt = state.resolvedAt
                gradingComments[sub]?[i].updatedAt = state.updatedAt
            }
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    // MARK: - Student flow transitions

    /// Begin an attempt at `item`: stage the assignment and go to the pre-exam
    /// checks. Fetching the real test/questions for the active session is the one
    /// remaining backend hop; until then we stage a faithful placeholder built
    /// from the work row so the exam screen reads correctly.
    func startWriting(_ item: ClassWorkItem) {
        errorMessage = nil
        // Signed in, the real test replaces this placeholder before Begin.
        // Signed out, a later draft carries forward the mock returned Draft 1
        // so SAT-5 is demoable without a backend.
        let version = item.activeVersion ?? 1
        activeAssignment = Assignment(
            id: item.activeSessionId ?? item.id,
            title: item.title,
            versionGroupId: item.versionGroupId,
            versionNumber: version,
            questions: [Question(id: "q", kind: "essay",
                                 prompt: Assignment.sample.questions.first?.prompt
                                     ?? "Respond to the prompt your teacher set.",
                                 wordLimit: 600)],
            timeLimitMinutes: nil,
            carryForward: !signedIn && version > 1)
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
        examDeadline = nil
        markedWriting = false
        examDraftHTML = nil
        examDraftCarried = false
        examCarryNote = nil
        examMaterialsFailed = false
        examLockState = nil
        pendingTeacherKey = nil
        examRecipientKeys = []
        examUnreadableDraft = false
        allowFreshOverUnreadable = false
        examResolveCode = item.activeCode
        if signedIn, let code = item.activeCode {
            Task {
                examMaterialsLoading = true
                if let test = await resolveActiveExam(code: code) {
                    await loadExamMaterials(from: test)
                } else {
                    examMaterialsLoading = false
                }
            }
        }
        studentScreen = .checks
    }

    /// Load reference files + links for a test we already resolved. Avoids a
    /// second lookupSession + getTest on the Begin path.
    func loadExamMaterials(from test: Assignment) async {
        guard signedIn else { examMaterialsLoading = false; return }
        examMaterialsLoading = true
        examMaterialsFailed = false
        defer { examMaterialsLoading = false }
        do {
            let q = test.questions.first
            let files = try await supabase.listTestFiles(ids: q?.fileIds ?? [])
            let links = try await supabase.listTestURLs(ids: q?.urlIds ?? [])
            examFiles = files
            examLinks = links
        } catch {
            examMaterialsFailed = true
        }
    }

    func retryExamMaterials() async {
        guard signedIn, let test = activeAssignment else { return }
        await loadExamMaterials(from: test)
    }

    /// Re-run session lookup after Begin was blocked by a failed resolve.
    func retryResolveActiveExam() async {
        guard signedIn, let code = examResolveCode, !code.isEmpty else { return }
        errorMessage = nil
        examMaterialsLoading = true
        if let test = await resolveActiveExam(code: code) {
            await loadExamMaterials(from: test)
        } else {
            examMaterialsLoading = false
        }
    }

    /// Resolve the open session + REAL test for `code`, replacing the staged
    /// placeholder. Submissions must carry the real question id, so the
    /// session is exposed ONLY after the real test is staged — autosave gates
    /// on `activeExamSession`, and a session paired with the placeholder
    /// question id would write a corrupt submission row.
    @discardableResult
    func resolveActiveExam(code: String) async -> Assignment? {
        guard signedIn else { return nil }
        do {
            guard let session = try await supabase.lookupSession(code: code),
                  session.status == "open" else {
                errorMessage = "This assignment isn't open anymore."
                return nil
            }
            if let opens = session.opensAt, opens > Date() {
                let when = opens.formatted(date: .abbreviated, time: .shortened)
                errorMessage = "This exam opens at \(when)."
                return nil
            }
            guard let testId = session.testId,
                  let test = try await supabase.getTest(id: testId) else {
                errorMessage = "Couldn't load this assignment's prompt. Go back and try again."
                return nil
            }
            // Lock state first: exposing the session enables Begin, and Begin
            // must never run on a previous exam's keys.
            await loadExamRecipientKeys(classId: session.classId)
            activeAssignment = test
            activeExamSession = session
            outlineAllowedBySession[session.id] = test.outlineAllowed
            if test.outlineAllowed, myOutlines[session.id] == nil,
               let mine = try? await supabase.getMyOutline(sessionId: session.id, userId: userId) {
                myOutlines[session.id] = mine
            }
            return test
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Work out who this exam's essay is sealed to: the teacher's one essay
    /// key. Essays are never sent unsealed, so with no teacher key the exam
    /// cannot start. On a network error the previous state is kept, so a
    /// reload never blanks the key of an exam that is already running.
    private func loadExamRecipientKeys(classId: String?) async {
        guard let cid = classId,
              let tid = enrolledClasses.first(where: { $0.id == cid })?.teacherUserId,
              !tid.isEmpty else {
            examRecipientKeys = []
            examLockState = .unknownTeacher
            return
        }
        let me = userId
        guard let listed = try? await supabase.listDeviceKeys(userIds: [tid]) else { return }
        guard signedIn, userId == me else { return }
        let teacherKeys = listed.filter {
            $0.userId == tid && WeftContentSeal.isGenuine($0) && !$0.isStudentKind
        }
        let checked = TeacherKeyPins.check(teacherKeys, me: me, classId: cid)
        if let changed = checked.changedTo {
            examRecipientKeys = []
            pendingTeacherKey = (cid, changed)
            examLockState = .teacherKeyChanged
            return
        }
        examRecipientKeys = checked.ok
        examLockState = checked.ok.isEmpty ? .noTeacherKey : .ready
    }

    static let teacherKeyChangedMessage = "Your teacher's lock is different from last time. That happens when a teacher resets their essay password. Ask your teacher. If they did, choose Trust new lock."

    /// The student checked with their teacher: remember the new key for this
    /// class and use it from now on.
    func trustNewTeacherKey() async {
        guard let pending = pendingTeacherKey else { return }
        TeacherKeyPins.pin(pending.key.kid, me: userId, classId: pending.classId)
        pendingTeacherKey = nil
        errorMessage = nil
        if let session = activeExamSession, session.classId == pending.classId {
            await loadExamRecipientKeys(classId: pending.classId)
        }
    }

    /// The student chose to start a new copy over a draft this Mac can't open.
    func startFreshOverUnreadableDraft() {
        allowFreshOverUnreadable = true
        examUnreadableDraft = false
        errorMessage = nil
    }

    /// True when the essay can be sealed to the teacher and to the student.
    var examCanSeal: Bool {
        // A student's essay is sealed to the teacher only, so their own key
        // isn't needed to write (SAT-24). Teachers in student view still
        // need theirs.
        examLockState == .ready && (accountRole == .student || essayKeyState == .ready)
    }

    /// Begin button on the checks screen: register the students row (the
    /// proctoring contract) and only then enter the locked exam. False (with
    /// errorMessage set) means stay on the checks screen.
    func beginExam(screenCapture: Bool, remote: Bool, displayCount: Int?,
                   isVM: Bool?) async -> Bool {
        guard signedIn else {   // preview path
            examDraftCarried = false
            examCarryNote = nil
            if let a = activeAssignment, a.carryForward, a.versionNumber > 1 {
                examDraftHTML = CarryForwardPreview.draft1HTML
                examDraftCarried = true
                examCarryNote = Self.carriedNote(version: a.versionNumber - 1)
            }
            enterExam()
            return true
        }
        guard let session = activeExamSession else {
            errorMessage = "Couldn't reach this assignment's session. Go back and try again."
            return false
        }
        if essayKeyState != .ready { await checkEssayKey() }
        await loadExamRecipientKeys(classId: session.classId)
        guard examCanSeal else {
            switch examLockState {
            case .noTeacherKey:
                errorMessage = "Your teacher needs to set their essay password in Weft before this exam can start. Ask them, then try again."
            case .ready where essayKeyState == nil:
                errorMessage = accountRole == .student
                    ? "Couldn't reach Weft. Check your connection and try again."
                    : "Couldn't reach Weft to check your essay password. Check your connection and try again."
            case .ready:
                errorMessage = accountRole == .student
                    ? "Couldn't set up your Weft key. Check your connection and try again."
                    : "Enter your essay password first."
            case .unknownTeacher:
                errorMessage = "This exam isn't linked to a class, so your work can't be locked to your teacher."
            case .teacherKeyChanged:
                errorMessage = Self.teacherKeyChangedMessage
            default:
                errorMessage = "Couldn't check your teacher's lock. Check your connection and try again."
            }
            return false
        }
        // Last chance to fix an outline sealed to an old teacher key: once
        // the students row exists, the outline is locked.
        await resealOutlineIfNeeded(sessionId: session.id)
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
            // Anchor the countdown to the server BEFORE entering the kiosk:
            // ExamView used to seed Date()+limit at appearance, so a
            // crash-reentry got a brand-new window. start_essay is
            // idempotent (first started_at wins) and returns server_now
            // so the remaining minutes are the original window.
            guard let start = try await supabase.startEssay(studentId: sid) else {
                errorMessage = "Couldn't start the exam clock. Try Begin again."
                return false
            }
            // The registration + start round-trip is long enough for the
            // student to have left checks (deep link, sign-out, back). A
            // late success must not shove them into the kiosk — or worse,
            // cross-wire a stale students-row id with a newer session
            // (every autosave would then fail RLS inside a locked exam).
            guard studentScreen == .checks, activeExamSession?.id == session.id else {
                return false
            }
            activeStudentId = sid
            let remote: (id: String, html: String, cipher: WeftEnvelope?, updatedAt: Date?)?
            if let qid = activeAssignment?.questions.first?.id {
                remote = try? await supabase.getMyEssayDraft(sessionId: session.id,
                                                             studentId: sid,
                                                             questionId: qid)
            } else {
                remote = nil
            }
            let local = ExamDraftStore.load(userId: userId, sessionId: session.id)
            if let remote { activeSubmissionId = remote.id } else { activeSubmissionId = nil }
            examDraftCarried = false
            examCarryNote = nil
            var startsBlank = false
            switch (local, remote) {
            case let (local?, remote?):
                let revealed = revealHTML(remote.html, cipher: remote.cipher)
                let remoteAt = remote.updatedAt ?? .distantPast
                // The server copy is the one this Mac uploaded last: the local
                // draft has the same work (or newer), so it isn't "another Mac".
                let mine = remote.cipher.map {
                    $0.content.nonce == ExamDraftStore.lastUploadedNonce(userId: userId,
                                                                         sessionId: session.id)
                } ?? false
                if revealed.isEmpty, remote.cipher != nil, remoteAt > local.updatedAt,
                   !mine, !allowFreshOverUnreadable {
                    // A newer copy written on another Mac that this Mac can't
                    // open: don't let the older local copy overwrite it.
                    examUnreadableDraft = true
                    errorMessage = "Newer work for this exam was saved on another Mac. It's locked for your teacher, so it can't open here. Go back to that Mac if you can. Continuing here replaces it with the older copy on this Mac."
                    activeStudentId = nil
                    return false
                }
                if local.updatedAt >= remoteAt || revealed.isEmpty {
                    examDraftHTML = local.html
                } else {
                    examDraftHTML = revealed
                }
            case let (local?, nil):
                examDraftHTML = local.html
            case let (nil, remote?):
                let revealed = revealHTML(remote.html, cipher: remote.cipher)
                if revealed.isEmpty, remote.cipher != nil, !allowFreshOverUnreadable {
                    examUnreadableDraft = true
                    errorMessage = "Your saved work for this exam is locked for your teacher, so it can only continue on the Mac you started on. Go back to that Mac if you can. Starting a new copy here replaces it."
                    activeStudentId = nil
                    return false
                }
                examDraftHTML = revealed.isEmpty ? nil : revealed
            case (nil, nil):
                examDraftHTML = nil
                startsBlank = true
            }
            // Carry forward (SAT-5): only onto a blank page. Work already saved
            // for this draft, on this Mac or the server, is never replaced.
            if startsBlank, let test = activeAssignment, test.carryForward, test.versionNumber > 1 {
                let carried = await carryForwardPreviousDraft(test: test)
                // The lookup is a few more round-trips: same late-success
                // guard as above.
                guard studentScreen == .checks, activeExamSession?.id == session.id else {
                    activeStudentId = nil
                    return false
                }
                examDraftHTML = carried.html
                examDraftCarried = carried.html != nil
                examCarryNote = carried.note
            }
            guard examCanSeal, !examRecipientKeys.isEmpty else {
                activeStudentId = nil
                errorMessage = "Couldn't check your teacher's lock. Check your connection and try again."
                return false
            }
            examDeadline = Self.deadline(from: start,
                                         minutes: activeAssignment?.timeLimitMinutes)
            markedWriting = false
            errorMessage = nil
            enterExam()
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    static func carriedNote(version: Int) -> String {
        "Your Draft \(version) is in the editor. Keep what works and revise."
    }

    /// The student's own previous draft for a carry-forward draft (SAT-5):
    /// the most recent earlier draft they submitted, opened only if the
    /// teacher has returned it. A returned essay is sealed to the teacher;
    /// the teacher's Mac added a wrap for this student's key on return
    /// (essay_grades.student_wrap), and appending it here is the same step
    /// Returned work takes. Nothing is sent anywhere: the body is read from
    /// the student's own row and opened on this Mac. Never throws and never
    /// blocks the exam: on any failure the page starts blank with a note.
    private func carryForwardPreviousDraft(test: Assignment) async -> (html: String?, note: String?) {
        let earlier: [SupabaseManager.EarlierDraft]
        do {
            earlier = try await supabase.listMyEarlierDrafts(testId: test.id)
        } catch {
            return (nil, "Your earlier draft couldn't be loaded, so you're starting from a blank page.")
        }
        // Newest draft first. A skipped draft simply has no row, so this is
        // the latest draft the student actually handed in.
        guard let prev = earlier
            .filter({ $0.versionNumber < test.versionNumber && $0.submittedAt != nil })
            .max(by: { ($0.versionNumber, $0.submittedAt ?? .distantPast)
                     < ($1.versionNumber, $1.submittedAt ?? .distantPast) })
        else {
            return (nil, "There's no earlier draft of yours to bring in, so you're starting from a blank page.")
        }
        let label = "Draft \(prev.versionNumber)"
        guard prev.releasedAt != nil else {
            return (nil, "Your \(label) hasn't been returned yet, so you're starting from a blank page.")
        }
        let unreadable = "Your \(label) couldn't be opened on this Mac, so you're starting from a blank page."
        if essayKeyState != .ready { await checkEssayKey() }
        guard let body = try? await supabase.listOwnSubmissionBodies(ids: [prev.submissionId]).first
        else { return (nil, unreadable) }
        var cipher = body.contentCipher
        if var env = cipher,
           let wraps = try? await supabase.listMyReturnWraps(submissionIds: [prev.submissionId]),
           let w = wraps[prev.submissionId],
           !env.wraps.contains(where: { $0.recipientKid == w.recipientKid }) {
            env.wraps.append(w)
            cipher = env
        }
        let html = revealHTML(body.contentHtml, cipher: cipher)
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, unreadable)
        }
        return (html, Self.carriedNote(version: prev.versionNumber))
    }

    /// Move this attempt's roster row from "joined" to "writing" on the first
    /// edit. The teacher's live monitor labels students from students.status,
    /// and nothing ever wrote "writing", so a whole class of people typing read
    /// as "Joined" (which a teacher reads as "has not started") until submit.
    /// Called from every keystroke and costs one update per exam: the flag is
    /// set before the write, and only cleared again if the write failed, so the
    /// next edit retries rather than leaving the roster lying all lesson.
    func markWriting() {
        guard signedIn, !markedWriting, let studentId = activeStudentId else { return }
        markedWriting = true
        Task {
            let ok = await supabase.updateStudentStatus(id: studentId, status: "writing")
            if !ok { markedWriting = false }
        }
    }

    /// One durable save of the essay (debounced upstream). True = the work is
    /// on this Mac (and on the server when the network answered). A wifi blip
    /// must not look like data loss.
    func autosaveEssay(html: String, wordCount: Int) async -> Bool {
        let result = await saveEssay(html: html, wordCount: wordCount)
        return result.local || result.uploaded
    }

    /// Save locally, then upload the sealed copy. `uploaded` is true only when
    /// the server accepted THIS text, which is what submit must require.
    private func saveEssay(html: String, wordCount: Int) async -> (local: Bool, uploaded: Bool) {
        guard signedIn else { return (true, true) }   // preview: nothing to persist
        guard let session = activeExamSession,
              let studentId = activeStudentId,
              let questionId = activeAssignment?.questions.first?.id else { return (false, false) }
        let userId = userId
        let sessionId = session.id
        let aad = WeftContentSeal.aad(sessionId: sessionId, studentId: studentId,
                                      questionId: questionId)
        let teacherKeys = examRecipientKeys
        // Local AES-GCM plus a P-256 wrap per teacher used to run here, on the
        // main actor, so the keystroke after a pause waited on them. Both are
        // safe off the main actor (the enums are nonisolated). Sealed or not
        // sent: the server never receives the writing in the clear.
        var sealed = await Task.detached(priority: .utility) {
            let local = ExamDraftStore.save(userId: userId, sessionId: sessionId,
                                            html: html, wordCount: wordCount)
            // Teacher only: the student reads it once it is returned (SAT-24).
            let cipher = WeftContentSeal.sealHTML(html, userId: userId,
                                                  teacherKeys: teacherKeys, aad: aad,
                                                  includeSelf: false)
            return (local: local, cipher: cipher)
        }.value
        if sealed.cipher == nil {
            await loadExamRecipientKeys(classId: session.classId)
            if examCanSeal {
                let keys = examRecipientKeys
                let cipher = await Task.detached(priority: .utility) {
                    WeftContentSeal.sealHTML(html, userId: userId,
                                            teacherKeys: keys, aad: aad,
                                            includeSelf: false)
                }.value
                sealed = (local: sealed.local, cipher: cipher)
            }
        }
        let localOK = sealed.local
        let cipher = sealed.cipher
        guard let cipher else { return (localOK, false) }
        do {
            guard let id = try await supabase.upsertEssaySubmission(
                sessionId: session.id, studentId: studentId, questionId: questionId,
                wordCount: wordCount, cipher: cipher) else {
                return (localOK, false)
            }
            activeSubmissionId = id
            ExamDraftStore.rememberUploaded(nonce: cipher.content.nonce,
                                            userId: userId, sessionId: session.id)
            return (localOK, true)
        } catch {
            return (localOK, false)
        }
    }

    /// Final flush + DB lock + status. False = the final text did not reach
    /// the server, so the caller must NOT exit the exam (the work would be
    /// lost, or an older copy would be locked in). Does NOT route; the exam
    /// view orchestrates kiosk exit + finishExam on success.
    ///
    /// Idempotent across a lost response (SAT-34): if an earlier attempt's
    /// submit_essay committed but the reply never arrived, the row is already
    /// locked and every re-upload is refused. So the server is asked first,
    /// and again after a failed lock, and an already-submitted essay counts
    /// as success. A retry whose first attempt never reached the server
    /// finds the row unsubmitted and takes the normal flush + lock path.
    func submitExam(html: String, wordCount: Int) async -> Bool {
        if signedIn {
            if (await essayAlreadySubmitted()) != true {
                let saved = await saveEssay(html: html, wordCount: wordCount)
                guard saved.uploaded else { return false }
                guard let submissionId = activeSubmissionId else { return false }
                if !(await supabase.submitEssay(submissionId: submissionId)) {
                    // The lock may have committed with only the reply lost.
                    guard (await essayAlreadySubmitted()) == true else { return false }
                }
            }
            if let studentId = activeStudentId {
                await supabase.updateStudentStatus(id: studentId, status: "submitted")
            }
            if let session = activeExamSession {
                ExamDraftStore.remove(userId: userId, sessionId: session.id)
            }
        }
        activeStudentId = nil
        activeSubmissionId = nil
        activeExamSession = nil
        examDeadline = nil
        markedWriting = false
        allowFreshOverUnreadable = false
        return true
    }

    /// Server truth for this attempt's lock: true = submit_essay already
    /// stamped it, false = not submitted (or no row yet), nil = couldn't ask
    /// (network). nil is treated like false by the caller: the normal flush
    /// path runs and fails or succeeds on its own, as it did before.
    private func essayAlreadySubmitted() async -> Bool? {
        guard let session = activeExamSession,
              let studentId = activeStudentId,
              let questionId = activeAssignment?.questions.first?.id else { return nil }
        do {
            guard let state = try await supabase.getMySubmissionState(
                sessionId: session.id, studentId: studentId, questionId: questionId)
            else { return false }
            activeSubmissionId = state.id
            return state.submitted
        } catch {
            return nil
        }
    }

    /// True while the attempt's session is still open. lookup_session_by_code
    /// already returns no row for a closed session (and 000005 keeps that
    /// filter), so nil and status != open are the same signal: the teacher
    /// ended it. Throws on a transport failure so a blip is not the bell.
    func examSessionStillOpen() async throws -> Bool {
        guard signedIn, let code = activeExamSession?.code else { return true }
        let session = try await supabase.lookupSession(code: code)
        return session?.status == "open"
    }

    /// Convert the server's (started_at, server_now) pair plus the
    /// assignment's minute limit into a local Date. nil minutes = unlimited,
    /// matching the editor's "leave blank" and the server's NULL time_limit.
    private static func deadline(from start: EssayStart, minutes: Int?) -> Date? {
        guard let minutes, minutes > 0 else { return nil }
        let remaining = start.startedAt
            .addingTimeInterval(TimeInterval(minutes * 60))
            .timeIntervalSince(start.serverNow)
        return Date().addingTimeInterval(remaining)
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
            if var essay {
                essay.contentHtml = revealHTML(essay.contentHtml, cipher: essay.contentCipher)
                if essay.contentHtml.isEmpty, essay.contentCipher != nil {
                    essay.contentHtml = "<p><em>Your teacher has your essay. Once it's returned, read it under Returned work.</em></p>"
                }
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
    func goToHome()  {
        studentScreen = .home
        if signedIn { startStudentHomePolling() }
    }
    func enterExam() {
        ExamGate.inProgress = true   // block Sparkle update checks during the test
        stopStudentHomePolling()
        studentScreen = .exam
    }

    func finishExam() {
        ExamGate.inProgress = false
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
        examDeadline = nil
        examDraftHTML = nil
        examDraftCarried = false
        examCarryNote = nil
        examResolveCode = nil
        lastProctorFlags = nil
        studentScreen = .done
        if signedIn { Task { await loadClassWork() } }
    }

    /// Teacher-facing: the student left the exam window. Best-effort.
    func noteExamFocusLoss() {
        guard signedIn, let id = activeStudentId else { return }
        Task { await supabase.updateStudentStatus(id: id, status: "left fullscreen") }
    }

    /// After Resume, put the roster back on "writing" if they had already typed.
    func resumeExamFocus() {
        guard signedIn, markedWriting, let id = activeStudentId else { return }
        Task { await supabase.updateStudentStatus(id: id, status: "writing") }
    }

    /// Persist the latest detection flags so the live roster is not frozen at Begin.
    func reportProctoring(_ report: ProctoringReport) {
        guard signedIn, let id = activeStudentId else { return }
        let next = (screen: report.screenCapture, remote: report.remote,
                    displays: report.displays, vm: report.isVM)
        if let last = lastProctorFlags, last == next { return }
        lastProctorFlags = next
        Task {
            await supabase.updateProctoringFlags(id: id,
                                                 screenCapture: report.screenCapture,
                                                 remote: report.remote,
                                                 displayCount: report.displays,
                                                 isVM: report.isVM)
        }
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
    /// callback (weftnative://auth-callback) is handed to the sign-in attempt
    /// waiting on it. A link that arrives before sign-in is stashed and replayed
    /// once a session exists.
    /// Accepts both `weftnative` (this app's own, collision-free) and `weft`
    /// (kept for emailed links once the Electron app is retired).
    func handleDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "weftnative" || scheme == "weft" else { return }
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
        do {
            guard let session = try await supabase.lookupSession(code: code) else {
                errorMessage = "That exam link isn't open anymore."
                return
            }
            guard let cid = session.classId else {
                errorMessage = "That exam isn't attached to a class, so it can't be opened from this link."
                return
            }
            selectedClassId = cid
            classWork = []
            await loadClassWork()
            if let item = classWork.first(where: { $0.activeCode == code }) {
                startWriting(item)
            } else {
                errorMessage = "Couldn't find that assignment on your class home."
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Helpers

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Read a security-scoped picker URL off the main actor after a cheap size
    /// check, so a 50 MB attach cannot freeze the editor.
    fileprivate static func readPickedFile(_ fileURL: URL, maxBytes: Int) async throws -> Data {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { throw FileTooLarge() }
        let url = fileURL
        return try await Task.detached {
            try Data(contentsOf: url)
        }.value
    }
}

private struct FileTooLarge: Error {}

// MARK: - Editor attachment payload

/// An existing assignment's saved attachments, loaded in one hop so the
/// assignment editor never has to guess at a half-loaded state: an empty
/// `EditorAttachments` means the assignment genuinely has none, while a nil
/// load result means the fetch failed.
struct EditorAttachments: Sendable {
    var links: [(name: String, href: String)] = []
    var files: [TeacherFile] = []
}

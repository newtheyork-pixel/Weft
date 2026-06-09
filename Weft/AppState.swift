//
//  AppState.swift
//  Weft — observable app-wide state: who's signed in, which role/screen is up,
//  and the data the UI renders. Real Supabase loads populate it once a session
//  exists; until then (dev gallery / unsigned build) the bundled mock samples
//  keep every screen populated. `useMockData` is the switch.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class AppState {
    enum Route: Equatable { case signIn, teacher, student }

    /// Sub-navigation inside the student role (the native analogue of the
    /// Electron #stage-* swap). RootView → StudentFlowView reads this.
    enum StudentScreen: Equatable { case home, join, checks, exam, done, returned }

    // MARK: Session / identity
    var route: Route = .signIn
    var role: UserRole?
    var displayName: String = ""
    var email: String = ""
    var userId: String = ""
    var isAdmin: Bool = false
    var signedIn: Bool = false

    /// Render the bundled mock samples until a real session loads. Flipped false
    /// after a successful sign-in + first load so the screens show live data.
    var useMockData: Bool = true

    // MARK: Student in-role navigation
    var studentScreen: StudentScreen = .home

    // MARK: Data (mock defaults; replaced by real loads when signed in)
    var enrolledClasses: [ClassRoom] = [.sample, .sample2]
    var classWork: [ClassWorkItem] = ClassWorkItem.sampleList
    var assignments: [Assignment] = [.sample, .sample2]
    var teacherClasses: [ClassRoom] = [.sample, .sample2]
    var roster: [RosterStudent] = RosterStudent.sample
    var returnedWork: [ReturnedWorkItem] = []

    var selectedClassId: String?
    /// The assignment a student is about to take / is taking (drives ExamView).
    var activeAssignment: Assignment?
    /// Reference materials for the active exam (sample defaults; replaced by the
    /// real test_files / test_urls when an active session resolves).
    var examFiles: [ExamFile] = ExamFile.sample
    var examLinks: [ExamLink] = ExamLink.sample

    // MARK: Teacher in-role navigation + state
    enum TeacherScreen: Equatable { case home, editor, grading, roster }
    var teacherScreen: TeacherScreen = .home
    /// The assignment being edited; nil means a brand-new assignment.
    var editingAssignment: Assignment?
    /// The currently live session (after Start live assignment).
    var liveSession: ExamSession?
    var pickedAssignmentId: String?
    var pickedClassId: String?
    // Class roster (for the Roster screen)
    var classRoster: [ClassEnrollment] = []
    var rosterClassId: String?
    var rosterClassName: String = ""
    // Grading
    var gradingSubmissions: [TeacherSubmission] = []
    var grades: [String: EssayGrade] = [:]   // submissionId -> grade
    var gradingTitle: String = ""

    // MARK: Async UI state
    var isLoading = false
    var errorMessage: String?

    private var supabase: SupabaseManager { .shared }

    // MARK: - Routing (no-auth paths keep mocks; used by the admin role chooser
    //         and the "for testing" buttons)

    func enterTeacher() {
        role = .teacher
        if displayName.isEmpty { displayName = "Thomas Seirer" }
        teacherScreen = .home
        route = .teacher
        if signedIn { Task { await loadTeacherHome() } }
    }

    func enterStudent() {
        role = .student
        if displayName.isEmpty { displayName = "Ava Chen" }
        studentScreen = .home
        route = .student
        if signedIn { Task { await loadStudentHome() } }
    }

    func signOut() {
        supabase.signOut()
        role = nil
        signedIn = false
        isAdmin = false
        useMockData = true
        userId = ""; email = ""; displayName = ""
        errorMessage = nil
        // Restore the not-signed-in (mock) state so no account's data leaks into
        // the next sign-in, and the dev/sign-in screens demo with samples again.
        selectedClassId = nil
        activeAssignment = nil
        studentScreen = .home
        enrolledClasses = [.sample, .sample2]
        classWork = ClassWorkItem.sampleList
        returnedWork = []
        // Teacher state back to defaults.
        teacherScreen = .home
        editingAssignment = nil
        liveSession = nil
        pickedAssignmentId = nil; pickedClassId = nil
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
        returnedWork = []
        selectedClassId = nil
        activeAssignment = nil
    }

    // MARK: - Auth

    /// Run Google OAuth, fetch the signed-in user, resolve their role, and route.
    /// On any failure the error is surfaced and we stay on the sign-in screen.
    func signInWithGoogle() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await supabase.signInWithGoogle()
            let user = try await supabase.fetchUser()
            userId = user.id
            email = user.email ?? ""
            displayName = user.displayName ?? user.email ?? "Signed in"
            signedIn = true
            useMockData = false
            dropMockData()

            // Best-effort server role lookup. If the backend doesn't expose it,
            // fall back to the on-screen role chooser (treat as admin).
            if let resolved = await supabase.resolveRole() {
                role = resolved
                isAdmin = (resolved == .admin)
                switch resolved {
                case .teacher, .admin:
                    route = .teacher
                    await loadTeacherHome()
                case .student:
                    studentScreen = .home
                    route = .student
                    await loadStudentHome()
                }
            } else {
                // Unknown role — let the user pick on the sign-in card.
                isAdmin = true
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Loads (student)

    /// Load the signed-in student's classes, then the work for the selected one.
    /// No-ops (keeps mocks) when not signed in.
    func loadStudentHome() async {
        guard signedIn else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let classes = try await supabase.myClasses(userId: userId)
            enrolledClasses = classes
            if selectedClassId == nil || !classes.contains(where: { $0.id == selectedClassId }) {
                selectedClassId = classes.first?.id
            }
            await loadClassWork()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Load the work rows for the currently selected class.
    func loadClassWork() async {
        guard signedIn, let cid = selectedClassId else { return }
        do {
            classWork = try await supabase.listClassWork(classId: cid)
        } catch {
            errorMessage = describe(error)
        }
    }

    func selectClass(_ id: String) {
        selectedClassId = id
        if signedIn { Task { await loadClassWork() } }
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
            if let joined { selectedClassId = joined.id }
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
        guard signedIn else { return }
        errorMessage = nil
        do {
            teacherClasses = try await supabase.listTeacherClasses()
            assignments = try await supabase.listTeacherTests(userId: userId)
            if pickedAssignmentId == nil || !assignments.contains(where: { $0.id == pickedAssignmentId }) {
                pickedAssignmentId = assignments.first?.id
            }
            if pickedClassId == nil || !teacherClasses.contains(where: { $0.id == pickedClassId }) {
                pickedClassId = teacherClasses.first?.id
            }
            // Restore an already-open session (app relaunch / another device) so
            // the home reflects reality and we never launch a duplicate.
            if liveSession == nil, let open = try? await supabase.listOpenSessions(userId: userId).first {
                liveSession = open
                await loadLiveRoster()
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Teacher: navigation
    func teacherGoHome() { errorMessage = nil; teacherScreen = .home }
    func openNewAssignment() { errorMessage = nil; editingAssignment = nil; teacherScreen = .editor }
    func openEditAssignment(_ a: Assignment) { errorMessage = nil; editingAssignment = a; teacherScreen = .editor }

    // MARK: - Teacher: classes
    func createClass(name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if !signedIn {
            teacherClasses.append(ClassRoom(id: "local-\(UUID().uuidString.prefix(6))",
                name: clean, joinCode: SupabaseManager.classCode(), archivedAt: nil))
            if pickedClassId == nil { pickedClassId = teacherClasses.last?.id }
            return
        }
        do { _ = try await supabase.createClass(name: clean); await loadTeacherHome() }
        catch { errorMessage = describe(error) }
    }

    func openRoster(_ c: ClassRoom) {
        errorMessage = nil
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
    func saveAssignment(title: String, prompt: String, wordLimit: Int?, timeLimitMinutes: Int?) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !p.isEmpty else {
            errorMessage = "An assignment needs a title and a prompt."
            return
        }
        errorMessage = nil
        let qid = editingAssignment?.questions.first?.id ?? "q-\(UUID().uuidString.prefix(8))"
        let q = Question(id: qid, kind: "essay", prompt: p, wordLimit: wordLimit)
        if !signedIn {
            if let id = editingAssignment?.id, let idx = assignments.firstIndex(where: { $0.id == id }) {
                assignments[idx] = Assignment(id: id, title: t,
                    versionGroupId: assignments[idx].versionGroupId,
                    versionNumber: assignments[idx].versionNumber,
                    questions: [q], timeLimitMinutes: timeLimitMinutes)
            } else {
                assignments.append(Assignment(id: "local-\(UUID().uuidString.prefix(6))", title: t,
                    versionGroupId: "g-\(UUID().uuidString.prefix(6))", versionNumber: 1,
                    questions: [q], timeLimitMinutes: timeLimitMinutes))
            }
            teacherScreen = .home
            return
        }
        do {
            if let id = editingAssignment?.id {
                try await supabase.updateTest(id: id, title: t, questions: [q], timeLimitMinutes: timeLimitMinutes)
            } else {
                _ = try await supabase.createTest(teacherUserId: userId, title: t,
                                                  questions: [q], timeLimitMinutes: timeLimitMinutes)
            }
            await loadTeacherHome()
            teacherScreen = .home
        } catch {
            errorMessage = describe(error)
        }
    }

    func deleteAssignment(_ a: Assignment) async {
        if !signedIn { assignments.removeAll { $0.id == a.id }; return }
        do { try await supabase.deleteTest(id: a.id); await loadTeacherHome() }
        catch { errorMessage = describe(error) }
    }

    // MARK: - Teacher: live session
    func launchSession() async {
        errorMessage = nil
        guard liveSession == nil else { return }   // one live session at a time
        guard let testId = pickedAssignmentId else {
            errorMessage = "Pick an assignment to launch."
            return
        }
        guard let classId = pickedClassId else {
            errorMessage = "Pick a class to launch for."
            return
        }
        if !signedIn {
            liveSession = ExamSession(id: "local-session", code: SupabaseManager.sessionCode(),
                                      testId: testId, classId: classId, status: "open")
            roster = RosterStudent.sample
            return
        }
        isLoading = true
        defer { isLoading = false }
        let ip = await ProctoringEngine().fetchPublicIP()
        do {
            liveSession = try await supabase.launchSession(testId: testId, classId: classId,
                                                           teacherUserId: userId, teacherIP: ip)
            await loadLiveRoster()
        } catch {
            errorMessage = describe(error)
        }
    }

    func loadLiveRoster() async {
        guard signedIn, let sid = liveSession?.id else { return }
        do { roster = try await supabase.listSessionStudents(sessionId: sid) }
        catch { errorMessage = describe(error) }
    }

    func endSession() async {
        if signedIn, let sid = liveSession?.id {
            try? await supabase.endSession(id: sid)
        }
        liveSession = nil
        gradingSubmissions = []
        grades = [:]
        roster = []
    }

    // MARK: - Teacher: grading
    func openGrading() {
        errorMessage = nil
        gradingTitle = assignments.first(where: { $0.id == liveSession?.testId })?.title ?? "Submissions"
        teacherScreen = .grading
        Task { await loadGrading() }
    }

    func loadGrading() async {
        guard let sid = liveSession?.id else { return }
        if !signedIn {
            // No submissions to load in preview; the grading screen falls back
            // to its own sample content.
            gradingSubmissions = []
            grades = [:]
            return
        }
        errorMessage = nil
        do {
            gradingSubmissions = try await supabase.listSessionSubmissions(sessionId: sid)
            // Refresh the roster too so late-joiner names resolve when grading.
            roster = try await supabase.listSessionStudents(sessionId: sid)
            let g = try await supabase.listGrades(submissionIds: gradingSubmissions.map(\.id))
            grades = Dictionary(uniqueKeysWithValues: g.map { ($0.submissionId, $0) })
        } catch {
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
        let existing = grades[submission.id]?.releasedAt
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
        // Reset to samples, then (when signed in) pull the real reference
        // materials for the active session in the background.
        examFiles = ExamFile.sample
        examLinks = ExamLink.sample
        if signedIn, let code = item.activeCode {
            Task { await loadExamMaterials(code: code) }
        }
        studentScreen = .checks
    }

    /// Resolve the active session's test, then load its reference files + links.
    /// Best-effort: on any failure we keep the sample materials.
    func loadExamMaterials(code: String) async {
        guard signedIn else { return }
        do {
            guard let session = try await supabase.lookupSession(code: code),
                  let testId = session.testId else { return }
            let files = try await supabase.listTestFiles(testId: testId)
            let links = try await supabase.listTestURLs(testId: testId)
            if !files.isEmpty { examFiles = files }
            if !links.isEmpty { examLinks = links }
        } catch {
            // keep samples; this is a non-blocking enhancement
        }
    }

    func openReturnedWork() {
        // ReturnedWorkView owns the load via its own `.task` (auto-cancelled with
        // the view); don't fire a second, detached load here.
        studentScreen = .returned
    }

    func goToJoin()  { studentScreen = .join }
    func goToHome()  { studentScreen = .home }
    func enterExam() { studentScreen = .exam }
    func finishExam() { activeAssignment = nil; studentScreen = .done }

    // MARK: - Helpers

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

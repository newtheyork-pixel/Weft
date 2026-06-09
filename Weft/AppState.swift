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

    // MARK: Async UI state
    var isLoading = false
    var errorMessage: String?

    private var supabase: SupabaseManager { .shared }

    // MARK: - Routing (no-auth paths keep mocks; used by the admin role chooser
    //         and the "for testing" buttons)

    func enterTeacher() {
        role = .teacher
        if displayName.isEmpty { displayName = "Thomas Seirer" }
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

    // MARK: - Loads (teacher)
    //
    // Teacher data wiring is intentionally light: the full teacher build/live
    // flows (roster realtime, session launch, grading writes) are a later wave
    // (see the rewrite memory). For now the teacher home renders mock data; this
    // hook is where the real `list_*` RPCs land when those flows are ported.
    func loadTeacherHome() async {
        guard signedIn else { return }
        // TODO(teacher wave): load real classes/assignments/roster here.
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
        studentScreen = .checks
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

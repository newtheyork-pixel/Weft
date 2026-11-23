//
//  DraftHistory.swift
//  Weft: a student's drafts of one assignment, for the grading screen.
//
//  A second draft is its own test in the same version group
//  (tests.version_group_id, tests.version_number), launched as its own
//  session(s) in the class. While grading one session, the teacher can look
//  at the same student's other drafts and compare them. The path:
//
//    graded session -> its test -> the version group (coalesce(version_group_id, id))
//      -> the teacher's tests in that group
//      -> the teacher's sessions for those tests in the SAME class
//      -> this student's students rows there (matched by user_id)
//      -> their essay_submissions (the submitted one, else the latest)
//
//  Every row is the teacher's own under the existing RLS. Essays are sealed
//  and opened here, on this Mac, the same way the grading load opens them.
//  Loaded lazily per student, after the grading screen is up, and cached
//  per (student user id, version group).
//

import Foundation

// MARK: - Rows

/// A test's place in its version group.
struct DraftTestRow: Decodable, Sendable {
    let id: String
    var versionGroupId: String?
    var versionNumber: Int?

    var groupId: String { versionGroupId ?? id }
    var version: Int { versionNumber ?? 1 }

    enum CodingKeys: String, CodingKey {
        case id
        case versionGroupId = "version_group_id"
        case versionNumber = "version_number"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        versionGroupId = try? c.decode(String.self, forKey: .versionGroupId)
        versionNumber = try? c.decode(Int.self, forKey: .versionNumber)
    }
}

/// A students row: who joined which session.
struct DraftStudentRow: Decodable, Sendable {
    let id: String
    var sessionId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
    }
}

// MARK: - Model

/// One draft of a student's essay.
struct StudentDraft: Identifiable, Equatable, Sendable {
    /// The essay_submissions id.
    let id: String
    let versionNumber: Int
    var paragraphs: [String]
    var wordCount: Int
    var submittedAt: Date?
    var updatedAt: Date?
    /// Sealed to a key this Mac does not hold.
    var unreadable: Bool = false

    var label: String { "Draft \(versionNumber)" }
}

enum DraftHistoryState: Equatable {
    case loading
    case loaded([StudentDraft])
    case failed(String)
}

/// The graded session's version group: which version each test is, and the
/// class sessions launched for those tests.
struct DraftGroup: Equatable {
    let groupId: String
    var versionByTest: [String: Int]
    /// Session id -> version number. Always holds the graded session.
    var versionBySession: [String: Int]
}

// MARK: - Loading

extension AppState {

    func clearDraftHistory() {
        draftHistories = [:]
        draftKeyBySubmission = [:]
        draftGroups = [:]
    }

    /// The drafts for a graded submission, once looked up. nil = not asked yet.
    func draftState(forSubmission id: String) -> DraftHistoryState? {
        draftKeyBySubmission[id].flatMap { draftHistories[$0] }
    }

    /// Look up this student's other drafts (once; cached). Safe to call on
    /// every visit to the student: a cached or in-flight lookup is reused.
    func loadStudentDrafts(submissionId: String, retry: Bool = false) async {
        guard signedIn, let session = gradingSession,
              let sub = gradingSubmissions.first(where: { $0.id == submissionId }) else { return }
        let sessionId = session.id
        let me = userId

        // Only a matching person can have drafts elsewhere. No user id (a
        // legacy row) means this paper stands alone.
        guard let studentId = sub.studentId,
              let uid = gradingRoster.first(where: { $0.id == studentId })?.userId else {
            let key = "none|\(submissionId)"
            draftKeyBySubmission[submissionId] = key
            draftHistories[key] = .loaded([])
            return
        }

        if let key = draftKeyBySubmission[submissionId], let state = draftHistories[key] {
            if case .failed = state, retry {
                draftHistories[key] = nil
            } else {
                return
            }
        }

        // The group is the same for every student: resolve it once.
        let group: DraftGroup
        if let known = draftGroups[sessionId] {
            group = known
        } else {
            let pendingKey = "\(uid)|session:\(sessionId)"
            draftKeyBySubmission[submissionId] = pendingKey
            draftHistories[pendingKey] = .loading
            do {
                group = try await resolveDraftGroup(session, teacherUserId: me)
            } catch {
                guard gradingSession?.id == sessionId else { return }
                // Moving to another student cancels the lookup: forget it so
                // the next visit asks again instead of showing a failure.
                draftHistories[pendingKey] = Task.isCancelled
                    ? nil : .failed("Couldn't look up this student's other drafts.")
                return
            }
            guard gradingSession?.id == sessionId else { return }
            draftHistories[pendingKey] = nil
            draftGroups[sessionId] = group
        }

        let key = "\(uid)|\(group.groupId)"
        draftKeyBySubmission[submissionId] = key
        if let state = draftHistories[key] {
            if case .failed = state, retry {} else { return }
        }
        draftHistories[key] = .loading
        do {
            let drafts = try await fetchDrafts(group: group, userId: uid, current: sub,
                                               currentVersion: group.versionBySession[sessionId] ?? 1)
            guard gradingSession?.id == sessionId else { return }
            draftHistories[key] = .loaded(drafts)
        } catch {
            guard gradingSession?.id == sessionId else { return }
            draftHistories[key] = Task.isCancelled
                ? nil : .failed("Couldn't load this student's other drafts.")
        }
    }

    private func resolveDraftGroup(_ session: ExamSession, teacherUserId: String) async throws -> DraftGroup {
        let db = SupabaseManager.shared
        // A session with no test or no class can't be matched to others.
        guard let testId = session.testId else {
            return DraftGroup(groupId: "session:\(session.id)", versionByTest: [:],
                              versionBySession: [session.id: 1])
        }
        let graded = try await db.draftTest(id: testId)
        let groupId = graded?.groupId ?? testId
        let currentVersion = graded?.version ?? 1
        guard let classId = session.classId else {
            return DraftGroup(groupId: groupId, versionByTest: [testId: currentVersion],
                              versionBySession: [session.id: currentVersion])
        }
        let tests = try await db.listVersionGroupTests(groupId: groupId, teacherUserId: teacherUserId)
        var versionByTest = Dictionary(tests.map { ($0.id, $0.version) }, uniquingKeysWith: { a, _ in a })
        versionByTest[testId] = currentVersion
        var versionBySession: [String: Int] = [session.id: currentVersion]
        if versionByTest.count > 1 {
            let sessions = try await db.listClassSessions(testIds: Array(versionByTest.keys),
                                                          classId: classId,
                                                          teacherUserId: teacherUserId)
            for s in sessions {
                guard let t = s.testId, let v = versionByTest[t] else { continue }
                versionBySession[s.id] = v
            }
        }
        return DraftGroup(groupId: groupId, versionByTest: versionByTest,
                          versionBySession: versionBySession)
    }

    /// One draft per version this student wrote: the graded paper for the
    /// graded version, else the submitted paper (the latest if there are
    /// several sessions), else the latest one they started. Versions the
    /// student never wrote are simply absent.
    private func fetchDrafts(group: DraftGroup, userId uid: String, current: TeacherSubmission,
                             currentVersion: Int) async throws -> [StudentDraft] {
        guard group.versionBySession.count > 1 else { return [] }
        let db = SupabaseManager.shared
        let students = try await db.listStudentRows(userId: uid, sessionIds: Array(group.versionBySession.keys))
        let sessionByStudent = Dictionary(students.compactMap { s in s.sessionId.map { (s.id, $0) } },
                                          uniquingKeysWith: { a, _ in a })
        let subs = try await db.listSubmissions(studentIds: Array(sessionByStudent.keys))

        var byVersion: [Int: [TeacherSubmission]] = [:]
        for s in subs {
            guard let sid = s.sessionId ?? s.studentId.flatMap({ sessionByStudent[$0] }),
                  let v = group.versionBySession[sid] else { continue }
            byVersion[v, default: []].append(s)
        }
        var picked: [Int: TeacherSubmission] = [:]
        for (v, list) in byVersion where v != currentVersion {
            let submitted = list.filter { $0.submittedAt != nil }
            let pool = submitted.isEmpty ? list : submitted
            picked[v] = pool.max { ($0.submittedAt ?? $0.updatedAt ?? .distantPast)
                < ($1.submittedAt ?? $1.updatedAt ?? .distantPast) }
        }
        // The graded paper itself, as stored (gradingSubmissions holds an
        // already opened copy; the raw row tells us if it was unreadable).
        picked[currentVersion] = subs.first { $0.id == current.id } ?? current
        guard picked.count > 1 else { return [] }

        return picked.map { v, s in openDraft(s, version: v) }
            .sorted { $0.versionNumber < $1.versionNumber }
    }

    /// Open a sealed draft on this Mac. Nothing is sent anywhere.
    private func openDraft(_ s: TeacherSubmission, version: Int) -> StudentDraft {
        var html = s.contentHtml ?? ""
        var unreadable = false
        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let cipher = s.contentCipher {
            if let opened = WeftContentSeal.openHTML(cipher, userId: userId) {
                html = opened
            } else {
                unreadable = true
            }
        }
        let paragraphs = unreadable ? [] : PaperText.paragraphs(fromHTML: html)
        return StudentDraft(id: s.id, versionNumber: version, paragraphs: paragraphs,
                            wordCount: s.wordCount ?? WordDiff.wordCount(paragraphs),
                            submittedAt: s.submittedAt, updatedAt: s.updatedAt,
                            unreadable: unreadable)
    }
}

// MARK: - Sample drafts (signed-out preview)

enum SampleDrafts {
    private static func days(_ n: Double) -> Date { Date().addingTimeInterval(-n * 86_400) }

    private static func draft(_ id: String, _ v: Int, _ paragraphs: [String], daysAgo: Double,
                              unreadable: Bool = false, words: Int? = nil) -> StudentDraft {
        StudentDraft(id: id, versionNumber: v, paragraphs: paragraphs,
                     wordCount: words ?? WordDiff.wordCount(paragraphs),
                     submittedAt: days(daysAgo), updatedAt: days(daysAgo), unreadable: unreadable)
    }

    /// The graded paper as the current draft in a sample list.
    static func current(_ id: String, version: Int, _ paragraphs: [String]) -> StudentDraft {
        draft(id, version, paragraphs, daysAgo: 0.1)
    }

    /// Ava wrote all three drafts.
    static let ava: [StudentDraft] = [
        draft("1-d1", 1, [
            "In the passage, the author uses light and dark imagery to set the mood of the chapter. Light stands for understanding and dark stands for confusion, and the narrator moves from one to the other.",
            "At the start, the lamp is described as \"a small, stubborn coin of gold against the whole weight of the night.\" This shows that the light is small and the dark is big. The author wants us to feel that the character is surrounded by confusion.",
            "At the end, when she tells the truth, \"a thin line of morning\" appears under the door. This shows that she finally understands. The light is a symbol of truth, and the darkness is a symbol of lies.",
        ], daysAgo: 21),
        draft("1-d2", 2, [
            "In the assigned passage, light and dark imagery does more than set a mood. It carries the argument of the chapter. Each time the narrator reaches for an image of brightness, it comes only after a stretch of shadow, which suggests that clarity has to be earned.",
            "Consider the opening, where the lamp is described as \"a small, stubborn coin of gold against the whole weight of the night.\" The light is small and it is stubborn, as if it must hold its ground. The dark, by contrast, is heavy: \"the whole weight of the night.\" The author frames understanding as hard work.",
            "This pattern repeats at the end of the scene. When the character finally speaks the truth she has avoided, the room does not flood with light. Instead, \"a thin line of morning\" appears under the door. A flood would suggest a sudden revelation; a thin line suggests something arriving slowly.",
            "In the end, the imagery is not just decoration. Light keeps its meaning because the text never gives it away cheaply.",
        ], daysAgo: 10),
    ]

    /// Ben skipped Draft 2.
    static let ben: [StudentDraft] = [
        draft("2-d1", 1, [
            "The passage uses light and dark to show what the character knows and what she will not admit. Darkness is a comfort for her, not a danger.",
            "When the narrator stays in the unlit hall, the writing slows down. The shadows are called \"forgiving.\" To stay in the dark is to avoid being judged, so light becomes the threat.",
            "At the end, the light through the curtain feels like exposure instead of hope.",
        ], daysAgo: 21),
    ]

    /// Maya's first draft was sealed on another Mac.
    static let maya: [StudentDraft] = [
        draft("3-d1", 1, [], daysAgo: 21, unreadable: true, words: 236),
        draft("3-d2", 2, [
            "Light and dark in this passage are not simple opposites. They mix together, and the author seems most interested in the gray between them.",
            "The recurring image of the \"half-lit window\" is the clearest example. It is neither bright nor black, and it comes back whenever the character is uncertain.",
            "This is a subtler design than a light-equals-good scheme. The author asks the reader to sit in the same uncertainty the character feels.",
        ], daysAgo: 10),
    ]
}

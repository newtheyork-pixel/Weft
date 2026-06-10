//
//  Models.swift
//  Weft — core data models, mirroring the Supabase schema. Codable for the
//  network layer, with mock samples for previews/UI build-out before the
//  backend is wired.
//

import Foundation

// MARK: - Roles

enum UserRole: String, Codable, Sendable {
    case teacher, student, admin
}

// MARK: - Class

struct ClassRoom: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var joinCode: String
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case joinCode = "join_code"
        case archivedAt = "archived_at"
    }

    init(id: String, name: String, joinCode: String, archivedAt: Date?) {
        self.id = id; self.name = name; self.joinCode = joinCode; self.archivedAt = archivedAt
    }

    /// Tolerant decode: `join_class_by_code` returns id + name but not always a
    /// `join_code` for the joiner, so default it rather than throwing keyNotFound.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        joinCode = (try? c.decode(String.self, forKey: .joinCode)) ?? ""
        archivedAt = try? c.decode(Date.self, forKey: .archivedAt)
    }

    static let sample = ClassRoom(id: "c1", name: "AP English", joinCode: "ABC234", archivedAt: nil)
    static let sample2 = ClassRoom(id: "c2", name: "Biology", joinCode: "BIO901", archivedAt: nil)
}

// MARK: - Assignment (a `tests` row) + its questions

struct Question: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var kind: String          // "essay" | "quiz"
    var prompt: String
    var wordLimit: Int?
    /// References into the per-teacher test_files / test_urls pools (the jsonb
    /// question stores these; there is no test_id FK on those tables).
    var fileIds: [String]
    var urlIds: [String]

    init(id: String, kind: String, prompt: String, wordLimit: Int?,
         fileIds: [String] = [], urlIds: [String] = []) {
        self.id = id; self.kind = kind; self.prompt = prompt
        self.wordLimit = wordLimit; self.fileIds = fileIds; self.urlIds = urlIds
    }

    /// Tolerant decode: older questions (and the jsonb) may omit these arrays.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "essay"
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        wordLimit = try? c.decode(Int.self, forKey: .wordLimit)
        fileIds = (try? c.decode([String].self, forKey: .fileIds)) ?? []
        urlIds = (try? c.decode([String].self, forKey: .urlIds)) ?? []
    }
}

struct Assignment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var versionGroupId: String
    var versionNumber: Int
    var questions: [Question]
    var timeLimitMinutes: Int?
    /// Teacher-controlled per assignment; default true keeps every existing
    /// assignment and the Electron editor (which never sends the column) unchanged.
    var spellcheckEnabled: Bool

    var isVersioned: Bool { versionNumber > 1 }

    enum CodingKeys: String, CodingKey {
        case id, title, questions
        case versionGroupId = "version_group_id"
        case versionNumber = "version_number"
        case timeLimitMinutes = "time_limit_minutes"
        case spellcheckEnabled = "spellcheck_enabled"
    }

    init(id: String, title: String, versionGroupId: String, versionNumber: Int,
         questions: [Question], timeLimitMinutes: Int?, spellcheckEnabled: Bool = true) {
        self.id = id; self.title = title; self.versionGroupId = versionGroupId
        self.versionNumber = versionNumber; self.questions = questions
        self.timeLimitMinutes = timeLimitMinutes
        self.spellcheckEnabled = spellcheckEnabled
    }

    /// Tolerant decode from a `tests` row: version_group_id/version_number may be
    /// null on a freshly created test, so default them (group = id, number = 1).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        questions = (try? c.decode([Question].self, forKey: .questions)) ?? []
        versionGroupId = (try? c.decode(String.self, forKey: .versionGroupId)) ?? id
        versionNumber = (try? c.decode(Int.self, forKey: .versionNumber)) ?? 1
        timeLimitMinutes = try? c.decode(Int.self, forKey: .timeLimitMinutes)
        spellcheckEnabled = (try? c.decode(Bool.self, forKey: .spellcheckEnabled)) ?? true
    }

    static let sample = Assignment(
        id: "t1", title: "Lit essay 1", versionGroupId: "g1", versionNumber: 1,
        questions: [Question(id: "q1", kind: "essay",
                             prompt: "Analyze the use of light and dark imagery in the assigned passage.",
                             wordLimit: 600)],
        timeLimitMinutes: 45)
    static let sample2 = Assignment(
        id: "t2", title: "Cellular Respiration Quiz", versionGroupId: "g2", versionNumber: 1,
        questions: [Question(id: "q2", kind: "essay", prompt: "Explain glycolysis.", wordLimit: 300)],
        timeLimitMinutes: nil)
}

// MARK: - Live session (a `sessions` row)

struct ExamSession: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var code: String
    var testId: String?
    var classId: String?
    var status: String        // "open" | "closed"

    enum CodingKeys: String, CodingKey {
        case id, code, status
        case testId = "test_id"
        case classId = "class_id"
    }
}

// MARK: - Student-facing class work (the list_class_work RPC row)

struct ClassWorkItem: Identifiable, Codable, Hashable, Sendable {
    var versionGroupId: String
    var title: String
    var activeSessionId: String?
    var activeCode: String?
    var launchedAt: Date?
    var mySubmittedAt: Date?
    var myReleasedAt: Date?
    var myPoints: Double?
    var myPointsPossible: Double?
    /// My submission time for the CURRENTLY OPEN draft (list_class_work v2);
    /// nil when the RPC is v1, there is no open draft, or I haven't submitted it.
    var myActiveSubmittedAt: Date?
    /// Version number of the open draft / highest version in the group.
    var activeVersion: Int?
    var latestVersion: Int?

    var id: String { versionGroupId }

    enum CodingKeys: String, CodingKey {
        case versionGroupId = "version_group_id"
        case title
        case activeSessionId = "active_session_id"
        case activeCode = "active_code"
        case launchedAt = "launched_at"
        case mySubmittedAt = "my_submitted_at"
        case myReleasedAt = "my_released_at"
        case myPoints = "my_points"
        case myPointsPossible = "my_points_possible"
        case myActiveSubmittedAt = "my_active_submitted_at"
        case activeVersion = "active_version"
        case latestVersion = "latest_version"
    }

    enum Section { case active, graded, past }

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

    static let active = ClassWorkItem(versionGroupId: "g1", title: "Lit essay 1",
                                      activeSessionId: "s1", activeCode: "483920",
                                      launchedAt: .now, mySubmittedAt: nil,
                                      myReleasedAt: nil, myPoints: nil, myPointsPossible: nil,
                                      myActiveSubmittedAt: nil, activeVersion: 2, latestVersion: 2)
    static let graded = ClassWorkItem(versionGroupId: "g3", title: "Rhetoric analysis",
                                      activeSessionId: nil, activeCode: nil,
                                      launchedAt: .now.addingTimeInterval(-86400 * 3),
                                      mySubmittedAt: .now.addingTimeInterval(-86400 * 3),
                                      myReleasedAt: .now.addingTimeInterval(-86400 * 2),
                                      myPoints: 92, myPointsPossible: 100,
                                      myActiveSubmittedAt: nil, activeVersion: nil, latestVersion: nil)
    static let past = ClassWorkItem(versionGroupId: "g4", title: "Sonnet close reading",
                                    activeSessionId: nil, activeCode: nil,
                                    launchedAt: .now.addingTimeInterval(-86400 * 11),
                                    mySubmittedAt: .now.addingTimeInterval(-86400 * 11),
                                    myReleasedAt: nil, myPoints: nil, myPointsPossible: nil,
                                    myActiveSubmittedAt: nil, activeVersion: nil, latestVersion: nil)
    static let sampleList = [active, graded, past]
}

// MARK: - Exam reference materials (test_files / test_urls)

/// A teacher-uploaded reference file for an exam (a `test_files` row). The bytes
/// live in the private `essay-files` storage bucket at `storagePath`.
struct ExamFile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var originalName: String
    var mimeType: String
    var storagePath: String

    var isPDF: Bool { mimeType.contains("pdf") || originalName.lowercased().hasSuffix(".pdf") }

    enum CodingKeys: String, CodingKey {
        case id
        case originalName = "original_name"
        case mimeType = "mime_type"
        case storagePath = "storage_path"
    }

    static let sample = [
        ExamFile(id: "f1", originalName: "Passage excerpt.pdf", mimeType: "application/pdf", storagePath: ""),
        ExamFile(id: "f2", originalName: "Imagery glossary.pdf", mimeType: "application/pdf", storagePath: ""),
    ]
}

/// A teacher-approved reference link for an exam (a `test_urls` row).
struct ExamLink: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    var url: String

    /// Bare host for display + whitelist. Tolerates a schemeless stored URL
    /// (e.g. "gcschool.org/library") by normalizing before parsing.
    var host: String {
        let raw = url.contains("://") ? url : "https://" + url
        return URL(string: raw)?.host ?? url
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case url
    }

    static let sample = [
        ExamLink(id: "u1", displayName: "JSTOR", url: "https://jstor.org/"),
        ExamLink(id: "u2", displayName: "BBC", url: "https://bbc.com/"),
        ExamLink(id: "u3", displayName: "Grace Church School", url: "https://gcschool.org/"),
    ]
}

// MARK: - Live roster (proctoring monitor)

struct RosterStudent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    /// nil = the network check was not performed (the native app deliberately
    /// skips IP matching; Electron rows still carry a real value).
    var networkSame: Bool?
    var remote: Bool
    var capture: Bool
    var displays: Int
    var isVM: Bool
    var status: String        // "writing" | "review" | "joined" | "submitted"

    /// Overall integrity signal. An unperformed network check is not a warning.
    var signal: Signal {
        if remote || capture || isVM || networkSame == false || displays > 1 { return .warn }
        return .ok
    }
    enum Signal { case ok, warn, bad }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case networkSame = "ip_match"
        case remote = "remote_session"
        case capture = "screen_capture"
        case displays = "display_count"
        case isVM = "is_vm"
    }

    init(id: String, name: String, networkSame: Bool?, remote: Bool, capture: Bool,
         displays: Int, isVM: Bool, status: String) {
        self.id = id; self.name = name; self.networkSame = networkSame
        self.remote = remote; self.capture = capture; self.displays = displays
        self.isVM = isVM; self.status = status
    }

    /// Tolerant decode from a `students` row (fields are null for a student who
    /// just joined and hasn't run checks yet).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Student"
        networkSame = try? c.decode(Bool.self, forKey: .networkSame)
        remote = (try? c.decode(Bool.self, forKey: .remote)) ?? false
        capture = (try? c.decode(Bool.self, forKey: .capture)) ?? false
        displays = (try? c.decode(Int.self, forKey: .displays)) ?? 1
        isVM = (try? c.decode(Bool.self, forKey: .isVM)) ?? false
        status = (try? c.decode(String.self, forKey: .status)) ?? "joined"
    }

    static let sample = [
        RosterStudent(id: "1", name: "Ava Chen", networkSame: true, remote: false, capture: false, displays: 1, isVM: false, status: "writing"),
        RosterStudent(id: "2", name: "Ben Ortiz", networkSame: false, remote: false, capture: false, displays: 1, isVM: false, status: "review"),
        RosterStudent(id: "3", name: "Maya Singh", networkSame: true, remote: false, capture: false, displays: 2, isVM: false, status: "writing"),
    ]
}

// MARK: - Teacher-side: enrollment, submissions, grades

/// A class roster member (a `class_enrollments` row).
struct ClassEnrollment: Identifiable, Codable, Hashable, Sendable {
    var displayName: String
    var userId: String
    var createdAt: Date?
    var removedAt: Date?

    var id: String { userId }
    var isActive: Bool { removedAt == nil }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case userId = "user_id"
        case createdAt = "created_at"
        case removedAt = "removed_at"
    }
}

/// A student's essay submission (an `essay_submissions` row), teacher-side.
struct TeacherSubmission: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var sessionId: String?
    var studentId: String?
    var questionId: String?
    var contentHtml: String?
    var wordCount: Int?
    var submittedAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case studentId = "student_id"
        case questionId = "question_id"
        case contentHtml = "content_html"
        case wordCount = "word_count"
        case submittedAt = "submitted_at"
        case updatedAt = "updated_at"
    }
}

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

/// A grade for a submission (an `essay_grades` row).
struct EssayGrade: Identifiable, Codable, Hashable, Sendable {
    var submissionId: String
    var points: Double?
    var pointsPossible: Double?
    var feedback: String?
    var releasedAt: Date?

    var id: String { submissionId }
    var isReleased: Bool { releasedAt != nil }

    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case points
        case pointsPossible = "points_possible"
        case feedback
        case releasedAt = "released_at"
    }
}

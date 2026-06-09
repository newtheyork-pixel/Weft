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
}

struct Assignment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var versionGroupId: String
    var versionNumber: Int
    var questions: [Question]
    var timeLimitMinutes: Int?

    var isVersioned: Bool { versionNumber > 1 }

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
    }

    enum Section { case active, graded, past }

    /// Which bucket this assignment belongs in for the student class home.
    var section: Section {
        if activeSessionId != nil { return .active }
        if myReleasedAt != nil { return .graded }
        return .past
    }

    static let active = ClassWorkItem(versionGroupId: "g1", title: "Lit essay 1",
                                      activeSessionId: "s1", activeCode: "483920",
                                      launchedAt: .now, mySubmittedAt: nil,
                                      myReleasedAt: nil, myPoints: nil, myPointsPossible: nil)
    static let graded = ClassWorkItem(versionGroupId: "g3", title: "Rhetoric analysis",
                                      activeSessionId: nil, activeCode: nil,
                                      launchedAt: .now.addingTimeInterval(-86400 * 3),
                                      mySubmittedAt: .now.addingTimeInterval(-86400 * 3),
                                      myReleasedAt: .now.addingTimeInterval(-86400 * 2),
                                      myPoints: 92, myPointsPossible: 100)
    static let past = ClassWorkItem(versionGroupId: "g4", title: "Sonnet close reading",
                                    activeSessionId: nil, activeCode: nil,
                                    launchedAt: .now.addingTimeInterval(-86400 * 11),
                                    mySubmittedAt: .now.addingTimeInterval(-86400 * 11),
                                    myReleasedAt: nil, myPoints: nil, myPointsPossible: nil)
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

    var host: String { URL(string: url)?.host ?? url }

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
    var networkSame: Bool
    var remote: Bool
    var capture: Bool
    var displays: Int
    var isVM: Bool
    var status: String        // "writing" | "review" | "joined" | "submitted"

    /// Overall integrity signal.
    var signal: Signal {
        if remote || capture || isVM || !networkSame || displays > 1 { return .warn }
        return .ok
    }
    enum Signal { case ok, warn, bad }

    static let sample = [
        RosterStudent(id: "1", name: "Ava Chen", networkSame: true, remote: false, capture: false, displays: 1, isVM: false, status: "writing"),
        RosterStudent(id: "2", name: "Ben Ortiz", networkSame: false, remote: false, capture: false, displays: 1, isVM: false, status: "review"),
        RosterStudent(id: "3", name: "Maya Singh", networkSame: true, remote: false, capture: false, displays: 2, isVM: false, status: "writing"),
    ]
}

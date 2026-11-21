//
//  TeacherKeyPins.swift
//  Weft — remember which device keys belong to each teacher, so whoever runs
//  the server cannot quietly add a key of their own and read new essays.
//
//  The first exam with a teacher pins that teacher's keys on this Mac (trust
//  on first use). Later exams wrap ONLY to pinned keys. A key the server adds
//  afterwards is ignored and the student is told; it is trusted only after
//  the teacher reads out their lock code and the student confirms it matches.
//

import Foundation
import CryptoKit

enum TeacherKeyPins {

    private static let defaultsPrefix = "weft.teacherKeyPins."

    /// Pinned kids for (student, teacher) on this Mac. Empty = never pinned.
    static func pinned(studentId: String, teacherId: String) -> Set<String> {
        let raw = UserDefaults.standard.stringArray(forKey: key(studentId, teacherId)) ?? []
        return Set(raw)
    }

    static func pin(_ kids: Set<String>, studentId: String, teacherId: String) {
        UserDefaults.standard.set(kids.sorted(), forKey: key(studentId, teacherId))
    }

    private static func key(_ studentId: String, _ teacherId: String) -> String {
        defaultsPrefix + studentId + "." + teacherId
    }

    /// Code for a set of keys, e.g. "K7Q4-MD9X-TBR2-W8HN": 16 characters,
    /// ~78 bits, so finding a fake key with the same code is out of reach. Same keys, same code on
    /// every Mac, so a teacher can read theirs aloud and students compare.
    static func lockCode(kids: Set<String>) -> String {
        guard !kids.isEmpty else { return "none" }
        let joined = kids.sorted().joined(separator: "\n")
        let digest = Array(SHA256.hash(data: Data(joined.utf8)))
        // Crockford-style alphabet: no 0/O or 1/I/L confusion when read aloud.
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")
        var chars: [Character] = []
        for i in 0..<16 { chars.append(alphabet[Int(digest[i]) % alphabet.count]) }
        return stride(from: 0, to: 16, by: 4)
            .map { String(chars[$0..<($0 + 4)]) }
            .joined(separator: "-")
    }
}

// Trust on first use: the FIRST exam a student takes with a teacher pins
// whatever keys the server lists then. Teachers can close that gap by showing
// their lock code at the first exam so students compare it.

/// Outcome of checking a teacher's published keys against this Mac's pins.
enum ExamLockState: Equatable, Sendable {
    /// Ready: wrap to these teacher kids. `code` is the teacher's lock code.
    case ready(code: String)
    /// The teacher has never opened Weft on a Mac, so there is nothing to
    /// seal to. The exam cannot start (essays are never sent unsealed).
    case noTeacherKey
    /// The server now lists teacher keys this Mac has not seen. They are
    /// ignored until the student confirms the new code with the teacher.
    /// Begin stays blocked until the student confirms the new code.
    /// `stillReady` = at least one pinned key is still listed.
    case changed(newCode: String, stillReady: Bool)
    /// No teacher is known for this exam (no class), so it cannot be sealed.
    case unknownTeacher
}

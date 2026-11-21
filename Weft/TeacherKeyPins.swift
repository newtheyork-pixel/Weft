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

    /// Short code for a set of keys, e.g. "K7Q4M-D9XTB" (10 characters,
    /// ~49 bits: too many to grind a matching fake key for). Same keys, same code on
    /// every Mac, so a teacher can read theirs aloud and students compare.
    static func lockCode(kids: Set<String>) -> String {
        guard !kids.isEmpty else { return "none" }
        let joined = kids.sorted().joined(separator: "\n")
        let digest = Array(SHA256.hash(data: Data(joined.utf8)))
        // Crockford-style alphabet: no 0/O or 1/I/L confusion when read aloud.
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")
        var chars: [Character] = []
        for i in 0..<10 { chars.append(alphabet[Int(digest[i]) % alphabet.count]) }
        return String(chars[0..<5]) + "-" + String(chars[5..<10])
    }
}

/// Outcome of checking a teacher's published keys against this Mac's pins.
enum ExamLockState: Equatable, Sendable {
    /// Ready: wrap to these teacher kids. `code` is the teacher's lock code.
    case ready(code: String)
    /// The teacher has never opened Weft on a Mac, so there is nothing to
    /// seal to. The exam cannot start (essays are never sent unsealed).
    case noTeacherKey
    /// The server now lists teacher keys this Mac has not seen. They are
    /// ignored until the student confirms the new code with the teacher.
    /// `stillReady` = at least one pinned key remains, so the exam can run
    /// sealed to the known keys meanwhile.
    case changed(newCode: String, stillReady: Bool)
    /// No teacher is known for this exam (no class), so it cannot be sealed.
    case unknownTeacher
}

//
//  EssayKey.swift
//  Weft — state of the signed-in person's essay key on this Mac, and of
//  the teacher key an exam is sealed to.
//

import Foundation

/// Whether this Mac holds the signed-in person's essay key.
enum EssayKeyState: Equatable {
    /// No essay password yet: pick one.
    case needsSetup
    /// A password exists; type it once on this Mac.
    case needsUnlock
    case ready
}

/// Whether the current exam's essay can be sealed to the teacher.
enum ExamLockState: Equatable {
    case ready
    /// The teacher hasn't set an essay password yet.
    case noTeacherKey
    /// The exam isn't linked to a class, so there's no teacher to seal to.
    case unknownTeacher
    /// The teacher's key isn't the one this Mac saw before for this class.
    /// Nothing is sealed to it until the student chooses to trust it (SAT-21).
    case teacherKeyChanged
}

/// The teacher key each student Mac has seen per class (SAT-21). The first
/// key seen is remembered; a different one later means the teacher reset
/// their essay password, or someone swapped the key on the server. Key ids
/// are public, so plain preferences are fine.
enum TeacherKeyPins {
    private static func key(_ me: String, _ classId: String) -> String {
        "weft.teacherKeyPin.\(me).\(classId)"
    }
    static func pinned(me: String, classId: String) -> String? {
        UserDefaults.standard.string(forKey: key(me, classId))
    }
    static func pin(_ kid: String, me: String, classId: String) {
        UserDefaults.standard.set(kid, forKey: key(me, classId))
    }

    /// The keys safe to seal to. A first key is remembered. A changed key
    /// comes back as `changedTo` with nothing to seal to.
    static func check(_ keys: [DevicePublicKey], me: String,
                      classId: String) -> (ok: [DevicePublicKey], changedTo: DevicePublicKey?) {
        guard let first = keys.first else { return ([], nil) }
        guard let known = pinned(me: me, classId: classId) else {
            pin(first.kid, me: me, classId: classId)
            return (keys, nil)
        }
        let same = keys.filter { $0.kid == known }
        return same.isEmpty ? ([], first) : (same, nil)
    }
}

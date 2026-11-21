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
}

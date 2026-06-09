//
//  AppState.swift
//  Weft — observable app-wide state: who's signed in, which role view is up,
//  and (for now) the mock data the UI renders until Supabase is wired.
//

import SwiftUI
import Observation

@Observable
final class AppState {
    enum Route: Equatable { case signIn, teacher, student }

    var route: Route = .signIn
    var role: UserRole?
    var displayName: String = ""
    var isAdmin: Bool = false

    // Mock data for the UI build-out phase (replaced by Supabase queries).
    var enrolledClasses: [ClassRoom] = [.sample, .sample2]
    var classWork: [ClassWorkItem] = ClassWorkItem.sampleList
    var assignments: [Assignment] = [.sample, .sample2]
    var teacherClasses: [ClassRoom] = [.sample, .sample2]
    var roster: [RosterStudent] = RosterStudent.sample

    // MARK: Routing

    func enterTeacher() {
        role = .teacher
        if displayName.isEmpty { displayName = "Thomas Seirer" }
        route = .teacher
    }

    func enterStudent() {
        role = .student
        if displayName.isEmpty { displayName = "Ava Chen" }
        route = .student
    }

    func signOut() {
        role = nil
        route = .signIn
    }
}

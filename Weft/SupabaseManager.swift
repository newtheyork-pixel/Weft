//
//  SupabaseManager.swift
//  Weft — a thin Supabase client built on URLSession only (NO supabase-js / SDK).
//
//  It mirrors the renderer's calling patterns (supabase-config.js + student.js +
//  teacher.js): a PostgREST layer (.from(...).select/insert/update) plus an RPC
//  layer (/rest/v1/rpc/<name>) and a GoTrue auth scaffold (PKCE OAuth via
//  ASWebAuthenticationSession). The shared anon key goes on every request as the
//  `apikey` header; once a user signs in, the access token rides along as a
//  Bearer `Authorization` header so row-level security sees the real user.
//
//  Design notes:
//  - `final class` + a shared singleton, matching how the renderer keeps one
//    `supabase` client. Token mutation is funnelled through @MainActor so the
//    UI and the network layer read a consistent value (Swift 6 strict
//    concurrency).
//  - Networking that needs entitlements (the OAuth web session) is scaffolded
//    with clear TODOs; the PostgREST/RPC plumbing is real and ready to call.
//

import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif
import AuthenticationServices

// MARK: - Configuration (mirrors renderer/supabase-config.js)

enum SupabaseConfig {
    static let url = URL(string: "https://elrrvicxsguqstqciodn.supabase.co")!
    static let anonKey = "sb_publishable_pTH5Q3s2o2CbCdDb7aXuvw_HsGZedAs"

    /// Custom URL scheme the OAuth flow redirects back to. Must be registered in
    /// the app's Info.plist (CFBundleURLTypes) for the deep link to land.
    static let redirectScheme = "weft"
    static let redirectURL = "weft://auth-callback"
}

// MARK: - Errors

enum SupabaseError: LocalizedError {
    case badResponse(status: Int, body: String)
    case noData
    case notSignedIn
    case auth(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(status, body):
            return "Supabase request failed (\(status)). \(body)"
        case .noData:
            return "Supabase returned no data."
        case .notSignedIn:
            return "You are not signed in."
        case let .auth(message):
            return message
        case let .decoding(message):
            return "Could not read the response. \(message)"
        }
    }
}

// MARK: - Manager

/// `@unchecked Sendable`: the only mutable state (`accessToken`/`refreshToken`)
/// is isolated to `@MainActor`; everything else is immutable (`let`). The
/// URLSession/JSONCoder members are thread-safe. That makes the shared singleton
/// safe to reach from any task under Swift 6 strict concurrency.
final class SupabaseManager: @unchecked Sendable {

    static let shared = SupabaseManager()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// The signed-in user's access token. nil until OAuth completes. Read on the
    /// main actor so the network layer and UI never see a torn value.
    @MainActor private(set) var accessToken: String?
    /// Refresh token from the same GoTrue session, kept for `grant_type=refresh_token`.
    @MainActor private(set) var refreshToken: String?

    private init(session: URLSession = .shared) {
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .supabase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .supabase
        self.encoder = encoder
    }

    // MARK: Token

    @MainActor
    func setSession(accessToken: String?, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    @MainActor
    func clearSession() {
        accessToken = nil
        refreshToken = nil
    }

    /// Headers for every PostgREST / RPC call. `apikey` is always the anon key;
    /// the Bearer token is the user's access token when signed in, otherwise the
    /// anon key (which is what GoTrue expects for anonymous reads).
    @MainActor
    private func headers(contentJSON: Bool) -> [String: String] {
        var h: [String: String] = [
            "apikey": SupabaseConfig.anonKey,
            "Authorization": "Bearer \(accessToken ?? SupabaseConfig.anonKey)"
        ]
        if contentJSON {
            h["Content-Type"] = "application/json"
        }
        return h
    }

    // MARK: - Low-level request

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseError.auth(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.noData
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.badResponse(status: http.statusCode, body: body)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // PostgREST returns 204 with an empty body for some writes; surface a
        // clear error rather than a cryptic decode failure.
        guard !data.isEmpty else { throw SupabaseError.noData }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw SupabaseError.decoding("\(error.localizedDescription). Body: \(snippet)")
        }
    }

    // MARK: - PostgREST helpers (the .from(...).select/insert/update surface)

    /// SELECT rows from a table. `query` carries the PostgREST filters and the
    /// `select=` projection, mirroring `.from(table).select(...).eq(...)` in JS.
    ///
    ///     let rows: [ClassRoom] = try await rows(
    ///         "class_enrollments",
    ///         query: [.init(name: "select", value: "class_id,classes(id,name)"),
    ///                 .init(name: "user_id", value: "eq.\(uid)")])
    func rows<T: Decodable>(_ table: String, query: [URLQueryItem] = []) async throws -> [T] {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("rest/v1/\(table)"),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        for (k, v) in await headers(contentJSON: false) { req.setValue(v, forHTTPHeaderField: k) }

        let data = try await perform(req)
        return try decode([T].self, from: data)
    }

    /// INSERT rows. Mirrors `.from(table).insert(values).select()`. Pass
    /// `returning: false` for fire-and-forget writes (PostgREST returns 204).
    @discardableResult
    func insert<Body: Encodable, T: Decodable>(
        _ table: String,
        values: Body,
        returning: Bool = true
    ) async throws -> [T] {
        var req = URLRequest(url: SupabaseConfig.url.appendingPathComponent("rest/v1/\(table)"))
        req.httpMethod = "POST"
        for (k, v) in await headers(contentJSON: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(returning ? "return=representation" : "return=minimal",
                     forHTTPHeaderField: "Prefer")
        req.httpBody = try encoder.encode(values)

        let data = try await perform(req)
        guard returning else { return [] }
        return try decode([T].self, from: data)
    }

    /// UPDATE rows matched by `query` (the PostgREST filters, e.g. id=eq.123).
    /// Mirrors `.from(table).update(values).eq(...)`.
    @discardableResult
    func update<Body: Encodable, T: Decodable>(
        _ table: String,
        values: Body,
        query: [URLQueryItem],
        returning: Bool = true
    ) async throws -> [T] {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("rest/v1/\(table)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "PATCH"
        for (k, v) in await headers(contentJSON: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(returning ? "return=representation" : "return=minimal",
                     forHTTPHeaderField: "Prefer")
        req.httpBody = try encoder.encode(values)

        let data = try await perform(req)
        guard returning else { return [] }
        return try decode([T].self, from: data)
    }

    // MARK: - RPC

    /// POST to /rest/v1/rpc/<name>, decoding the JSON result into `T`. Mirrors
    /// `supabase.rpc(name, params)`. Postgres functions returning SETOF decode as
    /// an array `T`; scalar-returning functions decode as the scalar.
    func rpc<T: Decodable>(_ name: String, params: [String: Any] = [:]) async throws -> T {
        var req = URLRequest(url: SupabaseConfig.url.appendingPathComponent("rest/v1/rpc/\(name)"))
        req.httpMethod = "POST"
        for (k, v) in await headers(contentJSON: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: params, options: [])

        let data = try await perform(req)
        return try decode(T.self, from: data)
    }

    // MARK: - Edge Functions (/functions/v1/<name>)

    /// POST to a Supabase Edge Function. Sends the `apikey` and the signed-in
    /// user's Bearer token so a `verify_jwt` function accepts the call and can
    /// re-derive the caller. Returns the raw response data; throws on non-2xx.
    @discardableResult
    func callFunction(_ name: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: SupabaseConfig.url.appendingPathComponent("functions/v1/\(name)"))
        req.httpMethod = "POST"
        for (k, v) in await headers(contentJSON: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await perform(req)
    }

    /// Fire a notification-email event (assignment_launched / class_invite /
    /// grades_published). Best-effort: a failed or unconfigured email must never
    /// break launching, grading, or joining, so this swallows errors.
    func notify(_ event: String, body: [String: Any]) async {
        var payload = body
        payload["event"] = event
        do { _ = try await callFunction("notify", body: payload) }
        catch { print("notify(\(event)) failed: \(error)") }
    }

    // MARK: - Typed RPC calls (the real Weft RPCs)

    /// One row per assignment (version_group_id) for a class: active session,
    /// the student's own submission/grade state. See student.js `list_class_work`.
    func listClassWork(classId: String) async throws -> [ClassWorkItem] {
        try await rpc("list_class_work", params: ["p_class_id": classId])
    }

    /// Degraded fallback when list_class_work isn't deployed: OPEN sessions only.
    /// Returns the raw decoded rows (shape varies, so the caller decodes a type).
    func listClassAssignments<T: Decodable>(classId: String) async throws -> [T] {
        try await rpc("list_class_assignments", params: ["p_class_id": classId])
    }

    /// Resolve a 6-digit session code to its session row. student.js takes the
    /// first element when the RPC returns an array.
    func lookupSession(code: String) async throws -> ExamSession? {
        let sessions: [ExamSession] = try await rpc("lookup_session_by_code",
                                                     params: ["p_code": code])
        return sessions.first
    }

    /// Idempotent class enrollment by class code. Returns the joined class row.
    /// SECURITY DEFINER on the server; matches student.js `join_class_by_code`.
    func joinClass(code: String, displayName: String) async throws -> ClassRoom? {
        let classes: [ClassRoom] = try await rpc("join_class_by_code", params: [
            "p_code": code,
            "p_display_name": displayName
        ])
        return classes.first
    }

    /// Released grades + essays for the signed-in student across all sessions.
    /// New consolidated RPC replacing the multi-table stitch in loadReturnedEssays().
    func getMyReturnedWork() async throws -> [ReturnedWorkItem] {
        try await rpc("get_my_returned_work")
    }

    /// The signed-in student's classes, via the documented enrollment join
    /// (`class_enrollments` → `classes`). Mirrors student.js's class list. The
    /// enrollment row doesn't carry the join code, so `joinCode` is left empty
    /// (the student home never shows it).
    func myClasses(userId: String) async throws -> [ClassRoom] {
        let rows: [EnrollmentRow] = try await rows("class_enrollments", query: [
            URLQueryItem(name: "select", value: "class_id,classes(id,name,archived_at)"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)")
        ])
        return rows.compactMap { row in
            guard let c = row.classes else { return nil }
            return ClassRoom(id: c.id, name: c.name, joinCode: "", archivedAt: c.archivedAt)
        }
    }

    // MARK: - Exam reference materials

    /// A single test row.
    func getTest(id: String) async throws -> Assignment? {
        let result: [Assignment] = try await rows("tests", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "id", value: "eq.\(id)"),
        ])
        return result.first
    }

    /// Reference files by id (test_files is a per-teacher pool keyed by a
    /// question's `fileIds`, not a test_id). Rendered via a signed URL.
    func listTestFiles(ids: [String]) async throws -> [ExamFile] {
        guard !ids.isEmpty else { return [] }
        return try await rows("test_files", query: [
            URLQueryItem(name: "select", value: "id,original_name,mime_type,storage_path"),
            URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"),
        ])
    }

    /// Approved reference links by id (test_urls pool, keyed by `urlIds`).
    func listTestURLs(ids: [String]) async throws -> [ExamLink] {
        guard !ids.isEmpty else { return [] }
        return try await rows("test_urls", query: [
            URLQueryItem(name: "select", value: "id,display_name,url"),
            URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"),
        ])
    }

    /// Insert approved links into the test_urls pool, returning their new ids
    /// (to store in a question's `urlIds`).
    func createTestURLs(userId: String, links: [(name: String, href: String)]) async throws -> [String] {
        guard !links.isEmpty else { return [] }
        struct Row: Encodable { let teacher_user_id: String; let display_name: String; let url: String; let source: String }
        let payload = links.map { Row(teacher_user_id: userId, display_name: $0.name, url: $0.href, source: "custom") }
        let created: [ExamLink] = try await insert("test_urls", values: payload, returning: true)
        return created.map(\.id)
    }

    /// Create a time-limited signed URL for an object in a (private) storage
    /// bucket. Used to load `essay-files` PDFs into the exam PDF viewer. Returns
    /// the fully-qualified URL.
    @MainActor
    func signedURL(bucket: String, path: String, expiresInSeconds: Int = 3600) async throws -> URL {
        let endpoint = SupabaseConfig.url
            .appendingPathComponent("storage/v1/object/sign")
            .appendingPathComponent(bucket)
            .appendingPathComponent(path)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        for (k, v) in headers(contentJSON: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": expiresInSeconds])
        let data = try await perform(req)
        struct SignedResponse: Decodable { let signedURL: String }
        let signed = try decode(SignedResponse.self, from: data)
        // The API returns an absolute-path reference like
        // "/object/sign/<bucket>/<path>?token=...". Concatenate it onto the
        // storage base explicitly — RFC 3986 relative resolution of a
        // leading-slash reference would REPLACE the base path and drop the
        // "/storage/v1" segment, 404-ing every file. (This matches supabase-js,
        // which does `${url}/storage/v1${signedURL}`.)
        let suffix = signed.signedURL.hasPrefix("/") ? signed.signedURL : "/" + signed.signedURL
        let baseStr = SupabaseConfig.url.appendingPathComponent("storage/v1").absoluteString
        if let full = URL(string: baseStr + suffix) {
            return full
        }
        throw SupabaseError.decoding("Bad signed URL: \(signed.signedURL)")
    }

    // MARK: - Low-level upsert / delete (used by the teacher write paths)

    /// PostgREST upsert (insert-or-merge on a conflict target).
    @discardableResult
    func upsert<Body: Encodable, T: Decodable>(
        _ table: String, values: Body, onConflict: String, returning: Bool = true
    ) async throws -> [T] {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("rest/v1/\(table)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "on_conflict", value: onConflict)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        for (k, v) in await headers(contentJSON: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("resolution=merge-duplicates,\(returning ? "return=representation" : "return=minimal")",
                     forHTTPHeaderField: "Prefer")
        req.httpBody = try encoder.encode(values)
        let data = try await perform(req)
        guard returning else { return [] }
        return try decode([T].self, from: data)
    }

    /// DELETE rows matched by `query`.
    func delete(_ table: String, query: [URLQueryItem]) async throws {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("rest/v1/\(table)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        for (k, v) in await headers(contentJSON: false) { req.setValue(v, forHTTPHeaderField: k) }
        _ = try await perform(req)
    }

    // MARK: - Teacher reads

    func listTeacherClasses() async throws -> [ClassRoom] {
        try await rows("classes", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "archived_at", value: "is.null"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ])
    }

    func listTeacherTests(userId: String) async throws -> [Assignment] {
        try await rows("tests", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "teacher_user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ])
    }

    func listOpenSessions(userId: String) async throws -> [ExamSession] {
        try await rows("sessions", query: [
            URLQueryItem(name: "select", value: "id,code,test_id,class_id,status"),
            URLQueryItem(name: "teacher_user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "status", value: "eq.open"),
        ])
    }

    func listSessionStudents(sessionId: String) async throws -> [RosterStudent] {
        try await rows("students", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "session_id", value: "eq.\(sessionId)"),
            URLQueryItem(name: "order", value: "joined_at.asc"),
        ])
    }

    func listClassEnrollments(classId: String) async throws -> [ClassEnrollment] {
        try await rows("class_enrollments", query: [
            URLQueryItem(name: "select", value: "display_name,user_id,created_at,removed_at"),
            URLQueryItem(name: "class_id", value: "eq.\(classId)"),
            URLQueryItem(name: "order", value: "created_at.asc"),
        ])
    }

    func listSessionSubmissions(sessionId: String) async throws -> [TeacherSubmission] {
        try await rows("essay_submissions", query: [
            URLQueryItem(name: "select", value: "id,session_id,student_id,question_id,content_html,word_count,updated_at,submitted_at"),
            URLQueryItem(name: "session_id", value: "eq.\(sessionId)"),
            URLQueryItem(name: "order", value: "submitted_at.asc.nullslast"),
        ])
    }

    func listGrades(submissionIds: [String]) async throws -> [EssayGrade] {
        guard !submissionIds.isEmpty else { return [] }
        let inList = "in.(" + submissionIds.joined(separator: ",") + ")"
        return try await rows("essay_grades", query: [
            URLQueryItem(name: "select", value: "submission_id,points,points_possible,feedback,released_at"),
            URLQueryItem(name: "submission_id", value: inList),
        ])
    }

    // MARK: - Teacher writes

    @discardableResult
    func createClass(name: String) async throws -> ClassRoom? {
        struct Payload: Encodable { let name: String; let join_code: String }
        let result: [ClassRoom] = try await insert("classes",
            values: Payload(name: name, join_code: Self.classCode()))
        return result.first
    }

    @discardableResult
    func createTest(teacherUserId: String, title: String, questions: [Question],
                    timeLimitMinutes: Int?) async throws -> Assignment? {
        struct Payload: Encodable {
            let teacher_user_id: String; let title: String
            let questions: [Question]; let time_limit_minutes: Int?
        }
        let result: [Assignment] = try await insert("tests",
            values: Payload(teacher_user_id: teacherUserId, title: title,
                            questions: questions, time_limit_minutes: timeLimitMinutes))
        return result.first
    }

    func updateTest(id: String, title: String, questions: [Question], timeLimitMinutes: Int?) async throws {
        struct Payload: Encodable {
            let title: String; let questions: [Question]
            let time_limit_minutes: Int?; let updated_at: String
        }
        let _: [Assignment] = try await update("tests",
            values: Payload(title: title, questions: questions,
                            time_limit_minutes: timeLimitMinutes, updated_at: Self.nowISO()),
            query: [URLQueryItem(name: "id", value: "eq.\(id)")], returning: false)
    }

    func deleteTest(id: String) async throws {
        try await delete("tests", query: [URLQueryItem(name: "id", value: "eq.\(id)")])
    }

    func archiveClass(id: String) async throws {
        struct Payload: Encodable { let archived_at: String }
        let _: [ClassRoom] = try await update("classes",
            values: Payload(archived_at: Self.nowISO()),
            query: [URLQueryItem(name: "id", value: "eq.\(id)")], returning: false)
    }

    @discardableResult
    func launchSession(testId: String?, classId: String?, teacherUserId: String,
                       teacherIP: String?) async throws -> ExamSession? {
        struct Payload: Encodable {
            let code: String; let teacher_ip: String?; let status: String
            let teacher_user_id: String; let test_id: String?; let class_id: String?
        }
        let result: [ExamSession] = try await insert("sessions",
            values: Payload(code: Self.sessionCode(), teacher_ip: teacherIP, status: "open",
                            teacher_user_id: teacherUserId, test_id: testId, class_id: classId))
        return result.first
    }

    func endSession(id: String) async throws {
        struct Payload: Encodable { let status: String; let closed_at: String }
        let _: [ExamSession] = try await update("sessions",
            values: Payload(status: "closed", closed_at: Self.nowISO()),
            query: [URLQueryItem(name: "id", value: "eq.\(id)")], returning: false)
    }

    /// Upsert a grade. `essay_grades.session_id` and `student_id` are NOT NULL,
    /// so they MUST be supplied (mirrors teacher.js). `releasedAt` is the exact
    /// value to store (the caller decides whether to keep/clear the share time).
    func upsertGrade(submissionId: String, sessionId: String, studentId: String,
                     points: Double?, pointsPossible: Double, feedback: String,
                     releasedAt: String?) async throws {
        struct Payload: Encodable {
            let submission_id: String; let session_id: String; let student_id: String
            let points: Double?; let points_possible: Double
            let feedback: String; let released_at: String?
        }
        let _: [EssayGrade] = try await upsert("essay_grades",
            values: Payload(submission_id: submissionId, session_id: sessionId, student_id: studentId,
                            points: points, points_possible: pointsPossible, feedback: feedback,
                            released_at: releasedAt),
            onConflict: "submission_id", returning: false)
    }

    // MARK: - Code + time helpers

    /// 6-digit numeric session join code (mirrors teacher.js generateCode).
    static func sessionCode() -> String { String(Int.random(in: 100000...999999)) }

    /// 6-char class join code, no ambiguous chars (mirrors generateClassCode).
    static func classCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).compactMap { _ in alphabet.randomElement() })
    }

    static func nowISO() -> String { SupabaseDate.fractional.string(from: Date()) }

    // MARK: - User & role

    /// Fetch the signed-in user from GoTrue (`/auth/v1/user`). Requires a token.
    @MainActor
    func fetchUser() async throws -> AuthUser {
        guard accessToken != nil else { throw SupabaseError.notSignedIn }
        var req = URLRequest(url: SupabaseConfig.url.appendingPathComponent("auth/v1/user"))
        req.httpMethod = "GET"
        for (k, v) in headers(contentJSON: false) { req.setValue(v, forHTTPHeaderField: k) }
        let data = try await perform(req)
        return try decode(AuthUser.self, from: data)
    }

    /// Best-effort server-side role lookup. The renderer routes teachers via a
    /// "Teachers sheet"; the native side asks the server through a `get_my_role`
    /// RPC that returns 'teacher' | 'student' | 'admin'. If that RPC isn't
    /// deployed (or returns an unexpected shape) this returns nil and the caller
    /// falls back to the on-screen role chooser. Never throws.
    func resolveRole() async -> UserRole? {
        if let raw: String = try? await rpc("get_my_role") {
            return UserRole(rawValue: raw)
        }
        return nil
    }

    // MARK: - Auth (GoTrue) — OAuth PKCE scaffold

    /// Kick off Google sign-in: open GoTrue's `/authorize` in a system web
    /// session, wait for the `weft://auth-callback?code=...` redirect, then
    /// exchange the code for a session. This is the desktop equivalent of the
    /// renderer's `supabase.auth.signInWithOAuth({ provider: 'google' })`.
    ///
    /// TODO(entitlements): ASWebAuthenticationSession needs a presentation anchor
    /// and the app must register the `weft` URL scheme in Info.plist
    /// (CFBundleURLTypes) plus the Sign in with Apple / network entitlements as
    /// appropriate. Wire `presentationContextProvider` to the key window once the
    /// AppKit window is available.
    @MainActor
    func signInWithGoogle() async throws {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)

        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("auth/v1/authorize"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: SupabaseConfig.redirectURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        let authorizeURL = comps.url!

        let callbackURL = try await Self.runWebAuth(
            url: authorizeURL,
            callbackScheme: SupabaseConfig.redirectScheme
        )

        // The redirect lands as weft://auth-callback?code=<authCode>. Pull it out.
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            // GoTrue can also redirect with ?error=...; surface that.
            let message = items.first(where: { $0.name == "error_description" })?.value
                ?? "Sign-in did not complete."
            throw SupabaseError.auth(message)
        }

        try await exchangeCode(code, verifier: verifier)
    }

    /// Exchange a PKCE auth code for a session, POSTing to
    /// /auth/v1/token?grant_type=pkce with `{ auth_code, code_verifier }` (the
    /// exact body the supabase-js client sends), then store the tokens.
    @MainActor
    func exchangeCode(_ authCode: String, verifier: String) async throws {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("auth/v1/token"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "pkce")]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "auth_code": authCode,
            "code_verifier": verifier
        ])

        let data = try await perform(req)
        let token = try decode(TokenResponse.self, from: data)
        setSession(accessToken: token.accessToken, refreshToken: token.refreshToken)
    }

    /// Sign out: drop the local session. The GoTrue `/logout` round-trip is best
    /// effort and can be added once a stored token revoke is needed.
    @MainActor
    func signOut() {
        clearSession()
    }

    // MARK: - Web auth (ASWebAuthenticationSession bridge)

    /// Run a one-shot ASWebAuthenticationSession and return the callback URL.
    ///
    /// TODO(entitlements): in a sandboxed build this needs the
    /// `com.apple.security.network.client` entitlement, and the session needs a
    /// non-nil `presentationContextProvider`. We supply a default anchor below;
    /// swap in the real key window when one is guaranteed to exist.
    @MainActor
    private static func runWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        let anchorProvider = WebAuthPresentationAnchor()
        return try await withCheckedThrowingContinuation { continuation in
            let webAuth = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: SupabaseError.auth(error.localizedDescription))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: SupabaseError.auth("No callback URL."))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            webAuth.presentationContextProvider = anchorProvider
            webAuth.prefersEphemeralWebBrowserSession = false
            // Keep the anchor alive for the lifetime of the session.
            objc_setAssociatedObject(webAuth, &WebAuthPresentationAnchor.key,
                                     anchorProvider, .OBJC_ASSOCIATION_RETAIN)
            if !webAuth.start() {
                continuation.resume(throwing: SupabaseError.auth("Could not start the sign-in session."))
            }
        }
    }
}

// MARK: - Returned-work DTO (the get_my_returned_work RPC row)

/// A single released (graded) essay for the signed-in student. Mirrors the
/// stitched shape student.js builds in loadReturnedEssays(): the essay body, the
/// score, the teacher's overall feedback, and the shared inline comments.
///
/// This is the network DTO; the read-only UI (ReturnedWorkView) maps it into its
/// own presentation model. Lives here (not Models.swift) so this file stays
/// self-contained and the typed RPC actually compiles.
struct ReturnedWorkItem: Identifiable, Codable, Hashable, Sendable {
    let submissionId: String
    var questionId: String?
    var contentHtml: String
    var wordCount: Int
    var points: Double?
    var pointsPossible: Double
    var feedback: String
    var releasedAt: Date?
    var comments: [ReturnedComment]

    var id: String { submissionId }

    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case questionId = "question_id"
        case contentHtml = "content_html"
        case wordCount = "word_count"
        case points
        case pointsPossible = "points_possible"
        case feedback
        case releasedAt = "released_at"
        case comments
    }
}

/// A shared inline comment anchored to a quote in the returned essay. Mirrors the
/// `essay_comments` columns student.js reads (visibility filtered to 'shared').
struct ReturnedComment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var submissionId: String?
    var rangeStart: Int?
    var rangeEnd: Int?
    var quote: String?
    var body: String
    var visibility: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case submissionId = "submission_id"
        case rangeStart = "range_start"
        case rangeEnd = "range_end"
        case quote
        case body
        case visibility
        case createdAt = "created_at"
    }
}

// MARK: - User & enrollment DTOs

/// The GoTrue user record (`/auth/v1/user`). Google identities put the name in
/// `user_metadata.full_name` (sometimes just `name`).
struct AuthUser: Decodable, Sendable {
    let id: String
    let email: String?
    let userMetadata: Metadata?

    struct Metadata: Decodable, Sendable {
        let fullName: String?
        let name: String?
        let picture: String?
        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case name, picture
        }
    }

    var displayName: String? { userMetadata?.fullName ?? userMetadata?.name }
    var avatarURL: String? { userMetadata?.picture }

    enum CodingKeys: String, CodingKey {
        case id, email
        case userMetadata = "user_metadata"
    }
}

/// One `class_enrollments` row with the embedded class (PostgREST resource
/// embedding `classes(...)`). Decoded by `myClasses(userId:)`.
private struct EnrollmentRow: Decodable {
    let classId: String
    let classes: ClassInfo?

    struct ClassInfo: Decodable {
        let id: String
        let name: String
        let archivedAt: Date?
        enum CodingKeys: String, CodingKey {
            case id, name
            case archivedAt = "archived_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case classId = "class_id"
        case classes
    }
}

// MARK: - GoTrue token response

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - PKCE helpers

enum PKCE {
    /// A high-entropy code verifier (43–128 chars, URL-safe base64 of 32 bytes).
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// S256 challenge: base64url( SHA256(verifier) ).
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation anchor for ASWebAuthenticationSession

/// Supplies a window for the system auth sheet to attach to. On macOS this is an
/// NSWindow; we fall back to a throwaway window if no key window exists yet.
final class WebAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated(unsafe) static var key: UInt8 = 0

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        if let window = NSApp?.keyWindow ?? NSApp?.windows.first {
            return window
        }
        // TODO(entitlements): no window available — create a transient one so the
        // sheet has an anchor. Replace with the real app window when wiring up.
        return NSWindow()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

// MARK: - Date strategies (Supabase ISO8601 with optional fractional seconds)

extension JSONDecoder.DateDecodingStrategy {
    /// Postgres/PostgREST timestamps come back as ISO8601, sometimes with
    /// fractional seconds (e.g. 2026-06-08T12:34:56.789012+00:00) and sometimes
    /// without. Try the fractional formatter first, then the plain one.
    static let supabase = custom { decoder in
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let date = SupabaseDate.parse(raw) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognized Supabase date: \(raw)")
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static let supabase = custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(SupabaseDate.fractional.string(from: date))
    }
}

enum SupabaseDate {
    // ISO8601DateFormatter isn't Sendable, but these instances are configured
    // once and only ever read (parsing/formatting is internally synchronized), so
    // nonisolated(unsafe) is sound here.
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        fractional.date(from: raw) ?? plain.date(from: raw)
    }
}

//
//  SupabaseManager.swift
//  Weft — a thin Supabase client built on URLSession only (NO supabase-js / SDK).
//
//  It mirrors the renderer's calling patterns (supabase-config.js + student.js +
//  teacher.js): a PostgREST layer (.from(...).select/insert/update) plus an RPC
//  layer (/rest/v1/rpc/<name>) and GoTrue auth (PKCE OAuth in the user's
//  default browser, returning via weft://auth-callback). The shared anon key
//  goes on every request as the
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

// MARK: - Configuration (mirrors renderer/supabase-config.js)

enum SupabaseConfig {
    static let url = URL(string: "https://elrrvicxsguqstqciodn.supabase.co")!
    static let anonKey = "sb_publishable_pTH5Q3s2o2CbCdDb7aXuvw_HsGZedAs"

    /// Custom URL scheme the auth callback arrives on. Deliberately NOT `weft`:
    /// the Electron app also registers `weft://`, so a shared scheme lets macOS
    /// route the OAuth callback to the wrong app. `weftnative://` is unique to
    /// this native build. Registered in Info.plist (CFBundleURLTypes).
    static let redirectScheme = "weftnative"
    static let redirectURL = "weftnative://auth-callback"
    /// Where GoTrue sends the browser after Google. An HTTPS page (not a custom
    /// scheme directly) because Safari refuses to follow a server redirect chain
    /// into a custom scheme without a user gesture; the page performs the final
    /// weftnative://auth-callback hop itself and closes the tab.
    /// Must be on the Supabase Auth redirect allow-list.
    static let browserRedirectURL = "https://weft.optimizegrade.com/auth-finish"
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

/// `@unchecked Sendable`: all mutable state (the token, its refresh token, the
/// refresh deadline and the in-flight refresh) is isolated to `@MainActor`;
/// everything else is immutable (`let`). The
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
    /// When to swap the access token out: 80% of its advertised lifetime, so a
    /// request never carries a token that dies in flight. nil means "unknown"
    /// (no expires_in was returned), which is treated as fresh; the 401 path
    /// below is the backstop.
    @MainActor private var accessTokenRefreshAfter: Date?
    /// The refresh currently in flight. A whole exam's worth of requests can
    /// notice the same expiring token at once; they share ONE round-trip
    /// instead of racing GoTrue and rotating the refresh token N times (every
    /// rotation but the last would be invalidated).
    @MainActor private var refreshInFlight: Task<Bool, Never>?

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
    func setSession(accessToken: String?, refreshToken: String?, expiresIn: Int? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        if accessToken != nil, let expiresIn, expiresIn > 0 {
            // Supabase access tokens last an hour by default, so this lands
            // ~48 minutes in: well inside a 90-minute exam, and long before
            // any request could be refused.
            accessTokenRefreshAfter = Date().addingTimeInterval(TimeInterval(expiresIn) * 0.8)
        } else {
            accessTokenRefreshAfter = nil
        }
    }

    @MainActor
    func clearSession() {
        accessToken = nil
        refreshToken = nil
        accessTokenRefreshAfter = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
    }

    /// Refresh the GoTrue session (`grant_type=refresh_token`), storing the
    /// rotated pair. Single-flight and never throwing: the Bool says whether a
    /// retry is worth attempting. A failure deliberately does NOT clear the
    /// session (signing a student out mid-exam would be far worse than one
    /// failed request), but it does back the next attempt off by 30 seconds so
    /// a dead network can't turn into a refresh storm.
    @MainActor
    @discardableResult
    func refreshSession() async -> Bool {
        if let inFlight = refreshInFlight { return await inFlight.value }
        guard let token = refreshToken, !token.isEmpty else { return false }
        let task = Task<Bool, Never> {
            do {
                return try await self.exchangeRefreshToken(token)
            } catch {
                print("session refresh failed: \(error)")
                // Only back off if this is still the session we were refreshing:
                // a sign-out or a new sign-in during the round-trip must not
                // hobble the next account's first refresh.
                if !Task.isCancelled, self.refreshToken == token {
                    self.accessTokenRefreshAfter = Date().addingTimeInterval(30)
                }
                return false
            }
        }
        refreshInFlight = task
        let ok = await task.value
        // Not `refreshInFlight = nil`: clearSession plus a new sign-in may have
        // installed a different in-flight refresh while this one was running,
        // and dropping the reference to it would let two rotations race.
        if refreshInFlight == task { refreshInFlight = nil }
        return ok
    }

    /// POST /auth/v1/token?grant_type=refresh_token. GoTrue rotates the refresh
    /// token on every use, so the response's is stored (falling back to the one
    /// we sent, which some GoTrue versions omit on an unchanged session).
    /// Returns whether the rotated pair was actually installed: false when the
    /// session it belongs to is no longer the signed-in one.
    @MainActor
    private func exchangeRefreshToken(_ token: String) async throws -> Bool {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("auth/v1/token"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": token])

        // allowRefresh: false. This request IS the refresh; letting it take
        // the refresh-and-retry path would recurse.
        let data = try await perform(req, allowRefresh: false)
        // The account we were refreshing for may be gone: signing out cancels
        // this task and clears the session, and the next sign-in installs a
        // different pair. Installing the rotated tokens now would put the
        // previous account's token back on every following request, which on a
        // stalled network (URLSession waits 60 seconds) means the next person's
        // writes would be made as the person before them.
        guard !Task.isCancelled, refreshToken == token else { return false }
        let new = try decode(TokenResponse.self, from: data)
        setSession(accessToken: new.accessToken,
                   refreshToken: new.refreshToken ?? token,
                   expiresIn: new.expiresIn)
        return true
    }

    /// Proactive half of the refresh: swap the token out before it expires.
    /// True when the token actually changed, so the caller re-stamps the
    /// Authorization header it already built.
    @MainActor
    private func refreshIfExpiring() async -> Bool {
        guard accessToken != nil, refreshToken != nil,
              let after = accessTokenRefreshAfter, Date() >= after else { return false }
        let before = accessToken
        await refreshSession()
        return accessToken != before
    }

    /// Re-stamp a built request's Authorization header with the CURRENT bearer
    /// token. Only touches a request that already carried one, so the token
    /// endpoints (apikey only) are left exactly as they were.
    @MainActor
    private func reauthorized(_ request: URLRequest) -> URLRequest {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { return request }
        var req = request
        req.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)",
                     forHTTPHeaderField: "Authorization")
        return req
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

    /// Send `request`, keeping the session alive around it: refresh the access
    /// token before it expires, and if the server rejects the token anyway,
    /// refresh once and retry the same request with the new one. That is what
    /// lets a 90-minute exam keep autosaving and keep loading reference PDFs
    /// past the hour mark. `allowRefresh: false` is for the token endpoints
    /// themselves (they carry no Bearer token and must not recurse).
    private func perform(_ request: URLRequest, allowRefresh: Bool = true) async throws -> Data {
        var req = request
        if allowRefresh, await refreshIfExpiring() {
            req = reauthorized(req)
        }
        let sentToken = accessToken
        let (data, http) = try await send(req)

        if allowRefresh, sentToken != nil, Self.isTokenRejection(status: http.statusCode, body: data) {
            // If another request already refreshed while this one was in
            // flight, just retry with the new token; otherwise refresh once.
            var refreshed = accessToken != sentToken
            if !refreshed { refreshed = await refreshSession() }
            if refreshed {
                let (retryData, retryHTTP) = try await send(reauthorized(req))
                guard (200..<300).contains(retryHTTP.statusCode) else {
                    throw SupabaseError.badResponse(status: retryHTTP.statusCode,
                                                    body: String(data: retryData, encoding: .utf8) ?? "")
                }
                return retryData
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.badResponse(status: http.statusCode, body: body)
        }
        return data
    }

    /// One URLSession round-trip, with transport errors mapped the way the rest
    /// of this file expects and a non-HTTP response treated as no data.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseError.auth(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.noData
        }
        return (data, http)
    }

    /// True when the response says the TOKEN was the problem, not the caller's
    /// permissions. PostgREST answers an expired JWT with 401 (PGRST301);
    /// Storage has shipped versions that answer 400 with the JWT named in the
    /// body, and an RLS refusal (a real 403) must not trigger a refresh.
    private static func isTokenRejection(status: Int, body: Data) -> Bool {
        if status == 401 { return true }
        guard status == 400 || status == 403 else { return false }
        let text = String(data: body.prefix(400), encoding: .utf8)?.lowercased() ?? ""
        return text.contains("jwt")
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

    /// PostgREST returns a JSON object for `RETURNS composite` and a JSON
    /// array for `RETURNS SETOF` / `RETURNS TABLE`. Join-class is the former
    /// (`returns public.classes`) but has shipped both shapes; accept either
    /// so a successful enroll is never discarded as a decode miss.
    private func decodeOne<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty else { throw SupabaseError.noData }
        if let one = try? decoder.decode(T.self, from: data) { return one }
        if let many = try? decoder.decode([T].self, from: data) {
            guard let first = many.first else { throw SupabaseError.noData }
            return first
        }
        return try decode(T.self, from: data)
    }

    /// RPC that returns a single row, whether PostgREST wrapped it in an array.
    func rpcOne<T: Decodable>(_ name: String, params: [String: Any] = [:]) async throws -> T {
        var req = URLRequest(url: SupabaseConfig.url.appendingPathComponent("rest/v1/rpc/\(name)"))
        req.httpMethod = "POST"
        for (k, v) in await headers(contentJSON: true) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: params, options: [])
        let data = try await perform(req)
        return try decodeOne(T.self, from: data)
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
    /// The SQL is `returns public.classes` (one composite row), so PostgREST
    /// sends an object — decoding that as `[ClassRoom]` used to throw, the join
    /// screen swallowed the error, and the student sat on the code field.
    func joinClass(code: String, displayName: String) async throws -> ClassRoom {
        try await rpcOne("join_class_by_code", params: [
            "p_code": code,
            "p_display_name": displayName
        ])
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

    /// DELETE rows matched by `query`, returning the rows actually deleted
    /// (Prefer: return=representation). The point: an RLS USING policy that
    /// hides a row from DELETE yields a 2xx with ZERO rows — never a 403 — so
    /// a plain delete cannot tell "deleted" from "refused". The representation
    /// can: an empty array means the row survived.
    func deleteReturning<T: Decodable>(_ table: String, query: [URLQueryItem]) async throws -> [T] {
        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("rest/v1/\(table)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        for (k, v) in await headers(contentJSON: false) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let data = try await perform(req)
        return try decode([T].self, from: data)
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

    /// All sessions ever run for a class (any status), newest first. This is
    /// what makes closed-session essays reachable again: grading is entered
    /// from these rows, not from the live session. The teacher filter is
    /// defense-in-depth alongside RLS (mirrors listOpenSessions); nullslast
    /// keeps undated legacy rows at the bottom (Postgres DESC is NULLS FIRST).
    func listClassSessions(classId: String, teacherUserId: String) async throws -> [ExamSession] {
        try await rows("sessions", query: [
            URLQueryItem(name: "select", value: "id,code,test_id,class_id,status,created_at"),
            URLQueryItem(name: "class_id", value: "eq.\(classId)"),
            URLQueryItem(name: "teacher_user_id", value: "eq.\(teacherUserId)"),
            URLQueryItem(name: "status", value: "neq.archived"),
            URLQueryItem(name: "order", value: "created_at.desc.nullslast"),
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
                    timeLimitMinutes: Int?, spellcheckEnabled: Bool = true,
                    outlineAllowed: Bool = false) async throws -> Assignment? {
        struct Payload: Encodable {
            let teacher_user_id: String; let title: String
            let questions: [Question]; let time_limit_minutes: Int?
            let spellcheck_enabled: Bool; let outline_allowed: Bool
        }
        let result: [Assignment] = try await insert("tests",
            values: Payload(teacher_user_id: teacherUserId, title: title,
                            questions: questions, time_limit_minutes: timeLimitMinutes,
                            spellcheck_enabled: spellcheckEnabled,
                            outline_allowed: outlineAllowed))
        return result.first
    }

    /// Clone `source` into the next draft of its version group: same group id,
    /// version_number = nextVersion, a FRESH essay-question id (each draft's
    /// submissions key on their own question), prompt/limits/files/links
    /// carried over. Launching the clone is the normal launch path.
    func createDraftTest(from source: Assignment, teacherUserId: String,
                         nextVersion: Int) async throws -> Assignment? {
        struct Payload: Encodable {
            let teacher_user_id: String; let title: String
            let questions: [Question]; let time_limit_minutes: Int?
            let version_group_id: String; let version_number: Int
            let spellcheck_enabled: Bool; let outline_allowed: Bool
        }
        // A pre-versioning source row carries NULL version_group_id in the DB
        // (the model coalesces it to the test's own id). Backfill it before
        // inserting the clone so the family chain is coherent server-side for
        // any consumer, coalescing or not — Electron does the same.
        struct GroupPatch: Encodable { let version_group_id: String }
        let _: [Assignment] = (try? await update("tests",
            values: GroupPatch(version_group_id: source.versionGroupId),
            query: [URLQueryItem(name: "id", value: "eq.\(source.id)"),
                    URLQueryItem(name: "version_group_id", value: "is.null")],
            returning: false)) ?? []

        // Single-question app today; later questions would keep their ids
        // across drafts (spec: out of scope).
        var questions = source.questions
        if let q = questions.first {
            questions[0] = Question(id: "q-\(UUID().uuidString.prefix(8))", kind: q.kind,
                                    prompt: q.prompt, wordLimit: q.wordLimit,
                                    fileIds: q.fileIds, urlIds: q.urlIds)
        }
        let rows: [Assignment] = try await insert("tests", values: Payload(
            teacher_user_id: teacherUserId, title: source.title, questions: questions,
            time_limit_minutes: source.timeLimitMinutes,
            version_group_id: source.versionGroupId, version_number: nextVersion,
            spellcheck_enabled: source.spellcheckEnabled,
            outline_allowed: source.outlineAllowed))
        return rows.first
    }

    func updateTest(id: String, title: String, questions: [Question], timeLimitMinutes: Int?,
                    spellcheckEnabled: Bool = true, outlineAllowed: Bool = false) async throws {
        struct Payload: Encodable {
            let title: String; let questions: [Question]
            let time_limit_minutes: Int?; let updated_at: String
            let spellcheck_enabled: Bool; let outline_allowed: Bool
        }
        let _: [Assignment] = try await update("tests",
            values: Payload(title: title, questions: questions,
                            time_limit_minutes: timeLimitMinutes, updated_at: Self.nowISO(),
                            spellcheck_enabled: spellcheckEnabled,
                            outline_allowed: outlineAllowed),
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

    /// Open a session, retrying the insert when the join code collides.
    /// `sessions.code` is UNIQUE and the code is a 6-digit draw that is never
    /// checked against history, so a collision with any session ever opened in
    /// this project is a hard failure in front of a waiting class. PostgREST
    /// reports it as 409 / SQLSTATE 23505; draw a fresh code and try again.
    /// Five attempts, so even a heavily used project resolves in one launch.
    @discardableResult
    func launchSession(testId: String?, classId: String?, teacherUserId: String,
                       teacherIP: String?) async throws -> ExamSession? {
        struct Payload: Encodable {
            let code: String; let teacher_ip: String?; let status: String
            let teacher_user_id: String; let test_id: String?; let class_id: String?
        }
        var lastCollision: Error?
        for _ in 0..<5 {
            do {
                let result: [ExamSession] = try await insert("sessions",
                    values: Payload(code: Self.sessionCode(), teacher_ip: teacherIP, status: "open",
                                    teacher_user_id: teacherUserId, test_id: testId, class_id: classId))
                return result.first
            } catch let error as SupabaseError {
                guard case let .badResponse(_, body) = error,
                      Self.isUniqueViolation(body: body) else { throw error }
                lastCollision = error
            }
        }
        throw lastCollision ?? SupabaseError.auth("Could not allocate a session code. Try again.")
    }

    /// True when PostgREST is reporting a unique-constraint collision
    /// (SQLSTATE 23505, surfaced as 409 Conflict). The SQLSTATE is what decides
    /// it, not the status: PostgREST answers 409 for a foreign-key violation
    /// too (23503), and retrying a stale test_id or class_id five times with
    /// fresh codes would only bury the real error.
    private static func isUniqueViolation(body: String) -> Bool {
        body.contains("23505") || body.lowercased().contains("duplicate key")
    }

    /// Close EVERY open session this teacher owns. End-session uses this
    /// rather than closing one row: the app's invariant is one live session
    /// at a time, so any other open rows are stale leftovers (crashes, old
    /// builds) that loadTeacherHome would otherwise resurrect one by one.
    func endAllOpenSessions(teacherUserId: String) async throws {
        struct Payload: Encodable { let status: String; let closed_at: String }
        let _: [ExamSession] = try await update("sessions",
            values: Payload(status: "closed", closed_at: Self.nowISO()),
            query: [URLQueryItem(name: "teacher_user_id", value: "eq.\(teacherUserId)"),
                    URLQueryItem(name: "status", value: "eq.open")],
            returning: false)
    }

    /// Hide a session from the class history without deleting essays. Uses the
    /// existing teacher UPDATE policy (status → archived). Open sessions are
    /// closed at the same time so a leftover live row cannot resurrect.
    func archiveSession(id: String) async throws {
        struct Payload: Encodable { let status: String; let closed_at: String }
        let _: [ExamSession] = try await update("sessions",
            values: Payload(status: "archived", closed_at: Self.nowISO()),
            query: [URLQueryItem(name: "id", value: "eq.\(id)")],
            returning: false)
    }

    /// Permanently delete a session. Essays, roster rows, grades, comments and
    /// outlines cascade with the session row. RLS must allow teacher DELETE
    /// (see Tessera migration 20260917000009); an empty representation means
    /// the policy refused the row and it is still there.
    func deleteSession(id: String) async throws {
        let gone: [ExamSession] = try await deleteReturning("sessions", query: [
            URLQueryItem(name: "id", value: "eq.\(id)")
        ])
        guard !gone.isEmpty else {
            throw SupabaseError.auth("Couldn't delete this session. Archive it to hide it from the list.")
        }
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

    // MARK: - Student exam lifecycle (register / autosave / submit)

    /// The caller's newest SUBMITTED essay for an assignment family (the
    /// read-only viewer behind the Past row). RLS-safe by construction:
    /// the RPC keys on auth.uid()'s own students rows.
    func getMySubmission(versionGroupId: String) async throws -> SubmittedEssay? {
        let rows: [SubmittedEssay] = try await rpc("get_my_submission",
                                                   params: ["p_version_group_id": versionGroupId])
        return rows.first
    }

    struct StudentRowID: Decodable, Sendable { let id: String }

    /// Register (or refresh) the caller's `students` row for a session at
    /// checks-pass, carrying the proctoring facts the checks screen computed.
    /// Mirrors student.js runChecks (onConflict session_id,user_id). The
    /// proctoring fields are REQUIRED: the live schema declares name,
    /// remote_session, screen_capture, display_count, and is_vm NOT NULL with
    /// no defaults, so an omitted key is a 23502 at insert time (live QA found
    /// this). ip / ip_match are deliberately NOT sent: the native app does not
    /// do IP/network matching (product call, 2026-06-10; the columns were made
    /// nullable for it — Electron still sends its own values).
    func registerStudent(sessionId: String, userId: String, email: String?,
                         name: String, screenCapture: Bool, remote: Bool,
                         displayCount: Int, isVM: Bool) async throws -> String? {
        struct Payload: Encodable {
            let session_id: String; let user_id: String
            let email: String?; let name: String
            let remote_session: Bool; let screen_capture: Bool
            let display_count: Int; let is_vm: Bool
            let status: String
        }
        let rows: [StudentRowID] = try await upsert("students",
            values: Payload(session_id: sessionId, user_id: userId, email: email,
                            name: name, remote_session: remote,
                            screen_capture: screenCapture, display_count: displayCount,
                            is_vm: isVM, status: "joined"),
            onConflict: "session_id,user_id")
        return rows.first?.id
    }

    /// Autosave/flush one essay (upsert: the row IS the submission). Returns
    /// the row id for the submit lock. updated_at is client-stamped: the table
    /// has no server now() trigger (Electron does the same).
    func upsertEssaySubmission(sessionId: String, studentId: String, questionId: String,
                               contentHTML: String, wordCount: Int) async throws -> String? {
        struct Payload: Encodable {
            let session_id: String; let student_id: String; let question_id: String
            let content_html: String; let word_count: Int; let updated_at: String
        }
        let rows: [StudentRowID] = try await upsert("essay_submissions",
            values: Payload(session_id: sessionId, student_id: studentId,
                            question_id: questionId, content_html: contentHTML,
                            word_count: wordCount, updated_at: Self.nowISO()),
            onConflict: "session_id,student_id,question_id")
        return rows.first?.id
    }

    /// Stamp `students.started_at` (idempotent: coalesce keeps the first
    /// registration) and return the server clock so the exam countdown is
    /// the remainder of that window. The RPC has been deployed since the
    /// essay-first wave; the native app just never called it, which is why
    /// a crash-reentry got a fresh client-side hour and why an untimed
    /// assignment still died at 45 minutes.
    func startEssay(studentId: String) async throws -> EssayStart? {
        let rows: [EssayStart] = try await rpc("start_essay",
                                               params: ["p_student_id": studentId])
        return rows.first
    }

    /// Lock a submitted essay at the DB layer (SECURITY DEFINER submit_essay:
    /// stamps submitted_at; RLS then refuses student edits). Best-effort.
    func submitEssay(submissionId: String) async -> Bool {
        do {
            let _: String? = try await rpc("submit_essay",
                params: ["p_submission_id": submissionId])
            return true
        } catch {
            print("submit_essay lock failed: \(error)")
            return false
        }
    }

    /// students.status transition (joined -> writing -> submitted). Best-effort,
    /// but the Bool is reported: the caller retries the writing transition on
    /// the next edit rather than leaving the teacher's monitor saying "Joined"
    /// for a student who has been typing for an hour.
    @discardableResult
    func updateStudentStatus(id: String, status: String) async -> Bool {
        struct Payload: Encodable { let status: String }
        do {
            let _: [StudentRowID] = try await update("students", values: Payload(status: status),
                query: [URLQueryItem(name: "id", value: "eq.\(id)")], returning: false)
            return true
        } catch {
            print("students.status update failed: \(error)")
            return false
        }
    }

    // MARK: - Student outlines (outline_uploads + the private `outlines` bucket)

    /// The caller's own outline row for a session, or nil if none was uploaded.
    /// The explicit user_id filter is NOT redundant with RLS: session owners
    /// can SELECT every outline in their sessions (listSessionOutlines), and a
    /// teacher may enter the student view (enterStudent) — without the filter
    /// they would get an arbitrary student's outline back as "mine". The
    /// caller filter keeps "at most one row" true by construction, the same
    /// defense-in-depth as myClasses / listClassSessions.
    func getMyOutline(sessionId: String, userId: String) async throws -> OutlineUpload? {
        let rows: [OutlineUpload] = try await rows("outline_uploads", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "session_id", value: "eq.\(sessionId)"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
        ])
        return rows.first
    }

    /// Insert-or-replace the caller's outline row for a session (one outline
    /// per student per session: onConflict session_id,user_id, mirroring
    /// registerStudent). user_id is deliberately NOT sent: the column defaults
    /// to auth.uid() server-side, which keeps the row caller-owned for RLS by
    /// construction. The server refuses this write once the student's
    /// `students` row exists (they began writing) — surface that to the UI.
    /// updated_at is client-stamped: the table has no server now() trigger
    /// (same as upsertEssaySubmission).
    @discardableResult
    func upsertOutline(sessionId: String, displayName: String, originalName: String,
                       mimeType: String, sizeBytes: Int,
                       storagePath: String) async throws -> OutlineUpload? {
        struct Payload: Encodable {
            let session_id: String; let display_name: String
            let original_name: String; let mime_type: String
            let size_bytes: Int; let storage_path: String
            let updated_at: String
        }
        let rows: [OutlineUpload] = try await upsert("outline_uploads",
            values: Payload(session_id: sessionId, display_name: displayName,
                            original_name: originalName, mime_type: mimeType,
                            size_bytes: sizeBytes, storage_path: storagePath,
                            updated_at: Self.nowISO()),
            onConflict: "session_id,user_id")
        return rows.first
    }

    /// Remove the caller's outline for a session: the row FIRST (that's where
    /// the RLS lock lives — if the student already began writing the delete is
    /// refused and the stored bytes must survive for the teacher), THEN the
    /// storage object, best-effort (an orphan in the private bucket is
    /// unreadable and harmless; a failed object delete must not resurrect the
    /// outline). No row = nothing to do.
    ///
    /// The row delete is VERIFIED, not trusted: PostgREST surfaces an
    /// RLS-refused DELETE as a 2xx with zero rows, never a 403, so the lock
    /// (begun writing on another device) would otherwise look like success —
    /// the cache would clear, the teacher's bytes would be deleted, and the
    /// row would resurrect on the next refresh. Returns false when the row
    /// survived (the lock); the storage object is touched only after the row
    /// is confirmed gone.
    func deleteOutline(sessionId: String, userId: String) async throws -> Bool {
        guard let existing = try await getMyOutline(sessionId: sessionId, userId: userId) else {
            return true // nothing to do; not a lock
        }
        let deleted: [OutlineUpload] = try await deleteReturning("outline_uploads", query: [
            URLQueryItem(name: "id", value: "eq.\(existing.id)"),
        ])
        guard !deleted.isEmpty else { return false } // row survived: the begin-writing lock
        do { try await deleteStorageObject(bucket: "outlines", path: existing.storagePath) }
        catch { print("outline storage delete failed: \(error)") }
        return true
    }

    /// Best-effort removal of one outline object — replace-under-a-new-filename
    /// cleanup. Failures are logged and swallowed: cleanup must never fail a
    /// replace that already succeeded, and an orphan in the private bucket is
    /// unreadable and harmless.
    func removeOutlineObject(path: String) async {
        do { try await deleteStorageObject(bucket: "outlines", path: path) }
        catch { print("outline replace cleanup failed: \(error)") }
    }

    /// Upload (or replace, via x-upsert) the raw outline bytes into the private
    /// `outlines` bucket at `path` (`<user_id>/<session_id>/<filename>`).
    /// Storage REST: POST /storage/v1/object/outlines/<path> with the usual
    /// apikey + Bearer headers so the bucket's RLS sees the owner.
    func uploadOutlineFile(data: Data, path: String, contentType: String) async throws {
        let endpoint = SupabaseConfig.url
            .appendingPathComponent("storage/v1/object/outlines")
            .appendingPathComponent(path)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        for (k, v) in await headers(contentJSON: false) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")
        req.httpBody = data
        _ = try await perform(req)
    }

    /// Every outline uploaded for a session, for the teacher's grading view
    /// (RLS grants session owners SELECT). Oldest first, like the live roster.
    func listSessionOutlines(sessionId: String) async throws -> [OutlineUpload] {
        try await rows("outline_uploads", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "session_id", value: "eq.\(sessionId)"),
            URLQueryItem(name: "order", value: "created_at.asc"),
        ])
    }

    /// Time-limited signed URL for an outline object — the bucket is private,
    /// so every read goes through /object/sign (the essay-files PDF pattern).
    @MainActor
    func signedOutlineURL(path: String) async throws -> URL {
        try await signedURL(bucket: "outlines", path: path)
    }

    /// DELETE one object from a storage bucket
    /// (REST: DELETE /storage/v1/object/<bucket>/<path>).
    private func deleteStorageObject(bucket: String, path: String) async throws {
        let endpoint = SupabaseConfig.url
            .appendingPathComponent("storage/v1/object")
            .appendingPathComponent(bucket)
            .appendingPathComponent(path)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "DELETE"
        for (k, v) in await headers(contentJSON: false) { req.setValue(v, forHTTPHeaderField: k) }
        _ = try await perform(req)
    }

    // MARK: - Teacher reference files + the approved-link pool (editor writes)

    /// The real `test_files` rows behind a question's `fileIds`, in the order
    /// the question stores them. A missing row is simply absent: a question can
    /// outlive a file the teacher deleted.
    func listTeacherFiles(ids: [String]) async throws -> [TeacherFile] {
        guard !ids.isEmpty else { return [] }
        let found: [TeacherFile] = try await rows("test_files", query: [
            URLQueryItem(name: "select", value: "id,original_name,mime_type,size_bytes,storage_path"),
            URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"),
        ])
        return ids.compactMap { id in found.first { $0.id == id } }
    }

    /// The `test_urls` rows behind a question's `urlIds`, in the question's own
    /// order. Tolerant of a NULL display_name (Electron-era rows left it unset),
    /// which `listTestURLs` / ExamLink would throw on mid-save.
    func listTeacherLinks(ids: [String]) async throws -> [TeacherLink] {
        guard !ids.isEmpty else { return [] }
        let found: [TeacherLink] = try await rows("test_urls", query: [
            URLQueryItem(name: "select", value: "id,display_name,url"),
            URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"),
        ])
        return ids.compactMap { id in found.first { $0.id == id } }
    }

    /// A collision-free object name inside the teacher's own folder: a UUID
    /// prefix plus the original name stripped to safe characters (mirrors
    /// safeEssayFileName in the Electron editor).
    static func safeReferenceFileName(_ originalName: String) -> String {
        let base = originalName.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last.map(String.init) ?? "file"
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let cleaned = String(base.map { allowed.contains($0) ? $0 : "_" }.prefix(120))
        return "\(UUID().uuidString.lowercased())-\(cleaned.isEmpty ? "file" : cleaned)"
    }

    /// Upload reference bytes into the PRIVATE `essay-files` bucket at
    /// `<teacher user id>/<uuid>-<safe name>`, the shape the bucket's INSERT
    /// policy requires (foldername[1] = auth.uid()). No `x-upsert`: the UUID
    /// makes every path new, so an upsert could only overwrite another file.
    func uploadEssayFile(data: Data, path: String, contentType: String) async throws {
        let endpoint = SupabaseConfig.url
            .appendingPathComponent("storage/v1/object/essay-files")
            .appendingPathComponent(path)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        for (k, v) in await headers(contentJSON: false) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try await perform(req)
    }

    /// Record an uploaded reference file in `test_files` (the per-teacher pool a
    /// question's `fileIds` points into). teacher_user_id is sent explicitly:
    /// the column has no auth.uid() default and the INSERT policy checks it.
    func createTestFile(userId: String, originalName: String, mimeType: String,
                        sizeBytes: Int, storagePath: String) async throws -> TeacherFile? {
        struct Row: Encodable {
            let teacher_user_id: String; let original_name: String
            let mime_type: String; let size_bytes: Int; let storage_path: String
        }
        let created: [TeacherFile] = try await insert("test_files", values: [
            Row(teacher_user_id: userId, original_name: originalName, mime_type: mimeType,
                size_bytes: sizeBytes, storage_path: storagePath)
        ], returning: true)
        return created.first
    }

    /// Delete one `test_files` row, VERIFIED: an RLS-refused DELETE arrives as a
    /// 2xx with zero rows, never a 403 (the deleteOutline gotcha), so a plain
    /// delete cannot tell "deleted" from "refused". False = the row survived,
    /// and its bytes must be left alone.
    func deleteTestFile(id: String) async throws -> Bool {
        let deleted: [TeacherFile] = try await deleteReturning("test_files", query: [
            URLQueryItem(name: "id", value: "eq.\(id)"),
        ])
        return !deleted.isEmpty
    }

    /// Best-effort removal of one reference object from `essay-files`. Failures
    /// are logged and swallowed: an orphan in a private bucket is unreadable and
    /// harmless, and cleanup must never fail the edit that caused it.
    func removeEssayFileObject(path: String) async {
        do { try await deleteStorageObject(bucket: "essay-files", path: path) }
        catch { print("essay-files cleanup failed: \(error)") }
    }

    /// What a re-save should do with a question's approved links: the row ids the
    /// question should now carry, plus the rows it used to carry and no longer
    /// does. Saving used to insert a fresh row per link every time, so every
    /// re-save duplicated the pool and orphaned the previous rows.
    struct TestURLPlan: Sendable {
        /// Ids for the links passed in, in the same order (an unchanged URL
        /// keeps its existing row).
        var ids: [String] = []
        /// Rows this question referenced before and no longer does. Safe to
        /// delete ONLY after the question itself has been written, and only once
        /// no other version still references them.
        var orphanIds: [String] = []
    }

    /// Reconcile a question's approved links against the rows it already owns:
    /// reuse the row whose URL is unchanged (renaming it in place when the
    /// display name moved), insert only genuinely new links, and report the
    /// leftovers. Duplicate URLs in `links` collapse onto a single row.
    func planTestURLs(userId: String, existingIds: [String],
                      links: [(name: String, href: String)]) async throws -> TestURLPlan {
        func key(_ url: String) -> String {
            url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let existing = try await listTeacherLinks(ids: existingIds)
        var byURL: [String: TeacherLink] = [:]
        for row in existing where byURL[key(row.url)] == nil { byURL[key(row.url)] = row }

        var plan = TestURLPlan()
        var reused: Set<String> = []
        var pending: [(slot: Int, name: String, href: String)] = []
        var seen: Set<String> = []
        for link in links {
            let k = key(link.href)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            if let row = byURL[k] {
                reused.insert(row.id)
                plan.ids.append(row.id)
                // Keep the name the teacher now sees. A failed rename leaves the
                // link working under its old name, so it never fails the save.
                if row.displayName != link.name {
                    _ = try? await renameTestURL(id: row.id, displayName: link.name)
                }
            } else {
                pending.append((slot: plan.ids.count, name: link.name, href: link.href))
                plan.ids.append("")   // filled in from the insert below
            }
        }
        if !pending.isEmpty {
            struct Row: Encodable {
                let teacher_user_id: String; let display_name: String
                let url: String; let source: String
            }
            let payload = pending.map {
                Row(teacher_user_id: userId, display_name: $0.name, url: $0.href, source: "custom")
            }
            let created: [TeacherLink] = try await insert("test_urls", values: payload, returning: true)
            // Match the new rows back by URL rather than trusting the response
            // order, and refuse to write a blank id into a question's urlIds.
            var newIDs: [String: String] = [:]
            for row in created where newIDs[key(row.url)] == nil { newIDs[key(row.url)] = row.id }
            for item in pending {
                guard let id = newIDs[key(item.href)] else {
                    throw SupabaseError.decoding("test_urls insert returned no row for \(item.href)")
                }
                plan.ids[item.slot] = id
            }
        }
        plan.orphanIds = existing.map(\.id).filter { !reused.contains($0) }
        return plan
    }

    /// Rename one `test_urls` row in place, so editing a display name does not
    /// orphan the row and mint a duplicate.
    @discardableResult
    func renameTestURL(id: String, displayName: String) async throws -> Bool {
        struct Patch: Encodable { let display_name: String }
        let rows: [TeacherLink] = try await update("test_urls",
            values: Patch(display_name: displayName),
            query: [URLQueryItem(name: "id", value: "eq.\(id)")])
        return !rows.isEmpty
    }

    /// Best-effort deletion of pool rows no question references any more.
    /// Called only AFTER the owning question has been written, so a failure
    /// leaves an unreferenced row behind (harmless) instead of stranding a live
    /// whitelist.
    func deleteTestURLs(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await delete("test_urls", query: [
                URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"),
            ])
        } catch { print("test_urls cleanup failed: \(error)") }
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

    // MARK: - Auth (GoTrue) — OAuth PKCE via the default browser

    /// The sign-in attempt currently waiting for its `weft://auth-callback` deep
    /// link to come back from the browser. One attempt at a time: starting a new
    /// one supersedes (cancels) the previous, and `cancelPendingSignIn()` lets
    /// the UI bail out — the user may simply close the browser tab, in which
    /// case no callback will ever arrive.
    @MainActor private var pendingAuthContinuation: CheckedContinuation<URL, Error>?

    /// Kick off Google sign-in in the user's DEFAULT BROWSER: open GoTrue's
    /// `/authorize` there, wait for the app to be re-activated by the
    /// `weft://auth-callback?code=...` redirect, then exchange the code for a
    /// session. The browser route (over ASWebAuthenticationSession) is a product
    /// call: the system web-auth window pops over the app as a detached
    /// private-browsing pane with no cookies, so users retyped their Google
    /// password every sign-in. The default browser already holds the school
    /// Google session — sign-in is usually one click on an account chip.
    @MainActor
    func signInWithGoogle() async throws {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)

        var comps = URLComponents(url: SupabaseConfig.url.appendingPathComponent("auth/v1/authorize"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: SupabaseConfig.browserRedirectURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Force Google's account chooser. Without this, Google silently reuses
            // the browser's existing session, so a wrong / shared account can never
            // be switched — you click "Sign in" and it just logs in the last one.
            // GoTrue forwards `prompt` to Google; select_account shows the picker
            // (and "Use another account") while still allowing one-click SSO.
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        let authorizeURL = comps.url!

        // Only one attempt can wait on the callback; a second click supersedes
        // the first (its continuation is resumed as cancelled, never leaked).
        cancelPendingSignIn()
        #if canImport(AppKit)
        NSWorkspace.shared.open(authorizeURL)
        #endif
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            pendingAuthContinuation = continuation
        }

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

    /// Hand the `weft://auth-callback` deep link to the waiting sign-in attempt.
    /// Routed here by `AppState.handleDeepLink`; a callback with no attempt
    /// waiting (a stale or replayed browser tab) is dropped harmlessly.
    @MainActor
    func resumeAuthCallback(_ url: URL) {
        pendingAuthContinuation?.resume(returning: url)
        pendingAuthContinuation = nil
    }

    /// Abandon the in-flight sign-in attempt (Cancel pressed, or a new attempt
    /// starting). Throws `CancellationError` into `signInWithGoogle`, which
    /// callers treat as "nothing to report" — not an error banner.
    @MainActor
    func cancelPendingSignIn() {
        pendingAuthContinuation?.resume(throwing: CancellationError())
        pendingAuthContinuation = nil
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

        // allowRefresh: false. There is no session to refresh yet: this is
        // the call that establishes one.
        let data = try await perform(req, allowRefresh: false)
        let token = try decode(TokenResponse.self, from: data)
        setSession(accessToken: token.accessToken, refreshToken: token.refreshToken,
                   expiresIn: token.expiresIn)
    }

    /// Sign out: drop the local session. The GoTrue `/logout` round-trip is best
    /// effort and can be added once a stored token revoke is needed.
    @MainActor
    func signOut() {
        clearSession()
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

// MARK: - Teacher-side attachment DTOs (the assignment editor)

/// One `test_files` row as the assignment editor needs it. Separate from
/// ExamFile because the editor shows the file's size, which the exam's
/// projection drops.
struct TeacherFile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var originalName: String
    var mimeType: String
    var sizeBytes: Int
    var storagePath: String

    enum CodingKeys: String, CodingKey {
        case id
        case originalName = "original_name"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case storagePath = "storage_path"
    }

    init(id: String, originalName: String, mimeType: String,
         sizeBytes: Int, storagePath: String) {
        self.id = id; self.originalName = originalName; self.mimeType = mimeType
        self.sizeBytes = sizeBytes; self.storagePath = storagePath
    }

    /// Tolerant decode (house pattern): only the id is load-bearing, and a row
    /// with an odd mime type or size must still list in the editor.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        originalName = (try? c.decode(String.self, forKey: .originalName)) ?? "Attached file"
        mimeType = (try? c.decode(String.self, forKey: .mimeType)) ?? "application/octet-stream"
        sizeBytes = (try? c.decode(Int.self, forKey: .sizeBytes)) ?? 0
        storagePath = (try? c.decode(String.self, forKey: .storagePath)) ?? ""
    }
}

/// One `test_urls` row for the teacher's write paths. Separate from ExamLink
/// because display_name is NULLABLE in the live schema: ExamLink's strict
/// decode throws on an Electron-era row that never set one, which would take
/// the editor's load (and the save's reconcile) down with it.
struct TeacherLink: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    var url: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case url
    }

    init(id: String, displayName: String, url: String) {
        self.id = id; self.displayName = displayName; self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
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

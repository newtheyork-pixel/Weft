//
//  ApprovedSites.swift
//  Weft — the school's approved-websites list, pulled from a published Google
//  Sheet (Name, URL, Scope). Mirrors the Electron app's "Add from list" picker
//  in the assignment editor. A native app can fetch the CSV directly (no CORS
//  wall), so no main-process bridge is needed; URLSession follows the redirect
//  Google's export issues.
//

import Foundation

struct ApprovedSite: Identifiable, Hashable, Sendable {
    let name: String
    let url: String
    let scope: Scope
    enum Scope: String, Sendable { case domain, exact }

    var id: String { url + "|" + name }
    var host: String {
        let raw = url.contains("://") ? url : "https://" + url
        return URL(string: raw)?.host ?? url
    }
}

/// The school's teacher directory: the "Teachers" tab of the same spreadsheet is
/// a single column of teacher emails (no header). On sign-in, an email on this
/// list routes to the teacher role; everyone else is a student.
enum TeacherDirectory {
    static var csvURL: URL {
        let override = ProcessInfo.processInfo.environment["WEFT_TEACHERS_URL"]
        let s = override ?? "https://docs.google.com/spreadsheets/d/1ukX4v4b6z4GdTXEurRwgjex8BqfRMS6d2HoOBoL3L7E/gviz/tq?tqx=out:csv&sheet=Teachers"
        return URL(string: s)!
    }

    /// Result distinguishes "fetched (maybe empty)" from "couldn't reach it", so
    /// the caller can fall back rather than wrongly demoting a teacher.
    struct Result { let emails: Set<String>; let ok: Bool }

    static func fetch() async -> Result {
        var req = URLRequest(url: csvURL)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return Result(emails: [], ok: false)
            }
            guard let text = String(data: data, encoding: .utf8) else { return Result(emails: [], ok: false) }
            return Result(emails: parse(text), ok: true)
        } catch {
            return Result(emails: [], ok: false)
        }
    }

    /// Parse a single-column CSV of (quoted) emails into a lowercased set.
    static func parse(_ csv: String) -> Set<String> {
        var out = Set<String>()
        let lines = csv.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
        for raw in lines {
            // Take the first column, strip surrounding quotes + whitespace.
            let first = raw.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? String(raw)
            let email = first.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespacesAndNewlines))
                .lowercased()
            if email.contains("@") { out.insert(email) }
        }
        return out
    }
}

enum ApprovedSitesService {
    /// The school's published sheet (overridable via env, matching the Electron
    /// TESSERA_APPROVED_SITES_URL). gid=0 is the approved-sites tab.
    static var csvURL: URL {
        let override = ProcessInfo.processInfo.environment["WEFT_APPROVED_SITES_URL"]
        let s = override ?? "https://docs.google.com/spreadsheets/d/1ukX4v4b6z4GdTXEurRwgjex8BqfRMS6d2HoOBoL3L7E/export?format=csv&gid=0"
        return URL(string: s)!
    }

    /// Fetch + parse the approved sites. Returns [] on any failure (the caller
    /// shows a calm "school list unavailable" rather than an error).
    static func fetch() async -> [ApprovedSite] {
        var req = URLRequest(url: csvURL)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return parse(text)
        } catch {
            return []
        }
    }

    /// Parse the CSV: header row (Name,URL,Scope) then data rows. The sheet has
    /// no quoted/comma-containing fields, so a simple split is sufficient; empty
    /// trailing rows (no URL) are skipped.
    static func parse(_ csv: String) -> [ApprovedSite] {
        var out: [ApprovedSite] = []
        var seen = Set<String>()
        let lines = csv.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
        for (i, raw) in lines.enumerated() {
            if i == 0 { continue }  // header
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard cols.count >= 2 else { continue }
            let name = cols[0]
            let url = cols[1]
            guard !url.isEmpty else { continue }
            let scope: ApprovedSite.Scope = (cols.count >= 3 && cols[2].lowercased() == "exact") ? .exact : .domain
            let key = url.lowercased()
            if seen.insert(key).inserted {
                out.append(ApprovedSite(name: name.isEmpty ? url : name, url: url, scope: scope))
            }
        }
        return out
    }
}

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

//
//  LockedBrowserView.swift
//  Weft — locked reference browser.
//
//  Native counterpart of the Electron `<webview>` LockedBrowser
//  (renderer/locked-browser.js / student.js `approvedSites`). During the essay
//  stage a student may only reach sites the teacher pre-approved. Each approved
//  link becomes a `ReferenceWebTab`: a long-lived WKWebView whose
//  WKNavigationDelegate is the security-critical gate. It ALLOWS navigation only
//  to URLs matching an approved entry's scheme, host and port, and CANCELS
//  everything else, including redirects that land off-list. Pop-ups, downloads
//  and right-click context menus are refused.
//
//  The tabs are owned by ReferenceTabStore for the whole exam, so hiding the
//  panel (⌘⇧R) keeps each page, its history and its login, and every tab of an
//  exam shares one ephemeral website data store (a library sign-in carries
//  across tabs and is discarded when the exam ends).
//
//  Target: macOS 26 SDK, Swift 6, no external packages.
//

import SwiftUI
import WebKit
import AppKit

// MARK: - The allow-list (mirrors locked-browser.js `_isAllowed`)

/// One entry on the locked browser's allow-list.
///
/// The Electron build matched the ORIGIN of a teacher-approved URL
/// (renderer/locked-browser.js:69-72 and :153-159 test `new URL(x).origin`
/// against a Set of approved origins), so scheme, host and port all had to
/// match and no subdomain was ever implied. This mirrors that: the path is
/// free, the host is not silently widened.
///
/// Two deliberate, documented differences:
///   - an entry's apex and its `www.` form are treated as the same site (school
///     sheets mix the two, and they are the same site by convention);
///   - a teacher can opt into subdomains explicitly by prefixing the host with
///     `*.` ("*.jstor.org"), which nothing else in the app grants.
struct AllowRule: Equatable, Sendable {
    let scheme: String
    let host: String
    /// nil means "the scheme's default port".
    let port: Int?
    /// True only for an explicit "*." entry.
    let includeSubdomains: Bool
}

/// Pure matching logic, deliberately nonisolated: the gate runs it from
/// WebKit's delegate callbacks and the store builds rules while configuring.
nonisolated enum ApprovedURLs {

    /// Parse one stored entry (a full URL, or a bare host, optionally prefixed
    /// with "*." for subdomains). Returns nil for anything that is not an
    /// http(s) web address, which is what keeps `mailto:`, `file:`,
    /// `javascript:` and `data:` entries out of the allow-list entirely.
    static func rule(from entry: String) -> AllowRule? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split the scheme off by hand rather than letting URLComponents guess:
        // prefixing "https://" onto "mailto:librarian@school.org" parses as the
        // host school.org, which would quietly widen the allow-list.
        var scheme = "https"
        var body = trimmed
        if let separator = body.range(of: "://") {
            scheme = String(body[body.startIndex..<separator.lowerBound]).lowercased()
            body = String(body[separator.upperBound...])
        } else if let colon = body.firstIndex(of: ":") {
            // A colon in a schemeless entry is only ever a port ("x.org:8443");
            // anything else is a scheme we refuse (mailto:, javascript:, data:).
            guard body[body.index(after: colon)...].first?.isNumber == true else { return nil }
        }
        guard scheme == "http" || scheme == "https" else { return nil }

        // "*." widens the host ONLY as the leading component of the host, which
        // is the one place a teacher can mean it. A "*." anywhere else is part
        // of a path ("/files/*.pdf") and must never turn into a subdomain rule;
        // the host guard below then refuses the leftover star.
        var includeSubdomains = false
        if body.hasPrefix("*.") {
            includeSubdomains = true
            body.removeFirst(2)
        }

        guard let comps = URLComponents(string: scheme + "://" + body),
              var host = comps.host?.lowercased(), !host.isEmpty
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }          // FQDN form
        guard !host.isEmpty, !host.contains("*"), !host.contains(" ") else { return nil }

        return AllowRule(scheme: scheme, host: host, port: comps.port,
                         includeSubdomains: includeSubdomains)
    }

    static func rules(from entries: [String]) -> [AllowRule] {
        entries.compactMap(rule(from:))
    }

    /// True if `url` is a web page a student may reach.
    static func isAllowed(_ url: URL, rules: [AllowRule]) -> Bool {
        // Only real web pages are ever eligible. This single guard is what
        // refuses javascript:, data:, file:, about:, mailto: and every other
        // scheme, wherever the navigation came from.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        while host.hasSuffix(".") { host.removeLast() }

        let port = url.port ?? defaultPort(scheme)
        for rule in rules {
            // Never a downgrade: an https entry does not authorise plain http.
            // The reverse is fine (same site, encrypted).
            guard scheme == rule.scheme || (scheme == "https" && rule.scheme == "http") else {
                continue
            }
            // A scheme upgrade takes the default port with it; an explicit port
            // in the entry still has to match exactly.
            let expected = rule.port ?? defaultPort(scheme)
            guard port == expected else { continue }
            if matches(host: host, rule: rule) { return true }
        }
        return false
    }

    private static func matches(host: String, rule: AllowRule) -> Bool {
        if host == rule.host { return true }
        if host == "www." + rule.host || rule.host == "www." + host { return true }
        if rule.includeSubdomains, host.hasSuffix("." + rule.host) { return true }
        return false
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "http" ? 80 : 443 }
}

// MARK: - One live web tab

/// The panel-visible state of a web tab. Separate from the tab itself so the
/// SwiftUI panel observes the state and not the WebKit plumbing.
@MainActor
@Observable
final class ReferenceWebTabState {
    var isLoading = false
    /// 0...1 while loading, for the hairline progress bar.
    var progress: Double = 0
    /// Non-nil when the page could not be shown: the panel renders this with a
    /// working Try again, instead of WebKit's blank white view.
    var failure: String?
    /// Host of whatever is on screen now (a page can navigate within the site).
    var host: String?
}

/// One approved website, live for the whole exam: its WKWebView, the whitelist
/// gate, and the loading / failure state the panel shows.
@MainActor
final class ReferenceWebTab: NSObject, WKNavigationDelegate, WKUIDelegate {

    let state = ReferenceWebTabState()
    let webView: WKWebView
    /// The teacher's URL for this tab, used for the first load and for Reload
    /// after a failure that left nothing on screen.
    let home: URL

    private var rules: [AllowRule]
    private let onNotice: (String) -> Void
    private var progressTask: Task<Void, Never>?
    private var started = false
    private var torn = false
    /// True once a page has actually committed in this web view, i.e. there is
    /// something readable on screen. WKWebView.url is NOT this: it already
    /// reports the provisional request the moment load() is called, so a
    /// navigation cancelled while still provisional (the download gate, the
    /// whitelist gate) would look like a rendered page.
    private var hasCommitted = false

    init(url: URL, rules: [AllowRule], dataStore: WKWebsiteDataStore,
         onNotice: @escaping (String) -> Void) {
        self.home = url
        self.rules = rules
        self.onNotice = onNotice

        let config = WKWebViewConfiguration()
        // One ephemeral store per exam (passed in): tabs share a session, so a
        // library login carries across them, and nothing is written to disk.
        config.websiteDataStore = dataStore
        // Block JS-opened pop-ups; we also veto new windows in the delegate.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = NoMenuWebView(frame: .zero, configuration: config)
        self.webView = webView
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        state.host = url.host
    }

    // MARK: Driving it

    /// First load. Called from the panel's `.task` (never from a view builder),
    /// and the blocked report is deferred, so no SwiftUI state is mutated
    /// during a view update.
    func start() {
        guard !started, !torn else { return }
        started = true
        guard ApprovedURLs.isAllowed(home, rules: rules) else {
            state.failure = Self.notApprovedText
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onNotice(Self.blockedText(for: self.home))
            }
            return
        }
        beginLoading()
        webView.load(URLRequest(url: home))
    }

    /// Reload control + the Try again on the failure card.
    func reload() {
        guard !torn else { return }
        state.failure = nil
        if hasCommitted {
            beginLoading()
            webView.reload()
        } else {
            // Nothing ever committed, so there is no page to reload: go back to
            // the teacher's link. reload() on a web view that never committed
            // does nothing at all.
            started = false
            start()
        }
    }

    func updateRules(_ rules: [AllowRule]) { self.rules = rules }

    /// End of exam: stop the network, drop the delegates, let the web content
    /// process go. The tab is discarded by the store straight after.
    func teardown() {
        guard !torn else { return }
        torn = true
        progressTask?.cancel()
        progressTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        state.isLoading = false
    }

    // MARK: Loading feedback

    private func beginLoading() {
        state.isLoading = true
        state.progress = max(0.05, webView.estimatedProgress)
        guard progressTask == nil else { return }
        // Polled rather than KVO-observed: the poll stays on the main actor for
        // the seconds a page takes, where a KVO handler would have to hop.
        progressTask = Task { [weak self] in
            while let tab = self, tab.state.isLoading, !Task.isCancelled {
                tab.state.progress = max(0.05, tab.webView.estimatedProgress)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func endLoading() {
        state.isLoading = false
        state.progress = 1
        progressTask?.cancel()
        progressTask = nil
    }

    private func reportBlocked(_ url: URL) {
        onNotice(Self.blockedText(for: url))
        // Blocked before anything ever rendered (a redirect off the teacher's
        // own link, say): the banner clears itself after 3 seconds, so the
        // empty pane has to explain itself too.
        if !hasCommitted {
            state.failure = Self.notApprovedText
        }
    }

    private static let notApprovedText = "This link isn't on your teacher's approved list."

    private static func blockedText(for url: URL) -> String {
        "Blocked: \(url.host ?? "that site") is not on your teacher's list."
    }

    /// A download or a response the web view cannot display. Downloads are off
    /// during an exam; say so instead of doing nothing at all.
    private func reportDownloadRefused() {
        endLoading()
        onNotice("Downloads are turned off during the exam.")
        // If nothing ever rendered in this tab (the teacher's own link points
        // straight at a file), the pane would otherwise stay blank.
        if !hasCommitted {
            state.failure = "That link is a file download, which is turned off during the exam."
        }
    }

    // MARK: The whitelist gate (security-critical)

    // EVERY top-level / subframe navigation passes through here. Allow only
    // http(s) URLs that match an approved entry; cancel everything else.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !torn, let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // A link that asks to be saved rather than shown (a download attribute,
        // or an attachment WebKit already decided to download).
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            reportDownloadRefused()
            return
        }

        guard ApprovedURLs.isAllowed(target, rules: rules) else {
            decisionHandler(.cancel)
            // Only surface the banner for attempts the STUDENT made.
            // Approved pages routinely embed off-list iframes (ads, video,
            // consent widgets) that navigate on their own during load;
            // those stay silently cancelled, or the banner fires "by
            // itself" with no click. The same applies to a click on an
            // off-list link INSIDE an allowed iframe: a dead link with no
            // banner is deliberate, because no public signal reliably
            // separates that click from the scripted subframe noise this
            // gate exists to silence.
            let targetsMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            // nil targetFrame = new-window attempt. Cancelling it here
            // means createWebViewWith never runs for it, so a student's
            // off-list target="_blank" click must be reported NOW. The
            // .linkActivated qualifier keeps scripted _blank attempts from
            // ad iframes quiet (synthetic a.click() can still spoof it, so
            // this is a strong heuristic, not a proof).
            let newWindowLinkClick = navigationAction.targetFrame == nil
                && navigationAction.navigationType == .linkActivated
            if targetsMainFrame || newWindowLinkClick {
                reportBlocked(target)
                // A blocked main-frame click leaves the current page in place;
                // the spinner must not keep spinning for a navigation that
                // will never happen.
                if state.isLoading { endLoading() }
            }
            return
        }
        decisionHandler(.allow)
    }

    // Defense in depth: re-check after the server responds (covers redirects
    // that landed somewhere off-list).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard !torn, let target = navigationResponse.response.url,
              ApprovedURLs.isAllowed(target, rules: rules)
        else {
            decisionHandler(.cancel)
            // Same main-frame-only rule as the action gate: a redirect that
            // lands a subframe off-list is cancelled silently.
            if navigationResponse.isForMainFrame,
               let target = navigationResponse.response.url {
                reportBlocked(target)
            }
            return
        }

        // An approved host can still answer with something the web view cannot
        // render (a .docx, a .zip, an attachment). WebKit would turn that into
        // a download with no delegate and simply abandon the navigation.
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            decisionHandler(.cancel)
            reportDownloadRefused()
            return
        }
        decisionHandler(.allow)
    }

    // Block new windows / pop-ups: re-route an allowed target into the same
    // web view, refuse the rest. Returning nil means "do not open a window".
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let target = navigationAction.request.url, !torn {
            if ApprovedURLs.isAllowed(target, rules: rules) {
                beginLoading()
                webView.load(URLRequest(url: target))
            } else {
                reportBlocked(target)
            }
        }
        return nil
    }

    // MARK: Navigation progress / failure

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state.failure = nil
        beginLoading()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommitted = true
        state.host = webView.url?.host ?? state.host
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.host = webView.url?.host ?? state.host
        endLoading()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        endLoading()
        state.failure = "The page stopped responding."
    }

    private func fail(_ error: Error) {
        endLoading()
        // A cancel we caused (the whitelist gate, or a new navigation
        // superseding this one) is not a failure to report: the blocked banner
        // has already explained it, and the page on screen is still fine.
        guard let message = Self.message(for: error) else { return }
        // Only claim the pane when there is nothing readable in it. A failure
        // while the first load is still provisional has committed nothing, even
        // though webView.url already reports the pending address.
        if !hasCommitted {
            state.failure = message
        } else {
            onNotice(message)
        }
    }

    private static func message(for error: Error) -> String? {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled:
                return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed:
                return "This Mac isn't connected to the internet right now."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "That site couldn't be found."
            case NSURLErrorTimedOut:
                return "The site took too long to respond."
            case NSURLErrorCannotConnectToHost:
                return "The site refused the connection."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot:
                return "The connection to that site isn't secure."
            default:
                return "The page couldn't be loaded."
            }
        }
        // 102 = frame load interrupted by a policy change (our own cancel),
        // 204 = the load was handed to something else. Neither is an error the
        // student needs to see.
        if ns.domain == "WebKitErrorDomain", ns.code == 102 || ns.code == 204 { return nil }
        return "The page couldn't be loaded."
    }
}

/// WKWebView subclass that swallows the right-click context menu. Students get
/// no "Open Link in New Window" / "Reload" / inspector escape hatches.
private final class NoMenuWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

// MARK: - Preview

#Preview("Locked browser") {
    // swiftlint:disable:next force_unwrapping
    let home = URL(string: "https://www.wikipedia.org")!
    let tab = ReferenceWebTab(url: home,
                              rules: ApprovedURLs.rules(from: ["wikipedia.org", "bbc.com"]),
                              dataStore: .nonPersistent(),
                              onNotice: { _ in })
    RetainedViewHost(view: tab.webView)
        .frame(width: 800, height: 600)
        .task { tab.start() }
}

// TODO(entitlements): the WKWebView needs the sandboxed app to declare the
// `com.apple.security.network.client` entitlement to reach the network. Outbound
// pop-up / download blocking is handled here, but a fully sandboxed build must
// also confirm no `com.apple.security.network.server` is granted unnecessarily.
// TODO: there is no back/forward chrome (the Electron version has one). Reload
// is wired; add WKWebView.goBack()/goForward() buttons here if teachers want
// them, the whitelist gate already covers them.

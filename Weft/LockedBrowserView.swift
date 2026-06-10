//
//  LockedBrowserView.swift
//  Weft — locked reference browser.
//
//  Native counterpart of the Electron `<webview>` LockedBrowser
//  (renderer/locked-browser.js / student.js `approvedSites`). During the essay
//  stage a student may only reach sites the teacher pre-approved. This wraps a
//  WKWebView whose WKNavigationDelegate is the security-critical gate: it ALLOWS
//  navigation only to URLs whose host matches the whitelist (domain or subdomain
//  match) and CANCELS everything else. Pop-ups / new windows are refused and
//  right-click context menus are suppressed.
//
//  Target: macOS 26 SDK, Swift 6, no external packages.
//

import SwiftUI
import WebKit
import AppKit

// MARK: - Host matching (mirrors locked-browser.js `_isAllowed`)

/// Whitelist matcher. An allowed host "bbc.com" covers `bbc.com`,
/// `www.bbc.com`, and `news.bbc.com`, but NOT `bbc.com.evil.com` or
/// `evilbbc.com` — the leading dot in the suffix test stops lookalikes.
/// Only http/https candidates are ever eligible.
enum HostWhitelist {

    /// Normalize a whitelist entry to a bare lowercased host.
    /// Accepts bare hosts ("bbc.com"), full URLs ("https://www.bbc.com/x"),
    /// strips a leading "www." so the entry covers the apex + subdomains.
    static func normalize(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host: String?
        if let comps = URLComponents(string: trimmed), let h = comps.host {
            host = h
        } else if let comps = URLComponents(string: "https://" + trimmed),
                  let h = comps.host {
            // Bare host or "host/path" with no scheme.
            host = h
        }
        guard var h = host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    /// True if `url` is an http(s) URL whose host matches any allowed base host
    /// (exact apex match OR a subdomain of it).
    static func isAllowed(_ url: URL, allowedHosts: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return false }

        for raw in allowedHosts {
            guard let base = normalize(raw) else { continue }
            if host == base || host.hasSuffix("." + base) {
                return true
            }
        }
        return false
    }
}

// MARK: - NSViewRepresentable wrapper

/// A WKWebView locked to a teacher-approved host whitelist.
///
/// - `url`: the page to load on first appearance. If it is not on the
///   whitelist nothing loads (and the coordinator reports it blocked).
/// - `allowedHosts`: the whitelist. Entries may be bare hosts ("bbc.com") or
///   full URLs; both are reduced to a host and matched by domain/subdomain.
struct LockedBrowserView: NSViewRepresentable {

    let url: URL
    let allowedHosts: [String]

    /// Optional hook fired (on the main actor) when a navigation is blocked.
    /// Lets a parent surface a "not on your teacher's list" banner.
    var onBlocked: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedHosts: allowedHosts, onBlocked: onBlocked)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Keep the locked browser's cookies/storage out of the app's main
        // session, mirroring the Electron dedicated partition.
        config.websiteDataStore = .nonPersistent()
        // Block JS-opened pop-ups; we also veto new windows in the delegate.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = NoMenuWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        // Only load the initial URL if it passes the whitelist; otherwise treat
        // it as a blocked attempt rather than silently navigating off-list.
        if HostWhitelist.isAllowed(url, allowedHosts: allowedHosts) {
            webView.load(URLRequest(url: url))
        } else {
            context.coordinator.reportBlocked(url)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Keep the coordinator's whitelist in sync with the latest inputs.
        context.coordinator.allowedHosts = allowedHosts
        context.coordinator.onBlocked = onBlocked
        // NOTE: we intentionally do NOT reload on every SwiftUI update — that
        // would fight in-browser navigation. The parent should rebuild the view
        // (new identity) to switch the starting page.
    }

    // MARK: Coordinator (the security-critical gate)

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

        var allowedHosts: [String]
        var onBlocked: ((URL) -> Void)?

        init(allowedHosts: [String], onBlocked: ((URL) -> Void)?) {
            self.allowedHosts = allowedHosts
            self.onBlocked = onBlocked
        }

        func reportBlocked(_ url: URL) {
            onBlocked?(url)
        }

        // The whitelist gate. EVERY top-level / subframe navigation passes
        // through here. Allow only http(s) URLs whose host is on the list;
        // cancel everything else.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if HostWhitelist.isAllowed(target, allowedHosts: allowedHosts) {
                decisionHandler(.allow)
            } else {
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
                }
            }
        }

        // Defense in depth: re-check after the server responds (covers
        // redirects that landed somewhere off-list).
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let target = navigationResponse.response.url,
               HostWhitelist.isAllowed(target, allowedHosts: allowedHosts) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                // Same main-frame-only rule as the action gate: a redirect that
                // lands a subframe off-list is cancelled silently.
                if navigationResponse.isForMainFrame,
                   let target = navigationResponse.response.url {
                    reportBlocked(target)
                }
            }
        }

        // Block new windows / pop-ups: re-route an allowed target into the same
        // web view, refuse the rest. Returning nil means "do not open a window".
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let target = navigationAction.request.url {
                if HostWhitelist.isAllowed(target, allowedHosts: allowedHosts) {
                    webView.load(URLRequest(url: target))
                } else {
                    reportBlocked(target)
                }
            }
            return nil
        }
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

// MARK: - Tiny SwiftUI wrapper that shows it

/// Minimal chrome around `LockedBrowserView`: a thin title strip plus the
/// locked web view, and a transient "blocked" banner. Drop this anywhere to
/// present the reference browser.
struct LockedBrowserPanel: View {

    let url: URL
    let allowedHosts: [String]

    @State private var blockedMessageVisible = false
    @State private var lastBlockedHost: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack(alignment: .top) {
                LockedBrowserView(url: url, allowedHosts: allowedHosts) { blocked in
                    lastBlockedHost = blocked.host
                    showBlockedBanner()
                }

                if blockedMessageVisible {
                    blockedBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, Theme.Space.sm)
                }
            }
        }
        .background(.white)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Text("Reference browser")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(url.host ?? url.absoluteString)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.muted2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .background(Color(white: 0.97))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(white: 0.88))
                .frame(height: 1)
        }
    }

    private var blockedBanner: some View {
        Text(bannerText)
            .font(Theme.sans(12, .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.bad)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private var bannerText: String {
        if let host = lastBlockedHost, !host.isEmpty {
            return "Blocked: \(host) is not on your teacher's list."
        }
        return "Blocked: that site is not on your teacher's list."
    }

    private func showBlockedBanner() {
        withAnimation(.easeOut(duration: 0.2)) { blockedMessageVisible = true }
        // Auto-hide after a few seconds (matches the Electron banner timeout).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeIn(duration: 0.2)) { blockedMessageVisible = false }
        }
    }
}

// MARK: - Preview

#Preview("Locked browser") {
    LockedBrowserPanel(
        // swiftlint:disable:next force_unwrapping
        url: URL(string: "https://www.wikipedia.org")!,
        allowedHosts: ["wikipedia.org", "bbc.com"]
    )
    .frame(width: 800, height: 600)
}

// TODO(entitlements): the WKWebView needs the sandboxed app to declare the
// `com.apple.security.network.client` entitlement to reach the network. Outbound
// pop-up / download blocking is handled here, but a fully sandboxed build must
// also confirm no `com.apple.security.network.server` is granted unnecessarily.
// TODO: there is no on-screen back/forward/reload chrome yet (the Electron
// version has one). Add WKWebView.goBack()/goForward()/reload() buttons here if
// teachers want navigation controls; the whitelist gate already covers them.

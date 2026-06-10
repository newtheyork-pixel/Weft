//
//  ExamReferencePanel.swift
//  Weft — the exam's reference area, browser-style: every teacher PDF and
//  approved website is a TAB. Click to switch instantly; views are created on
//  first visit and kept alive for the whole exam, so scroll / zoom / page /
//  web-navigation state survives and nothing ever reloads. A Split toggle
//  pins the current material above while the tabs drive the lower pane.
//

import SwiftUI
import PDFKit

struct ExamReferencePanel: View {
    let files: [ExamFile]
    let links: [ExamLink]
    let signedIn: Bool
    let store: ReferenceTabStore
    var onHide: () -> Void

    @State private var blockedHost: String?

    private let dividerThickness: CGFloat = 7

    /// Build a loadable URL from an approved link, prepending https:// when the
    /// teacher stored a bare host (otherwise the locked browser silently blocks
    /// the schemeless URL and nothing renders).
    private func normalizedURL(_ raw: String) -> URL? {
        let s = raw.contains("://") ? raw : "https://" + raw
        return URL(string: s)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            if store.materials.isEmpty {
                emptyState
            } else {
                materialCanvas
            }
        }
        .background(Color(white: 0.96))
        .task { store.configure(files: files, links: links, signedIn: signedIn) }
        .onChange(of: files) { _, f in store.configure(files: f, links: links, signedIn: signedIn) }
        .onChange(of: links) { _, l in store.configure(files: files, links: l, signedIn: signedIn) }
        .overlay(alignment: .top) {
            if let host = blockedHost {
                Text("Blocked: \(host) is not on your teacher's list.")
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
                    .background(Theme.bad, in: Capsule())
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: blockedHost) {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { blockedHost = nil }
                    }
            }
        }
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: Theme.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.materials) { m in tabChip(m) }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            if store.materials.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { store.toggleSplit() }
                } label: {
                    Image(systemName: store.splitActive ? "rectangle" : "rectangle.split.1x2")
                }
                .buttonStyle(.borderless)
                .help(store.splitActive ? "Back to one pane"
                                        : "Split: pin this on top, browse another below")
            }
            Button(action: onHide) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Hide references, write only (⌘⇧R)")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.regularMaterial)
    }

    private func tabChip(_ m: ReferenceMaterial) -> some View {
        let active = store.selectedID == m.id || store.pinnedID == m.id
        return Button { store.select(m.id) } label: {
            HStack(spacing: 5) {
                if store.pinnedID == m.id {
                    Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold))
                } else if store.pdfState(for: m) == .loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: m.icon).font(.system(size: 10, weight: .semibold))
                }
                Text(m.title)
                    .font(Theme.sans(12, active ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? Theme.accent.opacity(0.14) : Color.black.opacity(0.04),
                        in: Capsule())
            .foregroundStyle(active ? Theme.accent : Theme.ink)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(m.title)
    }

    // MARK: Material canvas (every visited view stays mounted; frames switch)

    private var visitedMaterials: [ReferenceMaterial] {
        store.materials.filter { store.visitedIDs.contains($0.id) }
    }

    private enum PaneRole { case pinned, active, hidden }

    private func role(of m: ReferenceMaterial) -> PaneRole {
        if store.splitActive, store.pinnedID == m.id { return .pinned }
        if store.selectedID == m.id { return .active }
        return .hidden
    }

    private var materialCanvas: some View {
        GeometryReader { geo in
            let split = store.splitActive
            let topH = split ? min(max(120, geo.size.height * store.splitFraction),
                                   max(120, geo.size.height - 120 - dividerThickness)) : 0
            let bottomH = split ? max(0, geo.size.height - topH - dividerThickness)
                                : geo.size.height

            ZStack(alignment: .topLeading) {
                ForEach(visitedMaterials) { m in
                    let r = role(of: m)
                    materialView(m)
                        // Hidden views keep a STABLE full-canvas frame: they're
                        // invisible, and pinning their geometry means a divider
                        // drag resizes only the two visible panes instead of
                        // reflowing every mounted web view per tick.
                        .frame(width: geo.size.width,
                               height: r == .pinned ? topH
                                     : r == .active ? bottomH
                                     : geo.size.height)
                        .offset(y: r == .pinned ? 0
                                  : (r == .active && split ? topH + dividerThickness : 0))
                        .opacity(r == .hidden ? 0 : 1)
                        .allowsHitTesting(r != .hidden)
                        .accessibilityHidden(r == .hidden)
                }

                // Same material pinned AND selected: the lower pane is empty.
                if split, store.pinnedID == store.selectedID {
                    Text("Pick another tab to show here")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.muted)
                        .frame(width: geo.size.width, height: bottomH)
                        .background(Color(white: 0.95))
                        .offset(y: topH + dividerThickness)
                }

                if split {
                    ZStack {
                        Rectangle().fill(Color.black.opacity(0.08))
                        Capsule().fill(Color.black.opacity(0.25)).frame(width: 36, height: 3)
                    }
                    .frame(width: geo.size.width, height: dividerThickness)
                    // contentShape BEFORE offset: applied after, the hit region
                    // stays anchored at the layout frame (canvas top) instead of
                    // moving with the rendered divider — verified empirically.
                    .contentShape(Rectangle())
                    .offset(y: topH)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                store.splitFraction = min(0.8, max(0.2,
                                    (v.location.y - dividerThickness / 2) / max(geo.size.height, 1)))
                            }
                    )
                }
            }
        }
    }

    @ViewBuilder private func materialView(_ m: ReferenceMaterial) -> some View {
        switch m {
        case .pdf(let file): pdfView(file)
        case .web(let link): webView(link)
        }
    }

    @ViewBuilder private func pdfView(_ file: ExamFile) -> some View {
        switch store.pdfState(for: file) {
        case .loaded(let doc):
            PDFKitView(document: doc)
        case .failed:
            VStack(spacing: Theme.Space.md) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 26)).foregroundStyle(Theme.muted2)
                Text("Couldn't load \(file.originalName).")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                Button("Try again") { store.retry(file: file) }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))
        case .loading, nil:
            ProgressView("Loading document…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.93))
        }
    }

    @ViewBuilder private func webView(_ link: ExamLink) -> some View {
        if let url = normalizedURL(link.url) {
            LockedBrowserView(url: url, allowedHosts: store.allowedHosts) { blocked in
                withAnimation { blockedHost = blocked.host ?? "that site" }
            }
        } else {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "globe").font(.system(size: 26)).foregroundStyle(Theme.muted2)
                Text("This link couldn't be opened.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "books.vertical").font(.system(size: 26)).foregroundStyle(Theme.muted2)
            Text("Your teacher didn't attach any reference materials.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.95))
    }
}

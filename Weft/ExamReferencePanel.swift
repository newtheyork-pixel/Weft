//
//  ExamReferencePanel.swift
//  Weft, the exam's reference area, browser-style: every teacher document and
//  approved website is a TAB. Click to switch instantly; the render surfaces
//  live in the store and are kept alive for the whole exam, so page, scroll,
//  zoom and web-navigation state survive even hiding the panel (⌘⇧R), and
//  nothing ever reloads. A Split toggle pins the current material above while
//  the tabs drive the lower pane.
//

import SwiftUI
import PDFKit

struct ExamReferencePanel: View {
    let files: [ExamFile]
    let links: [ExamLink]
    let signedIn: Bool
    /// True while the teacher's real materials are still being fetched. Until
    /// that answer is back the panel must not claim there are none.
    let materialsLoading: Bool
    let store: ReferenceTabStore
    var onHide: () -> Void

    private let dividerThickness: CGFloat = 7

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            content
        }
        .background(Color(white: 0.96))
        .task { store.configure(files: files, links: links, signedIn: signedIn) }
        .onChange(of: files) { _, f in store.configure(files: f, links: links, signedIn: signedIn) }
        .onChange(of: links) { _, l in store.configure(files: files, links: l, signedIn: signedIn) }
        .overlay(alignment: .top) {
            if let notice = store.notice {
                Text(notice.text)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
                    .background(Theme.bad, in: Capsule())
                    .padding(.top, 52)
                    .padding(.horizontal, Theme.Space.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.seq) {
                        try? await Task.sleep(for: .seconds(3))
                        store.clearNotice()
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.notice)
    }

    @ViewBuilder private var content: some View {
        if !store.materials.isEmpty {
            materialCanvas
        } else if materialsLoading || !files.isEmpty || !links.isEmpty {
            // The fetch is still out, or the store has materials to configure
            // and has simply not run its .task yet (which happens after the
            // first frame): a "nothing attached" message either way would be a
            // claim the app can't make.
            loadingCard("Loading your reference materials…")
        } else {
            emptyState
        }
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: Theme.Space.sm) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.materials) { m in tabChip(m).id(m.id) }
                    }
                    .padding(.vertical, 2)
                }
                // A selected tab that sits off-screen would be invisible.
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
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
                .linkPointer()
            }
            Button(action: onHide) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Hide references, write only (⌘⇧R)")
            .linkPointer()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.regularMaterial)
    }

    private func tabChip(_ m: ReferenceMaterial) -> some View {
        let pinned = store.pinnedID == m.id
        let active = store.selectedID == m.id || pinned
        return Button { store.select(m.id) } label: {
            HStack(spacing: 5) {
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold))
                } else if isBusy(m) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: m.icon).font(.system(size: 10, weight: .semibold))
                }
                Text(chipLabel(m.title))
                    .font(Theme.sans(12, active ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? Theme.accent.opacity(pinned ? 0.22 : 0.14)
                               : Color.black.opacity(0.04),
                        in: Capsule())
            .foregroundStyle(active ? Theme.accent : Theme.ink)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(pinned ? "\(m.title): pinned on top. Click to swap the panes." : m.title)
    }

    /// Tab labels are teacher file names, which can be arbitrarily long. Cap
    /// them with a middle ellipsis (the extension stays readable) so one long
    /// name can't push every other tab off the strip; the tooltip has the
    /// whole name.
    private func chipLabel(_ title: String) -> String {
        let maxChars = 30
        guard title.count > maxChars else { return title }
        let keep = (maxChars - 1) / 2
        return String(title.prefix(keep)) + "…" + String(title.suffix(keep))
    }

    private func isBusy(_ m: ReferenceMaterial) -> Bool {
        switch m {
        case .pdf(let f): return store.documentState(for: f)?.isLoading ?? false
        case .web(let l): return store.webTab(for: l)?.state.isLoading ?? false
        }
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

                // Safety net only: selecting the pinned material swaps the
                // panes (ReferenceTabStore.select) and configure() refuses to
                // leave both panes on one material, so this should not show.
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
        case .pdf(let file): documentPane(file)
        case .web(let link): webPane(link)
        }
    }

    // MARK: Document pane

    @ViewBuilder private func documentPane(_ file: ExamFile) -> some View {
        switch store.documentState(for: file) {
        case .pdf(let document):
            RetainedViewHost(view: store.pdfView(for: file, document: document))
        case .text(let attributed):
            RetainedViewHost(view: store.textView(for: file, attributed: attributed))
        case .unsupported:
            // Honest, and no Try again: re-downloading cannot make a file type
            // renderable.
            messageCard(icon: "doc.questionmark",
                        title: "This file type cannot be shown during the exam.",
                        detail: "\(file.originalName). Ask your teacher for a PDF.")
        case .failed:
            VStack(spacing: Theme.Space.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26)).foregroundStyle(Theme.muted2)
                Text("Couldn't load \(file.originalName).")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                Button("Try again") { store.retry(file: file) }
                    .buttonStyle(.glass)
                    .linkPointer()
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.95))
        case .loading, .none:
            loadingCard("Loading document…")
        }
    }

    // MARK: Web pane

    @ViewBuilder private func webPane(_ link: ExamLink) -> some View {
        if ReferenceTabStore.webURL(link.url) == nil {
            messageCard(icon: "globe",
                        title: "This link can't be opened.",
                        detail: "Ask your teacher to check the address for \(link.displayName).")
        } else if let tab = store.webTab(for: link) {
            VStack(spacing: 0) {
                webChrome(tab: tab, link: link)
                ZStack {
                    RetainedViewHost(view: tab.webView)
                    if let failure = tab.state.failure {
                        webFailure(tab: tab, link: link, message: failure)
                    }
                }
            }
        } else {
            // The tab is created here (a .task, never inside a view builder)
            // so nothing mutates state during a view update.
            loadingCard("Opening \(link.displayName)…")
                .task { store.ensureWebTab(link) }
        }
    }

    private func webChrome(tab: ReferenceWebTab, link: ExamLink) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted2)
                Text(tab.state.host ?? link.host)
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if tab.state.isLoading {
                    Text("Loading…")
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.muted2)
                }
                Button { tab.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Reload this page")
                .linkPointer()
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 5)
            .background(Color(white: 0.97))

            // Determinate hairline: the panel is not slower than a browser, it
            // just never used to say it was working.
            ProgressView(value: min(max(tab.state.progress, 0.03), 1))
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(height: 2)
                .opacity(tab.state.isLoading ? 1 : 0)
            Divider()
        }
    }

    private func webFailure(tab: ReferenceWebTab, link: ExamLink, message: String) -> some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26)).foregroundStyle(Theme.muted2)
            Text("Couldn't open \(tab.state.host ?? link.host).")
                .font(Theme.sans(13, .semibold)).foregroundStyle(Theme.inkSoft)
            Text(message)
                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Try again") { tab.reload() }
                .buttonStyle(.glass)
                .linkPointer()
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.95))
    }

    // MARK: Shared cards

    private func loadingCard(_ text: String) -> some View {
        ProgressView(text)
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.93))
    }

    private func messageCard(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.muted2)
            Text(title)
                .font(Theme.sans(13, .semibold)).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.95))
    }

    private var emptyState: some View {
        messageCard(icon: "books.vertical",
                    title: "Your teacher didn't attach any reference materials.",
                    detail: nil)
    }
}

// MARK: - Equatable: keystrokes must not rebuild the panel

// ExamView.body is invalidated on every keystroke (the autosave label), which
// re-created this whole subtree: the tab strip, the canvas geometry and an
// updateNSView on every mounted document and web view. The panel depends only
// on its materials and its store, so comparing those lets SwiftUI skip the
// rebuild entirely (see the .equatable() at the call site). onHide is excluded
// deliberately: it only toggles the caller's @State, whose storage is stable.
extension ExamReferencePanel: Equatable {
    static func == (a: ExamReferencePanel, b: ExamReferencePanel) -> Bool {
        a.store === b.store
            && a.signedIn == b.signedIn
            && a.materialsLoading == b.materialsLoading
            && a.files == b.files
            && a.links == b.links
    }
}

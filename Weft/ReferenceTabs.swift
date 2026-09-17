//
//  ReferenceTabs.swift
//  Weft — the exam reference area's model: one unified list of materials
//  (teacher documents + approved websites), which tab is selected / pinned
//  (split), per-document load state, and the long-lived render surfaces.
//
//  The store owns the PDF views, text views and web tabs for the whole exam, so
//  hiding the panel (⌘⇧R) and showing it again never reloads a document and
//  never loses a page, a scroll position, a zoom level or a web session.
//  Documents are fetched one at a time, the selected tab first.
//

import SwiftUI
import PDFKit
import WebKit
import AppKit

/// One openable reference material: a teacher document or an approved website.
enum ReferenceMaterial: Identifiable, Hashable {
    case pdf(ExamFile)
    case web(ExamLink)

    var id: String {
        switch self {
        case .pdf(let f): return Self.id(forFile: f)
        case .web(let l): return "web-\(l.id)"
        }
    }

    /// The material id of a file, without building the material (the store
    /// bridges the two id spaces in a few places).
    static func id(forFile file: ExamFile) -> String { "pdf-\(file.id)" }

    var title: String {
        switch self {
        case .pdf(let f): return f.isOutline ? "Your outline" : f.originalName
        case .web(let l): return l.displayName
        }
    }

    var icon: String {
        switch self {
        case .pdf(let f):
            if f.isOutline { return "pencil.and.outline" }
            return f.renderable == .unsupported ? "doc.questionmark" : "doc.text.fill"
        case .web: return "globe"
        }
    }
}

/// What the panel has for one reference file.
enum ReferenceDocument {
    case loading
    case pdf(PDFDocument)
    /// Word / RTF / plain text, read with AppKit's document importers.
    case text(NSAttributedString)
    /// A file type the exam panel cannot show at all. No retry is offered,
    /// because none could ever succeed.
    case unsupported
    /// The download failed. Try again is worth having.
    case failed

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

@MainActor
@Observable
final class ReferenceTabStore {

    /// A transient message for the panel's banner (a blocked site, a refused
    /// download). `seq` makes two identical messages distinct, so the banner
    /// re-appears for the second one.
    struct Notice: Equatable {
        let text: String
        let seq: Int
    }

    private(set) var materials: [ReferenceMaterial] = []
    private(set) var selectedID: String?
    /// Split mode: the material pinned to the top pane (nil = single pane).
    private(set) var pinnedID: String?
    /// Every material shown at least once; their views stay mounted for the
    /// rest of the exam (instant switching, scroll/zoom/web state preserved).
    /// One live web view per visited site, no eviction: teacher material
    /// counts are small (2-6) by design — revisit before a 30-link world.
    private(set) var visitedIDs: Set<String> = []
    /// Per-file load state, keyed by the raw ExamFile.id (NOT the prefixed
    /// ReferenceMaterial.id — use the documentState(for:) accessors, which
    /// exist precisely because there are two id spaces).
    private var docStates: [String: ReferenceDocument] = [:]
    /// The locked browser's allow-list for this exam, parsed from the teacher's
    /// stored link URLs.
    private(set) var allowRules: [AllowRule] = []
    private(set) var notice: Notice?
    /// Split divider position (top pane's share). Lives in the store, not the
    /// panel, so it survives the panel being hidden and re-shown (⌘⇧R).
    var splitFraction: CGFloat = 0.5

    /// Where to put the student back when Split is switched off again: the
    /// document they were reading, not the neighbour the split moved them to.
    private var preSplitSelectedID: String?
    private var signedIn = false
    private var noticeSeq = 0

    // Render surfaces and the serial download queue. Deliberately
    // @ObservationIgnored: they are view plumbing, not published state, and the
    // panel creates a surface lazily from inside `body`, where an observed
    // mutation would be a "modifying state during view update" hazard.
    @ObservationIgnored private var pdfViews: [String: PDFView] = [:]
    @ObservationIgnored private var textViews: [String: NSScrollView] = [:]
    @ObservationIgnored private var webDataStore: WKWebsiteDataStore?
    @ObservationIgnored private var queue: [ExamFile] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Web tabs ARE observed: the panel renders a tab's web view as soon as it
    /// exists, and creation happens in a `.task`, never in a view builder.
    private var webTabs: [String: ReferenceWebTab] = [:]

    var splitActive: Bool { pinnedID != nil }

    /// The selected / pinned material rows (panel conveniences).
    var selected: ReferenceMaterial? { materials.first { $0.id == selectedID } }
    var pinned: ReferenceMaterial? { materials.first { $0.id == pinnedID } }

    // MARK: Material list

    /// (Re)build the material list. Real materials can arrive after the panel
    /// is shown (loadExamMaterials resolves async), so this keeps the user's
    /// selection when it still exists and fetches only new files.
    func configure(files: [ExamFile], links: [ExamLink], signedIn: Bool) {
        self.signedIn = signedIn
        materials = files.map { .pdf($0) } + links.map { .web($0) }
        allowRules = ApprovedURLs.rules(from: links.map(\.url))
        for tab in webTabs.values { tab.updateRules(allowRules) }

        if selectedID == nil || !materials.contains(where: { $0.id == selectedID }) {
            selectedID = materials.first?.id
        }
        if let pinned = pinnedID, !materials.contains(where: { $0.id == pinned }) {
            pinnedID = nil
        }
        if let before = preSplitSelectedID, !materials.contains(where: { $0.id == before }) {
            preSplitSelectedID = nil
        }
        // Never leave both panes on the same material: that blanks the lower
        // pane, and the only way out used to be switching Split off.
        if pinnedID != nil, pinnedID == selectedID {
            pinnedID = nil
            preSplitSelectedID = nil
        }

        // Materials can be replaced mid-exam (samples -> real). Drop ghost
        // visited entries plus the load state, views and queued downloads of
        // anything that went away, so no stale view stays mounted and no
        // finished download writes back.
        let ids = Set(materials.map(\.id))
        visitedIDs.formIntersection(ids)
        let fileIDs = Set(files.map(\.id))
        for staleID in Array(docStates.keys) where !fileIDs.contains(staleID) {
            docStates[staleID] = nil
            pdfViews[staleID] = nil
            textViews[staleID] = nil
            queue.removeAll { $0.id == staleID }
        }
        let linkIDs = Set(links.map(\.id))
        for (staleID, tab) in Array(webTabs) where !linkIDs.contains(staleID) {
            tab.teardown()
            webTabs[staleID] = nil
        }
        if let selectedID { visitedIDs.insert(selectedID) }

        // Fetch the documents one at a time, the tab the student is looking at
        // first: four parallel downloads on school Wi-Fi is how the tab in
        // front ends up resolving last.
        enqueue(selectedFirst(files.filter { docStates[$0.id] == nil }))
    }

    func select(_ id: String) {
        guard materials.contains(where: { $0.id == id }) else { return }
        if id == pinnedID, let current = selectedID, current != id {
            // The pinned material is already on screen in the TOP pane, so
            // selecting it would empty the lower one. Swap the panes instead.
            pinnedID = current
            preSplitSelectedID = id
            selectedID = id
            visitedIDs.insert(id)
            return
        }
        selectedID = id
        visitedIDs.insert(id)
    }

    /// Toggle split: pin the current material on top and move the active tab
    /// to the next material so the two panes start on different things.
    /// Switching it off returns the student to the document they had pinned.
    func toggleSplit() {
        if pinnedID != nil {
            pinnedID = nil
            if let before = preSplitSelectedID,
               materials.contains(where: { $0.id == before }) {
                selectedID = before
                visitedIDs.insert(before)
            }
            preSplitSelectedID = nil
            return
        }
        guard let current = selectedID, materials.count > 1 else { return }
        preSplitSelectedID = current
        pinnedID = current
        if let i = materials.firstIndex(where: { $0.id == current }) {
            let next = materials[(i + 1) % materials.count].id
            selectedID = next
            visitedIDs.insert(next)
        }
    }

    // MARK: Documents

    /// Load state for a material; nil for web materials (they are not
    /// downloaded, they load in their own web view).
    func documentState(for material: ReferenceMaterial) -> ReferenceDocument? {
        if case .pdf(let f) = material { return docStates[f.id] }
        return nil
    }
    func documentState(for file: ExamFile) -> ReferenceDocument? { docStates[file.id] }

    func retry(file: ExamFile) {
        queue.removeAll { $0.id == file.id }
        guard signedIn, !file.storagePath.isEmpty else {
            docStates[file.id] = SamplePDF.shared.map { .pdf($0) } ?? .failed
            return
        }
        docStates[file.id] = .loading
        queue.insert(file, at: 0)      // the student is waiting on this one
        startWorker()
    }

    /// The retained PDF view for a file, created on first use: page, scroll
    /// position and zoom then survive the panel being hidden.
    func pdfView(for file: ExamFile, document: PDFDocument) -> PDFView {
        if let existing = pdfViews[file.id], existing.document === document { return existing }
        let view = ReferenceViews.makePDFView(document)
        pdfViews[file.id] = view
        return view
    }

    /// The retained text view for a Word / RTF / plain-text reference.
    func textView(for file: ExamFile, attributed: NSAttributedString) -> NSScrollView {
        if let existing = textViews[file.id] { return existing }
        let view = ReferenceViews.makeTextView(attributed)
        textViews[file.id] = view
        return view
    }

    private func selectedFirst(_ files: [ExamFile]) -> [ExamFile] {
        guard let selectedID,
              let i = files.firstIndex(where: { ReferenceMaterial.id(forFile: $0) == selectedID })
        else { return files }
        var out = files
        out.insert(out.remove(at: i), at: 0)
        return out
    }

    private func enqueue(_ files: [ExamFile]) {
        for file in files {
            guard docStates[file.id] == nil else { continue }
            // A file type the panel cannot render needs no download at all.
            guard file.renderable != .unsupported else {
                docStates[file.id] = .unsupported
                continue
            }
            // Sample materials (no storage path) and signed-out QA use the
            // bundled sample document, exactly like the old panel.
            guard signedIn, !file.storagePath.isEmpty else {
                docStates[file.id] = SamplePDF.shared.map { .pdf($0) } ?? .failed
                continue
            }
            docStates[file.id] = .loading
            queue.append(file)
        }
        startWorker()
    }

    /// One download at a time, in queue order. Cancelled wholesale when the
    /// exam ends so a large file can't keep transferring after teardown.
    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let store = self, !Task.isCancelled, let file = store.takeNext() {
                let document = await store.fetch(file)
                if Task.isCancelled { return }
                store.apply(document, to: file)
            }
            self?.worker = nil
        }
    }

    private func takeNext() -> ExamFile? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func fetch(_ file: ExamFile) async -> ReferenceDocument {
        do {
            let url = try await SupabaseManager.shared.signedURL(bucket: file.bucket,
                                                                 path: file.storagePath)
            return await ReferenceDocumentLoader.load(file: file, from: url)
        } catch {
            return .failed
        }
    }

    private func apply(_ document: ReferenceDocument, to file: ExamFile) {
        // The file may have been replaced while it was downloading.
        guard materials.contains(where: { $0.id == ReferenceMaterial.id(forFile: file) }) else {
            return
        }
        docStates[file.id] = document
    }

    // MARK: Web tabs

    func webTab(for link: ExamLink) -> ReferenceWebTab? { webTabs[link.id] }

    /// Create (once) and start the tab for an approved link. Called from the
    /// panel's `.task`, never from a view builder: creating a tab starts a
    /// network load and publishes state.
    func ensureWebTab(_ link: ExamLink) {
        guard webTabs[link.id] == nil, let url = Self.webURL(link.url) else { return }
        let tab = ReferenceWebTab(url: url, rules: allowRules,
                                  dataStore: sharedWebDataStore()) { [weak self] text in
            self?.post(notice: text)
        }
        webTabs[link.id] = tab
        tab.start()
    }

    /// A loadable URL for an approved link: teachers may store a bare host.
    /// Anything that is not an http(s) address gets no tab at all (the panel
    /// says the link cannot be opened), rather than a tab whose very creation
    /// reports a block.
    static func webURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// One ephemeral data store for every web tab of this exam: a library login
    /// in one tab is the same session in the next, and none of it is written to
    /// disk or kept past the exam.
    private func sharedWebDataStore() -> WKWebsiteDataStore {
        if let store = webDataStore { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        webDataStore = store
        return store
    }

    func post(notice text: String) {
        noticeSeq += 1
        notice = Notice(text: text, seq: noticeSeq)
    }

    func clearNotice() { notice = nil }

    // MARK: Teardown

    /// Exam over: cancel in-flight downloads, stop and drop every web tab
    /// (which discards the shared ephemeral session), and release the
    /// documents. Called from ExamView.endExam(), NOT when the panel is merely
    /// hidden, because hiding must keep everything alive.
    func endExam() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
        for tab in webTabs.values { tab.teardown() }
        webTabs.removeAll()
        webDataStore = nil
        pdfViews.removeAll()
        textViews.removeAll()
        docStates.removeAll()
        notice = nil
    }
}

//
//  ReferenceTabs.swift
//  Weft — the exam reference area's model: one unified list of materials
//  (teacher PDFs + approved websites), which tab is selected / pinned (split),
//  and per-PDF load state. Documents prefetch once at exam start; the panel
//  keeps every visited view alive, so switching tabs never reloads anything.
//

import SwiftUI
import PDFKit

/// One openable reference material: a teacher PDF or an approved website.
enum ReferenceMaterial: Identifiable, Hashable {
    case pdf(ExamFile)
    case web(ExamLink)

    var id: String {
        switch self {
        case .pdf(let f): return "pdf-\(f.id)"
        case .web(let l): return "web-\(l.id)"
        }
    }

    var title: String {
        switch self {
        case .pdf(let f): return f.isOutline ? "Your outline" : f.originalName
        case .web(let l): return l.displayName
        }
    }

    var icon: String {
        switch self {
        case .pdf(let f): return f.isOutline ? "pencil.and.outline" : "doc.text.fill"
        case .web: return "globe"
        }
    }
}

@MainActor
@Observable
final class ReferenceTabStore {
    enum PDFState: Equatable { case loading, loaded(PDFDocument), failed }

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
    /// ReferenceMaterial.id — use the pdfState(for:) accessors, which exist
    /// precisely because there are two id spaces).
    private var pdfStates: [String: PDFState] = [:]
    /// Split divider position (top pane's share). Lives in the store, not the
    /// panel, so it survives the panel being hidden and re-shown (⌘⇧R).
    var splitFraction: CGFloat = 0.5

    private var signedIn = false
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    var allowedHosts: [String] {
        materials.compactMap { if case .web(let l) = $0 { return l.host } else { return nil } }
    }
    var splitActive: Bool { pinnedID != nil }

    /// The selected / pinned material rows (panel conveniences).
    var selected: ReferenceMaterial? { materials.first { $0.id == selectedID } }
    var pinned: ReferenceMaterial? { materials.first { $0.id == pinnedID } }

    /// Load state for a material; nil for web materials (they have no
    /// prefetch). Bridges the two id spaces: pdfStates is keyed by the raw
    /// ExamFile.id, everything else by ReferenceMaterial.id.
    func pdfState(for material: ReferenceMaterial) -> PDFState? {
        if case .pdf(let f) = material { return pdfStates[f.id] }
        return nil
    }
    func pdfState(for file: ExamFile) -> PDFState? { pdfStates[file.id] }

    /// (Re)build the material list. Real materials can arrive after the panel
    /// is shown (loadExamMaterials resolves async), so this keeps the user's
    /// selection when it still exists and prefetches only new files.
    func configure(files: [ExamFile], links: [ExamLink], signedIn: Bool) {
        self.signedIn = signedIn
        materials = files.map { .pdf($0) } + links.map { .web($0) }
        if selectedID == nil || !materials.contains(where: { $0.id == selectedID }) {
            selectedID = materials.first?.id
        }
        if let pinned = pinnedID, !materials.contains(where: { $0.id == pinned }) {
            pinnedID = nil
        }
        // Materials can be replaced mid-exam (samples -> real). Drop ghost
        // visited entries and the load state/tasks of files that went away,
        // so no stale view stays mounted and no cancelled download writes back.
        let ids = Set(materials.map(\.id))
        visitedIDs.formIntersection(ids)
        let fileIDs = Set(files.map(\.id))
        for staleID in pdfStates.keys where !fileIDs.contains(staleID) {
            prefetchTasks[staleID]?.cancel()
            prefetchTasks[staleID] = nil
            pdfStates[staleID] = nil
        }
        if let selectedID { visitedIDs.insert(selectedID) }
        for file in files where pdfStates[file.id] == nil { prefetch(file) }
    }

    func select(_ id: String) {
        selectedID = id
        visitedIDs.insert(id)
    }

    /// Toggle split: pin the current material on top and move the active tab
    /// to the next material so the two panes start on different things.
    func toggleSplit() {
        if pinnedID != nil { pinnedID = nil; return }
        guard let current = selectedID, materials.count > 1 else { return }
        pinnedID = current
        if let i = materials.firstIndex(where: { $0.id == current }) {
            select(materials[(i + 1) % materials.count].id)
        }
    }

    func retry(file: ExamFile) {
        prefetchTasks[file.id]?.cancel()
        pdfStates[file.id] = nil
        prefetch(file)
    }

    /// Load a file's PDF once (fresh signed URL each attempt). Sample
    /// materials (no storage path) and signed-out QA use the bundled sample
    /// document, exactly like the old panel.
    private func prefetch(_ file: ExamFile) {
        guard signedIn, !file.storagePath.isEmpty else {
            if let doc = SamplePDF.shared {
                pdfStates[file.id] = .loaded(doc)
            } else {
                pdfStates[file.id] = .failed
            }
            return
        }
        pdfStates[file.id] = .loading
        prefetchTasks[file.id] = Task {
            var doc: PDFDocument?
            do {
                let url = try await SupabaseManager.shared.signedURL(bucket: file.bucket,
                                                                     path: file.storagePath)
                doc = await PDFLoader.load(from: url)
            } catch { doc = nil }
            if Task.isCancelled { return }
            pdfStates[file.id] = doc.map { .loaded($0) } ?? .failed
        }
    }
}

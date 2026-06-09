//
//  ExamReferencePanel.swift
//  Weft — the exam's reference column: the student chooses to see the teacher's
//  PDFs, the approved web links, or both at once (a native VSplitView), and can
//  collapse the whole column to write-only. PDFs render for real (PDFKit); the
//  web pane is the host-locked reference browser.
//

import SwiftUI
import PDFKit

enum ReferenceMode: String, CaseIterable, Identifiable {
    case split, pdf, web
    var id: String { rawValue }
    var label: String { self == .split ? "Split" : (self == .pdf ? "PDF" : "Web") }
}

struct ExamReferencePanel: View {
    let files: [ExamFile]
    let links: [ExamLink]
    let signedIn: Bool
    var onHide: () -> Void

    @State private var mode: ReferenceMode = .split
    @State private var selectedFileID: String?
    @State private var selectedLinkID: String?
    @State private var pdf: PDFDocument?
    @State private var pdfLoading = false
    @State private var blockedHost: String?

    private var allowedHosts: [String] { links.map(\.host) }
    private var selectedFile: ExamFile? {
        files.first { $0.id == selectedFileID } ?? files.first
    }
    private var selectedLink: ExamLink? {
        links.first { $0.id == selectedLinkID } ?? links.first
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            content
        }
        .background(Color(white: 0.96))
        .task { await primeSelection() }
        .onChange(of: selectedFileID) { _, _ in Task { await loadPDF() } }
    }

    // MARK: Mode bar
    private var modeBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Picker("", selection: $mode) {
                ForEach(ReferenceMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show PDFs, web links, or both")

            Spacer(minLength: 0)

            Button(action: onHide) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Hide references — write only (⌘⇧R)")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.regularMaterial)
    }

    // MARK: Content (split / pdf / web)
    @ViewBuilder private var content: some View {
        switch mode {
        case .split:
            VSplitView {
                pdfPane.frame(minHeight: 140)
                webPane.frame(minHeight: 140)
            }
        case .pdf:
            pdfPane
        case .web:
            webPane
        }
    }

    // MARK: PDF pane
    private var pdfPane: some View {
        VStack(spacing: 0) {
            paneHeader(icon: "doc.text.fill") {
                if files.isEmpty {
                    Text("No reference files").foregroundStyle(Theme.muted)
                } else if files.count == 1 {
                    Text(selectedFile?.originalName ?? "Document")
                        .foregroundStyle(Theme.ink).lineLimit(1)
                } else {
                    Menu {
                        ForEach(files) { f in
                            Button(f.originalName) { selectedFileID = f.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedFile?.originalName ?? "Document")
                                .foregroundStyle(Theme.ink).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            Divider()
            ZStack {
                if let pdf {
                    PDFKitView(document: pdf)
                } else if pdfLoading {
                    ProgressView("Loading document…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.93))
                } else {
                    paneEmpty(icon: "doc", text: files.isEmpty
                              ? "Your teacher didn't attach any files."
                              : "Couldn't load this document.")
                }
            }
        }
    }

    // MARK: Web pane
    private var webPane: some View {
        VStack(spacing: 0) {
            paneHeader(icon: "lock.fill") {
                if links.isEmpty {
                    Text("No reference links").foregroundStyle(Theme.muted)
                } else {
                    Menu {
                        ForEach(links) { l in
                            Button { selectedLinkID = l.id; blockedHost = nil } label: {
                                Text("\(l.displayName) — \(l.host)")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedLink.map { "\($0.displayName) · \($0.host)" } ?? "Pick a site")
                                .foregroundStyle(Theme.ink).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            Divider()
            ZStack(alignment: .top) {
                if let link = selectedLink, let url = URL(string: link.url) {
                    LockedBrowserView(url: url, allowedHosts: allowedHosts) { blocked in
                        blockedHost = blocked.host
                    }
                    .id(link.id)
                } else {
                    paneEmpty(icon: "globe", text: "Your teacher didn't approve any links.")
                }
                if let host = blockedHost {
                    Text("Blocked: \(host) is not on your teacher's list.")
                        .font(Theme.sans(12, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
                        .background(Theme.bad, in: Capsule())
                        .padding(.top, Theme.Space.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { blockedHost = nil }
                        }
                }
            }
        }
    }

    // MARK: Shared pane chrome
    private func paneHeader<Title: View>(icon: String, @ViewBuilder title: () -> Title) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            title().font(Theme.sans(12.5, .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 7)
        .background(Color(white: 0.985))
    }

    private func paneEmpty(icon: String, text: String) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.muted2)
            Text(text).font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.95))
    }

    // MARK: Loading
    private func primeSelection() async {
        if selectedFileID == nil { selectedFileID = files.first?.id }
        if selectedLinkID == nil { selectedLinkID = links.first?.id }
        // Pick a sensible default mode if one side is empty.
        if files.isEmpty && !links.isEmpty { mode = .web }
        else if links.isEmpty && !files.isEmpty { mode = .pdf }
        await loadPDF()
    }

    private func loadPDF() async {
        guard let file = selectedFile else { pdf = nil; return }
        // Sample materials (empty storage path) or not signed in → the bundled
        // sample document so the viewer is always populated for QA.
        if file.storagePath.isEmpty || !signedIn {
            pdf = SamplePDF.shared
            return
        }
        pdfLoading = true
        defer { pdfLoading = false }
        do {
            let url = try await SupabaseManager.shared.signedURL(bucket: "essay-files", path: file.storagePath)
            pdf = await PDFLoader.load(from: url)
        } catch {
            pdf = nil
        }
    }
}

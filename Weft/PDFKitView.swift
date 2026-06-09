//
//  PDFKitView.swift
//  Weft — a real PDF viewer for the exam reference panel (PDFKit). The Electron
//  build only ever showed file *names*; this renders the actual document.
//
//  Two sources: a remote URL (the private `essay-files` bucket, reached with a
//  signed URL + the student's token — see SupabaseManager.signedURL) or an
//  in-memory PDFDocument (the code-generated sample used by the dev gallery so
//  the viewer is visible without a live session).
//

import SwiftUI
import PDFKit
import AppKit

/// SwiftUI wrapper around PDFKit's `PDFView`. Native scrolling, selection,
/// search, and page shadows — the genuine macOS PDF experience.
struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    /// 0-based page to scroll to (e.g. a search hit). nil leaves the position.
    var scrollToPage: Int? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = NSColor(white: 0.93, alpha: 1)
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        if let i = scrollToPage, let page = document?.page(at: i) {
            view.go(to: page)
        }
    }
}

// MARK: - Loading

enum PDFLoader {
    /// Download a PDF over HTTP(S) (optionally with a Bearer token for a signed
    /// Supabase URL) and build a PDFDocument off the main thread.
    static func load(from url: URL, bearer: String? = nil) async -> PDFDocument? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return PDFDocument(data: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Sample PDF (dev gallery / no-session preview)

enum SamplePDF {
    /// Main-actor isolated: `make` does AppKit drawing, so first-touch must be on
    /// the main thread. (Sole caller is the @MainActor exam reference panel.)
    @MainActor static let shared: PDFDocument? = make(
        title: "Reference document",
        subtitle: "Daoism, assigned passage",
        paragraphs: [
            "This is a sample reference document so the in-exam PDF viewer renders in the dev gallery without a live session. In the real exam, the teacher's uploaded PDFs load here from the school's Weft storage.",
            "The interplay of light and shadow in the passage works as more than scenery. The author returns to dawn three times, each marking a shift in the narrator's certainty about what she has seen.",
            "The lantern in the window is never simply a source of warmth; it is the one fixed point against which the surrounding darkness is measured, and the narrator returns to it whenever the scene threatens to lose its bearings.",
            "By the final paragraph the two forces have collapsed into one. The dawn that breaks over the courtyard is neither pure relief nor pure loss; it is simply the moment at which the distinction stops mattering.",
        ],
        pages: 2)

    /// Render a simple multi-page PDF in code (US-Letter), so we never need a
    /// bundled asset. Each page is drawn into a flipped NSImage (top-left origin,
    /// text upright) and wrapped in a PDFPage — this avoids the CGContext
    /// text-matrix flip that renders NSString upside down in a raw PDF context.
    static func make(title: String, subtitle: String, paragraphs: [String], pages: Int) -> PDFDocument? {
        let size = NSSize(width: 612, height: 792)
        let titleFont = NSFont(name: "NewYork-Semibold", size: 26)
            ?? .systemFont(ofSize: 26, weight: .semibold)
        let subFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let bodyFont = NSFont(name: "NewYork", size: 13) ?? .systemFont(ofSize: 13)
        let ink = NSColor(red: 0.133, green: 0.125, blue: 0.110, alpha: 1)
        let muted = NSColor(red: 0.353, green: 0.333, blue: 0.314, alpha: 1)
        let margin: CGFloat = 64
        let width = size.width - margin * 2

        let doc = PDFDocument()
        for p in 0..<max(1, pages) {
            let image = NSImage(size: size, flipped: true) { _ in
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()

                var y: CGFloat = margin
                if p == 0 {
                    (title as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 40),
                        withAttributes: [.font: titleFont, .foregroundColor: ink])
                    y += 38
                    (subtitle as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: 22),
                        withAttributes: [.font: subFont, .foregroundColor: muted])
                    y += 34
                }

                let para = NSMutableParagraphStyle()
                para.lineSpacing = 5
                para.paragraphSpacing = 14
                for text in paragraphs {
                    let attr: [NSAttributedString.Key: Any] =
                        [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: para]
                    let bounding = (text as NSString).boundingRect(
                        with: CGSize(width: width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attr)
                    (text as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: bounding.height + 6),
                                            withAttributes: attr)
                    y += bounding.height + 18
                    if y > size.height - margin { break }
                }

                ("Weft · sample reference · page \(p + 1)" as NSString).draw(
                    in: CGRect(x: margin, y: size.height - margin + 18, width: width, height: 16),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: muted])
                return true
            }
            if let page = PDFPage(image: image) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        return doc
    }
}

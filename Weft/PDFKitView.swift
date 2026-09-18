//
//  PDFKitView.swift
//  Weft, the render surfaces for the exam reference panel: a real PDF viewer
//  (PDFKit, which also shows image references), a read-only text viewer for
//  Word / RTF / plain-text references (AppKit's document importers), and the
//  loader that turns a stored file into one of them. The Electron build only
//  ever showed file *names*; this renders the actual document.
//
//  Every surface is created ONCE per file and retained by ReferenceTabStore,
//  then hosted through `RetainedViewHost`. That is what makes page, scroll and
//  zoom survive hiding and re-showing the panel (⌘⇧R) without reloading.
//
//  Bytes come from the private `essay-files` / `outlines` buckets, reached with
//  a signed URL (see SupabaseManager.signedURL), or from the code-generated
//  sample document used by the dev gallery so the viewer is visible without a
//  live session.
//

import SwiftUI
import PDFKit
import AppKit

// MARK: - Hosting a long-lived AppKit view

/// Hosts an AppKit view that something else owns (the reference store), rather
/// than creating one per mount. SwiftUI may build and tear down the host many
/// times; the document, its page and its scroll position live in the retained
/// view, so nothing is lost or re-fetched.
struct RetainedViewHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Re-parent only when this container isn't already the view's home
        // (e.g. the panel was hidden and shown again, or the same material
        // moved between the split's two panes).
        if view.superview !== container { install(in: container) }
    }

    private func install(in container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - The render surfaces

enum ReferenceViews {

    /// PDFKit viewer: native scrolling, selection, search and page shadows.
    static func makePDFView(_ document: PDFDocument) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = NSColor(white: 0.93, alpha: 1)
        view.document = document
        return view
    }

    /// Read-only scrollable text for a Word / RTF / plain-text reference.
    static func makeTextView(_ attributed: NSAttributedString) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.93, alpha: 1)

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 10))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = .white
        text.textContainerInset = NSSize(width: 24, height: 24)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textStorage?.setAttributedString(attributed)
        scroll.documentView = text
        return scroll
    }
}

// MARK: - Loading

enum ReferenceDocumentLoader {

    /// Download a reference file and turn it into something the panel can
    /// render. Never throws, and deliberately separates "this file type cannot
    /// be shown" (no retry offered, because none could ever succeed) from
    /// "failed" (a network problem, where Try again is worth having).
    ///
    /// On cancellation the download throws and this returns `.failed`; the
    /// caller checks `Task.isCancelled` and discards the result.
    static func load(file: ExamFile, from url: URL) async -> ReferenceDocument {
        guard file.renderable != .unsupported else { return .unsupported }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failed
            }
            data = body
        } catch {
            return .failed
        }

        return await Task.detached(priority: .userInitiated) {
            decode(data: data, file: file)
        }.value
    }

    nonisolated private static func decode(data: Data, file: ExamFile) -> ReferenceDocument {
        switch file.renderable {
        case .pdf:
            if let doc = PDFDocument(data: data) { return .pdf(doc) }
            return data.starts(with: Array("%PDF".utf8)) ? .failed : .unsupported
        case .image:
            return imageDocument(from: data)
        case .word, .rtf, .plainText:
            return textDocument(from: data, file: file)
        case .unsupported:
            return .unsupported
        }
    }

    /// A picture (a chart, a photographed source, a scanned page): teachers
    /// attach these freely, and the Electron viewer showed them inline, so the
    /// exam panel must too. The decoded image is wrapped in a one-page PDF and
    /// handed to the same PDFKit surface as every other reference, which is what
    /// gives it fit-to-width, zoom and scrolling for free.
    nonisolated private static func imageDocument(from data: Data) -> ReferenceDocument {
        guard let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0,
              let page = PDFPage(image: image)
        else {
            // Bytes AppKit cannot decode at all, i.e. a file mislabelled as an
            // image: a retry downloads exactly the same thing, so this is
            // "cannot be shown", not "couldn't load". (PNG, JPEG, HEIC, GIF,
            // TIFF and SVG all decode; verified against real bytes.)
            return .unsupported
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return .pdf(doc)
    }

    nonisolated private static func textDocument(from data: Data, file: ExamFile) -> ReferenceDocument {
        if file.renderable == .plainText {
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            else { return .unsupported }
            return .text(styled(text))
        }

        // AppKit's importers read from a file URL, so the bytes go to a temp
        // file carrying the extension the importer expects, and are removed
        // again as soon as it has parsed them.
        let ext: String
        let type: NSAttributedString.DocumentType
        switch file.renderable {
        case .word where file.isOfficeOpenXML: ext = "docx"; type = .officeOpenXML
        case .word: ext = "doc"; type = .docFormat
        default: ext = "rtf"; type = .rtf
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("weft-reference-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp, options: .atomic)
            let attributed = try NSAttributedString(url: tmp,
                                                    options: [.documentType: type],
                                                    documentAttributes: nil)
            guard attributed.length > 0 else { return .unsupported }
            return .text(attributed)
        } catch {
            // The importer refused the file: a retry would fail identically,
            // so this is "cannot be shown", not "couldn't load".
            return .unsupported
        }
    }

    nonisolated private static func styled(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: para,
        ])
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

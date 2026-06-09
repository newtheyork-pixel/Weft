//
//  ExamView.swift
//  Weft — the in-exam writing surface: prompt + live timer, the rich-text
//  editor on a clean white page, an approved-resources side panel (files +
//  locked browser), and the honest "Proctoring on" chip. Mirrors the Electron
//  #stage-essay. Mock data for now; kiosk + autosave wire in next.
//

import SwiftUI

struct ExamView: View {
    @State private var controller = RichTextController()
    @State private var essay = NSAttributedString(
        string: "The interplay of light and shadow in the passage works as more than scenery. The author returns to dawn three times, each marking a shift in the narrator's certainty about what she has seen.")
    @State private var wordCount = 26
    @State private var deadline = Date().addingTimeInterval(38 * 60 + 24)
    @State private var sideTab: SideTab = .files

    enum SideTab { case files, links }

    private let prompt = "Analyze the use of light and dark imagery in the assigned passage."
    private let files = ["Passage excerpt.pdf", "Imagery glossary.pdf"]

    var body: some View {
        HStack(spacing: 0) {
            editorColumn
            Divider()
            sidePanel
                .frame(width: 380)
        }
        .background(Color(white: 0.97))
        .overlay(alignment: .bottomTrailing) { proctoringChip.padding(20) }
    }

    // MARK: Editor column
    private var editorColumn: some View {
        VStack(spacing: 0) {
            header
            RichTextToolbar(controller: controller)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.sm)
            RichTextEditor(text: $essay, wordCount: $wordCount, controller: controller)
                .background(Color.white)
                .padding(.horizontal, Theme.Space.xl)
            footerBar
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.96))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Kicker(text: "Writing prompt")
                Text(prompt)
                    .font(Theme.serif(20, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            countdown
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.md)
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
            Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(remaining < 300 ? Theme.warn : Theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.accent.opacity(0.10), in: Capsule())
        }
    }

    private var footerBar: some View {
        HStack {
            Button("Back") {}.buttonStyle(.glass)
            Spacer()
            Text("All saved")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            Spacer()
            Button("Next") {}.buttonStyle(.glassProminent).tint(Theme.accent)
        }
        .padding(Theme.Space.xl)
    }

    // MARK: Side panel (approved resources)
    private var sidePanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sideTab) {
                Text("Files (PDFs, docs)").tag(SideTab.files)
                Text("Reference links").tag(SideTab.links)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.Space.md)

            if sideTab == .files {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files, id: \.self) { f in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Theme.accent)
                            Text(f).font(Theme.sans(14)).foregroundStyle(Theme.inkSoft)
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, 14)
                        Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl)
                    }
                    Spacer()
                }
            } else {
                LockedBrowserView(
                    url: URL(string: "https://en.wikipedia.org/wiki/Imagery")!,
                    allowedHosts: ["wikipedia.org"]
                )
            }
        }
        .background(.regularMaterial)
    }

    // MARK: Proctoring chip
    private var proctoringChip: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.good).frame(width: 8, height: 8)
            Text("Proctoring on")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

#Preview {
    ExamView()
        .preferredColorScheme(.light)
        .frame(width: 1180, height: 780)
}

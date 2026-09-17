//
//  AssignmentEditorView.swift
//  Weft — the teacher's assignment editor (the essay composer) and the
//  template picker that precedes a brand-new assignment. Ported from the
//  Electron #template-backdrop + #editor-backdrop modals (renderer/teacher.html
//  + the renderEssayQuestionBody composer in teacher.js), rebuilt as native
//  glass modals floating over a dimmed ambient field.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor row models

/// One editing sitting, as a reference: a file whose upload lands after the
/// teacher cancelled has to be taken back out, and a View struct copy captured
/// by that upload's task cannot see the cancellation.
@MainActor private final class EditorSitting { var cancelled = false }

/// A website students are allowed to open during the essay. There is no
/// per-link scope: `test_urls` has no scope column in the live schema and the
/// locked browser matches on host alone, so every approved link means the whole
/// site and the editor says so rather than offering a choice it cannot keep.
private struct EditorLink: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var href: String
}

/// The three light starting templates a new assignment can begin from.
enum AssignmentTemplate: String, CaseIterable, Identifiable {
    case essay, reading, short
    var id: String { rawValue }

    var title: String {
        switch self {
        case .essay:   return "Essay prompt"
        case .reading: return "Reading response"
        case .short:   return "Short answer"
        }
    }
    var blurb: String {
        switch self {
        case .essay:   return "A focused writing prompt students respond to in long form."
        case .reading: return "Students react to a text or source and support their thinking."
        case .short:   return "A brief, to-the-point answer with a tight word limit."
        }
    }
    /// Starter prompt text pre-filled into the editor when chosen.
    var starterPrompt: String {
        switch self {
        case .essay:
            return "Write an essay that responds to the following prompt. Make a clear argument and support it with specific evidence.\n\n[Your prompt here]"
        case .reading:
            return "Respond to the assigned reading. What is the author arguing, and how well do they support it? Use specific examples from the text to back up your response."
        case .short:
            return "Answer the question below in a few clear sentences. Be specific and concise.\n\n[Your question here]"
        }
    }
    /// Sensible default word limit (nil = unlimited).
    var defaultWordLimit: Int? {
        switch self {
        case .essay:   return nil
        case .reading: return 400
        case .short:   return 150
        }
    }
}

// MARK: - Template picker

/// "Start a new assignment" — pick a starting point before the editor opens.
struct TemplatePickerView: View {
    @State private var selected: AssignmentTemplate = .essay

    /// Called with the chosen template when the teacher taps Continue.
    var onContinue: (AssignmentTemplate) -> Void = { _ in }
    var onCancel: () -> Void = {}

    var body: some View {
        ZStack {
            AmbientBackground()
            Color.black.opacity(0.28).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(spacing: Theme.Space.sm) {
                    ForEach(AssignmentTemplate.allCases) { template in
                        templateCard(template)
                    }
                }
                .padding(.top, Theme.Space.md)

                HStack(spacing: Theme.Space.md) {
                    Button("Continue") { onContinue(selected) }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .linkPointer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.glass)
                        .linkPointer()
                }
                .padding(.top, Theme.Space.lg)
            }
            .padding(Theme.Space.xl)
            .frame(width: 460)
            .weftGlass(Theme.Radius.xl)
            .overlay(alignment: .topTrailing) { closeButton }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.accent)
                Text("Start a new assignment")
                    .font(Theme.serif(20, .semibold))
                    .foregroundStyle(Theme.inkSoft)
            }
            Text("Pick a starting point. You can change everything in the next step.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
        }
    }

    private func templateCard(_ template: AssignmentTemplate) -> some View {
        let isOn = selected == template
        return Button {
            selected = template
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.title)
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                    Text(template.blurb)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isOn ? Theme.accent : Theme.muted2)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isOn ? Theme.accent.opacity(0.08) : Color.white.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent : Color.black.opacity(0.10),
                                  lineWidth: isOn ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.16), value: isOn)
        }
        .buttonStyle(.plain)
        .rowHover(corner: Theme.Radius.md)
        .linkPointer()
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var closeButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .padding(8)
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.md)
        .help("Close")
        .linkPointer()
        .accessibilityLabel("Close")
    }
}

// MARK: - Assignment editor

/// The essay composer: title, writing prompt, word limit, time limit,
/// attached reference files, and the website allow-list. A single essay
/// question per assignment, matching the Electron editor exactly.
struct AssignmentEditorView: View {
    @Environment(AppState.self) private var app

    /// Optional template pre-fill for a brand-new assignment (dev gallery /
    /// template picker entry). The live edit/create path is driven by
    /// `app.editingAssignment`.
    var template: AssignmentTemplate?

    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    // Form state
    @State private var title: String = ""
    @State private var prompt: String = ""
    @State private var wordLimit: String = ""
    @State private var timeLimit: String = ""
    /// Teacher-controlled per assignment; default true keeps students' spell-check
    /// on unless the teacher explicitly disables it. Primed from the existing
    /// assignment in prime() so editing round-trips the value faithfully.
    @State private var spellcheckEnabled: Bool = true
    /// Teacher-controlled per assignment; default false — outlines are opt-in.
    /// Primed from the existing assignment in prime() so editing round-trips
    /// the value faithfully.
    @State private var outlineAllowed: Bool = false
    /// The real `test_files` rows attached to this assignment's question.
    @State private var files: [TeacherFile] = []
    @State private var links: [EditorLink] = []

    // Attachment load + upload state. `attachmentsLoaded` gates Save: saving
    // while the saved files/links are still in flight used to overwrite the
    // question with an empty allow list (and drop its files).
    @State private var attachmentsLoaded: Bool = false
    @State private var attachmentsFailed: Bool = false
    @State private var fileImporterShown: Bool = false
    @State private var uploadingName: String?
    /// Files detached in this sitting: destroyed only once a save lands, so
    /// cancelling leaves every stored byte where it was.
    @State private var removedFiles: [TeacherFile] = []
    /// Files uploaded in this sitting, by id. Cancelling deletes the ones no
    /// saved assignment references (the upload happens at pick time).
    @State private var uploadedThisSitting: [String: TeacherFile] = [:]
    @State private var sitting = EditorSitting()

    // New-link drafting
    @State private var newLinkName: String = ""
    @State private var newLinkHref: String = ""
    @State private var linkError: String?

    private var isNew: Bool { app.editingAssignment == nil }
    private var heading: String { isNew ? "New assignment" : "Edit assignment" }
    /// Never save on top of attachments we haven't got: a load still in flight
    /// (or one that failed) would be written out as "no files, no websites".
    private var canSave: Bool { attachmentsLoaded && !attachmentsFailed && uploadingName == nil }

    /// PDF only, because that is all the exam can show: the reference panel
    /// renders every attached file through PDFKit (ReferenceTabs builds a
    /// .pdf material per file), so a Word or image attachment would open as a
    /// failed tab in the middle of an exam.
    private static let referenceTypes: [UTType] = [.pdf]

    var body: some View {
        ZStack {
            AmbientBackground()
            Color.black.opacity(0.28).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.md)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        titleField
                        promptField
                        wordLimitField
                        timeLimitField
                        spellcheckToggle
                        outlineToggle
                        filesSection
                        websitesSection
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.lg)
                }

                if let message = app.errorMessage {
                    errorBanner(message)
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.bottom, Theme.Space.sm)
                }

                footer
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.lg)
            }
            .frame(width: 560, height: 660)
            .weftGlass(Theme.Radius.xl)
            .overlay(alignment: .topTrailing) { closeButton }
        }
        .onAppear(perform: prime)
        .task { await app.loadApprovedSites() }
        .fileImporter(isPresented: $fileImporterShown,
                      allowedContentTypes: Self.referenceTypes) { result in
            switch result {
            case .success(let url): attach(url)
            case .failure(let error):
                app.errorMessage = "Couldn't open that file. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: isNew ? "square.and.pencil" : "pencil.and.outline")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.accent)
                Text(heading)
                    .font(Theme.serif(20, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
            }
        }
    }

    // MARK: Fields

    private var titleField: some View {
        fieldGroup(label: "Title") {
            TextField("e.g. Chapter 4 essay", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.sans(15))
                .foregroundStyle(Theme.inkSoft)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(fieldBackground)
        }
    }

    private var promptField: some View {
        fieldGroup(label: "Writing prompt") {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Describe what students should write about…")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.muted2)
                        .padding(.top, 12)
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.inkSoft)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
            }
            .background(fieldBackground)
        }
    }

    private var wordLimitField: some View {
        inlineField(
            label: "Word limit",
            hint: "Leave blank for unlimited."
        ) {
            TextField("no limit", text: $wordLimit)
                .textFieldStyle(.plain)
                .font(Theme.sans(14))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 110)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(fieldBackground)
        }
    }

    private var timeLimitField: some View {
        inlineField(
            label: "Time limit (minutes)",
            hint: "Leave blank for unlimited time. Enter minutes to enforce a limit (e.g. 60 = one hour). When time runs out, the essay saves itself and locks."
        ) {
            TextField("", text: $timeLimit)
                .textFieldStyle(.plain)
                .font(Theme.sans(14))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 110)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(fieldBackground)
        }
    }

    private var spellcheckToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow spell check while writing", isOn: $spellcheckEnabled)
                .font(Theme.sans(14))
                .foregroundStyle(Theme.inkSoft)
                .toggleStyle(.switch)
                .help("When off, students see no spelling squiggles during this assignment")
            Text("Spell check is on by default. Turn it off for assignments where you want students to rely on their own spelling.")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.muted2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var outlineToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow outline", isOn: $outlineAllowed)
                .font(Theme.sans(14))
                .foregroundStyle(Theme.inkSoft)
                .toggleStyle(.switch)
                .help("When on, students can attach an outline from the class home before they start")
            Text("Students may upload a PDF or Word outline until they begin writing.")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.muted2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Attached files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionHead(title: "Attached files") {
                Button {
                    fileImporterShown = true
                } label: {
                    Label("Attach file", systemImage: "paperclip")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(canSave ? Theme.accent : Theme.muted2)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .linkPointer()
                .help("Attach a PDF students can open during the essay (up to 50 MB)")
            }

            if let uploadingName {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Uploading \(uploadingName)…")
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }

            if !attachmentsLoaded {
                Text("Loading this assignment's files…")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            } else if files.isEmpty {
                Text("No files attached. Students will see whatever you add here.")
                    .font(Theme.sans(12))
                    .italic()
                    .foregroundStyle(Theme.muted2)
                    .padding(.top, 2)
            } else {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(files) { file in
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "doc")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                            Text(file.originalName)
                                .font(Theme.sans(13))
                                .foregroundStyle(Theme.inkSoft)
                                .lineLimit(1)
                            Spacer(minLength: Theme.Space.sm)
                            Text(Self.sizeLabel(file.sizeBytes))
                                .font(Theme.sans(12))
                                .foregroundStyle(Theme.muted2)
                            Button("Remove") { remove(file) }
                            .buttonStyle(.plain)
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.bad)
                            .linkPointer()
                            .help("Remove this file when you save")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(fieldBackground)
                        .rowHover()
                    }
                }
                .animation(.easeOut(duration: 0.18), value: files)
            }
        }
    }

    /// A human size for an attached file (the Electron editor's formatBytes).
    private static func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Websites students may open

    /// "Add from the school list" pulls the school's published Google Sheet of
    /// approved sites (the Electron picker, restored).
    @ViewBuilder private var schoolListRow: some View {
        if app.approvedSitesLoading {
            Label("Loading the school list", systemImage: "globe")
                .font(Theme.sans(12)).foregroundStyle(Theme.muted)
        } else if !app.approvedSites.isEmpty {
            HStack(spacing: Theme.Space.sm) {
                Menu {
                    ForEach(app.approvedSites) { site in
                        Button("\(site.name) · \(site.host)") { addApprovedSite(site) }
                    }
                } label: {
                    Label("Add from school list", systemImage: "list.bullet.rectangle")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().linkPointer()
                Text("·").foregroundStyle(Theme.muted2)
                Button("Add all") { addAllApprovedSites() }
                    .buttonStyle(.plain)
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .linkPointer()
                    .help("Add every school-approved site")
                Spacer(minLength: 0)
            }
        }
    }

    private func addApprovedSite(_ site: ApprovedSite) {
        guard !links.contains(where: { $0.href.caseInsensitiveCompare(site.url) == .orderedSame }) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            links.append(EditorLink(name: site.name, href: site.url))
        }
    }

    private func addAllApprovedSites() {
        withAnimation(.easeOut(duration: 0.18)) {
            for site in app.approvedSites where
                !links.contains(where: { $0.href.caseInsensitiveCompare(site.url) == .orderedSame }) {
                links.append(EditorLink(name: site.name, href: site.url))
            }
        }
    }

    private var websitesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionHead(title: "Websites students may open") { EmptyView() }

            schoolListRow

            // Add a link by name + URL.
            VStack(spacing: Theme.Space.sm) {
                TextField("Display name (e.g. Hamlet on Folger)", text: $newLinkName)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .background(fieldBackground)
                HStack(spacing: Theme.Space.sm) {
                    TextField("https://example.com/article", text: $newLinkHref)
                        .textFieldStyle(.plain)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(fieldBackground)
                    Button("Add") { addLink() }
                        .buttonStyle(.glass)
                        .help("Add this website to the allow list")
                        .linkPointer()
                }
            }

            if let linkError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(linkError)
                        .font(Theme.sans(12, .semibold))
                }
                .foregroundStyle(Theme.bad)
                .transition(.opacity)
            }

            if !attachmentsLoaded {
                Text("Loading this assignment's websites…")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            } else if links.isEmpty {
                Text("No websites added. Students can only open links you list here (e.g. a dictionary or an article). Everything else is blocked during the essay.")
                    .font(Theme.sans(12))
                    .italic()
                    .foregroundStyle(Theme.muted2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(links) { link in
                        linkRow(link)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: links)
            }
        }
        // No editing until the saved list is on screen: an edit made during the
        // load would be overwritten the moment it arrived.
        .disabled(!attachmentsLoaded)
        .animation(.easeOut(duration: 0.16), value: linkError)
    }

    private func linkRow(_ link: EditorLink) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name)
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                if !link.href.isEmpty {
                    Text(link.href)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            // Every approved link opens the whole site: the locked browser
            // matches on host, and test_urls stores no per-page scope. Stating
            // it beats a picker whose choice nothing can honour.
            Text("Entire site")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.muted2)
                .help("Students can open any page on this site during the essay")
            Button("Remove") {
                withAnimation(.easeOut(duration: 0.18)) {
                    links.removeAll { $0.id == link.id }
                }
            }
            .buttonStyle(.plain)
            .font(Theme.sans(12, .semibold))
            .foregroundStyle(Theme.bad)
            .linkPointer()
            .help("Remove this website")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(fieldBackground)
        .rowHover()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.md) {
            Button {
                save()
            } label: {
                Label("Save assignment", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(app.isLoading || !canSave)
            .linkPointer()
            .help(saveHelp)
            Button("Cancel") { cancel() }
                .buttonStyle(.glass)
                .linkPointer()
            Spacer()
            if app.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving…")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if attachmentsFailed {
                Text("Reopen the editor to load the files and websites.")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(Theme.bad)
            } else if !attachmentsLoaded {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading attachments…")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.isLoading)
        .animation(.easeOut(duration: 0.2), value: attachmentsLoaded)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(message)
                .font(Theme.sans(13, .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.bad)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.bad.opacity(0.10))
        )
        .transition(.opacity)
    }

    private var closeButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .padding(8)
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.md)
        .help("Close")
        .linkPointer()
        .accessibilityLabel("Close")
    }

    // MARK: Reusable field chrome

    @ViewBuilder
    private func fieldGroup<Content: View>(label: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: label)
            content()
        }
    }

    @ViewBuilder
    private func inlineField<Content: View>(label: String,
                                            hint: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                Kicker(text: label)
                content()
            }
            Text(hint)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.muted2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sectionHead<Trailing: View>(title: String,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack {
                Kicker(text: title)
                Spacer()
                trailing()
            }
            .padding(.bottom, Theme.Space.sm)
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Color.white.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
            )
    }

    // MARK: Behaviour

    /// Why Save is unavailable, for the button's tooltip.
    private var saveHelp: String {
        if uploadingName != nil { return "Wait for the file to finish uploading" }
        if attachmentsFailed { return "This assignment's files and websites couldn't be loaded, so saving now would remove them" }
        if !attachmentsLoaded { return "Loading this assignment's files and websites" }
        return "Save this assignment"
    }

    private func prime() {
        guard let existing = app.editingAssignment else {
            // A brand-new assignment has nothing to load, so Save is live at once.
            attachmentsLoaded = true
            if let template {
                prompt = template.starterPrompt
                if let wl = template.defaultWordLimit { wordLimit = String(wl) }
            }
            return
        }
        title = existing.title
        prompt = existing.questions.first?.prompt ?? ""
        if let wl = existing.questions.first?.wordLimit { wordLimit = String(wl) }
        if let tl = existing.timeLimitMinutes { timeLimit = String(tl) }
        // Prime the spell-check + outline toggles from the saved assignment
        // so editing round-trips the values and a teacher can change them
        // on a re-edit.
        spellcheckEnabled = existing.spellcheckEnabled
        outlineAllowed = existing.outlineAllowed
        // Load the saved files AND websites before either list is editable, and
        // keep Save shut until they land: a save inside this window used to
        // write an empty allow list over the whitelist the locked browser
        // depends on, and to leave the attached files invisible.
        Task {
            guard let loaded = await app.editorAttachments(for: existing) else {
                attachmentsFailed = true
                return
            }
            links = loaded.links.map { EditorLink(name: $0.name, href: $0.href) }
            files = loaded.files
            attachmentsLoaded = true
        }
    }

    private func cancel() {
        // Attaching uploads at pick time, so anything uploaded in this sitting
        // and not saved has to go back out. Files that were already saved are
        // left alone, removed or not: cancelling must not destroy them.
        sitting.cancelled = true
        let orphans = Array(uploadedThisSitting.values)
        if !orphans.isEmpty {
            Task { await app.discardUnsavedAttachments(orphans) }
        }
        app.teacherGoHome()
        onCancel()
    }

    /// Upload the picked reference file, then list the real row it created.
    private func attach(_ url: URL) {
        guard uploadingName == nil else { return }
        uploadingName = url.lastPathComponent
        Task {
            let file = await app.attachReferenceFile(fileURL: url, contentType: Self.mime(for: url))
            uploadingName = nil
            guard let file else { return }   // attachReferenceFile set errorMessage
            guard !sitting.cancelled else {
                // Cancelled while the bytes were going up: the file belongs to
                // no assignment, so take it back out rather than leave it in
                // the bucket forever.
                await app.discardUnsavedAttachments([file])
                return
            }
            uploadedThisSitting[file.id] = file
            withAnimation(.easeOut(duration: 0.18)) { files.append(file) }
        }
    }

    /// Detach a file. The row and its bytes are destroyed by the save, once the
    /// assignment no longer references them, so a cancel is still a full undo.
    private func remove(_ file: TeacherFile) {
        withAnimation(.easeOut(duration: 0.18)) {
            files.removeAll { $0.id == file.id }
        }
        removedFiles.append(file)
    }

    /// Content type for the picked file. The picker allows PDF only, so the
    /// extension is authoritative (the outlineMime pattern).
    private static func mime(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private func addLink() {
        linkError = nil
        let name = newLinkName.trimmingCharacters(in: .whitespaces)
        let href = newLinkHref.trimmingCharacters(in: .whitespaces)
        guard !href.isEmpty else {
            linkError = "Add a website address."
            return
        }
        guard href.lowercased().hasPrefix("http") else {
            linkError = "Use a full address starting with https://"
            return
        }
        // One row per address: saving collapses duplicates onto a single
        // test_urls row anyway, so accepting one here would only look like a
        // second entry that vanishes on the next open.
        guard !links.contains(where: { $0.href.caseInsensitiveCompare(href) == .orderedSame }) else {
            linkError = "That website is already on the list."
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            links.append(EditorLink(name: name.isEmpty ? href : name, href: href))
        }
        newLinkName = ""
        newLinkHref = ""
    }

    private func save() {
        // Persist through AppState. Blank -> nil = "unlimited". A value
        // that is not a bare positive integer is a typo, not a wish for
        // unlimited: "60 min" used to write NULL and the teacher saw the
        // field still holding their text. Refuse the save and say why,
        // next to Save, which is the control that looked like a no-op
        // when the banner lived up in the scroll view.
        guard canSave else { return }
        let words: Int?
        switch Self.parseLimit(wordLimit) {
        case .unlimited: words = nil
        case .value(let n): words = n
        case .invalid:
            app.errorMessage = "Word limit must be a whole number of words, or left blank for unlimited."
            return
        }
        let minutes: Int?
        switch Self.parseLimit(timeLimit) {
        case .unlimited: minutes = nil
        case .value(let n): minutes = n
        case .invalid:
            app.errorMessage = "Time limit must be a whole number of minutes, or left blank for unlimited."
            return
        }
        Task {
            await app.saveAssignment(
                title: title,
                prompt: prompt,
                wordLimit: words,
                timeLimitMinutes: minutes,
                spellcheckEnabled: spellcheckEnabled,
                outlineAllowed: outlineAllowed,
                links: links.map { (name: $0.name, href: $0.href) },
                fileIds: files.map(\.id),
                removedFiles: removedFiles
            )
            // A save that landed leaves nothing to clean up on cancel.
            if app.errorMessage == nil {
                removedFiles = []
                uploadedThisSitting = [:]
            }
        }
        onSave()
    }

    private enum LimitInput { case unlimited, value(Int), invalid }

    /// Empty is unlimited; a positive integer is a limit; anything else
    /// ("60 min", "1 hour", "none") is a typo the teacher must see.
    private static func parseLimit(_ text: String) -> LimitInput {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .unlimited }
        if let n = Int(trimmed), n > 0 { return .value(n) }
        return .invalid
    }
}

// MARK: - Preview

#Preview("Editor") {
    AssignmentEditorView(template: .essay)
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 760, height: 760)
}

#Preview("Template picker") {
    TemplatePickerView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 680, height: 620)
}

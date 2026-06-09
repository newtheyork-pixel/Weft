//
//  AssignmentEditorView.swift
//  Weft — the teacher's assignment editor (the essay composer) and the
//  template picker that precedes a brand-new assignment. Ported from the
//  Electron #template-backdrop + #editor-backdrop modals (renderer/teacher.html
//  + the renderEssayQuestionBody composer in teacher.js), rebuilt as native
//  glass modals floating over a dimmed ambient field.
//

import SwiftUI

// MARK: - Mock data models for the editor

/// A reference file a teacher attaches to the prompt (students can open it).
private struct EditorFile: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var size: String
}

/// A website students are allowed to open during the essay.
private struct EditorLink: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var href: String
    var scope: Scope = .domain
    enum Scope: String, CaseIterable { case domain, exact
        var label: String { self == .domain ? "Entire site" : "This page only" }
    }
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
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.glass)
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
    /// Pre-fill from a template (new assignment) or an existing assignment.
    var template: AssignmentTemplate?
    var existing: Assignment?

    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    // Form state
    @State private var title: String = ""
    @State private var prompt: String = ""
    @State private var wordLimit: String = ""
    @State private var timeLimit: String = ""
    @State private var files: [EditorFile] = []
    @State private var links: [EditorLink] = []

    // New-link drafting
    @State private var newLinkName: String = ""
    @State private var newLinkHref: String = ""
    @State private var linkError: String?

    @State private var didSave = false

    private var isNew: Bool { existing == nil }
    private var heading: String { isNew ? "New assignment" : "Edit assignment" }

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
                        filesSection
                        websitesSection
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.lg)
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
            Button {
                // Blackbaud import is a later wave — surfaced for parity.
            } label: {
                Text("Import from Blackbaud →")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .linkPointer()
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

    // MARK: Attached files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionHead(title: "Attached files") {
                Button {
                    addMockFile()
                } label: {
                    Label("Attach file", systemImage: "paperclip")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .linkPointer()
                .help("Attach a reference file students can open")
            }

            if files.isEmpty {
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
                            Text(file.name)
                                .font(Theme.sans(13))
                                .foregroundStyle(Theme.inkSoft)
                                .lineLimit(1)
                            Spacer(minLength: Theme.Space.sm)
                            Text(file.size)
                                .font(Theme.sans(12))
                                .foregroundStyle(Theme.muted2)
                            Button("Remove") {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    files.removeAll { $0.id == file.id }
                                }
                            }
                            .buttonStyle(.plain)
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.bad)
                            .linkPointer()
                            .help("Remove this file")
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

    // MARK: Websites students may open

    private var websitesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionHead(title: "Websites students may open") { EmptyView() }

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

            if links.isEmpty {
                Text("No websites added. Students can only open links you list here (e.g. a dictionary or an article). Everything else is blocked during the essay.")
                    .font(Theme.sans(12))
                    .italic()
                    .foregroundStyle(Theme.muted2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                VStack(spacing: Theme.Space.xs) {
                    ForEach($links) { $link in
                        linkRow($link)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: links)
            }
        }
        .animation(.easeOut(duration: 0.16), value: linkError)
    }

    private func linkRow(_ link: Binding<EditorLink>) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.wrappedValue.name)
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                if !link.wrappedValue.href.isEmpty {
                    Text(link.wrappedValue.href)
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            Picker("", selection: link.scope) {
                ForEach(EditorLink.Scope.allCases, id: \.self) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)
            .help("Choose whether students can open the whole site or only this page")
            Button("Remove") {
                withAnimation(.easeOut(duration: 0.18)) {
                    links.removeAll { $0.id == link.wrappedValue.id }
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
                Label(didSave ? "Saved" : "Save assignment",
                      systemImage: didSave ? "checkmark" : "tray.and.arrow.down")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(didSave)
            Button("Cancel") { onCancel() }
                .buttonStyle(.glass)
            Spacer()
            if didSave {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.good)
                    Text("Saved")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.good)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: didSave)
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

    // MARK: Behaviour (mock)

    private func prime() {
        if let existing {
            title = existing.title
            if let q = existing.questions.first {
                prompt = q.prompt
                if let wl = q.wordLimit { wordLimit = String(wl) }
            }
            if let tl = existing.timeLimitMinutes { timeLimit = String(tl) }
        } else if let template {
            prompt = template.starterPrompt
            if let wl = template.defaultWordLimit { wordLimit = String(wl) }
        }
    }

    private func addMockFile() {
        let n = files.count + 1
        withAnimation(.easeOut(duration: 0.18)) {
            files.append(EditorFile(name: "reference-\(n).pdf", size: "248 KB"))
        }
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
        withAnimation(.easeOut(duration: 0.18)) {
            links.append(EditorLink(name: name.isEmpty ? href : name, href: href))
        }
        newLinkName = ""
        newLinkHref = ""
    }

    private func save() {
        // Mock save — backend is a later wave. Flash confirmation then bubble up.
        withAnimation { didSave = true }
        onSave()
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

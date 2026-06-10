//
//  TeacherHomeView.swift
//  Weft — teacher home, class-first. Level 1: your classes + the global
//  Library. Level 2: one class's detail (live monitor / launch / session
//  history / roster). Grading is reached ONLY from session history rows,
//  never from the live surface.
//

import SwiftUI

struct TeacherHomeView: View {
    @Environment(AppState.self) private var app
    @State private var newClassName = ""
    @State private var showNewClass = false

    /// The picked assignment's title (from grouped rows), falling back gracefully when nothing is set.
    private var pickedAssignmentTitle: String {
        app.groupedAssignments.first(where: { $0.id == app.pickedAssignmentId })?.title ?? "an assignment"
    }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Teacher")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let error = app.errorMessage { errorBanner(error) }
                    if app.teacherSelectedClassId == nil {
                        introHeader
                        if app.teacherClasses.isEmpty { classesEmpty } else { classCards }
                        newClassButton
                        libraryCard
                    } else {
                        classDetail
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: app.teacherSelectedClassId)
                .animation(.easeOut(duration: 0.2), value: app.liveSession?.id)
                .animation(.easeOut(duration: 0.2), value: app.classSessions)
                .animation(.easeOut(duration: 0.2), value: app.teacherClasses.count)
            }
        }
        .background(AmbientBackground())
        .task { await app.loadTeacherHome() }
        .alert("New class", isPresented: $showNewClass) {
            TextField("Class name", text: $newClassName)
            Button("Create") {
                Task {
                    await app.createClass(name: newClassName)
                    newClassName = ""
                }
            }
            Button("Cancel", role: .cancel) { newClassName = "" }
        } message: {
            Text("Give the class a name. Students join with the class code.")
        }
    }

    // MARK: Level 1: your classes + the Library

    private var introHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your classes")
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text("Open a class to launch, monitor, and grade its sessions.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
        }
        .padding(.bottom, Theme.Space.sm)
    }

    /// One full-width card per class (the student classes-list idiom). A single
    /// button per card, no inner buttons: Roster lives in the detail header.
    /// The LIVE chip (derived ONLY from liveSession) is the only live
    /// affordance at this level.
    private var classCards: some View {
        VStack(spacing: Theme.Space.md) {
            ForEach(app.teacherClasses) { c in
                Button { app.selectTeacherClass(c.id) } label: {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "person.2")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(c.name)
                                    .font(Theme.sans(15, .semibold))
                                    .foregroundStyle(Theme.ink)
                                if app.liveSession?.classId == c.id {
                                    Chip(text: "LIVE", kind: .good)
                                }
                            }
                            Text("Class code \(c.joinCode)")
                                .font(Theme.sans(12.5))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.muted2)
                    }
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .weftGlass(Theme.Radius.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkPointer()
            }
        }
    }

    private var classesEmpty: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted2)
            Text("Create a class to get started. Students join with the class code.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.md)
    }

    private var newClassButton: some View {
        Button {
            showNewClass = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text("New class")
                    .font(Theme.sans(13, .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help("Create a new class")
    }

    /// The global assignment library. Assignments belong to the teacher and
    /// bind to a class only at launch, so there are no launch controls here:
    /// launching is a class-detail act.
    private var libraryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    sectionHeader("doc.text", "Library")
                    Spacer()
                    Button("+ New") { app.openNewAssignment() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .font(Theme.sans(13, .semibold))
                        .linkPointer()
                        .help("Create a new assignment")
                }
                ForEach(app.groupedAssignments) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(a.title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.inkSoft)
                                if a.versionNumber > 1 {
                                    Text("v\(a.versionNumber)")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.accent.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            Text("Essay" + (a.timeLimitMinutes.map { " · \($0) min" } ?? "")).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button {
                            Task { await app.createNextDraft(of: a) }
                        } label: {
                            Image(systemName: "doc.badge.plus")
                        }
                        .buttonStyle(.glass)
                        .help("New draft (v\(a.versionNumber + 1)): copy this assignment, tweak, launch")
                        Button("Edit") { app.openEditAssignment(a) }.buttonStyle(.glass)
                    }
                    .padding(.vertical, Theme.Space.sm)
                    .padding(.horizontal, Theme.Space.sm)
                    .rowHover()
                }
            }
        }
    }

    // MARK: Level 2: class detail

    /// One class's operational surface. If the selection no longer resolves
    /// (class deleted under us), render nothing; loadTeacherHome's hygiene
    /// pops the level back to the classes list.
    @ViewBuilder private var classDetail: some View {
        if let c = app.selectedTeacherClass {
            detailHeader(c)
            liveArea(c)
            sessionsCard
        }
    }

    private func detailHeader(_ c: ClassRoom) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button { app.leaveTeacherClass() } label: {
                Label("Your classes", systemImage: "chevron.left")
                    .font(Theme.sans(13, .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .linkPointer()
            HStack {
                Text(c.name)
                    .font(Theme.serif(24, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button("Roster") { app.openRoster(c) }.buttonStyle(.glass)
            }
            Text("Class code \(c.joinCode)")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.muted)
        }
    }

    /// Exactly one of three states: this class owns the live session (monitor),
    /// another class owns it (pointer, launch hidden), or nothing is live
    /// (launch). Hiding the launch card while another class is live shows the
    /// one-live-session invariant instead of letting the teacher discover it
    /// through an error; launchSession's guard remains as backstop.
    @ViewBuilder private func liveArea(_ c: ClassRoom) -> some View {
        if app.liveSession?.classId == c.id {
            liveNowCard
            monitorRosterCard
        } else if app.liveSession != nil {
            livePointerRow
        } else {
            launchCard(c)
        }
    }

    private var liveNowCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("\(app.liveSession.map(app.sessionTitle) ?? "Assignment") is live · \(app.roster.count == 1 ? "1 student" : "\(app.roster.count) students")")
                    .font(Theme.sans(17, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                HStack(spacing: Theme.Space.md) {
                    Chip(text: "Open", kind: .good)
                    HStack(spacing: 6) {
                        // "Session code", never "Class code": the class JOIN
                        // code sits in the header directly above this card.
                        Kicker(text: "Session code")
                        Text(app.liveSession?.code ?? "------").font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                    }
                    Spacer()
                    Button("End session") {
                        Task { await app.endSession() }
                    }
                    .buttonStyle(.glass)
                    .help("Close this session for all students")
                }
            }
        }
    }

    /// The live proctoring monitor. THIS IS THE ENTIRE LIVE SURFACE: watching
    /// only, no grading affordance anywhere in it. Teachers grade later, from
    /// the session history rows below.
    private var monitorRosterCard: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("person.3", "Roster  \(app.roster.count)")
                    .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.lg).padding(.bottom, Theme.Space.sm)
                Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl)
                if app.roster.isEmpty {
                    // Zero joined is the NORMAL state right after launch:
                    // state it explicitly (house idiom), never a bare divider.
                    Text("No students yet. Students join with the session code.")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 13)
                } else {
                    ForEach(Array(app.roster.enumerated()), id: \.element.id) { idx, s in
                        if idx > 0 { Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl) }
                        HStack(spacing: Theme.Space.md) {
                            Text(s.name).font(Theme.sans(14)).foregroundStyle(Theme.inkSoft)
                            Spacer()
                            if let same = s.networkSame {
                                Text(same ? "Same Wi-Fi" : "Different network").font(Theme.sans(12.5)).foregroundStyle(same ? Theme.muted : Theme.warn)
                            }
                            Chip(text: s.status.capitalized, kind: s.signal == .ok ? .good : .warn)
                        }
                        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 13)
                    }
                }
            }
        }
    }

    /// Quiet single line shown when ANOTHER class owns the live session, with
    /// an actionable pointer when the owning class is known.
    private var livePointerRow: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Text("A session is live in \(app.liveClassName ?? "another class").")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
            if let liveCid = app.liveSession?.classId {
                Button("Go to \(app.liveClassName ?? "class")") {
                    app.selectTeacherClass(liveCid)
                }
                .buttonStyle(.plain)
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.accent)
                .linkPointer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.sm)
    }

    /// The launch card. No class picker: the class is the one being viewed.
    /// With an empty library it points back to the Library instead of
    /// presenting an empty picker and a Start that can only fail post-click.
    private func launchCard(_ c: ClassRoom) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Kicker(text: "Launch")
                if app.groupedAssignments.isEmpty {
                    Text("No assignments yet. Create one in the Library, then launch it here.")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        app.leaveTeacherClass()
                    } label: {
                        Label("Go to the Library", systemImage: "doc.text")
                            .font(Theme.sans(13, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .linkPointer()
                } else {
                    Text("Ready to launch \(pickedAssignmentTitle) for \(c.name).")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.muted)
                    idPicker("Assignment", value: pickedAssignmentTitle,
                             items: app.groupedAssignments.map { a in
                                 (a.id, a.versionNumber > 1 ? "\(a.title) · v\(a.versionNumber)" : a.title)
                             }) { app.pickedAssignmentId = $0 }
                    Button {
                        Task { await app.launchSession() }
                    } label: {
                        Label("Start live assignment", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .disabled(app.isLoading)   // a launch is in flight: no double-launch
                    .padding(.top, Theme.Space.xs)
                }
            }
        }
    }

    /// Session history, any status, newest first. EVERY row carries Review
    /// essays, the open one included: a history row is the grading entry
    /// point at any time, day-of or weeks later. The live monitor never
    /// carries it.
    private var sessionsCard: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("clock.arrow.circlepath", "Sessions")
                    .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.lg).padding(.bottom, Theme.Space.sm)
                Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl)
                if let sessions = app.classSessions {
                    if sessions.isEmpty {
                        Text("No sessions yet. Launch an assignment to start one.")
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, Theme.Space.xl).padding(.vertical, 13)
                    } else {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, s in
                            if idx > 0 { Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl) }
                            sessionRow(s)
                                .padding(.horizontal, Theme.Space.xl).padding(.vertical, 13)
                        }
                    }
                } else {
                    // nil = not loaded: never assert emptiness before a load confirms it.
                    Text("Loading sessions…")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 13)
                }
            }
        }
    }

    private func sessionRow(_ s: ExamSession) -> some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.sessionTitle(s)).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.inkSoft)
                Text(meta(for: s)).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Chip(text: s.status == "open" ? "Open" : "Closed",
                 kind: s.status == "open" ? .good : .neutral)
            Button("Review essays") {
                app.openGrading(session: s, title: app.sessionTitle(s))
            }
            .buttonStyle(.glass)
        }
    }

    /// Row meta: the launch date (matching ReviewGradingView's date treatment)
    /// plus the session code; code-only when created_at is missing
    /// (nil-while-unknown: never invent a date).
    private func meta(for s: ExamSession) -> String {
        guard let when = s.createdAt else { return "code \(s.code)" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: when) + " · code \(s.code)"
    }

    // MARK: Helpers

    /// A small inline error banner, matching the student home's treatment.
    /// Retry is level-aware: a class detail also reloads its session history
    /// (the second call covers an early throw in the first). The rest of the
    /// page stays rendered beneath the banner.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") {
                if app.teacherSelectedClassId == nil {
                    Task { await app.loadTeacherHome() }
                } else {
                    Task { await app.loadTeacherHome(); await app.loadClassSessions() }
                }
            }
            .buttonStyle(.plain)
            .font(Theme.sans(12.5, .semibold))
            .foregroundStyle(Theme.accent)
            .linkPointer()
        }
        .padding(Theme.Space.md)
        .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    /// A small leading SF Symbol paired with the standard Kicker label, for a
    /// more native section header without symbol-spamming.
    private func sectionHeader(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Kicker(text: title)
        }
    }

    /// Id-based picker: selecting an item passes its id (so two items with the
    /// same display title never collide).
    private func idPicker(_ label: String, value: String, items: [(String, String)],
                          onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: label)
            Menu {
                ForEach(items, id: \.0) { item in Button(item.1) { onPick(item.0) } }
            } label: {
                HStack {
                    Text(value).font(Theme.sans(14)).foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.12)))
                .linkPointer()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }
}

#Preview {
    TeacherHomeView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 760, height: 800)
}

//
//  AdminOverviewLayout.swift
//  Weft: admin page, option B: one calm scrolling page. Counts at the top,
//  then the three areas as cards; full lists and rosters open in sheets.
//

import SwiftUI

struct AdminOverviewLayout: View {
    @Environment(AppState.self) private var app
    @State private var pending: PendingStaffAction?
    @State private var sheet: Sheet?

    private let staffPreviewCount = 5
    private let workPreviewCount = 5

    enum Sheet: Identifiable {
        case staff
        case roster(String)
        case work
        var id: String {
            switch self {
            case .staff: "staff"
            case .roster(let id): "roster-\(id)"
            case .work: "work"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                if let error = app.errorMessage, sheet == nil { AdminErrorBanner(message: error) }
                AdminPageHeader(title: "Your school",
                                subtitle: "Staff, classes and student work, all in one place.")
                    .padding(.bottom, Theme.Space.xs)
                counts
                staffCard
                classesCard
                workCard
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .staff: StaffSheet(close: { sheet = nil })
            case .roster(let id): RosterSheet(classId: id, close: { sheet = nil })
            case .work: WorkSheet(close: { sheet = nil }, open: { session in
                sheet = nil
                app.openAdminGrading(session)
            })
            }
        }
        .staffConfirmations($pending, app: app)
    }

    // MARK: Counts

    private var counts: some View {
        HStack(spacing: Theme.Space.md) {
            countTile("\(app.staff.filter { $0.role == .teacher }.count)", "Teachers")
            countTile("\(app.adminCount)", "Admins")
            countTile("\(app.activeSchoolClasses.count)", "Classes")
            countTile("\(app.schoolSessions.count)", "Sessions")
        }
    }

    private func countTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.isEmpty ? " " : value)
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.inkSoft)
                .monospacedDigit()
            Kicker(text: label)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .weftGlass(Theme.Radius.md)
    }

    // MARK: Teachers and admins

    private var staffCard: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader("person.2", "Teachers and admins", action: "Manage") { sheet = .staff }
                let shown = Array(app.sortedStaff.prefix(staffPreviewCount))
                if shown.isEmpty {
                    note(app.adminLoaded ? "No one on the list yet." : "Loading staff…")
                }
                ForEach(shown) { m in
                    rowDivider
                    HStack(spacing: Theme.Space.md) {
                        Text(m.email)
                            .font(Theme.sans(14.5))
                            .foregroundStyle(Theme.inkSoft)
                        if app.isSelf(m) { Chip(text: "You", kind: .accent) }
                        Spacer()
                        Text(m.role == .admin ? "Admin" : "Teacher")
                            .font(Theme.sans(13))
                            .foregroundStyle(m.role == .admin ? Theme.accent : Theme.muted)
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, 10)
                }
                let more = app.staff.count - shown.count
                if more > 0 {
                    rowDivider
                    moreButton("\(more) more") { sheet = .staff }
                }
            }
            .padding(.bottom, Theme.Space.xs)
        }
    }

    // MARK: Classes

    private var classesCard: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader("person.3", "Classes", action: nil) {}
                let classes = app.activeSchoolClasses
                if classes.isEmpty {
                    note(app.adminLoaded ? "No classes yet." : "Loading classes…")
                }
                ForEach(classes) { c in
                    rowDivider
                    Button { sheet = .roster(c.id) } label: {
                        HStack(spacing: Theme.Space.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                    .font(Theme.sans(15, .semibold))
                                    .foregroundStyle(Theme.inkSoft)
                                Text("\(app.teacherLabel(c.teacherUserId)) · \(AdminFormat.students(c.studentCount))")
                                    .font(Theme.sans(12.5))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Text("Roster")
                                .font(Theme.sans(12.5, .semibold))
                                .foregroundStyle(Theme.accent)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.muted2)
                        }
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowHover(corner: 0)
                }
            }
            .padding(.bottom, Theme.Space.xs)
        }
    }

    // MARK: Work

    private var workCard: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader("doc.text", "Recent work",
                           action: app.schoolSessions.count > workPreviewCount ? "See all" : nil) {
                    sheet = .work
                }
                let shown = Array(app.schoolSessions.prefix(workPreviewCount))
                if shown.isEmpty {
                    note(app.adminLoaded ? "No sessions yet." : "Loading sessions…")
                }
                ForEach(shown) { s in
                    rowDivider
                    AdminWorkRow(session: s) { app.openAdminGrading(s) }
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, 11)
                }
            }
            .padding(.bottom, Theme.Space.xs)
        }
    }

    // MARK: Helpers

    private func cardHeader(_ symbol: String, _ title: String, action: String?,
                            perform: @escaping () -> Void) -> some View {
        HStack {
            AdminSectionHeader(symbol: symbol, title: title)
            Spacer()
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .linkPointer()
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.sm)
    }

    private var rowDivider: some View {
        Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(13))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, 12)
    }

    private func moreButton(_ text: String, perform: @escaping () -> Void) -> some View {
        Button(text, action: perform)
            .buttonStyle(.plain)
            .font(Theme.sans(13, .semibold))
            .foregroundStyle(Theme.accent)
            .linkPointer()
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, 10)
    }
}

/// One session row: title, class and date, submitted count, status, Open.
struct AdminWorkRow: View {
    let session: SchoolSession
    let open: () -> Void
    @Environment(AppState.self) private var app

    var body: some View {
        let chip = AdminFormat.statusChip(session.status)
        let meta = [app.schoolClassName(session.classId), AdminFormat.dateTime(session.createdAt)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Text(meta)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(AdminFormat.submitted(session.submittedCount))
                .font(Theme.sans(13))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            Chip(text: chip.text, kind: chip.kind)
            Button("Review essays", action: open)
                .buttonStyle(.glass)
                .linkPointer()
                .help("Read and grade this session's essays")
        }
    }
}

// MARK: - Sheets

/// A plain sheet frame: title, Done, then the content.
private struct AdminSheetFrame<Content: View>: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Theme.serif(22, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                    Text(subtitle)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.defaultAction)
                    .linkPointer()
            }
            .padding(Theme.Space.xl)
            if let error = app.errorMessage {
                AdminErrorBanner(message: error)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.md)
            }
            Divider().opacity(0.5)
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.sm)
            }
        }
        .frame(width: 560, height: 560)
    }
}

private struct StaffSheet: View {
    let close: () -> Void
    @Environment(AppState.self) private var app
    @State private var pending: PendingStaffAction?

    var body: some View {
        AdminSheetFrame(title: "Teachers and admins",
                        subtitle: "Add staff by email. They can sign in with Google any time after.",
                        close: close) {
            VStack(alignment: .leading, spacing: 0) {
                AddStaffForm()
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.md)
                ForEach(app.sortedStaff) { m in
                    Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl)
                    HStack(spacing: Theme.Space.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(m.email)
                                    .font(Theme.sans(14.5, .semibold))
                                    .foregroundStyle(Theme.inkSoft)
                                if app.isSelf(m) { Chip(text: "You", kind: .accent) }
                            }
                            if m.addedAt != nil {
                                Text("Added \(AdminFormat.date(m.addedAt))")
                                    .font(Theme.sans(12))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        StaffRoleMenu(member: m, pending: $pending)
                        Button("Remove") { pending = .remove(m) }
                            .buttonStyle(.plain)
                            .font(Theme.sans(12.5, .semibold))
                            .foregroundStyle(Theme.muted)
                            .linkPointer()
                            .padding(.leading, Theme.Space.sm)
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, 10)
                }
            }
        }
        .staffConfirmations($pending, app: app)
    }
}

private struct RosterSheet: View {
    let classId: String
    let close: () -> Void
    @Environment(AppState.self) private var app

    var body: some View {
        let c = app.schoolClasses.first { $0.id == classId }
        AdminSheetFrame(title: c?.name ?? "Class",
                        subtitle: c.map { "\(app.teacherLabel($0.teacherUserId)) · class code \($0.joinCode)" } ?? "",
                        close: close) {
            AdminRosterList(classId: classId)
        }
    }
}

private struct WorkSheet: View {
    let close: () -> Void
    let open: (SchoolSession) -> Void
    @Environment(AppState.self) private var app

    var body: some View {
        AdminSheetFrame(title: "All work",
                        subtitle: "Every session in the school. Open one to read and grade it.",
                        close: close) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(app.schoolSessions.enumerated()), id: \.element.id) { idx, s in
                    if idx > 0 { Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl) }
                    AdminWorkRow(session: s) { open(s) }
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, 10)
                }
            }
        }
    }
}

#Preview {
    AdminHomeView(variant: .overview)
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

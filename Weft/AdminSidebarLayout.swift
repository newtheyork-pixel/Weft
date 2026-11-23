//
//  AdminSidebarLayout.swift
//  Weft: admin page, option A: a left sidebar with the three areas
//  (Teachers and admins, Students, All work) and the chosen area on the right.
//

import SwiftUI

struct AdminSidebarLayout: View {
    @Environment(AppState.self) private var app
    @State private var section: AdminSection = .staff
    /// The class whose roster is open in Students (nil = the class list).
    @State private var openClassId: String?
    @State private var pending: PendingStaffAction?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 256)
            Divider().overlay(Color.black.opacity(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let error = app.errorMessage { AdminErrorBanner(message: error) }
                    switch section {
                    case .staff: staffArea
                    case .students: studentsArea
                    case .work: workArea
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: openClassId)
            }
        }
        .staffConfirmations($pending, app: app)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Kicker(text: "School")
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)
            ForEach(AdminSection.allCases) { s in
                sidebarRow(s)
            }
            Spacer()
            Text("Changes save as you make them.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.muted2)
                .padding(.horizontal, Theme.Space.md)
        }
        .padding(.vertical, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(0.18))
    }

    private func sidebarRow(_ s: AdminSection) -> some View {
        let selected = section == s
        return Button {
            section = s
            if s != .students { openClassId = nil }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: s.symbol)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                Text(s.title)
                    .font(Theme.sans(14, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSoft)
                Spacer()
                Text(count(s))
                    .font(Theme.sans(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.accent.opacity(selected ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHover()
    }

    private func count(_ s: AdminSection) -> String {
        switch s {
        case .staff: "\(app.staff.count)"
        case .students: "\(app.activeSchoolClasses.count)"
        case .work: "\(app.schoolSessions.count)"
        }
    }

    // MARK: Teachers and admins

    @ViewBuilder private var staffArea: some View {
        AdminPageHeader(title: "Teachers and admins",
                        subtitle: "Add staff by email. They can sign in with Google any time after.")
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                AdminSectionHeader(symbol: "person.badge.plus", title: "Add someone")
                AddStaffForm()
            }
        }
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if app.staff.isEmpty {
                    emptyNote(app.adminLoaded ? "No one on the list yet." : "Loading staff…")
                }
                ForEach(Array(app.sortedStaff.enumerated()), id: \.element.id) { idx, m in
                    if idx > 0 { rowDivider }
                    staffRow(m)
                }
            }
            .padding(.vertical, Theme.Space.sm)
        }
    }

    private func staffRow(_ m: StaffMember) -> some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.email)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                    if app.isSelf(m) { Chip(text: "You", kind: .accent) }
                }
                if m.addedAt != nil {
                    Text("Added \(AdminFormat.date(m.addedAt))")
                        .font(Theme.sans(12.5))
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
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .rowHover()
    }

    // MARK: Students

    @ViewBuilder private var studentsArea: some View {
        if let cid = openClassId, let c = app.schoolClasses.first(where: { $0.id == cid }) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Button { openClassId = nil } label: {
                    Label("All classes", systemImage: "chevron.left")
                        .font(Theme.sans(13, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .linkPointer()
                AdminPageHeader(title: c.name,
                                subtitle: "\(app.teacherLabel(c.teacherUserId)) · class code \(c.joinCode)")
            }
            GlassCard(padding: 0) {
                AdminRosterList(classId: c.id)
                    .padding(.vertical, Theme.Space.sm)
            }
        } else {
            AdminPageHeader(title: "Students",
                            subtitle: "Every class in the school. Open one to see who is in it.")
            GlassCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    let classes = app.activeSchoolClasses
                    if classes.isEmpty {
                        emptyNote(app.adminLoaded ? "No classes yet." : "Loading classes…")
                    }
                    ForEach(Array(classes.enumerated()), id: \.element.id) { idx, c in
                        if idx > 0 { rowDivider }
                        classRow(c)
                    }
                }
                .padding(.vertical, Theme.Space.sm)
            }
        }
    }

    private func classRow(_ c: SchoolClass) -> some View {
        Button { openClassId = c.id } label: {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                    Text(app.teacherLabel(c.teacherUserId))
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(AdminFormat.students(c.studentCount))
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.muted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHover()
    }

    // MARK: All work

    @ViewBuilder private var workArea: some View {
        AdminPageHeader(title: "All work",
                        subtitle: "Every session in the school. Open one to read and grade it.")
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if app.schoolSessions.isEmpty {
                    emptyNote(app.adminLoaded ? "No sessions yet." : "Loading sessions…")
                }
                ForEach(Array(app.schoolSessions.enumerated()), id: \.element.id) { idx, s in
                    if idx > 0 { rowDivider }
                    AdminWorkRow(session: s) { app.openAdminGrading(s) }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                }
            }
            .padding(.vertical, Theme.Space.sm)
        }
    }

    // MARK: Helpers

    private var rowDivider: some View {
        Divider().opacity(0.4).padding(.horizontal, 22)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(13))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
    }
}

#Preview {
    AdminHomeView(variant: .sidebar)
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

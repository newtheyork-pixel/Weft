//
//  AdminTablesLayout.swift
//  Weft: admin page, option C: tabs across the top, each a dense table
//  with a search box. Students shows the open class's roster beside the table.
//

import SwiftUI

struct AdminTablesLayout: View {
    @Environment(AppState.self) private var app
    @State private var section: AdminSection = .staff
    @State private var search = ""
    @State private var pending: PendingStaffAction?
    @State private var selectedStaff: StaffMember.ID?
    @State private var selectedClass: SchoolClass.ID?
    @State private var selectedSession: SchoolSession.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            toolbar
            if let error = app.errorMessage { AdminErrorBanner(message: error) }
            switch section {
            case .staff: staffTab
            case .students: studentsTab
            case .work: workTab
            }
        }
        .padding(Theme.Space.xl)
        .staffConfirmations($pending, app: app)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Space.md) {
            Picker("Area", selection: $section) {
                ForEach(AdminSection.allCases) { s in
                    Text("\(s.title)  \(count(s))").tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                TextField(searchPrompt, text: $search)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(13))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted2)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(width: 240)
            .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12)))
        }
    }

    private var searchPrompt: String {
        switch section {
        case .staff: "Search email"
        case .students: "Search class or teacher"
        case .work: "Search assignment or class"
        }
    }

    private func count(_ s: AdminSection) -> Int {
        switch s {
        case .staff: app.staff.count
        case .students: app.activeSchoolClasses.count
        case .work: app.schoolSessions.count
        }
    }

    private func matches(_ fields: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Teachers and admins

    private var filteredStaff: [StaffMember] {
        app.sortedStaff.filter { matches($0.email, $0.role.rawValue) }
    }

    private var staffTab: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Text("Add someone")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                AddStaffForm()
                    .frame(maxWidth: 520)
                Spacer(minLength: 0)
            }
            tableCard {
                Table(filteredStaff, selection: $selectedStaff) {
                    TableColumn("Email") { m in
                        HStack(spacing: 6) {
                            Text(m.email)
                            if app.isSelf(m) { Chip(text: "You", kind: .accent) }
                        }
                    }
                    .width(min: 220, ideal: 320)
                    TableColumn("Role") { m in
                        StaffRoleMenu(member: m, pending: $pending)
                    }
                    .width(min: 90, ideal: 110, max: 140)
                    TableColumn("Added") { m in
                        Text(AdminFormat.date(m.addedAt)).foregroundStyle(Theme.muted)
                    }
                    .width(min: 90, ideal: 120, max: 160)
                    TableColumn("") { m in
                        Button("Remove") { pending = .remove(m) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.muted)
                            .linkPointer()
                    }
                    .width(70)
                }
            } empty: {
                emptyText(app.staff.isEmpty
                          ? (app.adminLoaded ? "No one on the list yet." : "Loading staff…")
                          : "No matches.", isEmpty: filteredStaff.isEmpty)
            }
        }
    }

    // MARK: Students

    private var filteredClasses: [SchoolClass] {
        app.activeSchoolClasses.filter { matches($0.name, app.teacherLabel($0.teacherUserId), $0.joinCode) }
    }

    private var studentsTab: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            tableCard {
                Table(filteredClasses, selection: $selectedClass) {
                    TableColumn("Class") { c in Text(c.name) }
                        .width(min: 160, ideal: 240)
                    TableColumn("Teacher") { c in
                        Text(app.teacherLabel(c.teacherUserId)).foregroundStyle(Theme.muted)
                    }
                    .width(min: 110, ideal: 160)
                    TableColumn("Students") { c in
                        Text(c.studentCount.map(String.init) ?? "").monospacedDigit()
                    }
                    .width(min: 60, ideal: 70, max: 90)
                    TableColumn("Code") { c in
                        Text(c.joinCode).foregroundStyle(Theme.muted).monospaced()
                    }
                    .width(min: 70, ideal: 80, max: 100)
                }
            } empty: {
                emptyText(app.activeSchoolClasses.isEmpty
                          ? (app.adminLoaded ? "No classes yet." : "Loading classes…")
                          : "No matches.", isEmpty: filteredClasses.isEmpty)
            }
            rosterPanel
                .frame(width: 300)
        }
    }

    private var rosterPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cid = selectedClass, let c = app.schoolClasses.first(where: { $0.id == cid }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                    Text(AdminFormat.students(c.studentCount))
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.muted)
                }
                .padding(Theme.Space.md)
                Divider().opacity(0.5)
                ScrollView {
                    AdminRosterList(classId: c.id, dense: true)
                        .padding(.vertical, Theme.Space.xs)
                }
            } else {
                Text("Select a class to see its students.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.muted)
                    .padding(Theme.Space.md)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .weftGlass(Theme.Radius.md)
    }

    // MARK: All work

    private var filteredSessions: [SchoolSession] {
        app.schoolSessions.filter {
            matches($0.title, app.schoolClassName($0.classId), $0.code,
                    AdminFormat.statusChip($0.status).text)
        }
    }

    private var workTab: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            tableCard {
                Table(filteredSessions, selection: $selectedSession) {
                    TableColumn("Assignment") { s in Text(s.title) }
                        .width(min: 180, ideal: 260)
                    TableColumn("Class") { s in
                        Text(app.schoolClassName(s.classId)).foregroundStyle(Theme.muted)
                    }
                    .width(min: 100, ideal: 150)
                    TableColumn("Date") { s in
                        Text(AdminFormat.dateTime(s.createdAt)).foregroundStyle(Theme.muted)
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Submitted") { s in
                        Text(s.submittedCount.map(String.init) ?? "").monospacedDigit()
                    }
                    .width(min: 64, ideal: 76, max: 90)
                    TableColumn("Status") { s in
                        let chip = AdminFormat.statusChip(s.status)
                        Chip(text: chip.text, kind: chip.kind)
                    }
                    .width(min: 70, ideal: 84, max: 100)
                    TableColumn("") { s in
                        Button("Review") { app.openAdminGrading(s) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .linkPointer()
                            .help("Read and grade this session's essays")
                    }
                    .width(60)
                }
                .contextMenu(forSelectionType: SchoolSession.ID.self) { _ in
                    EmptyView()
                } primaryAction: { ids in
                    if let id = ids.first, let s = app.schoolSessions.first(where: { $0.id == id }) {
                        app.openAdminGrading(s)
                    }
                }
            } empty: {
                emptyText(app.schoolSessions.isEmpty
                          ? (app.adminLoaded ? "No sessions yet." : "Loading sessions…")
                          : "No matches.", isEmpty: filteredSessions.isEmpty)
            }
            Text("Double-click a row to open it.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.muted2)
        }
    }

    // MARK: Helpers

    /// A table on a glass card, with a plain line over it when it has no rows.
    private func tableCard<T: View, E: View>(@ViewBuilder _ table: () -> T,
                                            @ViewBuilder empty: () -> E) -> some View {
        table()
            .scrollContentBackground(.hidden)
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .font(Theme.sans(13))
            .overlay(alignment: .top) { empty().padding(.top, 44) }
            .padding(Theme.Space.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .weftGlass(Theme.Radius.md)
    }

    @ViewBuilder private func emptyText(_ text: String, isEmpty: Bool) -> some View {
        if isEmpty {
            Text(text)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
        }
    }
}

#Preview {
    AdminHomeView(variant: .tables)
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

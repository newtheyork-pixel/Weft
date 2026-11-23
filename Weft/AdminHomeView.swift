//
//  AdminHomeView.swift
//  Weft: the school admin page (SAT-20): teachers and admins, every class
//  and roster, and every session's work. Three layouts of the same page are
//  built so one can be picked: A (sidebar), B (overview), C (tables). The live
//  one comes from `weft.adminVariant`; debug builds show a switch in the top
//  bar, and the dev gallery shows all three. The shared pieces live here.
//

import SwiftUI

/// The three admin page layouts.
enum AdminVariant: Int, CaseIterable, Identifiable {
    case sidebar = 1, overview = 2, tables = 3
    var id: Int { rawValue }

    var letter: String {
        switch self {
        case .sidebar: "A"
        case .overview: "B"
        case .tables: "C"
        }
    }

    var name: String {
        switch self {
        case .sidebar: "Sidebar"
        case .overview: "Overview"
        case .tables: "Tables"
        }
    }
}

/// The three areas of the admin page.
enum AdminSection: String, CaseIterable, Identifiable {
    case staff, students, work
    var id: String { rawValue }

    var title: String {
        switch self {
        case .staff: "Teachers and admins"
        case .students: "Students"
        case .work: "All work"
        }
    }

    var shortTitle: String {
        switch self {
        case .staff: "Staff"
        case .students: "Students"
        case .work: "All work"
        }
    }

    var symbol: String {
        switch self {
        case .staff: "person.2"
        case .students: "person.3"
        case .work: "doc.text"
        }
    }
}

/// Router for the admin role: the admin page, or grading a session opened
/// from it (the same grading screen teachers use).
struct AdminFlowView: View {
    /// nil = the saved choice (`weft.adminVariant`).
    var variant: AdminVariant?
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.adminScreen {
            case .home: AdminHomeView(variant: variant)
            case .grading: ReviewGradingView()
            }
        }
        .animation(.smooth(duration: 0.28), value: app.adminScreen)
    }
}

/// The admin page: top bar plus the chosen layout.
struct AdminHomeView: View {
    /// nil = the saved choice; set by the dev gallery to pin one layout.
    var variant: AdminVariant?
    @Environment(AppState.self) private var app
    @AppStorage("weft.adminVariant") private var storedVariant = AdminVariant.sidebar.rawValue

    private var current: AdminVariant {
        variant ?? AdminVariant(rawValue: storedVariant) ?? .sidebar
    }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Admin", trailing: variantSwitch)
            Group {
                switch current {
                case .sidebar: AdminSidebarLayout()
                case .overview: AdminOverviewLayout()
                case .tables: AdminTablesLayout()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AmbientBackground())
        .task { await app.loadAdminHome() }
    }

    /// Debug builds only: flip between the three layouts in place.
    private var variantSwitch: AnyView? {
        #if DEBUG
        guard variant == nil else { return nil }
        return AnyView(
            Picker("Layout", selection: $storedVariant) {
                ForEach(AdminVariant.allCases) { v in Text(v.letter).tag(v.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .help("Admin page layout (debug builds only)")
        )
        #else
        return nil
        #endif
    }
}

// MARK: - Shared formatting

enum AdminFormat {
    static func date(_ d: Date?) -> String {
        guard let d else { return "" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ d: Date?) -> String {
        guard let d else { return "" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func students(_ n: Int?) -> String {
        guard let n else { return "Students not counted" }
        return n == 1 ? "1 student" : "\(n) students"
    }

    static func submitted(_ n: Int?) -> String {
        guard let n else { return "" }
        return "\(n) submitted"
    }

    static func statusChip(_ status: String) -> (text: String, kind: Chip.Kind) {
        switch status {
        case "open": ("Open", .good)
        case "archived": ("Archived", .neutral)
        default: ("Closed", .neutral)
        }
    }
}

// MARK: - Shared pieces

extension AppState {
    /// The signed-in person's own staff row (never true in preview).
    func isSelf(_ m: StaffMember) -> Bool {
        signedIn && !email.isEmpty && m.email == email.lowercased()
    }
}

/// A staff change that needs a yes first.
enum PendingStaffAction: Identifiable {
    case remove(StaffMember)
    case demoteSelf(StaffMember)

    var id: String {
        switch self {
        case .remove(let m): "remove-\(m.email)"
        case .demoteSelf(let m): "demote-\(m.email)"
        }
    }
}

extension View {
    /// The confirmation for removing someone, or for an admin making
    /// themselves a teacher.
    func staffConfirmations(_ pending: Binding<PendingStaffAction?>, app: AppState) -> some View {
        let isPresented = Binding(get: { pending.wrappedValue != nil },
                                  set: { if !$0 { pending.wrappedValue = nil } })
        let action = pending.wrappedValue
        return confirmationDialog(confirmTitle(action, app: app),
                                  isPresented: isPresented,
                                  titleVisibility: .visible,
                                  presenting: action) { a in
            switch a {
            case .remove(let m):
                Button("Remove", role: .destructive) { Task { await app.removeStaff(m) } }
            case .demoteSelf(let m):
                Button("Make me a teacher", role: .destructive) {
                    Task { await app.setStaffRole(m, to: .teacher) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { a in
            switch a {
            case .remove(let m):
                Text(app.isSelf(m)
                     ? "You will lose access to this page."
                     : "They lose staff access. Their classes and student work stay.")
            case .demoteSelf:
                Text("You will lose access to this page.")
            }
        }
    }

    private func confirmTitle(_ a: PendingStaffAction?, app: AppState) -> String {
        switch a {
        case .remove(let m): "Remove \(m.email)?"
        case .demoteSelf: "Make yourself a teacher?"
        case nil: ""
        }
    }
}

/// Role menu for one staff row. Making yourself a teacher asks first.
struct StaffRoleMenu: View {
    let member: StaffMember
    @Binding var pending: PendingStaffAction?
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            Button("Teacher") { pick(.teacher) }
            Button("Admin") { pick(.admin) }
        } label: {
            // One Text so the chevron stays after the word (a Menu label
            // HStack puts its image first on macOS).
            (Text(member.role == .admin ? "Admin" : "Teacher")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.inkSoft)
             + Text("  ")
             + Text(Image(systemName: "chevron.down"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.muted))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .linkPointer()
        .help("Change role")
    }

    private func pick(_ role: UserRole) {
        guard role != member.role else { return }
        if role == .teacher, app.isSelf(member) {
            pending = .demoteSelf(member)
        } else {
            Task { await app.setStaffRole(member, to: role) }
        }
    }
}

/// Add a teacher or admin by email.
struct AddStaffForm: View {
    @Environment(AppState.self) private var app
    @State private var email = ""
    @State private var role: UserRole = .teacher
    @State private var busy = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            TextField("name@school.org", text: $email)
                .textFieldStyle(.plain)
                .font(Theme.sans(14))
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12)))
                .onSubmit(add)
            Picker("Role", selection: $role) {
                Text("Teacher").tag(UserRole.teacher)
                Text("Admin").tag(UserRole.admin)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Button("Add", action: add)
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty)
                .linkPointer()
        }
    }

    private func add() {
        guard !busy else { return }
        busy = true
        Task {
            if await app.addStaff(email: email, role: role) {
                email = ""
                role = .teacher
            }
            busy = false
        }
    }
}

/// One class's roster: current students with Remove, then removed students
/// with Add back.
struct AdminRosterList: View {
    let classId: String
    /// Tighter rows for the tables layout's side panel.
    var dense = false
    @Environment(AppState.self) private var app

    private var rows: [ClassEnrollment]? { app.adminRosters[classId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rows {
                let active = rows.filter(\.isActive)
                let removed = rows.filter { !$0.isActive }
                if active.isEmpty {
                    note("No students in this class yet.")
                }
                ForEach(Array(active.enumerated()), id: \.element.id) { idx, s in
                    if idx > 0 { divider }
                    row(s, removed: false)
                }
                if !removed.isEmpty {
                    Kicker(text: "Removed")
                        .padding(.horizontal, hPad)
                        .padding(.top, dense ? Theme.Space.md : Theme.Space.lg)
                        .padding(.bottom, Theme.Space.xs)
                    ForEach(Array(removed.enumerated()), id: \.element.id) { idx, s in
                        if idx > 0 { divider }
                        row(s, removed: true)
                    }
                }
            } else {
                note("Loading students…")
            }
        }
        .task(id: classId) { await app.loadAdminRoster(classId: classId) }
    }

    private var hPad: CGFloat { dense ? Theme.Space.md : 22 }

    private var divider: some View {
        Divider().opacity(0.4).padding(.horizontal, hPad)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(13))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, hPad)
            .padding(.vertical, 12)
    }

    private func row(_ s: ClassEnrollment, removed: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            if !dense { InitialsBadge(name: s.displayName, faded: removed) }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayName)
                    .font(Theme.sans(dense ? 13.5 : 15))
                    .foregroundStyle(removed ? Theme.muted : Theme.inkSoft)
                if removed, let when = s.removedAt {
                    Text("Removed \(AdminFormat.date(when))")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted2)
                }
            }
            Spacer()
            Button(removed ? "Add back" : "Remove") {
                Task { await app.setStudentRemoved(classId: classId, student: s, removed: !removed) }
            }
            .buttonStyle(.plain)
            .font(Theme.sans(12.5, .semibold))
            .foregroundStyle(removed ? Theme.accent : Theme.muted)
            .linkPointer()
            .help(removed ? "Put this student back in the class" : "Take this student out of the class")
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, dense ? 7 : 11)
        .rowHover()
    }
}

/// Round initials for a person row (the roster screen's treatment).
struct InitialsBadge: View {
    let name: String
    var faded = false

    var body: some View {
        Circle().fill(Theme.accent.opacity(faded ? 0.06 : 0.12))
            .frame(width: 30, height: 30)
            .overlay(Text(initials)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(faded ? Theme.muted2 : Theme.accent))
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[parts.count - 1].prefix(1)).uppercased() }
        return String(name.prefix(2)).uppercased()
    }
}

/// The admin page's error line. Dismissable; Reload refetches the page.
struct AdminErrorBanner: View {
    let message: String
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Reload") { Task { await app.loadAdminHome() } }
                .buttonStyle(.plain)
                .font(Theme.sans(12.5, .semibold))
                .foregroundStyle(Theme.accent)
                .linkPointer()
            Button {
                app.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .linkPointer()
            .help("Dismiss")
        }
        .padding(Theme.Space.md)
        .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }
}

/// Small leading symbol + Kicker, the teacher home's section header.
struct AdminSectionHeader: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Kicker(text: title)
        }
    }
}

/// Page heading: serif title plus one plain line.
struct AdminPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text(subtitle)
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Side-by-side comparison (dev gallery)

/// All three layouts at once, scaled down, for picking one. They fit
/// across a wide window; a narrow one scrolls sideways.
struct AdminCompareView: View {
    private let size = CGSize(width: 1000, height: 720)

    var body: some View {
        GeometryReader { geo in
            grid(scale: min(0.62, max(0.45, (geo.size.width - 4 * Theme.Space.xl) / (3 * size.width))))
        }
        .background(AmbientBackground())
    }

    private func grid(scale: CGFloat) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                ForEach(AdminVariant.allCases) { v in
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text("\(v.letter) · \(v.name)")
                            .font(Theme.sans(13, .semibold))
                            .foregroundStyle(Theme.inkSoft)
                        AdminHomeView(variant: v)
                            .frame(width: size.width, height: size.height)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: size.width * scale, height: size.height * scale,
                                   alignment: .topLeading)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(Color.black.opacity(0.12)))
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
    }
}

#Preview("Admin page") {
    AdminFlowView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 1100, height: 760)
}

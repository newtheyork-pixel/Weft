//
//  StudentClassHomeView.swift
//  Weft — the student's class home: classes list (with open-count badges) or
//  class detail (Active / Graded / Past sections). Two-level navigation, no
//  chip picker. Native, on real Liquid Glass.
//

import SwiftUI

struct StudentClassHomeView: View {
    @Environment(AppState.self) private var app

    private var active: [ClassWorkItem] { app.classWork.filter { $0.section == .active } }
    private var graded: [ClassWorkItem] { app.classWork.filter { $0.section == .graded } }
    private var past: [ClassWorkItem] { app.classWork.filter { $0.section == .past } }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if app.selectedClassId == nil { intro }
                    if let error = app.errorMessage { errorBanner(error) }
                    if app.selectedClassId == nil {
                        if app.enrolledClasses.isEmpty {
                            emptyState
                        } else {
                            classesLevel
                        }
                    } else {
                        detailHeader
                        if !active.isEmpty { sectionCard("Active", active) }
                        if !graded.isEmpty { sectionCard("Graded", graded) }
                        if !past.isEmpty { sectionCard("Past", past) }
                        if active.isEmpty && graded.isEmpty && past.isEmpty { detailEmpty }
                    }
                    joinAnother
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: app.classWork.count)
                .animation(.easeOut(duration: 0.2), value: app.selectedClassId)
                .animation(.easeOut(duration: 0.2), value: app.enrolledClasses.count)
            }
        }
        .background(AmbientBackground())
        .task { await app.loadStudentHome() }
    }

    // MARK: Classes level

    private var classesLevel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Kicker(text: "Your classes")
            ForEach(app.enrolledClasses) { c in
                Button { app.selectClass(c.id) } label: {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                                .font(Theme.sans(15, .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(openBadge(for: c.id))
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
                .pointerStyle(.link)
            }
        }
    }

    private func openBadge(for classId: String) -> String {
        let n = app.classOpenCounts[classId] ?? 0
        if n == 0 { return "Nothing due right now" }
        return n == 1 ? "1 open assignment" : "\(n) open assignments"
    }

    // MARK: Class detail header

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button { app.leaveClass() } label: {
                Label("Your classes", systemImage: "chevron.left")
                    .font(Theme.sans(13, .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .pointerStyle(.link)
            Text(app.enrolledClasses.first(where: { $0.id == app.selectedClassId })?.name ?? "Class")
                .font(Theme.serif(24, .semibold))
                .foregroundStyle(Theme.inkSoft)
        }
    }

    // MARK: Empty states

    private var emptyState: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted2)
            Text("No assignments yet. Join a class with a class code and your work will appear here.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.md)
    }

    private var detailEmpty: some View {
        Text("No assignments in this class yet.")
            .font(Theme.sans(13))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, Theme.Space.md)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { Task { await app.loadStudentHome() } }
                .buttonStyle(.plain)
                .font(Theme.sans(12.5, .semibold))
                .foregroundStyle(Theme.accent)
                .linkPointer()
        }
        .padding(Theme.Space.md)
        .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    // MARK: Intro (classes level only)
    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your assignments")
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text("Pick up where you left off, or join another class with a class code.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
        }
        .padding(.bottom, Theme.Space.sm)
    }

    // MARK: Section card
    private func sectionCard(_ title: String, _ items: [ClassWorkItem]) -> some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: sectionIcon(title))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Kicker(text: title)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 10)
                Divider().opacity(0.4).padding(.horizontal, 22)
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider().opacity(0.4).padding(.horizontal, 22) }
                    row(item)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 15)
                }
            }
        }
    }

    private func sectionIcon(_ title: String) -> String {
        switch title {
        case "Active": return "pencil.line"
        case "Graded": return "checkmark.seal"
        default:       return "archivebox"
        }
    }

    @ViewBuilder
    private func row(_ item: ClassWorkItem) -> some View {
        HStack(spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                    if let draft = item.draftLabel {
                        Text(draft)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(metaText(item))
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            switch item.section {
            case .active:
                Button("Start writing") { app.startWriting(item) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
            case .graded:
                HStack(spacing: 14) {
                    Text("\(fmt(item.myPoints)) / \(fmt(item.myPointsPossible))")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.inkSoft)
                    Button {
                        app.openReturnedWork()
                    } label: {
                        HStack(spacing: 5) {
                            Text("View returned work")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .linkPointer()
                    .help("Open your graded work")
                }
            case .past:
                Chip(text: "Read-only", kind: .neutral)
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: Join another
    private var joinAnother: some View {
        Button {
            app.goToJoin()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text("Join another class")
                    .font(Theme.sans(13, .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help("Join a class with a class code")
        .padding(.top, Theme.Space.sm)
    }

    // MARK: Helpers
    private func metaText(_ item: ClassWorkItem) -> String {
        switch item.section {
        case .active: return "Open now"
        case .graded: return "Returned \(shortDate(item.myReleasedAt))"
        case .past:   return "Submitted \(shortDate(item.mySubmittedAt))"
        case nil:     return ""
        }
    }
    private func fmt(_ d: Double?) -> String {
        guard let d else { return "0" }
        return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
    private func shortDate(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

#Preview {
    StudentClassHomeView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 560, height: 760)
}

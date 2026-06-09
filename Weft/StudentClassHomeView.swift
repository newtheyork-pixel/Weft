//
//  StudentClassHomeView.swift
//  Weft — the student's class home: pick a class, see Active / Graded / Past
//  assignments, one row each, no codes. Native, on real Liquid Glass.
//

import SwiftUI

struct StudentClassHomeView: View {
    @Environment(AppState.self) private var app
    @State private var selectedClass: ClassRoom?

    private var active: [ClassWorkItem] { app.classWork.filter { $0.section == .active } }
    private var graded: [ClassWorkItem] { app.classWork.filter { $0.section == .graded } }
    private var past: [ClassWorkItem] { app.classWork.filter { $0.section == .past } }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    intro
                    classPicker
                    if !active.isEmpty { sectionCard("Active", active) }
                    if !graded.isEmpty { sectionCard("Graded", graded) }
                    if !past.isEmpty { sectionCard("Past", past) }
                    joinAnother
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .background(AmbientBackground())
        .onAppear { if selectedClass == nil { selectedClass = app.enrolledClasses.first } }
    }

    // MARK: Intro
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

    // MARK: Class picker
    private var classPicker: some View {
        Menu {
            ForEach(app.enrolledClasses) { c in
                Button(c.name) { selectedClass = c }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Kicker(text: "Class")
                    Text(selectedClass?.name ?? "Select a class")
                        .font(Theme.sans(17, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .weftGlass(Theme.Radius.md)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: Section card
    private func sectionCard(_ title: String, _ items: [ClassWorkItem]) -> some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Kicker(text: title)
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

    @ViewBuilder
    private func row(_ item: ClassWorkItem) -> some View {
        HStack(spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Text(metaText(item))
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            switch item.section {
            case .active:
                Button("Start writing") {}
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
            case .graded:
                HStack(spacing: 14) {
                    Text("\(fmt(item.myPoints)) / \(fmt(item.myPointsPossible))")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.inkSoft)
                    Button("View returned work") {}
                        .buttonStyle(.plain)
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.accent)
                }
            case .past:
                Chip(text: "Read-only", kind: .neutral)
            }
        }
    }

    // MARK: Join another
    private var joinAnother: some View {
        Button {
        } label: {
            Text("Join another class")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.Space.sm)
    }

    // MARK: Helpers
    private func metaText(_ item: ClassWorkItem) -> String {
        switch item.section {
        case .active: return "Open now"
        case .graded: return "Returned \(shortDate(item.myReleasedAt))"
        case .past:   return "Submitted \(shortDate(item.mySubmittedAt))"
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

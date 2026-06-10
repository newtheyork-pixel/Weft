//
//  TeacherRosterView.swift
//  Weft — a class's roster (enrolled students from class_enrollments), reached
//  from the teacher home's per-class "Roster" button.
//

import SwiftUI

struct TeacherRosterView: View {
    @Environment(AppState.self) private var app

    @State private var inviteText: String = ""

    private var active: [ClassEnrollment] { app.classRoster.filter(\.isActive) }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Teacher", trailing: AnyView(backButton))
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    header
                    if active.isEmpty { emptyState } else { rosterCard }
                    inviteCard
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .background(AmbientBackground())
        .task { await app.loadRoster() }
    }

    private var backButton: some View {
        Button { app.teacherGoHome() } label: {
            Label("Back", systemImage: "chevron.left").font(Theme.sans(13, .semibold))
        }
        .buttonStyle(.glass).tint(Theme.accent).linkPointer()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.rosterClassName.isEmpty ? "Class roster" : app.rosterClassName)
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text("\(active.count) student\(active.count == 1 ? "" : "s") enrolled.")
                .font(Theme.sans(14)).foregroundStyle(Theme.muted)
        }
    }

    private var rosterCard: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "person.3").foregroundStyle(Theme.muted)
                    Kicker(text: "Students")
                }
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)
                Divider().opacity(0.4).padding(.horizontal, 22)
                ForEach(Array(active.enumerated()), id: \.element.id) { idx, s in
                    if idx > 0 { Divider().opacity(0.4).padding(.horizontal, 22) }
                    HStack(spacing: Theme.Space.md) {
                        Circle().fill(Theme.accent.opacity(0.12))
                            .frame(width: 30, height: 30)
                            .overlay(Text(initials(s.displayName))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent))
                        Text(s.displayName).font(Theme.sans(15)).foregroundStyle(Theme.inkSoft)
                        Spacer()
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .rowHover()
                }
            }
        }
    }

    private var inviteCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Image(systemName: "envelope.badge").foregroundStyle(Theme.muted)
                    Kicker(text: "Invite students")
                }
                Text("Email an invitation that includes this class's join code. Separate addresses with commas, spaces, or new lines.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $inviteText)
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(minHeight: 74)
                    .padding(8)
                    .weftGlass(Theme.Radius.md)
                    .scrollContentBackground(.hidden)
                HStack(alignment: .firstTextBaseline) {
                    Button {
                        let emails = inviteText
                            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
                            .map(String.init)
                        Task { await app.inviteStudents(emails: emails); inviteText = "" }
                    } label: {
                        Label("Send invitations", systemImage: "paperplane.fill")
                            .font(Theme.sans(14, .semibold))
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).linkPointer()
                    .disabled(inviteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if let status = app.inviteStatus {
                        Text(status)
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(Theme.muted2)
            Text("No students have joined this class yet. Share the class code so they can join.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.md)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[parts.count - 1].prefix(1)).uppercased() }
        return String(name.prefix(2)).uppercased()
    }
}

#Preview {
    TeacherRosterView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 620, height: 600)
}

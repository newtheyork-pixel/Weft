//
//  TeacherHomeView.swift
//  Weft — teacher home: Build (set up + launch) / Live (monitor + grade).
//  Native shell with mock data; the full flows port in over the next stages.
//

import SwiftUI

struct TeacherHomeView: View {
    @Environment(AppState.self) private var app
    enum Tab: Hashable { case build, live }
    @State private var tab: Tab = .build
    @State private var pickedAssignment = "Lit essay 1"
    @State private var pickedClass = "AP English"

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Teacher")
            Picker("", selection: $tab) {
                Text("Build").tag(Tab.build)
                Text("Live").tag(Tab.live)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.vertical, Theme.Space.md)

            ScrollView {
                Group {
                    if tab == .build { buildView } else { liveView }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.2), value: tab)
            }
        }
        .background(AmbientBackground())
    }

    // MARK: Build
    private var buildView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Kicker(text: "Session")
                    Text("Ready to launch \(pickedAssignment) for \(pickedClass).")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.muted)
                    labeledPicker("Assignment", pickedAssignment, app.assignments.map(\.title)) { pickedAssignment = $0 }
                    labeledPicker("Class", pickedClass, app.teacherClasses.map(\.name)) { pickedClass = $0 }
                    Button {
                        tab = .live
                    } label: {
                        Label("Start live assignment", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .padding(.top, Theme.Space.xs)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack {
                        sectionHeader("doc.text", "Assignments")
                        Spacer()
                        Button("+ New") {}
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .font(Theme.sans(13, .semibold))
                            .linkPointer()
                            .help("Create a new assignment")
                    }
                    ForEach(app.assignments) { a in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.inkSoft)
                                Text("Essay" + (a.timeLimitMinutes.map { " · \($0) min" } ?? "")).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Edit") {}.buttonStyle(.glass)
                        }
                        .padding(.vertical, Theme.Space.sm)
                        .padding(.horizontal, Theme.Space.sm)
                        .rowHover()
                    }
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack {
                        sectionHeader("person.2", "Classes")
                        Spacer()
                        Button("+ New") {}
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .font(Theme.sans(13, .semibold))
                            .linkPointer()
                            .help("Create a new class")
                    }
                    ForEach(app.teacherClasses) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.inkSoft)
                                Text("Class code \(c.joinCode)").font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Roster") {}.buttonStyle(.glass)
                        }
                        .padding(.vertical, Theme.Space.sm)
                        .padding(.horizontal, Theme.Space.sm)
                        .rowHover()
                    }
                }
            }
        }
    }

    // MARK: Live
    private var liveView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("\(pickedAssignment) is live for \(pickedClass) · \(app.roster.count) students")
                        .font(Theme.sans(17, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                    HStack(spacing: Theme.Space.md) {
                        Chip(text: "Open", kind: .good)
                        HStack(spacing: 6) {
                            Kicker(text: "Class code")
                            Text("ABC234").font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                        }
                        Spacer()
                        Button("End session") {}.buttonStyle(.glass).help("Close this session for all students")
                    }
                }
            }

            GlassCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        sectionHeader("person.3", "Roster  \(app.roster.count)")
                        Spacer()
                        Button("Review essays") {}.buttonStyle(.glass)
                    }
                    .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.lg).padding(.bottom, Theme.Space.sm)
                    Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl)
                    ForEach(Array(app.roster.enumerated()), id: \.element.id) { idx, s in
                        if idx > 0 { Divider().opacity(0.4).padding(.horizontal, Theme.Space.xl) }
                        HStack(spacing: Theme.Space.md) {
                            Text(s.name).font(Theme.sans(14)).foregroundStyle(Theme.inkSoft)
                            Spacer()
                            Text(s.networkSame ? "Same Wi-Fi" : "Different network").font(Theme.sans(12.5)).foregroundStyle(s.networkSame ? Theme.muted : Theme.warn)
                            Chip(text: s.status.capitalized, kind: s.signal == .ok ? .good : .warn)
                        }
                        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 13)
                    }
                }
            }
        }
    }

    // MARK: Helpers

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

    private func labeledPicker(_ label: String, _ value: String, _ options: [String], _ onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: label)
            Menu {
                ForEach(options, id: \.self) { o in Button(o) { onPick(o) } }
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

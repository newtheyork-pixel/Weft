//
//  StudentChecksView.swift
//  Weft — the pre-exam "Get ready to write" checks screen, with the Phase 2
//  privacy nutrition label. Native port of #stage-checks + the trust card from
//  the Electron student renderer. Transparency only: it explains, honestly and
//  in two columns, what Weft watches during an exam and what it never touches.
//  No opt-out, no controls beyond entering the exam.
//

import SwiftUI

struct StudentChecksView: View {
    @Environment(AppState.self) private var app

    @State private var report: ProctoringReport?
    @State private var running = true

    /// "What it checks" — grounded in runChecks()/monitorTick() and the in-exam
    /// loops. Honest, plain-language copy ported from renderTrustLabel().
    private let checks: [String] = [
        "Confirms you are on the same network as your teacher (not on a VPN or phone hotspot).",
        "Checks that no remote-control software (such as TeamViewer or Chrome Remote Desktop) is running.",
        "Checks that no screen-sharing or screen-recording software is running.",
        "Counts your displays and looks for a hidden second or virtual screen.",
        "Confirms this is a real computer, not a virtual machine.",
        "Takes a still picture of your screen about once a minute so your teacher can see your work (only if you allow screen recording).",
        "Keeps watching for those same things while you write, and rechecks every few seconds.",
    ]

    /// "What it never does" — the equally honest counter-list.
    private let neverDoes: [String] = [
        "It does not listen to or record any audio or your microphone.",
        "It does not record continuous video of you or your screen.",
        "It does not log your keystrokes or read what you type elsewhere.",
        "It does not read your files, messages, or browsing history outside this exam.",
        "It does not track your location, and it does no face matching or eye tracking.",
        "It stops completely the moment you submit or exit.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    header
                    statusCard
                    nutritionLabel
                    enterButton
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .background(AmbientBackground())
        .task {
            running = true
            report = await ProctoringEngine().runChecks(teacherIP: nil)
            running = false
        }
    }

    // MARK: Live check status
    private var statusCard: some View {
        GlassCard {
            HStack(spacing: Theme.Space.md) {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Running checks…")
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                } else if let report {
                    Image(systemName: warnings(report).isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(warnings(report).isEmpty ? Theme.good : Theme.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warnings(report).isEmpty ? "All clear" : "Heads up before you start")
                            .font(Theme.sans(14, .semibold))
                            .foregroundStyle(Theme.inkSoft)
                        Text(warnings(report).isEmpty
                             ? "No monitoring software detected. You can enter the exam."
                             : warnings(report).joined(separator: " · "))
                            .font(Theme.sans(12.5))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Human-readable warnings derived from the report (advisory only; the
    /// student can still enter — the exam itself blacks out on a live violation).
    private func warnings(_ r: ProctoringReport) -> [String] {
        var w: [String] = []
        if r.screenCapture { w.append("Screen-share/recording app running" + (r.detectedApps.isEmpty ? "" : " (\(r.detectedApps.joined(separator: ", ")))")) }
        if r.remote { w.append("Remote-control software detected") }
        if r.displays > 1 { w.append("\(r.displays) displays connected") }
        if r.isVM { w.append("Running in a virtual machine") }
        return w
    }

    // MARK: Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Get ready to write")
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.inkSoft)
            Text("We make sure you're in the room and no monitoring software is running. About 30 seconds.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
        }
        .padding(.bottom, Theme.Space.xs)
    }

    // MARK: Privacy nutrition label
    private var nutritionLabel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                // Head
                HStack(spacing: 9) {
                    glyph
                    Text("What Weft checks during this exam")
                        .font(Theme.sans(16, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
                Text("So your teacher can trust the work is yours, done here, on your own. Nothing here is secret.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                // Two honest columns
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    column(label: "What it checks", items: checks, mark: .check)
                    column(label: "What it never does", items: neverDoes, mark: .minus)
                }
                .padding(.top, Theme.Space.xs)

                // Retention footer
                Divider().opacity(0.4)
                    .padding(.top, Theme.Space.xs)
                Text("Everything stays inside your school's Weft account, visible to your teacher. It is kept while the assignment is open and graded, then cleared on your school's schedule.")
                    .font(Theme.sans(11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: A single honest column
    private enum Mark { case check, minus }

    private func column(label: String, items: [String], mark: Mark) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 2)
            ForEach(items, id: \.self) { item in
                trustRow(item, mark: mark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func trustRow(_ text: String, mark: Mark) -> some View {
        HStack(alignment: .top, spacing: 9) {
            switch mark {
            case .check:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.good)
                    .frame(width: 14, height: 14, alignment: .center)
                    .padding(.top, 1)
            case .minus:
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted2)
                    .frame(width: 14, height: 14, alignment: .center)
                    .padding(.top, 1)
            }
            Text(text)
                .font(Theme.sans(12.5))
                .foregroundStyle(mark == .check ? Theme.inkSoft : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Inset glyph (calm ringed dot, matching the CSS .trust-glyph)
    private var glyph: some View {
        Circle()
            .fill(Theme.accent.opacity(0.12))
            .frame(width: 18, height: 18)
            .overlay(
                Circle()
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .padding(5)
            )
    }

    // MARK: Enter exam
    private var enterButton: some View {
        Button {
            app.enterExam()
        } label: {
            Text(running ? "Finishing checks…" : "Enter exam")
                .font(Theme.sans(15, .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .disabled(running)
        .padding(.top, Theme.Space.xs)
    }
}

#Preview {
    StudentChecksView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 620, height: 760)
}

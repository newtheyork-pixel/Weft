//
//  StudentDoneView.swift
//  Weft — the post-exam DONE screen. A calm green check, "Submitted.", and the
//  Phase-2 DATA LEDGER: an honest, plain-language summary of what was captured
//  during the exam and how long it is kept. Ported from the Electron
//  #stage-done section + the trust ledger (renderDataLedger), rebuilt natively
//  on real Liquid Glass.
//

import SwiftUI

struct StudentDoneView: View {
    @Environment(AppState.self) private var app

    /// Whether screen pictures were captured this session (governs the
    /// "Screen pictures" row). In Electron this row is always pushed; webcam
    /// stills are conditional on requireWebcam().
    var screenCaptureOn: Bool = true
    /// Whether the camera was on this session (governs the "Camera stills" row).
    var webcamOn: Bool = false

    /// One captured-data row: a plain label and a plain detail line.
    private struct LedgerRow: Identifiable {
        let id = UUID()
        let what: String
        let detail: String
    }

    private var rows: [LedgerRow] {
        var r: [LedgerRow] = [
            LedgerRow(what: "Your essay",
                      detail: "Your submitted writing and its autosaved drafts."),
            LedgerRow(what: "Integrity checks",
                      detail: "Pass or fail results of the network, remote-control, screen-share, display, and VM checks."),
            LedgerRow(what: "Pauses and flags",
                      detail: "A note if you left fullscreen or if monitoring software appeared."),
        ]
        if screenCaptureOn {
            r.append(LedgerRow(what: "Screen pictures",
                               detail: "Periodic still images of your screen (only if you allowed screen recording)."))
        }
        if webcamOn {
            r.append(LedgerRow(what: "Camera stills",
                               detail: "Occasional still photos from your camera."))
        }
        r.append(LedgerRow(what: "Grade and comments",
                           detail: "Your teacher's score and feedback, once they return it."))
        return r
    }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student")
            ScrollView {
                VStack(spacing: Theme.Space.xl) {
                    hero
                    ledger
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.xxl)
            }
        }
        .background(AmbientBackground())
    }

    // MARK: Hero — green check + confirmation
    private var hero: some View {
        VStack(spacing: Theme.Space.lg) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.good.opacity(0.18), Theme.good.opacity(0.06)],
                            center: UnitPoint(x: 0.5, y: 0.35),
                            startRadius: 2, endRadius: 44
                        )
                    )
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.good)
            }
            .shadow(color: Theme.good.opacity(0.20), radius: 9, x: 0, y: 6)

            VStack(spacing: 6) {
                Text("Submitted.")
                    .font(Theme.serif(26, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Text("Your work is in. You can close this window.")
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.muted)
            }

            Button("Back to my assignments") { app.goToHome() }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .padding(.top, Theme.Space.xs)
                .linkPointer()
        }
    }

    // MARK: Data ledger — what we captured, and for how long
    private var ledger: some View {
        GlassCard(corner: Theme.Radius.lg, padding: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                head
                rowsList
                retention
            }
        }
    }

    private var head: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("What we captured, and how long it is kept")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var rowsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                if idx > 0 {
                    Divider().opacity(0.4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.what)
                        .font(Theme.sans(13, .medium))
                        .foregroundStyle(Theme.inkSoft)
                    Text(row.detail)
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
            }
        }
        .animation(.easeOut(duration: 0.18), value: rows.count)
    }

    private var retention: some View {
        Text("All of this lives in your school's Weft account for your teacher only. It is kept while the assignment is graded, then cleared on your school's schedule. Monitoring stopped the moment you submitted.")
            .font(Theme.sans(12.5))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Space.xs)
    }
}

#Preview {
    StudentDoneView(screenCaptureOn: true, webcamOn: true)
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 520, height: 720)
}

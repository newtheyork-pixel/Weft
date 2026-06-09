//
//  ProctoringModals.swift
//  Weft — the mid-exam "writing paused" blackout (screen-sharing detected) and
//  the elevated crash-recovery prompt. Ported from student.html #monitor-blackout
//  and #recovery-modal.
//

import SwiftUI

/// Covers the screen if screen-sharing/recording software appears mid-exam.
/// Calm, not punitive: close the app and writing resumes automatically.
struct StudentBlockedView: View {
    var detectedApp: String = "zoom.us"

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.97).ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Writing paused")
                    .font(Theme.serif(26, .semibold))
                    .foregroundStyle(.white)
                Text("Screen-sharing software was detected on this machine:")
                    .font(Theme.sans(14))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Text(detectedApp)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                Text("Close it and your writing will resume automatically. Your teacher has been notified.")
                    .font(Theme.sans(14))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Can't close it? Submit and exit") {}
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .padding(.top, Theme.Space.sm)
            }
            .padding(Theme.Space.xxxl)
        }
    }
}

/// Shown pre-kiosk if unsaved work from a previous attempt is found.
struct RecoveryPromptView: View {
    var words: Int = 612
    var lastEdited: String = "11 minutes ago"

    var body: some View {
        ZStack {
            AmbientBackground()
            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("We saved your work")
                            .font(Theme.serif(22, .semibold))
                            .foregroundStyle(Theme.inkSoft)
                        Text("Pick up where you left off. \(words) words, last edited \(lastEdited).")
                            .font(Theme.sans(14))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The interplay of light and shadow in the passage works as more than scenery. The author returns to dawn three times...")
                        .font(Theme.serif(14))
                        .foregroundStyle(Theme.inkSoft.opacity(0.8))
                        .lineLimit(3)
                        .padding(Theme.Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack(spacing: Theme.Space.md) {
                        Button("Restore my work") {}
                            .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                        Button("Start fresh from the saved version") {}
                            .buttonStyle(.glass).controlSize(.large)
                    }
                }
            }
            .frame(maxWidth: 460)
            .padding(Theme.Space.xxl)
        }
    }
}

#Preview("Blocked") {
    StudentBlockedView().frame(width: 760, height: 620)
}

#Preview("Recovery") {
    RecoveryPromptView().preferredColorScheme(.light).frame(width: 620, height: 560)
}

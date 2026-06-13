//
//  ProctoringModals.swift
//  Weft — the mid-exam "writing paused" blackout (screen-sharing detected) and
//  the elevated crash-recovery prompt. Ported from student.html #monitor-blackout
//  and #recovery-modal.
//

import SwiftUI

/// Full-screen blackout overlay used mid-exam — either because screen-sharing /
/// recording software appeared, or because the student left the exam window.
/// Calm, not punitive. Defaults reproduce the original screen-sharing copy so the
/// dev gallery preview is unchanged.
struct StudentBlockedView: View {
    var title: String = "Writing paused"
    var message: String = "Screen-sharing software was detected on this machine:"
    /// The monospaced highlight line (an app name); nil hides it.
    var detail: String? = "zoom.us"
    var footnote: String = "Close it and your writing will resume automatically. Your teacher has been notified."
    var submitTitle: String? = "Can't close it? Submit and exit"
    /// Fully hide the exam content behind the wash. The screen-sharing flavor
    /// MUST be opaque: its entire purpose is to keep the live question out of a
    /// detected screen capture, and a translucent fill leaks the prompt + essay
    /// into every captured frame. The focus-loss flavor can stay translucent.
    var opaque: Bool = false
    var onSubmit: () -> Void = {}

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.13).opacity(opaque ? 1.0 : 0.97).ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                Text(title)
                    .font(Theme.serif(26, .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(Theme.sans(14))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                if let detail {
                    Text(detail)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                }
                Text(footnote)
                    .font(Theme.sans(14))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                if let submitTitle {
                    Button(submitTitle, action: onSubmit)
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .padding(.top, Theme.Space.sm)
                }
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

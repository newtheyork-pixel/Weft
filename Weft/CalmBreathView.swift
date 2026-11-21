//
//  CalmBreathView.swift
//  Weft — a short guided breath for nervous moments: before an exam starts
//  and during one. In for 4, out for 6 (a longer breath out slows the heart).
//  Nothing here is logged or sent to the teacher.
//

import SwiftUI
import AppKit

struct CalmBreathView: View {
    /// Shown under the circle, e.g. "Your time keeps running. Your work is saved."
    var note: String?
    /// Label for the button that closes the view.
    var doneTitle: String = "Back to writing"
    var breaths: Int = 3
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false
    /// Bumped by "One more round" to restart the timer task.
    @State private var round = 0
    /// Listens for Escape while the guide is on screen.
    @State private var escMonitor: Any?

    static let inhale: Double = 4
    static let exhale: Double = 6
    private static let small: Double = 0.55
    private static let large: Double = 1.0

    private var total: Double { Double(breaths) * (Self.inhale + Self.exhale) }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: finished)) { context in
                    let phase = Self.phase(at: context.date.timeIntervalSince(start),
                                           breaths: breaths, finished: finished)
                    VStack(spacing: Theme.Space.lg) {
                        ZStack {
                            Circle()
                                .strokeBorder(Theme.accent.opacity(0.25),
                                              style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
                            Circle()
                                .fill(RadialGradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.75)],
                                                     center: .center, startRadius: 10, endRadius: 140))
                                .scaleEffect(reduceMotion ? 0.8 : phase.scale)
                            Text(phase.count.map(String.init) ?? "")
                                .font(.system(size: 34, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                        }
                        .frame(width: 240, height: 240)
                        .accessibilityHidden(true)

                        Text(phase.word)
                            .font(Theme.serif(26, .semibold))
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.updatesFrequently)

                        Text(phase.progress)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.muted)
                            .monospacedDigit()
                    }
                }

                if let note {
                    Text(note)
                        .font(Theme.sans(13.5))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                }

                HStack(spacing: Theme.Space.md) {
                    if finished {
                        Button("One more round") {
                            start = Date()
                            finished = false
                            round += 1
                        }
                        .buttonStyle(.glass)
                    }
                    Button(doneTitle, action: onDone)
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                }
            }
            .padding(Theme.Space.xl)
        }
        .onAppear {
            guard escMonitor == nil else { return }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }   // 53 = Escape
                onDone()
                return nil
            }
        }
        .onDisappear {
            if let escMonitor { NSEvent.removeMonitor(escMonitor) }
            escMonitor = nil
        }
        .task(id: round) {
            try? await Task.sleep(for: .seconds(total))
            if !Task.isCancelled { finished = true }
        }
    }

    struct Phase: Equatable {
        var word: String
        var count: Int?
        var scale: Double
        var progress: String
    }

    /// Where the guide is `elapsed` seconds in. Pure, so it can be tested.
    static func phase(at elapsed: Double, breaths: Int, finished: Bool) -> Phase {
        let cycle = inhale + exhale
        let total = Double(max(breaths, 1)) * cycle
        if finished || elapsed >= total {
            return Phase(word: "Well done", count: nil, scale: small,
                         progress: "\(breaths) slow breath\(breaths == 1 ? "" : "s")")
        }
        let t = max(0, elapsed)
        let n = min(Int(t / cycle), breaths - 1)
        let inCycle = t - Double(n) * cycle
        let inhaling = inCycle < inhale
        let length = inhaling ? inhale : exhale
        let into = inhaling ? inCycle : inCycle - inhale
        let frac = min(max(into / length, 0), 1)
        let eased = frac < 0.5 ? 2 * frac * frac : 1 - pow(-2 * frac + 2, 2) / 2
        let scale = inhaling ? small + (large - small) * eased : large - (large - small) * eased
        let left = max(1, Int((length - into).rounded(.up)))
        return Phase(word: inhaling ? "Breathe in" : "Breathe out",
                     count: left, scale: scale,
                     progress: "Breath \(n + 1) of \(breaths)")
    }
}

#Preview {
    CalmBreathView(note: "Your time keeps running. Your work is saved.") { }
        .frame(width: 700, height: 600)
}

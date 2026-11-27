//
//  CalmBreathView.swift
//  Weft — a short guided breath for nervous moments: before an exam starts
//  and during one. In for 4, out for 6 (a longer breath out slows the heart).
//  Nothing here is logged or sent to the teacher.
//
//  The guide is a bloom of soft, overlapping petals on a dark backdrop. It
//  opens and turns as you breathe in and folds back into one glowing circle
//  as you breathe out. A thin ring around it fills over the whole session.
//

import SwiftUI
import AppKit

struct CalmBreathView: View {
    /// Shown under the guide, e.g. "Your time keeps running. Your work is saved."
    var note: String?
    /// Label for the button that closes the view.
    var doneTitle: String = "Back to writing"
    var breaths: Int = 3
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false
    /// How long "Well done" stays up before the guide closes by itself.
    static let doneHold: Double = 1.5
    /// Listens for Escape while the guide is on screen.
    @State private var escMonitor: Any?

    static let inhale: Double = 4
    static let exhale: Double = 6
    private static let small: Double = 0.55
    private static let large: Double = 1.0

    /// Width of the bloom at its fullest.
    private static let bloomSize: CGFloat = 300
    /// Gap between the open bloom and the session ring.
    private static let ringGap: CGFloat = 22

    private var total: Double { Double(breaths) * (Self.inhale + Self.exhale) }

    var body: some View {
        ZStack {
            BreathBackdrop()

            VStack(spacing: Theme.Space.xl) {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: finished)) { context in
                    let phase = Self.phase(at: context.date.timeIntervalSince(start),
                                           breaths: breaths, finished: finished)
                    content(for: phase)
                }

                if let note {
                    Text(note)
                        .font(Theme.sans(13.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }

                Button(doneTitle, action: onDone)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .tint(BreathPalette.petal)
            }
            .padding(Theme.Space.xl)
        }
        // Dark throughout, so the glass button and material read correctly
        // whatever the system appearance is.
        .environment(\.colorScheme, .dark)
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
        // After the last breath: show "Well done" briefly, then close by
        // itself. Closing early cancels this task, so onDone runs once.
        .task {
            do {
                // Tight tolerance: left to the system, a 30 s sleep can run
                // over by more than a second.
                try await Task.sleep(for: .seconds(total), tolerance: .milliseconds(20))
                finished = true
                try await Task.sleep(for: .seconds(Self.doneHold), tolerance: .milliseconds(20))
                onDone()
            } catch {
                // Cancelled: the student closed it first.
            }
        }
    }

    // MARK: Guide

    @ViewBuilder
    private func content(for phase: Phase) -> some View {
        // Reduce Motion: the bloom holds still, half open, and only its
        // brightness rises and falls with the breath.
        let open = reduceMotion ? 0.6 : phase.bloom
        let glow = reduceMotion ? 0.55 + 0.45 * phase.bloom : 1.0
        let ring = Self.bloomSize + 2 * Self.ringGap

        VStack(spacing: Theme.Space.xl) {
            ZStack {
                // Session ring: a faint track that fills over all breaths.
                Circle()
                    .stroke(.white.opacity(0.07), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: phase.overall)
                    .stroke(
                        BreathPalette.petal,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(phase.overall > 0 ? 0.85 : 0)

                // Soft halo behind the petals, so the bloom seems to glow.
                BreathBloom(open: open, size: Self.bloomSize)
                    .blur(radius: 32)
                    .opacity(0.6 * glow)

                BreathBloom(open: open, size: Self.bloomSize)
                    .opacity(glow)

                if phase.isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 6)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: ring, height: ring)
            // The room brightens a little as you breathe in. A background
            // does not change the layout, so it can reach past the ring.
            .background {
                RadialGradient(colors: [BreathPalette.sky.opacity(0.10 + 0.16 * phase.bloom), .clear],
                               center: .center, startRadius: 0, endRadius: 460)
                    .frame(width: 920, height: 920)
                    .allowsHitTesting(false)
            }
            .animation(.spring(duration: 0.5, bounce: 0.25), value: phase.isDone)
            .accessibilityHidden(true)

            VStack(spacing: Theme.Space.sm) {
                // Cross-fade the instruction instead of snapping between words.
                ZStack {
                    Text(phase.word)
                        .id(phase.word)
                        .font(Theme.serif(30, .semibold))
                        .foregroundStyle(.white)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                .animation(.easeInOut(duration: 0.45), value: phase.word)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityValue(phase.progress)

                Text(phase.count.map(String.init) ?? " ")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.25), value: phase.count)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Timing

    struct Phase: Equatable {
        var word: String
        var count: Int?
        var scale: Double
        var progress: String
        /// Which breath this is, from 0. Equals `breaths` once finished.
        var breath: Int = 0
        /// How far through the current breath (in and out), 0…1.
        var cycleFraction: Double = 0
        /// How far through the whole session, 0…1.
        var overall: Double = 0
        var isDone: Bool = false

        /// `scale` mapped to how open the bloom is: 0 folded, 1 fully open.
        var bloom: Double {
            min(max((scale - CalmBreathView.small) / (CalmBreathView.large - CalmBreathView.small), 0), 1)
        }
    }

    /// Where the guide is `elapsed` seconds in. Pure, so it can be tested.
    static func phase(at elapsed: Double, breaths: Int, finished: Bool) -> Phase {
        let cycle = inhale + exhale
        let total = Double(max(breaths, 1)) * cycle
        if finished || elapsed >= total {
            return Phase(word: "Well done", count: nil, scale: small,
                         progress: "\(breaths) slow breath\(breaths == 1 ? "" : "s")",
                         breath: breaths, cycleFraction: 1, overall: 1, isDone: true)
        }
        let t = max(0, elapsed)
        let n = min(Int(t / cycle), max(breaths, 1) - 1)
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
                     progress: "Breath \(n + 1) of \(breaths)",
                     breath: n,
                     cycleFraction: min(max(inCycle / cycle, 0), 1),
                     overall: min(max(t / total, 0), 1))
    }
}

// MARK: - Pieces

/// Colours for the guide: one blue throughout.
private enum BreathPalette {
    /// Soft glow behind the bloom.
    static let sky  = Color(red: 0.30, green: 0.56, blue: 0.90)
    /// The bloom's one colour: Weft's navy, lifted so it glows on dark.
    static let petal = Color(red: 0.24, green: 0.47, blue: 0.84)
    static let backdropTop    = Color(red: 0.035, green: 0.055, blue: 0.105)
    static let backdropBottom = Color(red: 0.060, green: 0.105, blue: 0.190)
}

/// Six translucent petals, all one colour. Folded (`open` 0) they sit on
/// top of each other as one small bright circle; opening pushes each out
/// from the centre and
/// twists the whole bloom. Where petals overlap their light adds up.
private struct BreathBloom: View {
    /// 0 folded … 1 fully open.
    var open: Double
    var size: CGFloat

    private static let petals = 6

    var body: some View {
        let o = CGFloat(open)
        // Open: each petal is half the bloom wide and touches the centre, so
        // the six together fill `size`. Folded: one circle a quarter wide.
        let diameter = size / 2 * (0.5 + 0.5 * o)
        let reach = size / 4 * o
        ZStack {
            ForEach(0..<Self.petals, id: \.self) { i in
                Circle()
                    .fill(BreathPalette.petal)
                    .frame(width: diameter, height: diameter)
                    // Folded, all six stack up; fade them so the stack is a
                    // bright teal circle rather than pure white.
                    .opacity(0.2 + 0.3 * Double(o))
                    .offset(y: -reach)
                    .rotationEffect(.degrees(Double(i) * 360 / Double(Self.petals)))
                    .blendMode(.plusLighter)
            }
        }
        // A sixth of a turn while opening: the petals sweep into place.
        .rotationEffect(.degrees(-60 * (1 - open)))
        .frame(width: size, height: size)
        // Draw on the GPU in one pass: smoother motion, and the overlapping
        // light adds up cleanly instead of flickering at the edges.
        .drawingGroup()
    }
}

/// Deep, slightly blurred night backdrop over whatever is behind the guide.
private struct BreathBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [BreathPalette.backdropTop, BreathPalette.backdropBottom],
                           startPoint: .top, endPoint: .bottom)
                .opacity(0.94)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    CalmBreathView(note: "Your time keeps running. Your work is saved.") { }
        .frame(width: 700, height: 640)
}

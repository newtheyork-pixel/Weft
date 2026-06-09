//
//  WindowAccessor.swift
//  Weft — bridge from a SwiftUI view to its hosting NSWindow, so the kiosk
//  controller can lock the exact window the exam is shown in. Place an invisible
//  WindowAccessor in a view's background; it reports the window once AppKit has
//  attached the view to one, and again only if the hosting window changes.
//

import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Remembers the last window we reported so we don't re-fire onResolve on
    /// every SwiftUI update tick (only on a genuine window change).
    final class Coordinator {
        weak var lastWindow: NSWindow?
        var hasReported = false
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        report(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        report(from: nsView, coordinator: context.coordinator)
    }

    private func report(from view: NSView, coordinator: Coordinator) {
        // The view may not be in a window yet at make-time; defer one runloop tick.
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                let window = view?.window
                guard !coordinator.hasReported || coordinator.lastWindow !== window else { return }
                coordinator.hasReported = true
                coordinator.lastWindow = window
                onResolve(window)
            }
        }
    }
}

extension View {
    /// Calls `onResolve` with the hosting NSWindow once it is available (and again
    /// only if the window changes).
    func onWindow(_ onResolve: @escaping @MainActor (NSWindow?) -> Void) -> some View {
        background(WindowAccessor(onResolve: onResolve))
    }
}

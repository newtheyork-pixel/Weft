//
//  HitTargets.swift
//  Weft: button styles with click targets the size of what you see.
//
//  SwiftUI's `.plain` button style only takes clicks on the label's drawn
//  pixels: the glyph of an icon, the letters of a word. The gaps between
//  letters, the padding and a transparent background all let the click fall
//  through, so buttons feel smaller than they look. A `.contentShape` placed
//  outside the button does not fix that; it has to sit on the label.
//
//  `.plainHit`  looks exactly like `.plain`, but the whole label frame
//               (padding included) takes the click.
//  `.iconHit`   for small icon-only buttons: at least 32x32 pt to click,
//               with a soft hover fill so the target is visible.
//

import SwiftUI
import AppKit

/// `.plain` look, whole-frame click target.
struct PlainHitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Icon (or short label) button with a 32x32 pt minimum click target and a
/// hover fill.
struct IconHitButtonStyle: ButtonStyle {
    var minSize: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        IconHitBody(configuration: configuration, minSize: minSize)
    }

    private struct IconHitBody: View {
        let configuration: ButtonStyleConfiguration
        let minSize: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .frame(minWidth: minSize, minHeight: minSize)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(fillOpacity))
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }

        private var fillOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.12 }
            return hovering ? 0.06 : 0
        }
    }
}

extension ButtonStyle where Self == PlainHitButtonStyle {
    /// Like `.plain`, but the whole label frame takes the click.
    static var plainHit: PlainHitButtonStyle { PlainHitButtonStyle() }
}

extension ButtonStyle where Self == IconHitButtonStyle {
    /// Small icon button with a 32x32 pt click target and a hover fill.
    static var iconHit: IconHitButtonStyle { IconHitButtonStyle() }
}

// MARK: - Menu button

/// One row of a `PopUpMenuButton` menu.
enum PopUpMenuEntry {
    case item(String, () -> Void)
    case header(String)
    case separator
}

/// A toolbar button (`.iconHit`, 32 pt target) that opens an AppKit menu at
/// the click. Used instead of a SwiftUI `Menu`, which on macOS is a pop-up
/// button sized to its label and ignores clicks on padding around it.
struct PopUpMenuButton<Label: View>: View {
    let label: String
    let entries: () -> [PopUpMenuEntry]
    @ViewBuilder let content: () -> Label

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 3) {
                content()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .buttonStyle(.iconHit)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .linkPointer()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries() {
            switch entry {
            case .item(let title, let run):
                let action = MenuAction(run)
                let item = NSMenuItem(title: title, action: #selector(MenuAction.runAction), keyEquivalent: "")
                item.target = action
                item.representedObject = action   // target is weak; keep it alive
                menu.addItem(item)
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            }
        }
        // Open at the pointer (the click that pressed the button). A keyboard
        // press has no useful event location, so fall back to the pointer.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let view = window.contentView else { return }
        let inWindow: NSPoint
        if let event = NSApp.currentEvent, event.window === window,
           event.type == .leftMouseUp || event.type == .leftMouseDown {
            inWindow = event.locationInWindow
        } else {
            inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        }
        menu.popUp(positioning: nil, at: view.convert(inWindow, from: nil), in: view)
    }
}

/// Holds a menu item's closure for the Objective-C target/action pair.
private final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func runAction() { run() }
}

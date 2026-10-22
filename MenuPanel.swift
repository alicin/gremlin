import AppKit
import Carbon.HIToolbox
import SwiftUI

// The glass panel that opens from the menu bar item in place of a menu. It closes on a click elsewhere or Escape.
@MainActor
final class MenuPanel: NSObject, NSWindowDelegate {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let model: MenuModel
    private var window: GlassWindow?
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []

    init(model: MenuModel) {
        self.model = model
    }

    var isOpen: Bool { window != nil }

    func toggle(below button: NSStatusBarButton?) {
        isOpen ? close() : open(below: button)
    }

    func open(below button: NSStatusBarButton?) {
        guard window == nil else { return }
        model.page = .main
        onOpen?()
        let host = NSHostingView(rootView: MenuRoot(model: model) { [weak self] _ in self?.window?.reshadow() })
        host.sizingOptions = []
        let window = GlassWindow(level: .popUpMenu, keyable: true)
        window.contentView = host
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }
        self.window = window

        let anchor = Self.frame(of: button)
        let screen = anchor.flatMap { anchor in NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // Centered under the menu bar item, but kept on screen when the item is near an edge.
        let center = anchor?.midX ?? visible.maxX - 8 - MenuRoot.width / 2
        let glass = min(max(visible.minX + 8, center - MenuRoot.width / 2), visible.maxX - 8 - MenuRoot.width)
        // An auto-hiding menu bar isn't left out of the visible frame, so go by the item when it's lower.
        let top = min(visible.maxY, anchor?.minY ?? visible.maxY) - 6
        model.maxHeight = top - visible.minY - 8
        // The window reaches down as far as the glass ever could and never resizes, so the glass stays pinned to the top
        // and grows or shrinks downward. Clicks on the clear part below it go through to whatever is underneath.
        window.setFrame(NSRect(x: glass, y: top - model.maxHeight, width: MenuRoot.width, height: model.maxHeight), display: true)

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }
        button?.highlight(true)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.keyCode == UInt16(kVK_ANSI_Q) else { return event }
            self?.model.perform(.quit)
            return nil
        } as Any)
        self.button = button
    }

    func close() {
        guard let window else { return }
        self.window = nil
        // It stays on screen while it fades, and losing key then mustn't close a panel opened in the meantime.
        window.delegate = nil
        window.onCancel = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; window.animator().alphaValue = 0 }) {
            window.orderOut(nil)
        }
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        close()
    }

    // The menu bar item's place on screen, or nil when the system doesn't say where it is.
    private static func frame(of button: NSStatusBarButton?) -> NSRect? {
        guard let button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSScreen.screens.contains { $0.frame.intersects(frame) } ? frame : nil
    }
}

struct MenuRoot: View {
    static let width: CGFloat = 364

    @ObservedObject var model: MenuModel
    let onSize: (CGSize) -> Void

    var body: some View {
        MenuView(model: model)
            .frame(width: Self.width)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGlass()
    }
}

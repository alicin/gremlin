import AppKit

// A small floating panel under the menu bar. It shows over full-screen apps without taking focus from the call, and
// unlike a notification it still appears when Gremlin's notifications or a Focus are turned off.
@MainActor
final class Prompt: NSObject {
    struct Action {
        let title: String
        let run: () -> Void
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    private var message: NSTextField?
    private var actions: [Action] = []
    private(set) var topic: String?

    func show(_ topic: String, icon: NSImage?, title: String, message text: String, actions: [Action], on screen: NSScreen?) {
        hide()
        self.topic = topic
        self.actions = actions
        let width: CGFloat = 400

        let iconView = NSImageView(image: icon ?? NSApp.applicationIconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        let messageField = NSTextField(wrappingLabelWithString: text)
        messageField.font = .systemFont(ofSize: 12)
        messageField.textColor = .secondaryLabelColor
        message = messageField
        let words = NSStackView(views: [titleField, messageField])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: actions.enumerated().map { index, action in
            let button = NSButton(title: action.title, target: self, action: #selector(clicked))
            button.tag = index
            button.bezelStyle = .push
            if index == 0 { button.keyEquivalent = "\r" }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
            return button
        })
        buttons.orientation = .vertical
        buttons.spacing = 4
        let row = NSStackView(views: [iconView, words, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 16)
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            row.widthAnchor.constraint(equalToConstant: width),
        ])

        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: 80), styleMask: [.nonactivatingPanel, .borderless],
                          backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        panel.setContentSize(background.fittingSize)
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - panel.frame.height - 12))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
        self.panel = panel
    }

    // A layer's corner radius doesn't clip the blur, a mask image does.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func update(_ text: String) {
        message?.stringValue = text
    }

    func hide(_ topic: String? = nil) {
        guard topic == nil || topic == self.topic else { return }
        panel?.orderOut(nil)
        panel = nil
        message = nil
        actions = []
        self.topic = nil
    }

    @objc private func clicked(_ sender: NSButton) {
        let action = actions[sender.tag]
        hide()
        action.run()
    }
}

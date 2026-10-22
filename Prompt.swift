import AppKit
import SwiftUI

// A small floating panel under the menu bar. It shows over full-screen apps without taking focus from the call, and
// unlike a notification it still appears when Gremlin's notifications or a Focus are turned off.
@MainActor
final class Prompt: NSObject {
    struct Action {
        let title: String
        let run: () -> Void
    }

    enum Icon {
        // An app's icon, or Gremlin's.
        case app(NSImage?)
        case symbol(String)
    }

    fileprivate final class Message: ObservableObject {
        @Published var text = ""
    }

    private var window: GlassWindow?
    private let message = Message()
    private(set) var topic: String?

    func show(_ topic: String, icon: Icon, title: String, message text: String, actions: [Action], on screen: NSScreen?) {
        hide()
        self.topic = topic
        message.text = text
        let view = PromptView(icon: icon, title: title, message: message, actions: actions.map { action in
            Action(title: action.title) { [weak self] in
                self?.hide()
                action.run()
            }
        })
        .onGlass()
        let host = NSHostingView(rootView: view)
        let window = GlassWindow(level: .statusBar, keyable: false)
        window.contentView = host
        let size = host.fittingSize
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        window.setFrame(NSRect(x: visible.maxX - 16 - size.width, y: visible.maxY - 10 - size.height,
                               width: size.width, height: size.height), display: true)
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.animator().alphaValue = 1
        window.reshadow()
        self.window = window
    }

    func update(_ text: String) {
        message.text = text
    }

    func hide(_ topic: String? = nil) {
        guard topic == nil || topic == self.topic else { return }
        window?.orderOut(nil)
        window = nil
        self.topic = nil
    }
}

private struct PromptView: View {
    let icon: Prompt.Icon
    let title: String
    @ObservedObject var message: Prompt.Message
    let actions: [Prompt.Action]
    @Environment(\.glass) private var look

    var body: some View {
        HStack(spacing: 12) {
            switch icon {
            case .app(let image):
                Image(nsImage: image ?? NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Tone.warning.color, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold))
                Text(message.text).font(.system(size: 12)).foregroundStyle(look.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                ForEach(actions.indices, id: \.self) { index in
                    Button(actions[index].title, action: actions[index].run)
                        .buttonStyle(PillStyle(kind: index == 0 ? .prominent : .control, height: 28, wide: true))
                }
            }
            .frame(minWidth: 100)
            .fixedSize()
        }
        .padding(14)
        .frame(width: 400)
        .legible()
        .surface(.panel, radius: 24)
    }
}

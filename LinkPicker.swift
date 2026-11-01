import AppKit
import Carbon.HIToolbox
import SwiftUI

// Asks which browser a link should open in. It takes keystrokes without activating Gremlin, so the app the link was
// clicked in stays in front until a browser is chosen.
@MainActor
final class LinkPicker: NSObject, NSWindowDelegate {
    final class State: ObservableObject {
        @Published var urls: [URL] = []
        @Published var targets: [LinkTarget] = []
        @Published var keys: [String: String] = [:]
        @Published var selected = 0
        @Published var source: String?
    }

    static let columns = 7
    static let tile: CGFloat = 84

    private unowned let links: Links
    private let state = State()
    private var window: GlassWindow?
    private var monitors: [Any] = []

    init(links: Links) {
        self.links = links
    }

    func show(_ urls: [URL], source: String?) {
        // A link that arrives while one is waiting joins it, and the choice covers them all.
        guard window == nil else {
            state.urls += urls
            return
        }
        let targets = links.shownTargets
        guard !targets.isEmpty else {
            urls.forEach { links.open($0, in: links.primary) }
            return
        }
        state.urls = urls
        state.targets = targets
        state.keys = links.pickerKeys(for: targets)
        state.selected = targets.firstIndex(of: links.primary) ?? 0
        state.source = source

        let host = NSHostingView(rootView: LinkPickerView(state: state, links: links, picker: self).onGlass())
        let window = GlassWindow(level: .popUpMenu, keyable: true)
        window.contentView = host
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let x = min(max(visible.minX + 8, mouse.x - size.width / 2), visible.maxX - 8 - size.width)
        let y = min(max(visible.minY + 8, mouse.y + 16), visible.maxY - 8 - size.height)
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; window.animator().alphaValue = 1 }
        window.reshadow()
        self.window = window

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        } as Any)
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.onCancel = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; window.animator().alphaValue = 0 }) {
            window.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        close()
    }

    func choose(_ target: LinkTarget, background: Bool = false, newWindow: Bool = false) {
        let urls = state.urls
        close()
        urls.forEach { links.open($0, in: target, background: background, newWindow: newWindow) }
    }

    // Command-clicking a browser means "always", and Control means "without leaving what I'm in".
    func click(_ target: LinkTarget) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command), let url = state.urls.first { links.addRule(for: url, target: target) }
        choose(target, background: flags.contains(.control))
    }

    func alwaysOpen(_ target: LinkTarget) {
        if let url = state.urls.first { links.addRule(for: url, target: target) }
        choose(target)
    }

    func copyLinks() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        close()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let count = state.targets.count
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_LeftArrow:
            state.selected = (state.selected - 1 + count) % count
        case kVK_RightArrow:
            state.selected = (state.selected + 1) % count
        case kVK_UpArrow where count > Self.columns:
            state.selected = max(0, state.selected - Self.columns)
        case kVK_DownArrow where count > Self.columns:
            state.selected = min(count - 1, state.selected + Self.columns)
        case kVK_Tab where flags.contains(.control):
            state.selected = (state.selected + (flags.contains(.shift) ? count - 1 : 1)) % count
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            choose(state.targets[state.selected], background: flags.contains(.control))
        case kVK_ANSI_C where flags == .command:
            copyLinks()
        default:
            guard let key = event.charactersIgnoringModifiers?.lowercased(), !flags.contains(.command),
                  let target = target(forKey: key) else { return false }
            choose(target, background: flags.contains(.control))
        }
        return true
    }

    private func target(forKey key: String) -> LinkTarget? {
        if let number = Int(key), number >= 1, number <= state.targets.count { return state.targets[number - 1] }
        return state.targets.first { state.keys[$0.id] == key }
    }
}

private struct LinkPickerView: View {
    @ObservedObject var state: LinkPicker.State
    let links: Links
    let picker: LinkPicker
    @Environment(\.glass) private var look

    private var url: URL? { state.urls.first }

    private var host: String {
        guard let url else { return "" }
        return url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "", options: .anchored)
    }

    private var rest: String {
        guard let url, !url.isFileURL else { return "" }
        let text = url.path + (url.query.map { "?" + $0 } ?? "")
        return text == "/" ? "" : text
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(LinkPicker.tile), spacing: 4), count: min(state.targets.count, LinkPicker.columns))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(host).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        if state.urls.count > 1 {
                            Text("+\(state.urls.count - 1) more").font(.system(size: 11, weight: .semibold)).foregroundStyle(look.sub)
                        }
                    }
                    if !rest.isEmpty {
                        Text(rest).font(.system(size: 11)).foregroundStyle(look.sub).lineLimit(1).truncationMode(.middle)
                    }
                }
                .help(url?.absoluteString ?? "")
                Spacer(minLength: 8)
                Button { picker.copyLinks() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(RoundStyle(size: 26))
                    .help("Copy Link  ⌘C")
                    .accessibilityLabel("Copy Link")
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(state.targets.indices, id: \.self) { index in
                    tile(index)
                }
            }
        }
        .padding(12)
        .fixedSize()
        .legible()
        .surface(.panel, radius: 22)
    }

    private func tile(_ index: Int) -> some View {
        let target = state.targets[index]
        let browser = links.browsers.first { $0.id == target.app }
        return Button { picker.click(target) } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    if let icon = links.icon(of: target) {
                        Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                    }
                    if target.isPrivate {
                        badge("eyeglasses")
                    } else if target.profile != nil {
                        badge("person.fill")
                    }
                }
                Text(tileTitle(target)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85).truncationMode(.tail)
                Text(keyHint(index, target)).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(look.sub)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(width: LinkPicker.tile)
            .background {
                if state.selected == index { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(look.fill(0.14)) }
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(links.title(of: target))
        .contextMenu {
            Button("Always Open \(host) Here") { picker.alwaysOpen(target) }
            if browser?.newWindowFlag != nil, !target.isPrivate {
                Button("Open in New Window") { picker.choose(target, newWindow: true) }
            }
            Button("Open in Background") { picker.choose(target, background: true) }
            if browser?.privateFlag != nil, !target.isPrivate {
                Button("Open in Private Window") {
                    picker.choose(LinkTarget(app: target.app, isPrivate: true))
                }
            }
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color(white: 0.2), in: Circle())
    }

    private func tileTitle(_ target: LinkTarget) -> String {
        if let profile = target.profileName { return profile }
        return links.appURL(target.app).map(Browsers.name) ?? target.app
    }

    private func keyHint(_ index: Int, _ target: LinkTarget) -> String {
        state.keys[target.id]?.uppercased() ?? (index < 9 ? String(index + 1) : " ")
    }
}

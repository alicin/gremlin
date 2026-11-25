import AppKit
import SwiftUI

// Gremlin's main window: a floating glass sidebar of everything it does, and the selected module's screen.
// Gremlin shows in the Dock only while this window is open, and stays a menu bar app otherwise.

@MainActor
final class Navigator: ObservableObject {
    /// nil is Home.
    @Published var selection: Module?
    @Published var query = ""
    @Published var collapsed: Set<String> = []

    func go(_ module: Module?) {
        withAnimation(Motion.snappy) { selection = module }
    }
}

@MainActor
final class GremlinWindow: NSObject, NSWindowDelegate {
    let navigator = Navigator()
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    private let model: MenuModel
    private let recordings: Recordings
    private var window: NSWindow?

    init(model: MenuModel, recordings: Recordings) {
        self.model = model
        self.recordings = recordings
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ module: Module? = nil, page: Bool = false) {
        if page { navigator.selection = module }
        if window == nil { window = makeWindow() }
        onOpen?()
        Self.installMenu()
        // Plain activate() is only a request, and macOS declines it when a hotkey or the menu bar opened the window.
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if window?.isKeyWindow == true, NSApp.isActive { close() } else { show() }
    }

    func close() {
        window?.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = WindowRoot(model: model, navigator: navigator, recordings: recordings)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Gremlin"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar moves the window buttons down and in, so they sit inside the floating sidebar.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("GremlinWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = self
        return window
    }

    // Screens are laid out for at least this much room; below it the sidebar and the bento rows stop fitting.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, 1000), height: max(frameSize.height, 660))
    }

    func windowWillClose(_ notification: Notification) {
        navigator.query = ""
        onClose?()
    }

    // Gremlin never shows a menu bar, but its main menu still answers ⌘C, ⌘V, ⌘W and ⌘Q in the window.
    private static func installMenu() {
        guard NSApp.mainMenu?.items.first?.title != "Gremlin" else { return }
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        submenu("Gremlin", [
            item("About Gremlin", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide Gremlin", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Gremlin", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }
}

// MARK: - Root

struct WindowRoot: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var navigator: Navigator
    @ObservedObject var recordings: Recordings

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            ScreenHost()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackdrop())
        .tint(Palette.accent)
        .ignoresSafeArea()
        .environmentObject(model)
        .environmentObject(navigator)
        .environmentObject(recordings)
        .environmentObject(model.links)
        .environmentObject(model.drives)
        .environmentObject(model.displays)
        .environmentObject(model.scrolling)
        .environmentObject(model.vpn)
        .environmentObject(model.cables)
    }
}

/// The window's own color with a few holographic blooms, so the glass sidebar has something to bend.
private struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Palette.window
                Group {
                    Circle().fill(Palette.holoLilac).frame(width: 340, height: 340).offset(x: -150, y: -60)
                    Circle().fill(Palette.holoMint).frame(width: 260, height: 260).offset(x: -40, y: 250)
                    Circle().fill(Palette.holoPink).frame(width: 300, height: 300).offset(x: -110, y: 520)
                    Circle().fill(Palette.holoSky).frame(width: 220, height: 220).offset(x: 120, y: 420)
                    Circle().fill(Palette.holoPeach).frame(width: 320, height: 320).offset(x: geo.size.width - 230, y: -230)
                    Circle().fill(Palette.holoLemon).frame(width: 200, height: 200).offset(x: geo.size.width - 420, y: -150)
                }
                .blur(radius: 70)
                .opacity(scheme == .dark ? 0.42 : 0.55)
            }
        }
        .ignoresSafeArea()
    }
}

private struct ScreenHost: View {
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        ZStack(alignment: .topLeading) {
            screen
                .id(navigator.selection)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.985, anchor: .top)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var screen: some View {
        switch navigator.selection {
        case nil: HomeScreen()
        case .meetings: MeetingsScreen()
        case .tools: ToolsScreen()
        case .keepAwake: KeepAwakeScreen()
        case .displays: DisplaysScreen()
        case .restart: RestartScreen()
        case .fixes: FixesScreen()
        case .ipad: IPadScreen()
        case .universalControl: UniversalControlScreen()
        case .scrolling: ScrollingScreen()
        case .cables: CablesScreen()
        case .links: LinksScreen()
        case .drives: DrivesScreen()
        case .vpn: VPNScreen()
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - Screen frame

/// A module's screen: a card with a band in the module's color holding its title and main actions, and the
/// content below. Content that fits stays put so columns can reach the bottom; taller content scrolls.
struct ScreenCard<Trailing: View, Content: View>: View {
    let module: Module
    var scrolls = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    static var band: CGFloat { 108 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(spacing: 0) {
            ScreenHeader(module: module) { trailing }
            Group {
                if scrolls {
                    ViewThatFits(in: .vertical) {
                        content.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        ScrollView(.vertical) { content.padding(18) }.scrollIndicators(.automatic)
                    }
                } else {
                    content.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .background {
            ZStack(alignment: .top) {
                Palette.page
                VividSurface(colors: module.fill, symbol: module == .settings ? "pawprint.fill" : module.symbol, radius: 0, glow: false)
                    .frame(height: Self.band)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.stroke, lineWidth: 1) }
        .shadow(color: Palette.shadow, radius: 18, y: 8)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
    }
}

struct ScreenHeader<Trailing: View>: View {
    let module: Module
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if module == .settings {
                    AppIconView(size: 52)
                } else {
                    Image(systemName: module.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 50, height: 50)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(0.22)))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.system(size: 27, weight: .bold, design: .rounded))
                Text(module.blurb).font(.system(size: 13.5, weight: .medium)).opacity(0.88)
            }
            Spacer(minLength: 16)
            trailing
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .frame(height: ScreenCard<Trailing, EmptyView>.band)
    }
}

/// A note for a screen's header band, like the time Keep Awake ends.
struct HeaderNote: View {
    let text: String
    var symbol = "clock.fill"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Capsule().fill(.white.opacity(0.2)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var navigator: Navigator
    @Namespace private var space
    @FocusState private var searchFocused: Bool

    private var groups: [(group: Module.Group, modules: [Module])] {
        let q = navigator.query.trimmingCharacters(in: .whitespaces)
        return Module.grouped.compactMap { entry in
            let modules = entry.modules.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.blurb.localizedCaseInsensitiveContains(q) }
            return modules.isEmpty ? nil : (entry.group, modules)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AppIconView(size: 46).shadow(color: Palette.indigo.opacity(0.3), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gremlin").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Unsticks your Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 42)
            .padding(.horizontal, 4)
            .padding(.bottom, 10)
            SearchField(text: $navigator.query, focused: $searchFocused)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SideRow(title: "Home", tint: Palette.accent, selected: navigator.selection == nil, space: space) {
                        PawTile(size: 24)
                    } trailing: {
                        EmptyView()
                    } action: {
                        navigator.go(nil)
                    }
                    ForEach(groups, id: \.group) { entry in
                        let folded = navigator.collapsed.contains(entry.group.rawValue) && navigator.query.isEmpty
                        GroupHeader(title: entry.group.rawValue, collapsed: folded) {
                            withAnimation(Motion.snappy) {
                                if folded { navigator.collapsed.remove(entry.group.rawValue) } else { navigator.collapsed.insert(entry.group.rawValue) }
                            }
                        }
                        if !folded {
                            ForEach(entry.modules) { module in
                                moduleRow(module).transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("Nothing matches “\(navigator.query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            // In a short window the list scrolls under the Settings row, so it fades out instead of being cut off.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                }
            }
            moduleRow(.settings).padding(.top, 4)
            AwakeChip().padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .glassSurface(cornerRadius: 20)
        .padding(8)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0)
            Button("") { navigator.go(.settings) }.keyboardShortcut(",", modifiers: .command).opacity(0)
        }
        // AppKit gives the window's first text field focus on open; search should wait for a click or ⌘K.
        .task {
            try? await Task.sleep(for: .milliseconds(30))
            searchFocused = false
        }
    }

    private func moduleRow(_ module: Module) -> some View {
        SideRow(title: module.title, tint: module.tint, selected: navigator.selection == module, space: space) {
            IconTile(symbol: module.symbol, tint: module.tint, size: 24)
        } trailing: {
            SideBadge(module: module)
        } action: {
            navigator.go(module)
        }
    }
}

extension View {
    /// Liquid Glass in a rounded shape, for floating surfaces.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
            if text.isEmpty {
                Text("⌘K")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.75) }
            } else {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(.primary.opacity(0.06), in: shape)
        .overlay { shape.strokeBorder(focused.wrappedValue ? Palette.accent.opacity(0.6) : .clear, lineWidth: 1) }
        .animation(Motion.snappy, value: focused.wrappedValue)
    }
}

private struct GroupHeader: View {
    let title: String
    let collapsed: Bool
    let action: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .opacity(hovering.value || collapsed ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

private struct SideRow<Icon: View, Trailing: View>: View {
    let title: String
    let tint: Color
    let selected: Bool
    let space: Namespace.ID
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing
    let action: () -> Void
    @StateObject private var hovering = Box(false)
    @StateObject private var bounce = Box(0)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                icon.symbolEffect(.bounce, value: bounce.value)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: 29)
            .background {
                if selected {
                    shape.fill(tint.opacity(0.2))
                        .overlay { shape.strokeBorder(tint.opacity(0.5), lineWidth: 0.75) }
                        .shadow(color: tint.opacity(0.25), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "selection", in: space)
                } else if hovering.value {
                    shape.fill(.primary.opacity(0.06))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .onChange(of: selected) { _, now in if now { bounce.value += 1 } }
    }
}

/// Live state next to a module's name, so the sidebar doubles as a status board.
private struct SideBadge: View {
    let module: Module
    @EnvironmentObject private var model: MenuModel
    @EnvironmentObject private var links: Links
    @EnvironmentObject private var drives: Drives
    @EnvironmentObject private var scrolling: ScrollDirection
    @EnvironmentObject private var vpn: VPN
    @EnvironmentObject private var cables: Cables

    var body: some View {
        switch module {
        case .meetings:
            if model.recording != nil {
                HStack(spacing: 3) {
                    Circle().fill(.white).frame(width: 5, height: 5)
                    Text("REC").font(.system(size: 9.5, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(Palette.coral.gradient, in: Capsule())
                .transition(.scale.combined(with: .opacity))
            } else if let progress = model.notesProgress {
                ProgressRing(progress: Recordings.percent(in: progress.detail).map { Double($0) / 100 } ?? 0.15, tint: Palette.coral, size: 14, line: 2.5)
                    .help(progress.title)
            }
        case .keepAwake:
            if model.awakeStop > 0 {
                Text(MenuModel.awakeStops[min(model.awakeStop, MenuModel.awakeStops.count - 1)])
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Ink.amber)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Palette.amber.opacity(0.22), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        case .links:
            let today = links.recent.filter { Calendar.current.isDateInToday($0.date) }.count
            if today > 0 {
                Text("\(today)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
        case .drives:
            if !drives.config.drives.isEmpty {
                let mounted = drives.config.drives.filter { drives.status(of: $0).phase == .mounted }.count
                Text("\(mounted)/\(drives.config.drives.count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
        case .universalControl:
            if model.watcher.isOn { Circle().fill(model.watcher.tone.color).frame(width: 6, height: 6) }
        case .ipad:
            if model.ipad?.state == .connected { Circle().fill(Palette.busy).frame(width: 6, height: 6) }
        case .scrolling:
            if scrolling.needsAccess { Circle().fill(Palette.warn).frame(width: 6, height: 6) }
        case .cables:
            if CablesScreen.stories(cables).contains(where: { $0.insights.contains { $0.tone == .warn } }) {
                Circle().fill(Palette.warn).frame(width: 6, height: 6).help("A cable is holding something back")
            } else if cables.chargingPort != nil {
                Image(systemName: "bolt.fill").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Ink.emerald)
            }
        case .vpn:
            let on = vpn.others.filter { $0.state == .on }.count + (vpn.tailscaleOn ? 1 : 0)
            if on > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Palette.good).frame(width: 6, height: 6)
                    Text("\(on)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Keep Awake is the state people check most, so it gets the live chip at the bottom of the sidebar.
private struct AwakeChip: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let awake = model.awakeStop > 0
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button {
            model.perform(.keepAwake(awake ? 0 : 2))
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    ProgressRing(progress: awake ? 1 : 0, tint: Palette.amber, size: 30, line: 3)
                    Image(systemName: awake ? "cup.and.saucer.fill" : "moon.zzz.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(awake ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(awake ? "Awake · \(model.awakeText.replacingOccurrences(of: "Until ", with: "until "))" : "Sleeping as usual")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(awake ? "Click to let it sleep" : "Click to stay awake for 1 h")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(awake ? AnyShapeStyle(Palette.amber.opacity(0.16)) : AnyShapeStyle(.primary.opacity(0.05)), in: shape)
            .overlay { shape.strokeBorder(awake ? Palette.amber.opacity(0.35) : .clear, lineWidth: 0.75) }
            .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .animation(Motion.bouncy, value: awake)
    }
}

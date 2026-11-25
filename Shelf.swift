import AppKit
import Carbon.HIToolbox
import SwiftUI

// The shelf: a glass strip that rises from the bottom of the screen on a hotkey, one card per module. Opening a card
// turns the strip into that module's own cards. Each module's cards live in ShelfCards.swift.

@MainActor
final class Shelf: NSObject, NSWindowDelegate {
    var onOpen: (() -> Void)?
    private let model: MenuModel
    private let recordings: Recordings
    private lazy var state = ShelfState(model: model, recordings: recordings)
    private var window: ShelfPanel?
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?

    private static let side: CGFloat = 14
    private static let top: CGFloat = 30

    init(model: MenuModel, recordings: Recordings) {
        self.model = model
        self.recordings = recordings
    }

    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? close() : show() }

    func show() {
        guard window == nil else { return }
        onOpen?()
        state.prepare()

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let full = screen.frame
        let visible = screen.visibleFrame
        // The window reaches down over the Dock, so the shelf rises from the true bottom of the screen and settles above it.
        let gap = visible.minY - full.minY + Self.side
        state.insets = EdgeInsets(top: Self.top, leading: Self.side, bottom: gap, trailing: Self.side)
        let frame = NSRect(x: visible.minX, y: full.minY, width: visible.width, height: gap + ShelfMetrics.height + Self.top)

        let window = ShelfPanel()
        let host = NSHostingView(rootView: ShelfRoot(model: model, recordings: recordings, close: { [weak self] in self?.close() }, state: state))
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self
        window.setFrame(frame, display: false)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        installMonitors(window)
    }

    func close() {
        guard let window else { return }
        self.window = nil
        // It stays up while it sinks, and losing key then mustn't close a shelf opened in the meantime.
        window.delegate = nil
        removeMonitors()
        model.restarted = []
        model.confirmRestartAll = false
        let duration = Motion.reduced ? 0.05 : 0.16
        withAnimation(.easeIn(duration: duration)) { state.presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            window.orderOut(nil)
            // Takes the SwiftUI tree out of the window, which also removes its key and scroll monitors.
            window.contentView = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        close()
    }

    private func installMonitors(_ window: NSWindow) {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        // The window is bigger than the glass, and a click on its clear part counts as a click outside.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            let insets = self.state.insets
            let glass = NSRect(x: insets.leading, y: insets.bottom, width: window.frame.width - insets.leading - insets.trailing,
                               height: ShelfMetrics.height)
            guard !glass.contains(event.locationInWindow) else { return event }
            self.close()
            return nil
        } as Any)
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                       queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
    }
}

/// Key without activating Gremlin, so the app underneath keeps the menu bar, and above the Dock and full-screen apps.
private final class ShelfPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // After isFloatingPanel, which sets a level that sits under the Dock.
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        allowsToolTipsWhenApplicationIsInactive = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityLabel("Gremlin shelf")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - State

/// A meeting being transcribed, summarized or compressed, from MeetingNotes' progress.
struct ShelfJob: Equatable {
    enum Kind { case compressing, transcribing, summarizing, other }

    let folder: URL
    let kind: Kind
    let title: String
    let percent: Int?

    init(_ progress: MeetingNotes.Progress) {
        folder = progress.folder
        percent = Recordings.percent(in: progress.detail)
        let words = progress.title.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "Compressing": kind = .compressing
        case "Transcribing": kind = .transcribing
        case "Summarizing": kind = .summarizing
        default: kind = .other
        }
        title = kind == .other ? progress.title : words.first ?? progress.title
    }

    var tint: Color {
        switch kind {
        case .compressing: Palette.amber
        case .transcribing, .other: Palette.iris
        case .summarizing: Palette.grape
        }
    }

    var doing: String {
        switch kind {
        case .compressing: "Making a smaller copy"
        case .transcribing: "Writing the transcript"
        case .summarizing: "Writing the summary"
        case .other: title
        }
    }
}

@MainActor
final class ShelfState: ObservableObject {
    enum Day: String, CaseIterable {
        case all = "All"
        case today = "Today"
        case week = "This week"
        case earlier = "Earlier"
    }

    let model: MenuModel
    let recordings: Recordings
    var close: () -> Void = {}
    /// Clear space around the glass for its shadow; at the bottom it also clears the Dock.
    @Published var insets = EdgeInsets(top: 30, leading: 30, bottom: 30, trailing: 30)

    @Published var presented = false
    @Published var page: Module?
    @Published var selected = Module.meetings
    @Published var peek: Module?
    @Published var group: Module.Group? { didSet { if group != oldValue { keepSelection() } } }
    @Published var query = "" { didSet { if query != oldValue { keepSelection() } } }
    @Published var sub: String?
    /// Bumped to put the cursor in the search field that's showing.
    @Published var focus = 0

    @Published var day = Day.all
    @Published var meetingQuery = "" { didSet { if meetingQuery != oldValue { keepMeeting() } } }
    @Published var meeting: URL?
    @Published var preview: URL?
    @Published var copied: URL?

    init(model: MenuModel, recordings: Recordings) {
        self.model = model
        self.recordings = recordings
    }

    /// Every show starts on the strip, with the card it last had picked.
    func prepare() {
        presented = false
        page = nil
        peek = nil
        preview = nil
        sub = nil
        query = ""
        meetingQuery = ""
        group = nil
        focus += 1
    }

    // MARK: What's showing

    var modules: [Module] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return Module.allCases.filter { module in
            (group == nil || module.group == group)
                && (words.isEmpty || [module.title, module.blurb, module.group.rawValue, status(module)].contains {
                    $0.localizedCaseInsensitiveContains(words)
                })
        }
    }

    var meetings: [Recordings.Item] {
        let words = meetingQuery.trimmingCharacters(in: .whitespaces)
        return recordings.items.filter { item in
            (day == .all || Self.day(of: item.date) == day)
                && (words.isEmpty || item.title.localizedCaseInsensitiveContains(words)
                    || item.people.contains { $0.localizedCaseInsensitiveContains(words) })
        }
    }

    var job: ShelfJob? { model.notesProgress.map(ShelfJob.init) }

    static func day(of date: Date?) -> Day {
        guard let date else { return .earlier }
        if Calendar.current.isDateInToday(date) { return .today }
        return Date().timeIntervalSince(date) < 7 * 86400 ? .week : .earlier
    }

    func status(_ module: Module) -> String {
        let model = self.model
        switch module {
        case .meetings:
            if let recording = model.recording { return recording.audioOnly ? "Recording audio" : "Recording screen and audio" }
            if model.starting { return "Starting…" }
            let items = recordings.items
            var running = Set(items.filter(\.uncompressed).map(\.folder))
            if let job { running.insert(job.folder) }
            let ready = items.filter { $0.transcribed && !running.contains($0.folder) }.count
            if items.isEmpty, running.isEmpty { return "No recordings yet" }
            return running.isEmpty ? "\(ready) ready" : "\(running.count) running · \(ready) ready"
        case .tools: return "4 shortcuts"
        case .keepAwake: return model.awakeText
        case .displays: return Self.displaysStatus(model.displays)
        case .restart: return model.restarted.isEmpty ? "\(Restart.items.count) parts" : "Restarted \(model.restarted.count)"
        case .fixes:
            let on = [AppSwitch.autoFixFocus, AppSwitch.notificationCenterWatchdog, AppSwitch.universalControlWatcher].filter { model.switches[$0] == true }
            return "\(on.count) of 3 on"
        case .ipad:
            guard let ipad = model.ipad else { return "Not on this Mac" }
            return switch ipad.state {
            case .nearby: "\(ipad.name) · nearby"
            case .connecting: "Connecting…"
            case .disconnecting: "Disconnecting…"
            case .connected: "\(ipad.name) · connected"
            case .away: "\(ipad.name) · not nearby"
            }
        case .universalControl: return model.watcher.isOn ? model.watcher.status : "The watcher is off"
        case .links:
            let links = model.links
            return links.isDefault ? "Opening in \(Self.short(links.title(of: links.primary)))" : "Not the default browser"
        case .drives:
            let drives = model.drives
            let all = drives.config.drives
            guard !all.isEmpty else { return "No drives yet" }
            if all.contains(where: { drives.status(of: $0).phase == .connecting }) { return "Connecting…" }
            return "\(all.filter { drives.status(of: $0).phase == .mounted }.count) of \(all.count) mounted"
        case .scrolling:
            let scrolling = model.scrolling
            if scrolling.needsAccess { return "Needs Accessibility" }
            let flipped = scrolling.devices.filter(scrolling.flips)
            if flipped.isEmpty { return "Same as macOS" }
            return flipped.count == 1 ? "Flipping \(flipped[0].title)" : "Flipping \(flipped.count) devices"
        case .cables:
            let cables = model.cables
            if let port = cables.chargingPort, let contract = port.contract?.winning {
                return "Charging · \(cables.charging.inputMilliwatts.map(Units.watts) ?? Units.watts(contract.milliwatts))"
            }
            let n = cables.connectedPorts.count
            return n == 0 ? "Nothing plugged in" : n == 1 ? "1 plugged in" : "\(n) plugged in"
        case .vpn:
            let vpn = model.vpn
            let others = vpn.others.filter { $0.state == .on }
            var parts: [String] = []
            if vpn.tailscaleTunnel != nil { parts.append(vpn.tailscaleOn ? "Tailscale on" : "Tailscale off") }
            if !vpn.others.isEmpty { parts.append(others.count == 1 ? others[0].name : "\(others.count) of \(vpn.others.count) on") }
            return parts.isEmpty ? "No VPNs" : parts.joined(separator: " · ")
        case .settings: return model.login ? "Opens at login" : "Version \(Self.version)"
        }
    }

    func isLive(_ module: Module) -> Bool {
        switch module {
        case .meetings: model.recording != nil || model.starting || model.notesProgress != nil
        case .keepAwake: model.awakeStop != 0
        case .ipad: model.ipad?.state == .connected
        case .vpn: model.vpn.others.contains { $0.state == .on }
        default: false
        }
    }

    static func displaysStatus(_ displays: Displays) -> String {
        if let layout = displays.layout(displays.applying) { return "Applying \(layout.title)…" }
        if let current = displays.current { return "Arranged as \(current.title)" }
        if displays.config.layouts.isEmpty { return "No layouts saved" }
        return displays.config.layouts.contains(where: displays.fits) ? "Not a saved layout" : "No layout for these displays"
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    static func short(_ name: String) -> String { name.replacingOccurrences(of: "Google ", with: "") }

    // MARK: Moving around

    func select(_ module: Module) {
        withAnimation(Motion.bouncy) {
            selected = module
            if peek != nil { peek = module }
        }
    }

    func open(_ module: Module) {
        withAnimation(Motion.snappy) {
            peek = nil
            sub = nil
            if module != .settings { selected = module }
            if module == .meetings, meeting == nil || !meetings.contains(where: { $0.folder == meeting }) {
                meeting = job?.folder ?? meetings.first?.folder
            }
            page = module
        }
        focus += 1
    }

    func back() {
        guard page != nil else { return }
        withAnimation(Motion.snappy) {
            page = nil
            preview = nil
        }
        focus += 1
    }

    func setGroup(_ group: Module.Group?) {
        withAnimation(Motion.bouncy) { self.group = group }
    }

    func setDay(_ day: Day) {
        withAnimation(Motion.bouncy) {
            self.day = day
            keepMeeting()
        }
    }

    func selectMeeting(_ folder: URL) {
        withAnimation(Motion.bouncy) {
            meeting = folder
            if preview != nil { preview = folder }
        }
    }

    func togglePreview(_ folder: URL) {
        withAnimation(Motion.bouncy) {
            meeting = folder
            preview = preview == folder ? nil : folder
        }
    }

    private func keepSelection() {
        let list = modules
        if !list.contains(selected), let first = list.first { selected = first }
        if let peek, !list.contains(peek) { self.peek = nil }
    }

    private func keepMeeting() {
        let list = meetings
        guard !list.contains(where: { $0.folder == meeting }) else { return }
        meeting = list.first?.folder
        if preview != nil { preview = meeting }
    }

    func move(_ delta: Int) {
        switch page {
        case nil:
            let list = modules
            guard !list.isEmpty else { return }
            let index = list.firstIndex(of: selected) ?? 0
            select(list[min(max(index + delta, 0), list.count - 1)])
        case .meetings?:
            let list = meetings.map(\.folder)
            guard let first = list.first else { return }
            guard let index = list.firstIndex(where: { $0 == meeting }) else { return selectMeeting(first) }
            selectMeeting(list[min(max(index + delta, 0), list.count - 1)])
        case let module?:
            let all = Module.allCases
            let index = all.firstIndex(of: module) ?? 0
            open(all[(index + delta + all.count) % all.count])
        }
    }

    func enter() {
        switch page {
        case nil: if modules.contains(selected) { open(selected) }
        case .meetings?:
            guard let item = recordings.items.first(where: { $0.folder == meeting }) else { return }
            let file = FileManager.default.fileExists(atPath: item.transcript.path) ? item.transcript : item.folder
            run(.open(file), closing: true)
        case let module?: openInGremlin(module)
        }
    }

    func space() {
        switch page {
        case nil: withAnimation(Motion.bouncy) { peek = peek == nil ? selected : nil }
        case .meetings?: if let meeting { togglePreview(meeting) }
        default: break
        }
    }

    func jump(_ number: Int) {
        let list = modules
        guard number >= 1, number <= list.count else { return }
        open(list[number - 1])
    }

    func escape() {
        if peek != nil {
            withAnimation(Motion.bouncy) { peek = nil }
        } else if preview != nil {
            withAnimation(Motion.bouncy) { preview = nil }
        } else if page == .meetings, !meetingQuery.isEmpty {
            meetingQuery = ""
        } else if page != nil {
            back()
        } else if !query.isEmpty {
            query = ""
        } else {
            close()
        }
    }

    func cycle(_ delta: Int) {
        if page == .meetings {
            let all = Day.allCases
            setDay(all[((all.firstIndex(of: day) ?? 0) + delta + all.count) % all.count])
        } else if page == nil {
            let all: [Module.Group?] = [nil] + Module.Group.allCases
            let index = all.firstIndex { $0 == group } ?? 0
            setGroup(all[(index + delta + all.count) % all.count])
        }
    }

    // MARK: Doing things

    /// Anything that captures the screen or acts on the app in front waits for the shelf to get out of the way.
    func run(_ action: MenuModel.Action, closing: Bool = false) {
        guard closing else { return model.perform(action) }
        close()
        let model = self.model
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.perform(action) }
    }

    func openInGremlin(_ module: Module?) {
        run(.openWindow(module), closing: true)
    }

    func open(url: URL) {
        close()
        NSWorkspace.shared.open(url)
    }

    // MARK: Keys

    private static let numberKeys = [kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6,
                                     kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9]

    private var searching: String {
        page == .meetings ? meetingQuery : page == nil ? query : ""
    }

    func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)
        if flags.contains(.command) {
            // Gremlin has no main menu, and without one nothing sends these to a text field.
            let edit: Selector? = switch (code, flags) {
            case (kVK_ANSI_X, .command): #selector(NSText.cut(_:))
            case (kVK_ANSI_C, .command): #selector(NSText.copy(_:))
            case (kVK_ANSI_V, .command): #selector(NSText.paste(_:))
            case (kVK_ANSI_A, .command): #selector(NSText.selectAll(_:))
            case (kVK_ANSI_Z, .command): Selector(("undo:"))
            case (kVK_ANSI_Z, [.command, .shift]): Selector(("redo:"))
            default: nil
            }
            if let edit { return NSApp.sendAction(edit, to: nil, from: nil) }
            // By physical key, since some layouts only type digits with ⇧.
            if flags == .command, let number = Self.numberKeys[code] {
                jump(number)
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "[": back()
            case "f": focus += 1
            case ",": openInGremlin(.settings)
            // The menu bar belongs to the app underneath, so these mean "put the shelf away", not "quit Gremlin".
            case "w", "q": close()
            default: return false
            }
            return true
        }
        switch code {
        case kVK_Escape: escape()
        case kVK_LeftArrow: move(-1)
        case kVK_RightArrow: move(1)
        case kVK_Return, kVK_ANSI_KeypadEnter: enter()
        case kVK_Tab: cycle(flags.contains(.shift) ? -1 : 1)
        case kVK_Space where searching.isEmpty: space()
        default:
            // Typing goes to the search field even after a click took the cursor out of it.
            guard page == nil || page == .meetings, flags.subtracting(.shift).isEmpty, !(window?.firstResponder is NSText),
                  let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return false }
            if page == .meetings { meetingQuery += text } else { query += text }
            focus += 1
        }
        return true
    }
}

// MARK: - Root

struct ShelfRoot: View {
    let model: MenuModel
    let recordings: Recordings
    var close: () -> Void
    @StateObject private var state: ShelfState

    init(model: MenuModel, recordings: Recordings, close: @escaping () -> Void = {}, state: ShelfState? = nil) {
        self.model = model
        self.recordings = recordings
        self.close = close
        _state = StateObject(wrappedValue: state ?? ShelfRoot.harnessState(model: model, recordings: recordings))
    }

    var body: some View {
        ShelfGlass(s: state)
            .background { ShelfEvents(state: state) }
            .onAppear {
                state.close = close
                withAnimation(Motion.reduced ? .easeOut(duration: 0.12) : .spring(response: 0.46, dampingFraction: 0.8)) { state.presented = true }
            }
    }

    // SHELF_PAGE opens a module at launch for screenshots: "meetings", or with "+preview", "+peek" or "+q=word" added.
    private static func harnessState(model: MenuModel, recordings: Recordings) -> ShelfState {
        let state = ShelfState(model: model, recordings: recordings)
        let parts = (ProcessInfo.processInfo.environment["SHELF_PAGE"] ?? "").split(separator: "+").map(String.init)
        if let id = parts.first, let module = Module(rawValue: id) {
            state.page = module
            if module != .settings { state.selected = module }
        }
        for extra in parts.dropFirst() {
            if extra.hasPrefix("select=") { state.selected = Module(rawValue: String(extra.dropFirst(7))) ?? state.selected }
            if extra.hasPrefix("q=") { state.query = String(extra.dropFirst(2)) }
            if extra.hasPrefix("group=") { state.group = Module.Group.allCases.first { $0.rawValue.lowercased().hasPrefix(extra.dropFirst(6).lowercased()) } }
        }
        if parts.contains("peek") { state.peek = state.selected }
        if state.page == .meetings {
            // The library scans in the background, so the first meeting is picked once it's there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                state.meeting = state.job?.folder ?? state.meetings.first?.folder
                if parts.contains("preview") {
                    state.preview = state.meetings.first { $0.summarized && $0.folder != state.job?.folder }?.folder
                    if let preview = state.preview { state.meeting = preview }
                }
            }
        }
        return state
    }
}

private struct ShelfGlass: View {
    @ObservedObject var s: ShelfState

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ShelfMetrics.radius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ShelfBody(s: s)
                .frame(height: ShelfMetrics.height)
                .clipShape(shape)
                .modifier(ShelfGlassEffect(shape: shape))
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .white.opacity(0.18)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                }
                .background { ShelfShadow(shape: shape) }
                .padding(s.insets)
                .offset(y: s.presented ? 0 : ShelfMetrics.height + s.insets.bottom + 40)
                .opacity(s.presented ? 1 : 0)
        }
        .tint(Palette.accent)
    }
}

private struct ShelfGlassEffect: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(ShelfMetrics.glassTint), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// The window is clear with no shadow of its own, so the shelf draws one, hollowed out so it can't darken the glass.
private struct ShelfShadow: View {
    let shape: RoundedRectangle

    var body: some View {
        shape.fill(Color.black)
            .shadow(color: .black.opacity(0.34), radius: 20, y: 9)
            .shadow(color: Palette.indigoDeep.opacity(0.3), radius: 2, y: 1)
            .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
            .compositingGroup()
    }
}

private struct ShelfBody: View {
    @ObservedObject var s: ShelfState

    var body: some View {
        VStack(spacing: 0) {
            ShelfTopBar(s: s)
                .frame(height: ShelfMetrics.barHeight)
                // Above the strip, so a card's glow passes behind the controls.
                .zIndex(1)
            ZStack {
                content
                    .id(s.page?.rawValue ?? "home")
                    .transition(.asymmetric(insertion: .offset(x: 60).combined(with: .opacity), removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ShelfHintBar(s: s)
                .frame(height: ShelfMetrics.hintHeight)
        }
    }

    @ViewBuilder private var content: some View {
        switch s.page {
        case nil: ShelfHomeStrip(s: s)
        case .meetings?: ShelfMeetingsStrip(s: s, recordings: s.recordings, model: s.model)
        case let module?: ShelfModulePage(s: s, module: module)
        }
    }
}

/// Watches the keyboard and the scroll wheel for the window it's in, ahead of the text field.
private struct ShelfEvents: NSViewRepresentable {
    let state: ShelfState

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.state = state
        return view
    }

    func updateNSView(_ view: EventView, context: Context) { view.state = state }

    static func dismantleNSView(_ view: EventView, coordinator: ()) { view.stop() }

    final class EventView: NSView {
        weak var state: ShelfState?
        private var monitors: [Any] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let key = event
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, key.window === window, let state = self.state else { return false }
                    return state.handle(key, in: window)
                }
                return handled ? nil : event
            } as Any)
            // A strip of cards should still scroll with a plain mouse wheel, so vertical turns become horizontal.
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let wheel = event
                let mine = MainActor.assumeIsolated { wheel.window != nil && wheel.window === self?.window }
                return mine ? Self.horizontal(event) : event
            } as Any)
        }

        func stop() {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        }

        nonisolated private static func horizontal(_ event: NSEvent) -> NSEvent {
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let copy = event.cgEvent?.copy() else { return event }
            copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: copy.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            copy.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: copy.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            copy.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            return NSEvent(cgEvent: copy) ?? event
        }
    }
}

// MARK: - Top bar

private struct ShelfTopBar: View {
    @ObservedObject var s: ShelfState
    @Namespace private var ns

    var body: some View {
        ZStack {
            if let page = s.page {
                Group {
                    if page == .meetings { ShelfMeetingsBar(s: s, ns: ns) } else { ShelfPageBar(s: s, module: page) }
                }
                .id(page)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                ShelfHomeBar(s: s, ns: ns)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, ShelfMetrics.inset)
        .padding(.top, 4)
    }
}

private struct ShelfHomeBar: View {
    @ObservedObject var s: ShelfState
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(size: 32)
                .shadow(color: Palette.indigoDeep.opacity(0.3), radius: 3, y: 1)
                .rotationEffect(.degrees(-6))
            ShelfSearch(placeholder: "Search utilities", text: $s.query, focus: s.focus)
            HStack(spacing: 2) {
                ShelfGroupChip(title: "All", symbol: nil, selected: s.group == nil, fill: Palette.accent, ns: ns) { s.setGroup(nil) }
                ForEach(Module.Group.allCases, id: \.self) { group in
                    ShelfGroupChip(title: group.rawValue, symbol: Self.symbol(group), selected: s.group == group, fill: Palette.accent, ns: ns) {
                        s.setGroup(group)
                    }
                }
            }
            Spacer(minLength: 8)
            ShelfActivity(s: s, model: s.model)
            ShelfBarDivider()
            ShelfGearButton { s.openInGremlin(.settings) }
        }
    }

    private static func symbol(_ group: Module.Group) -> String {
        switch group {
        case .capture: "record.circle"
        case .mac: "laptopcomputer"
        case .devices: "ipad.landscape.and.iphone"
        case .network: "network"
        }
    }
}

/// What's going on right now: a recording, a meeting being written up, or a problem that needs a look.
private struct ShelfActivity: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        HStack(spacing: 8) {
            if let recording = model.recording {
                Button { s.open(.meetings) } label: {
                    HStack(spacing: 7) {
                        LiveDot(color: .white, size: 6)
                            .frame(width: 10, height: 10)
                        TimelineView(.periodic(from: recording.started, by: 1)) { _ in
                            Text(Meetings.elapsed(since: recording.started))
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        }
                        SoundBars(live: recording.hearing, color: .white.opacity(0.9), count: 5, width: 2.5, height: 13)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(LinearGradient(colors: [Palette.coral.opacity(0.82), Palette.coral], startPoint: .top, endPoint: .bottom), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(ShelfPress())
                .help("Recording · open Meetings")
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if model.starting {
                ShelfActivityChip(title: "Starting", detail: nil, tint: Palette.coral, value: nil) { s.open(.meetings) }
            }
            if let job = s.job {
                ShelfActivityChip(title: job.title, detail: job.percent.map { "\($0)%" }, tint: job.tint,
                                  value: job.percent.map { Double($0) / 100 }) {
                    s.open(.meetings)
                    s.selectMeeting(job.folder)
                }
                .help("\(MeetingNotes.title(of: job.folder)) · open Meetings")
            }
            ForEach(model.banners.filter { $0.kind != .working }.prefix(1)) { banner in
                ShelfBannerChip(banner: banner, s: s)
            }
        }
        .animation(Motion.bouncy, value: model.recording != nil)
    }
}

private struct ShelfActivityChip: View {
    let title: String
    let detail: String?
    let tint: Color
    let value: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let value {
                    ShelfRing(value: value, tint: tint, size: 15, line: 2.5)
                } else {
                    ShelfSpinner(tint: tint, size: 15, line: 2.5)
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(ShelfHover())
    }
}

private struct ShelfBannerChip: View {
    let banner: MenuModel.Banner
    @ObservedObject var s: ShelfState

    var body: some View {
        let problem = banner.kind == .problem
        Button {
            guard let action = banner.action else { return }
            if case .dismissProblem = action { s.run(action) } else { s.run(action, closing: true) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: problem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(problem ? Palette.warn : Palette.good)
                Text(banner.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: 220)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(ShelfHover())
        .help(banner.detail)
    }
}

private struct ShelfPageBar: View {
    @ObservedObject var s: ShelfState
    let module: Module

    var body: some View {
        HStack(spacing: 12) {
            ShelfCrumb(module: module) { s.back() }
            Text(module.blurb)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ShelfPageAction(s: s, module: module)
            Button { s.openInGremlin(module) } label: {
                HStack(spacing: 6) {
                    Text("Open in Gremlin")
                    Image(systemName: "return").font(.system(size: 10.5, weight: .bold)).opacity(0.55)
                }
            }
            .buttonStyle(ShelfPill(kind: .soft, height: 30))
            .help("Open \(module.title) in Gremlin's window")
            ShelfBarDivider()
            ShelfGearButton { s.openInGremlin(.settings) }
        }
    }
}

private struct ShelfMeetingsBar: View {
    @ObservedObject var s: ShelfState
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 12) {
            ShelfCrumb(module: .meetings) { s.back() }
            ShelfSearch(placeholder: "Search meetings", text: $s.meetingQuery, focus: s.focus, width: 190)
            HStack(spacing: 2) {
                ForEach(ShelfState.Day.allCases, id: \.self) { day in
                    ShelfGroupChip(title: day.rawValue, symbol: nil, selected: s.day == day, fill: Palette.coral, ns: ns) { s.setDay(day) }
                }
            }
            Spacer(minLength: 8)
            ShelfRecordControls(s: s, model: s.model)
            ShelfBarDivider()
            ShelfIconButton(symbol: "arrow.up.forward.app", help: "Open Meetings in Gremlin") { s.openInGremlin(.meetings) }
            ShelfGearButton { s.openInGremlin(.settings) }
        }
    }
}

private struct ShelfCrumb: View {
    let module: Module
    let back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    AppIconView(size: 22)
                    Text("Gremlin").font(.system(size: 12.5, weight: .medium))
                }
                .padding(.leading, 10)
                .padding(.trailing, 11)
                .frame(height: 32)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(ShelfHover())
            .help("Back to the shelf")
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                IconTile(symbol: module.symbol, tint: module.tint, size: 24)
                Text(module.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1).fixedSize()
            }
        }
    }
}

private struct ShelfSearch: View {
    let placeholder: String
    @Binding var text: String
    let focus: Int
    var width: CGFloat = 214

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.accent))
            ShelfTextField(text: $text, placeholder: placeholder, focus: focus)
                .frame(height: 20)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 34)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .animation(Motion.snappy, value: text.isEmpty)
    }
}

/// An AppKit field, so the shelf can hand it the cursor on open and keep it there while the arrows move the cards.
private struct ShelfTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focus: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            field.requestFocus()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focus = -1

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    final class Field: NSTextField {
        private var wantsFocus = false

        func requestFocus() {
            wantsFocus = true
            focusIfPossible()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfPossible()
        }

        // SwiftUI can ask before the field is in a window, so the request waits until it is.
        private func focusIfPossible() {
            guard wantsFocus, let window else { return }
            wantsFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
            }
        }
    }
}

private struct ShelfGroupChip: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let fill: Color
    let ns: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .symbolEffect(.bounce, value: selected)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? AnyShapeStyle(ShelfMetrics.ink(fill)) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                if selected {
                    Capsule()
                        .fill(LinearGradient(colors: [fill.opacity(0.78), fill], startPoint: .top, endPoint: .bottom))
                        .shadow(color: fill.opacity(0.45), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "chip", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(ShelfHover())
    }
}

private struct ShelfGearButton: View {
    let action: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(hovering.value ? 60 : 0))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(ShelfHover())
        .onHover { on in withAnimation(Motion.bouncy) { hovering.value = on } }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

private struct ShelfIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(ShelfHover())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ShelfBarDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18) }
}

// MARK: - Hint bar

private struct ShelfHintBar: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    @ObservedObject var recordings: Recordings

    init(s: ShelfState) {
        self.s = s
        model = s.model
        recordings = s.recordings
    }

    private var hints: [(String, String)] {
        switch s.page {
        case nil: [("← →", "Move"), ("↩", "Open"), ("Space", s.peek == nil ? "Look closer" : "Close"), ("⌘1–9", "Jump")]
        case .meetings?: [("← →", "Move"), ("↩", "Open"), ("Space", s.preview == nil ? "Look closer" : "Close preview"), ("esc", "Back")]
        default: [("esc", "Back"), ("← →", "Next utility"), ("↩", "Open in Gremlin")]
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            ForEach(hints, id: \.0) { keys, label in ShelfHint(keys: keys, label: label) }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, ShelfMetrics.inset + 2)
        .padding(.bottom, 8)
        .animation(Motion.snappy, value: s.preview == nil)
        .animation(Motion.snappy, value: s.peek == nil)
    }

    @ViewBuilder private var trailing: some View {
        switch s.page {
        case nil:
            HStack(spacing: 6) {
                HoloPaw(size: 10, sticker: true)
                let all = Module.allCases.count
                Text(s.query.isEmpty && s.group == nil ? "\(all) utilities" : "\(s.modules.count) of \(all)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                ShelfHint(keys: "esc", label: "Close").padding(.leading, 12)
            }
        case .meetings?:
            let count = s.meetings.count
            Button { s.run(.showRecordings, closing: true) } label: {
                Text("\(count) \(count == 1 ? "recording" : "recordings") in Movies › Meetings")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(ShelfPress())
            .help("Show them in Finder")
        case let module?:
            HStack(spacing: 6) {
                if s.isLive(module) {
                    LiveDot(color: module.tint, size: 6).frame(width: 10, height: 10)
                } else {
                    Circle().fill(module.tint).frame(width: 6, height: 6)
                }
                ShelfLiveStatus(s: s, module: module)
            }
        }
    }
}

/// A module's status line, redrawn when the module's own model changes rather than only when the shelf does.
private struct ShelfLiveStatus: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var scrolling: ScrollDirection
    @ObservedObject var vpn: VPN
    @ObservedObject var cables: Cables
    let module: Module

    init(s: ShelfState, module: Module) {
        self.s = s
        scrolling = s.model.scrolling
        vpn = s.model.vpn
        cables = s.model.cables
        self.module = module
    }

    var body: some View {
        Text(s.status(module)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct ShelfHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(keys.split(separator: " ").map(String.init), id: \.self) { Keycap(text: $0, small: true) }
            }
            if !label.isEmpty { Text(label).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Metrics and colors

enum ShelfMetrics {
    static let radius: CGFloat = 30
    static let barHeight: CGFloat = 56
    static let hintHeight: CGFloat = 38
    static let inset: CGFloat = 22
    static let cardWidth: CGFloat = 228
    static let cardHeight: CGFloat = 268
    static let cardRadius: CGFloat = 18
    static let spacing: CGFloat = 14
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 30
    static let recordingWidth: CGFloat = 184
    static let previewWidth: CGFloat = 664
    static let peekWidth: CGFloat = 272
    static let selectedScale: CGFloat = 1.045
    static let height: CGFloat = barHeight + cardHeight + 18 + hintHeight

    static let glassTint = Color.dynamic(light: NSColor(hex: 0xF6F0FF, alpha: 0.3), dark: NSColor(hex: 0x1E1446, alpha: 0.5))
    // Solid, so the glass behind can't show through a card and gray it out.
    static let paper = Color.dynamic(light: .white, dark: NSColor(hex: 0x1C1838))
    static let paperTint = Color.dynamic(light: NSColor(hex: 0xF4F2FB), dark: NSColor(hex: 0x252046))
    static let hairline = Color.dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))
    static let transcriptInk = Color(hex: 0x17112F)

    static func isLight(_ color: Color) -> Bool { color == Palette.amber || color == Palette.lime }
    static func ink(_ color: Color) -> Color { isLight(color) ? Color.black.opacity(0.78) : .white }

    /// The same hue, dark enough to read as a glyph on white.
    static func deep(_ color: Color) -> Color {
        if color == Palette.amber { return Color(hex: 0xE28A00) }
        if color == Palette.lime { return Color(hex: 0x4C9A0A) }
        if color == Palette.mint { return Color(hex: 0x12A57A) }
        if color == Palette.teal { return Color(hex: 0x0E9CA8) }
        return color
    }
}

// MARK: - Card

struct ShelfCard<Content: View>: View {
    let title: String
    let status: String
    let symbol: String
    let tint: Color
    var width: CGFloat
    var footer: String?
    var footerAccessory: AnyView?
    var headerAccessory: AnyView?
    var selected: Bool
    var progress: Double?
    var live: Bool
    var index: Int
    var onTap: (() -> Void)?
    var onOpen: (() -> Void)?
    let content: Content

    @StateObject private var hoverBox = Box<CGPoint?>(nil)
    @StateObject private var appeared = Box(false)

    private var hover: CGPoint? { hoverBox.value }

    init(_ title: String, status: String, symbol: String, tint: Color, width: CGFloat = ShelfMetrics.cardWidth, footer: String? = nil,
         footerAccessory: AnyView? = nil, headerAccessory: AnyView? = nil, selected: Bool = false, progress: Double? = nil,
         live: Bool = false, index: Int = 0, onTap: (() -> Void)? = nil, onOpen: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.status = status
        self.symbol = symbol
        self.tint = tint
        self.width = width
        self.footer = footer
        self.footerAccessory = footerAccessory
        self.headerAccessory = headerAccessory
        self.selected = selected
        self.progress = progress
        self.live = live
        self.index = index
        self.onTap = onTap
        self.onOpen = onOpen
        self.content = content()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ShelfMetrics.cardRadius, style: .continuous) }

    private var tilt: (x: Double, y: Double) {
        guard let point = hover, !selected, !Motion.reduced else { return (0, 0) }
        let x = (point.x / width - 0.5) * 2
        let y = (point.y / ShelfMetrics.cardHeight - 0.5) * 2
        return (Double(-y) * 3, Double(x) * 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            ShelfCardHeader(title: title, status: status, symbol: symbol, tint: tint, progress: progress, live: live, accessory: headerAccessory)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            if footer != nil || footerAccessory != nil {
                ShelfCardFooter(text: footer ?? "", accessory: footerAccessory)
            }
        }
        .frame(width: width, height: ShelfMetrics.cardHeight)
        .background(ShelfMetrics.paper)
        .clipShape(shape)
        .overlay { shape.strokeBorder(ShelfMetrics.hairline, lineWidth: 0.5) }
        .overlay { shine }
        .overlay { shape.strokeBorder(Palette.holo, lineWidth: 2.5).opacity(selected ? 1 : 0) }
        .background {
            shape.fill(Palette.holo)
                .padding(-1)
                .blur(radius: 9)
                .opacity(selected ? 0.85 : 0)
        }
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status)")
        .accessibilityAction(named: "Open") { onOpen?() }
        .onTapGesture(count: 2) { onOpen?() }
        .simultaneousGesture(TapGesture().onEnded { onTap?() })
        .rotation3DEffect(.degrees(tilt.x), axis: (1, 0, 0), perspective: 0.5)
        .rotation3DEffect(.degrees(tilt.y), axis: (0, 1, 0), perspective: 0.5)
        .onContinuousHover(coordinateSpace: .local) { phase in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                switch phase {
                case .active(let point): hoverBox.value = point
                case .ended: hoverBox.value = nil
                }
            }
        }
        .scaleEffect(selected ? min(ShelfMetrics.selectedScale, (width + 16) / width) : (hover != nil ? 1.012 : 1))
        .shadow(color: .black.opacity(selected ? 0.22 : 0.13), radius: selected ? 12 : 6, y: selected ? 6 : 3)
        .animation(Motion.bouncy, value: selected)
        .animation(Motion.bouncy, value: width)
        .offset(y: appeared.value ? 0 : 36)
        .opacity(appeared.value ? 1 : 0)
        .onAppear {
            withAnimation(Motion.bouncy.delay(0.1 + Double(min(index, 8)) * 0.035)) { appeared.value = true }
        }
    }

    @ViewBuilder private var shine: some View {
        if let point = hover {
            RadialGradient(colors: [.white.opacity(0.2), .clear],
                           center: UnitPoint(x: point.x / width, y: point.y / ShelfMetrics.cardHeight), startRadius: 0, endRadius: 170)
                .blendMode(.plusLighter)
                .clipShape(shape)
                .allowsHitTesting(false)
        }
    }
}

private struct ShelfCardHeader: View {
    let title: String
    let status: String
    let symbol: String
    let tint: Color
    var progress: Double?
    var live = false
    var accessory: AnyView?

    var body: some View {
        let ink = ShelfMetrics.ink(tint)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 5) {
                    if live { LiveDot(color: ink, size: 5).frame(width: 8, height: 8) }
                    Text(status)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .contentTransition(.numericText())
                }
                .opacity(0.86)
            }
            Spacer(minLength: 4)
            if let accessory { accessory }
            ShelfBadge(symbol: symbol, tint: tint)
        }
        .foregroundStyle(ink)
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .frame(height: ShelfMetrics.headerHeight)
        .background {
            ZStack {
                tint
                LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.3)).frame(height: 0.5) }
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(ink.opacity(0.18))
                        Rectangle().fill(ink.opacity(0.85)).frame(width: g.size.width * min(1, max(0, progress)))
                    }
                }
                .frame(height: 3)
            }
        }
    }
}

private struct ShelfCardFooter: View {
    let text: String
    let accessory: AnyView?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let accessory { accessory }
        }
        .padding(.horizontal, 13)
        .frame(height: ShelfMetrics.footerHeight)
    }
}

/// The white tile in a header's corner, where Clipboard shows the source app's icon.
struct ShelfBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(ShelfMetrics.deep(tint).gradient)
            .frame(width: size, height: size)
            .background(.white, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

struct ShelfGhostCard: View {
    let title: String
    let detail: String
    let symbol: String
    var index = 0
    var action: (() -> Void)?
    @StateObject private var appeared = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfMetrics.cardRadius, style: .continuous)
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background(Color.primary.opacity(0.07), in: Circle())
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)
        }
        .frame(width: ShelfMetrics.cardWidth, height: ShelfMetrics.cardHeight)
        .background(Color.primary.opacity(0.03), in: shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])) }
        .contentShape(shape)
        .onTapGesture { action?() }
        .hoverLift()
        .offset(y: appeared.value ? 0 : 36)
        .opacity(appeared.value ? 1 : 0)
        .onAppear { withAnimation(Motion.bouncy.delay(0.1 + Double(index) * 0.035)) { appeared.value = true } }
    }
}

// MARK: - Strip

struct ShelfStrip<Content: View>: View {
    var target: String?
    let content: Content

    init(target: String?, @ViewBuilder content: () -> Content) {
        self.target = target
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: ShelfMetrics.spacing) { content }
                    .padding(.vertical, 9)
            }
            .contentMargins(.horizontal, ShelfMetrics.inset, for: .scrollContent)
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .mask(ShelfEdgeFade())
            .onAppear {
                guard let target else { return }
                DispatchQueue.main.async { proxy.scrollTo(target) }
            }
            .onChange(of: target) { _, target in
                guard let target else { return }
                withAnimation(Motion.snappy) { proxy.scrollTo(target) }
            }
        }
    }
}

extension View {
    /// Scrolling to a card leaves room for its ring and glow, and keeps it clear of the faded edges.
    func shelfScrollID<ID: Hashable>(_ id: ID) -> some View {
        padding(.horizontal, 30).id(id).padding(.horizontal, -30)
    }
}

/// Fades the strip into the glass at the sides, and reaches up and down behind the bars so a card's glow isn't cut off.
private struct ShelfEdgeFade: View {
    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 18)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
        }
        .padding(.top, -ShelfMetrics.barHeight)
        .padding(.bottom, -ShelfMetrics.hintHeight)
    }
}

struct ShelfEmpty: View {
    let title: String
    let detail: String
    @StateObject private var fanned = Box(false)

    var body: some View {
        HStack(spacing: 26) {
            ZStack {
                ForEach(0..<3) { i in
                    let o = CGFloat(i - 1)
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(ShelfMetrics.paper)
                        .frame(width: 62, height: 74)
                        .overlay(alignment: .top) {
                            UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11, style: .continuous)
                                .fill(i == 1 ? AnyShapeStyle(Palette.holo) : AnyShapeStyle(ShelfMetrics.paperTint))
                                .frame(height: 18)
                        }
                        .rotationEffect(.degrees(fanned.value ? Double(o) * 12 : 0))
                        .offset(x: fanned.value ? o * 24 : 0, y: fanned.value ? abs(o) * 6 : 0)
                        .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
                        .zIndex(i == 1 ? 1 : 0)
                }
            }
            .frame(width: 130, height: 100)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(Motion.bouncy.delay(0.08)) { fanned.value = true } }
    }
}

// MARK: - Controls

struct ShelfPill: ButtonStyle {
    enum Kind { case tint(Color), soft }
    var kind: Kind
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        ShelfPillBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct ShelfPillBody: View {
    @Environment(\.isEnabled) private var enabled
    let configuration: ButtonStyleConfiguration
    let kind: ShelfPill.Kind
    let height: CGFloat

    var body: some View {
        let fill: AnyShapeStyle
        let ink: Color
        switch kind {
        case .tint(let color):
            fill = AnyShapeStyle(LinearGradient(colors: [color.opacity(0.82), color], startPoint: .top, endPoint: .bottom))
            ink = ShelfMetrics.ink(color)
        case .soft:
            fill = AnyShapeStyle(Color.primary.opacity(0.08))
            ink = .primary
        }
        return configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// For buttons that draw their own surfaces: a slight dip when pressed.
struct ShelfPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// For quiet controls on the glass: a soft capsule under the pointer.
struct ShelfHover: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ShelfHoverBody(configuration: configuration) }
}

private struct ShelfHoverBody: View {
    let configuration: ButtonStyleConfiguration
    @StateObject private var hovering = Box(false)

    var body: some View {
        configuration.label
            .background(Color.primary.opacity(hovering.value ? 0.08 : 0), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering.value)
            .onHover { hovering.value = $0 }
    }
}

struct ShelfRing: View {
    let value: Double
    let tint: Color
    var size: CGFloat = 14
    var line: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0.02, value)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: value)
    }
}

/// A ring that turns while there's no percentage to show.
struct ShelfSpinner: View {
    let tint: Color
    var size: CGFloat = 14
    var line: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                Circle().stroke(Color.primary.opacity(0.14), lineWidth: line)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size, height: size)
        }
    }
}

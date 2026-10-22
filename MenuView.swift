import SwiftUI

// What the panel shows. AppDelegate fills it in from the features and carries out its actions.
@MainActor
final class MenuModel: ObservableObject {
    enum Page {
        case main
        case restart
        case universalControl
        case settings
    }

    enum Action: Equatable {
        case record(audioOnly: Bool)
        case stopRecording
        case open(URL)
        case openTranscript(URL)
        case dismissTranscript
        case fix(URL)
        case dismissProblem
        case showRecordings
        case grabText
        case pickColor
        case plainPaste
        case fixFocus
        case keepAwake(Int)
        case toggleSidecar
        case setSwitch(String, Bool)
        case resetUniversalControl(UniversalControlWatcher.Target)
        case startPairing
        case stopPairing
        case unpair
        case restart(Int)
        case restartAll
        case setLogin(Bool)
        case setLanguage(String?)
        case quit
    }

    struct Recording: Equatable {
        var started: Date
        var audioOnly: Bool
        var hearing: Bool
    }

    struct Banner: Equatable, Identifiable {
        enum Kind {
            case working
            case done
            case problem
        }

        var id: String
        var kind: Kind
        var symbol = "exclamationmark"
        var title: String
        var detail: String
        var button: String?
        var action: Action?
        var dismiss: Action?
    }

    struct IPad: Equatable {
        enum State {
            case nearby
            case connecting
            case disconnecting
            case connected
            case away
        }

        var name: String
        var state: State
        var seen: Date?
    }

    struct Watcher: Equatable {
        var isOn = false
        var tone = Tone.off
        var status = ""
        var detail = ""
        var lastReset = ""
    }

    enum Pairing: Equatable {
        case unpaired
        case pairing
        case paired(name: String, status: String)
    }

    static let awakeStops = ["Off", "30m", "1h", "2h", "4h", "∞"]
    static let reachable = "reachable"
    static let unreachable = "not reachable"
    static let languages: [(name: String, code: String?)] = [
        ("Automatic", nil), ("English", "en"), ("Turkish", "tr"), ("German", "de"), ("French", "fr"), ("Spanish", "es"),
    ]

    @Published var page = Page.main
    @Published var recording: Recording?
    @Published var starting = false
    @Published var banners: [Banner] = []
    @Published var awakeStop = 0
    @Published var awakeText = "Off"
    @Published var awakeOthers: [String] = []
    @Published var ipad: IPad?
    @Published var watcher = Watcher()
    @Published var pairing = Pairing.unpaired
    @Published var thisMac = "This Mac"
    @Published var switches: [String: Bool] = [:]
    @Published var accessibility = false
    @Published var login = false
    @Published var language: String?
    @Published var restarted: Set<Int> = []
    // The most the glass can grow before it would run off the bottom of the screen.
    @Published var maxHeight = CGFloat.infinity
    @Published var contentHeight: CGFloat = 0
    @Published var confirmRestartAll = false

    var perform: (Action) -> Void = { _ in }

    func go(_ page: Page) {
        // A long, soft ease-out that settles without overshooting.
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)) { self.page = page }
    }
}

struct MenuView: View {
    @ObservedObject var model: MenuModel
    @Environment(\.glass) private var look

    private static let padding: CGFloat = 18

    var body: some View {
        let room = model.maxHeight - Self.padding * 2
        Group {
            // Only when the screen is too short: a scroll view clips the shadows inside and the slide between pages.
            if model.contentHeight > room {
                ScrollView { pages }.frame(height: room)
            } else {
                pages
            }
        }
        .padding(Self.padding)
        .legible()
        .surface(.panel)
    }

    private var pages: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.page {
            case .main: MainPage(model: model).transition(.page(from: .leading))
            case .restart: RestartPage(model: model).transition(.page(from: .trailing))
            case .universalControl: UniversalControlPage(model: model).transition(.page(from: .trailing))
            case .settings: SettingsPage(model: model).transition(.page(from: .trailing))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.contentHeight = $0 }
    }
}

private struct PageSlide: ViewModifier {
    let x: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: x).blur(radius: blur).opacity(opacity)
    }
}

private extension AnyTransition {
    // The old page goes at once and the new one slides in, so the glass morphs straight to the new height.
    static func page(from edge: HorizontalEdge) -> AnyTransition {
        .asymmetric(insertion: .modifier(active: PageSlide(x: edge == .leading ? -28 : 28, blur: 5, opacity: 0),
                                         identity: PageSlide(x: 0, blur: 0, opacity: 1)),
                    removal: .identity)
    }
}

// MARK: Main page

private struct MainPage: View {
    @ObservedObject var model: MenuModel
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecordStrip(model: model)
            ForEach(model.banners) { BannerRow(banner: $0, perform: model.perform) }
            ToolsRow(perform: model.perform)
            KeepAwakeSection(model: model)
            if let ipad = model.ipad { IPadCard(ipad: ipad, perform: model.perform) }
            UniversalControlCard(model: model)
            RestartSection(model: model)
            Rectangle().fill(look.fill(0.12)).frame(height: 1)
            HStack {
                Button("Show Recordings") { model.perform(.showRecordings) }
                Spacer()
                Button { model.go(.settings) } label: {
                    HStack(spacing: 4) {
                        Text("Settings")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                }
            }
            .buttonStyle(PressStyle())
            .font(.system(size: 13))
            .padding(.horizontal, 2)
        }
    }
}

// The record controls, or the running recording. Shortcuts live in the tooltips so the strip stays roomy.
private struct RecordStrip: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        HStack(spacing: 10) {
            if let recording = model.recording {
                RecordingNow(recording: recording) { model.perform(.stopRecording) }
            } else if model.starting {
                Spinner(size: 22, line: 3)
                Text("Starting…").font(.system(size: 15, weight: .bold))
                Spacer()
            } else {
                Text("Record").font(.system(size: 15, weight: .bold))
                Spacer()
                Button { model.perform(.record(audioOnly: true)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                        Text("Audio")
                    }
                }
                .buttonStyle(PillStyle(kind: .control, height: 44, font: 13))
                .help("Record audio only  ⌃⌥⌘A")
                Button { model.perform(.record(audioOnly: false)) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(.white).frame(width: 10, height: 10)
                        Text("Screen")
                    }
                }
                .buttonStyle(PillStyle(kind: .record, height: 44, font: 13))
                .help("Record the screen and audio  ⌃⌥⌘R")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, model.recording == nil ? 10 : 8)
        .frame(height: 64)
        .surface(.strip)
    }
}

private struct RecordingNow: View {
    @Environment(\.glass) private var look
    let recording: MenuModel.Recording
    let stop: () -> Void

    var body: some View {
        Circle().fill(Tone.danger.color).frame(width: 10, height: 10).shadow(color: Tone.danger.color, radius: 5)
        VStack(alignment: .leading, spacing: 1) {
            TimelineView(.periodic(from: recording.started, by: 1)) { _ in
                Text(Meetings.elapsed(since: recording.started)).font(.system(size: 16, weight: .bold).monospacedDigit())
            }
            Text(recording.audioOnly ? "Audio only" : "Screen and audio").font(.system(size: 11)).foregroundStyle(look.sub)
        }
        Spacer(minLength: 0)
        LevelBars(active: recording.hearing)
        Spacer(minLength: 0)
        Button(action: stop) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Tone.danger.color).frame(width: 16, height: 16)
                .frame(width: 48, height: 48)
                .surface(.prominent)
        }
        .buttonStyle(PressStyle())
        .help("Stop recording  ⌃⌥⌘R")
        .accessibilityLabel("Stop recording")
    }
}

// Moves while something is being heard, and lies low through silence.
private struct LevelBars: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<6) { index in
                    let wave = sin(time * 7.5 + Double(index) * 1.3) * 0.5 + 0.5
                    Capsule().fill(Tone.warning.color)
                        .frame(width: 3, height: 26 * (active ? 0.3 + 0.7 * wave : 0.16))
                }
            }
            .frame(height: 28)
            .animation(.easeOut(duration: 0.3), value: active)
        }
    }
}

private struct BannerRow: View {
    let banner: MenuModel.Banner
    let perform: (MenuModel.Action) -> Void
    @Environment(\.glass) private var look

    var body: some View {
        HStack(spacing: 10) {
            switch banner.kind {
            case .working: Spinner(size: 24, line: 3)
            case .done: Badge(symbol: "checkmark", tone: .good)
            case .problem: Badge(symbol: banner.symbol, tone: .warning)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(banner.detail).font(.system(size: 11)).foregroundStyle(look.sub).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let title = banner.button, let action = banner.action {
                Button(title) { perform(action) }.buttonStyle(PillStyle(kind: banner.kind == .done ? .prominent : .control))
            }
            if let dismiss = banner.dismiss {
                Button { perform(dismiss) } label: { Image(systemName: "xmark") }.buttonStyle(RoundStyle(size: 26))
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .surface(banner.kind == .problem ? .warning : .card)
    }
}

private struct ToolsRow: View {
    let perform: (MenuModel.Action) -> Void
    @Environment(\.glass) private var look

    private struct Tool {
        let title: String
        let keys: String
        let symbol: String
        let action: MenuModel.Action
    }

    private let tools = [
        Tool(title: "Grab Text", keys: "⇧⌘1", symbol: "text.viewfinder", action: .grabText),
        Tool(title: "Pick Color", keys: "⇧⌘2", symbol: "eyedropper", action: .pickColor),
        Tool(title: "Plain Paste", keys: "⌃⌥⌘V", symbol: "doc.on.clipboard", action: .plainPaste),
        Tool(title: "Fix Focus", keys: "⌃⌥⌘F", symbol: "scope", action: .fixFocus),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tools, id: \.title) { tool in
                Button { perform(tool.action) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tool.symbol).font(.system(size: 19, weight: .medium))
                            .frame(width: 48, height: 48)
                            .surface(.control)
                        Text(tool.title).font(.system(size: 12, weight: .semibold))
                        Text(tool.keys).font(.system(size: 11)).foregroundStyle(look.sub)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PressStyle())
            }
        }
    }
}

private struct KeepAwakeSection: View {
    @ObservedObject var model: MenuModel
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keep Awake").font(.system(size: 15, weight: .bold))
                Spacer()
                Text(model.awakeText).font(.system(size: 12)).foregroundStyle(look.sub)
            }
            StopSlider(count: MenuModel.awakeStops.count, value: model.awakeStop) { model.perform(.keepAwake($0)) }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .accessibilityElement()
                .accessibilityLabel("Keep Awake")
                .accessibilityValue(model.awakeText)
                .accessibilityAdjustableAction { direction in
                    let last = MenuModel.awakeStops.count - 1
                    switch direction {
                    case .increment: model.perform(.keepAwake(min(model.awakeStop + 1, last)))
                    case .decrement: model.perform(.keepAwake(max(model.awakeStop - 1, 0)))
                    @unknown default: break
                    }
                }
            HStack(spacing: 0) {
                ForEach(MenuModel.awakeStops.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 0) }
                    Button(MenuModel.awakeStops[index]) {
                        withAnimation(.snappy) { model.perform(.keepAwake(index)) }
                    }
                    .font(.system(size: 11, weight: index == model.awakeStop ? .bold : .medium))
                    .foregroundStyle(index == model.awakeStop ? look.ink : look.sub)
                    .frame(width: 44)
                    .buttonStyle(PressStyle())
                }
            }
            if !model.awakeOthers.isEmpty {
                Text("Also kept awake by " + ListFormatter.localizedString(byJoining: model.awakeOthers))
                    .font(.system(size: 11)).foregroundStyle(look.sub)
            }
        }
    }
}

private struct StopSlider: View {
    @Environment(\.glass) private var look
    let count: Int
    let value: Int
    let pick: (Int) -> Void
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var dragging: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let step = width / CGFloat(count - 1)
            let x = dragging ?? CGFloat(value) * step
            ZStack(alignment: .leading) {
                Capsule().fill(look.fill(0.15)).frame(height: 8)
                Capsule().fill(Tone.busy.color).frame(width: max(8, x + 4), height: 8)
                Circle().fill(.white).frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1)
                    .offset(x: x - 13)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { drag, dragging, _ in dragging = min(max(0, drag.location.x), width) }
                .onEnded { drag in
                    let stop = Int((min(max(0, drag.location.x), width) / step).rounded())
                    withAnimation(.snappy) { pick(stop) }
                })
        }
        .frame(height: 26)
    }
}

private struct IPadCard: View {
    let ipad: MenuModel.IPad
    let perform: (MenuModel.Action) -> Void
    @Environment(\.glass) private var look

    private var status: (tone: Tone, text: String) {
        switch ipad.state {
        case .nearby: (.good, "Nearby · ready to connect")
        case .connecting: (.busy, "Connecting…")
        case .disconnecting: (.busy, "Disconnecting…")
        case .connected: (.busy, "Connected as a display")
        case .away: (.off, ipad.seen.map { "Not nearby · seen \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" }
            ?? "Not nearby")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            TileIcon(symbol: "ipad.landscape")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ipad.name) \(Text("· Sidecar ⌃⌥⌘S").fontWeight(.medium).foregroundStyle(look.sub))")
                    .font(.system(size: 13, weight: .bold)).lineLimit(1)
                HStack(spacing: 6) {
                    Dot(tone: status.tone)
                    Text(status.text).lineLimit(1)
                }
                .font(.system(size: 11)).foregroundStyle(look.sub)
            }
            Spacer(minLength: 0)
            switch ipad.state {
            case .connecting, .disconnecting: Spinner()
            case .nearby: Button("Connect") { perform(.toggleSidecar) }.buttonStyle(PillStyle(kind: .primary))
            case .connected: Button("Disconnect") { perform(.toggleSidecar) }.buttonStyle(PillStyle())
            case .away: Button("Connect") {}.buttonStyle(PillStyle()).disabled(true)
            }
        }
        .padding(12)
        .surface(.card)
    }
}

private struct UniversalControlCard: View {
    @ObservedObject var model: MenuModel
    @Environment(\.glass) private var look

    private var isPaired: Bool {
        if case .paired = model.pairing { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TileIcon(symbol: "rectangle.on.rectangle")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Universal Control").font(.system(size: 13, weight: .bold))
                    HStack(spacing: 6) {
                        Dot(tone: model.watcher.tone)
                        Text(model.watcher.isOn ? model.watcher.status : "The watcher is off").lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(look.sub)
                }
                Spacer(minLength: 0)
                GlassSwitch(label: "Universal Control Watcher", isOn: model.watcher.isOn) {
                    model.perform(.setSwitch(AppSwitch.universalControlWatcher, !model.watcher.isOn))
                }
            }
            HStack(spacing: 8) {
                Text(model.watcher.lastReset).font(.system(size: 11)).foregroundStyle(look.sub).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(isPaired ? "Reset here" : "Reset now") { model.perform(.resetUniversalControl(.local)) }
                    .buttonStyle(PillStyle())
                    .help(isPaired ? "Resets Universal Control on this Mac. The › page can reset the other Mac too." : "")
                Button { model.go(.universalControl) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(RoundStyle())
                    .help("Devices, pairing and where to reset")
                    .accessibilityLabel("Universal Control details")
            }
        }
        .padding(12)
        .surface(.card)
    }
}

private struct RestartSection: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restart").font(.system(size: 15, weight: .bold))
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    let item = Restart.items[index]
                    chip(item.short, symbol: model.restarted.contains(index) ? "checkmark" : item.symbol) {
                        model.perform(.restart(index))
                    }
                    .help("\(item.title): \(item.hint)")
                }
                chip("More", symbol: "ellipsis") { model.go(.restart) }
            }
        }
    }

    private func chip(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .surface(.control, radius: 16)
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: Pages

private struct PageHeader<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(RoundStyle()).accessibilityLabel("Back")
            Text(title).font(.system(size: 17, weight: .bold))
            Spacer(minLength: 0)
            trailing
        }
    }
}

private struct SectionTitle: View {
    let text: String
    @Environment(\.glass) private var look

    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(look.sub)
    }
}

private struct RestartPage: View {
    @ObservedObject var model: MenuModel
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Restart", back: { model.go(.main) }) {
                Text("macOS starts each one again").font(.system(size: 12)).foregroundStyle(look.sub)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(Restart.items.indices, id: \.self) { index in
                    tile(index)
                }
            }
            let everything = model.restarted.count == Restart.items.count
            Button(model.confirmRestartAll ? "Click Again to Restart All" : everything ? "Everything restarted" : "Restart All") {
                model.perform(.restartAll)
            }
                .buttonStyle(PillStyle(kind: .danger, height: 42, font: 13, wide: true))
        }
    }

    private func tile(_ index: Int) -> some View {
        let item = Restart.items[index]
        let done = model.restarted.contains(index)
        return Button { model.perform(.restart(index)) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: item.symbol).font(.system(size: 17, weight: .medium)).frame(height: 22)
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(done ? "Restarted just now" : item.hint)
                    .font(.system(size: 11, weight: done ? .semibold : .regular))
                    .foregroundStyle(done ? Tone.good.color : look.sub)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.control, radius: 16)
        }
        .buttonStyle(PressStyle())
    }
}

private struct UniversalControlPage: View {
    @ObservedObject var model: MenuModel
    @Environment(\.glass) private var look

    private struct Device: Identifiable {
        let id: String
        let symbol: String
        let detail: String
        let tone: Tone
    }

    private var devices: [Device] {
        var devices = [Device(id: model.thisMac, symbol: "laptopcomputer",
                              detail: model.watcher.isOn ? "This Mac · watching" : "This Mac · watcher off",
                              tone: model.watcher.isOn ? .good : .off)]
        if let ipad = model.ipad {
            let detail = switch ipad.state {
            case .connected: "iPad · a display for this Mac"
            case .away: "iPad · not nearby"
            default: "iPad · nearby"
            }
            devices.append(Device(id: ipad.name, symbol: "ipad", detail: detail, tone: ipad.state == .away ? .off : .good))
        }
        if case .paired(let name, let status) = model.pairing {
            let tone: Tone = switch status {
            case MenuModel.reachable: .good
            case MenuModel.unreachable: .warning
            default: .off
            }
            devices.append(Device(id: name, symbol: "macmini", detail: "Paired · \(status)", tone: tone))
        }
        return devices
    }

    private var targets: [(String, UniversalControlWatcher.Target)] {
        guard case .paired(let name, _) = model.pairing else { return [("This Mac", .local)] }
        return [("This Mac", .local), (name, .remote), ("Both", .both)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Universal Control", back: { model.go(.main) }) {
                GlassSwitch(label: "Universal Control Watcher", isOn: model.watcher.isOn) {
                    model.perform(.setSwitch(AppSwitch.universalControlWatcher, !model.watcher.isOn))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Dot(tone: model.watcher.tone)
                    Text(model.watcher.isOn ? model.watcher.status : "The watcher is off").font(.system(size: 15, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.watcher.detail).font(.system(size: 12)).foregroundStyle(look.sub).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.card)

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "Devices")
                ForEach(devices) { device in
                    HStack(spacing: 10) {
                        TileIcon(symbol: device.symbol)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.id).font(.system(size: 13, weight: .semibold))
                            Text(device.detail).font(.system(size: 11)).foregroundStyle(look.sub)
                        }
                        Spacer(minLength: 0)
                        Dot(tone: device.tone)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Reset now")
                HStack(spacing: 8) {
                    ForEach(targets, id: \.0) { target in
                        Button(target.0) { model.perform(.resetUniversalControl(target.1)) }
                            .buttonStyle(PillStyle(height: 34, wide: true))
                    }
                }
                Text(model.watcher.lastReset).font(.system(size: 11)).foregroundStyle(look.sub)
            }

            pairingCard
        }
    }

    private var pairingCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                switch model.pairing {
                case .paired(let name, _):
                    Text("Paired with \(name)").font(.system(size: 13, weight: .semibold))
                    Text("Either Mac can reset the other").font(.system(size: 11)).foregroundStyle(look.sub)
                case .unpaired:
                    Text("Not paired").font(.system(size: 13, weight: .semibold))
                    Text("Pair to let either Mac reset the other").font(.system(size: 11)).foregroundStyle(look.sub)
                case .pairing:
                    Text("Waiting for the other Mac").font(.system(size: 13, weight: .semibold))
                    Text("Choose Pair Another Mac… there too, then compare the codes both Macs show")
                        .font(.system(size: 11)).foregroundStyle(look.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            switch model.pairing {
            case .paired: Button("Unpair") { model.perform(.unpair) }.buttonStyle(PillStyle())
            case .unpaired: Button("Pair Another Mac…") { model.perform(.startPairing) }.buttonStyle(PillStyle(kind: .primary))
            case .pairing:
                Spinner()
                Button("Cancel") { model.perform(.stopPairing) }.buttonStyle(PillStyle())
            }
        }
        .padding(12)
        .surface(.card)
    }
}

private struct SettingsPage: View {
    @ObservedObject var model: MenuModel
    @Environment(\.glass) private var look

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Settings", back: { model.go(.main) }) { EmptyView() }
            group("Meetings") {
                toggle("Offer to record calls", "A panel asks when a call takes the mic", key: AppSwitch.offerToRecordCalls)
                row("Transcript language", "whisper detects it on Automatic") {
                    Menu {
                        ForEach(MenuModel.languages, id: \.name) { language in
                            Button(language.name) { model.perform(.setLanguage(language.code)) }
                        }
                    } label: {
                        Text(valueText(MenuModel.languages.first { $0.code == model.language }?.name ?? model.language ?? "Automatic"))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                row("Recordings", "Transcripts and recordings") {
                    Button { model.perform(.showRecordings) } label: { Text(valueText("Movies › Meetings")) }.buttonStyle(PressStyle())
                }
            }
            group("Fixes") {
                toggle("Auto-Fix Lost Focus", model.accessibility ? "Gives keystrokes back to the front window" : "Needs Accessibility",
                       key: AppSwitch.autoFixFocus)
                toggle("Fix Stuck Notification Center", "Restarts it after 30 s at full CPU", key: AppSwitch.notificationCenterWatchdog)
                toggle("Universal Control Watcher", "Resets it when a device gives up", key: AppSwitch.universalControlWatcher)
            }
            group("General") {
                row("Start at Login", nil) {
                    GlassSwitch(label: "Start at Login", isOn: model.login) { model.perform(.setLogin(!model.login)) }
                }
            }
            HStack {
                Text("Gremlin \(version) · log in ~/Library/Logs").font(.system(size: 11)).foregroundStyle(look.sub)
                Spacer()
                Button("Quit Gremlin ⌘Q") { model.perform(.quit) }.buttonStyle(PillStyle(kind: .danger))
            }
        }
    }

    private func valueText(_ value: String) -> String {
        value + " ›"
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            VStack(alignment: .leading, spacing: 12) { rows() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.card)
        }
    }

    private func row(_ title: String, _ detail: String?, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(look.sub) }
            }
            Spacer(minLength: 0)
            trailing().font(.system(size: 12)).foregroundStyle(look.sub)
        }
    }

    private func toggle(_ title: String, _ detail: String, key: String) -> some View {
        row(title, detail) {
            GlassSwitch(label: title, isOn: model.switches[key] ?? false) { model.perform(.setSwitch(key, !(model.switches[key] ?? false))) }
        }
    }
}

// The settings keys, shared by the panel and the features they switch.
enum AppSwitch {
    static let autoFixFocus = "autoFixFocus"
    static let notificationCenterWatchdog = "notificationCenterWatchdog"
    static let universalControlWatcher = "universalControlWatcher"
    static let offerToRecordCalls = "offerToRecordCalls"
}

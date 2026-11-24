import AppKit
import SwiftUI

// The live widgets on Home, plus the pieces Home shares with the Tools and Keep Awake screens. Each widget wears its
// module's color: vivid for the ones you reach for, paper for the ones you glance at. Its header opens the module,
// and its buttons act in place.

// MARK: - Shared

enum ToolsCatalog {
    struct Tool: Identifiable {
        let id: String
        let title: String
        let keys: String
        let symbol: String
        let action: MenuModel.Action
        let hint: String
        let detail: String
    }

    static let all = [
        Tool(id: "grab", title: "Grab Text", keys: "⇧⌘1", symbol: "text.viewfinder", action: .grabText,
             hint: "Copy the text in any part of the screen",
             detail: "Drag over it, or press Space to pick a window. A QR code or barcode is copied as what it says."),
        Tool(id: "color", title: "Pick Color", keys: "⇧⌘2", symbol: "eyedropper", action: .pickColor,
             hint: "Copy a color as hex",
             detail: "Opens the system color loupe. The color you click goes to the clipboard as sRGB hex."),
        Tool(id: "paste", title: "Plain Paste", keys: "⌃⌥⌘V", symbol: "doc.on.clipboard", action: .plainPaste,
             hint: "Paste without formatting",
             detail: "Strips the fonts, colors and links from what's on the clipboard, then pastes it."),
        Tool(id: "focus", title: "Fix Focus", keys: "⌃⌥⌘F", symbol: "scope", action: .fixFocus,
             hint: "Give keystrokes back to the front window",
             detail: "For when the menu bar shows one app but typing goes nowhere, often after switching Spaces."),
    ]

    static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}

/// What Keep Awake says about itself, in the widget, the screen and the greeting.
@MainActor
enum KeepAwakeInfo {
    static var last: Int { MenuModel.awakeStops.count - 1 }

    static func value(_ stop: Int) -> String { MenuModel.awakeStops[min(max(stop, 0), last)] }

    /// "until 10:41 AM", for under the dial.
    static func caption(_ model: MenuModel) -> String {
        switch model.awakeStop {
        case 0: "sleeps as usual"
        case last...: "until you stop it"
        default: lowered(model.awakeText)
        }
    }

    static func others(_ model: MenuModel) -> String? {
        guard !model.awakeOthers.isEmpty else { return nil }
        let names = model.awakeOthers.count > 2 ? Array(model.awakeOthers.prefix(2)) + ["\(model.awakeOthers.count - 2) more"] : model.awakeOthers
        return ListFormatter.localizedString(byJoining: names)
    }

    nonisolated static func lowered(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }
}

struct HomeSpinner: View {
    var tint: Color
    var size: CGFloat = 14
    var line: CGFloat = 2

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: line)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size - line, height: size - line)
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Keep Awake dial

/// The Keep Awake stops on a gauge, Off at the bottom left and ∞ at the bottom right. With `pick`, the knob drags.
struct KeepAwakeDial: View {
    let stop: Int
    let value: String
    let caption: String
    var onColor = false
    var labels = false
    var pick: ((Int) -> Void)?
    @StateObject private var dragging = Box<Double?>(nil)

    fileprivate static let start = 120.0
    fileprivate static let sweep = 300.0
    private var last: Int { KeepAwakeInfo.last }

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            dial(size: size)
                .frame(width: size, height: size)
                .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .accessibilityElement()
        .accessibilityLabel("Keep Awake")
        .accessibilityValue("\(value), \(caption)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: pick?(min(stop + 1, last))
            case .decrement: pick?(max(stop - 1, 0))
            @unknown default: break
            }
        }
    }

    private func dial(size: CGFloat) -> some View {
        let line = max(8, size * 0.07)
        let radius = size / 2 - line / 2 - (labels ? 2 : 0)
        let fraction = dragging.value ?? Double(stop) / Double(last)
        let fill: AnyShapeStyle = onColor ? AnyShapeStyle(Color.white)
            : AnyShapeStyle(LinearGradient(colors: Module.keepAwake.fill, startPoint: .top, endPoint: .bottom))
        return ZStack {
            DialArc(fraction: 1, radius: radius)
                .stroke(onColor ? Color.white.opacity(0.24) : Palette.amber.opacity(0.17), style: StrokeStyle(lineWidth: line, lineCap: .round))
            DialArc(fraction: fraction, radius: radius)
                .stroke(fill, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .opacity(fraction > 0.001 ? 1 : 0)
            ForEach(0...last, id: \.self) { index in
                let reached = Double(index) / Double(last) <= fraction + 0.001
                Circle()
                    .fill(reached ? (onColor ? Palette.amber.opacity(0.7) : Color.white.opacity(0.8)) : (onColor ? Color.white.opacity(0.55) : Color.primary.opacity(0.22)))
                    .frame(width: line * 0.32, height: line * 0.32)
                    .offset(Self.point(Double(index) / Double(last), radius))
            }
            Circle()
                .fill(.white)
                .frame(width: line * 1.75, height: line * 1.75)
                .overlay { Circle().strokeBorder(onColor ? Color.clear : Palette.amber, lineWidth: max(2, line * 0.18)) }
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .offset(Self.point(fraction, radius))
            VStack(spacing: size * 0.005) {
                Text(value)
                    .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.system(size: max(11, size * 0.07), weight: .semibold))
                    .foregroundStyle(onColor ? AnyShapeStyle(Color.white.opacity(0.88)) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: size * 0.62)
            }
            if labels { stopLabels(radius: radius - line - size * 0.075, font: min(14, max(11, size * 0.05))) }
            if pick != nil {
                RingShape(radius: radius, width: line * 2.6)
                    .fill(Color.white.opacity(0.001))
                    .gesture(drag(size: size))
            }
        }
        .animation(Motion.bouncy, value: stop)
    }

    private func stopLabels(radius: CGFloat, font: CGFloat) -> some View {
        ForEach(0...last, id: \.self) { index in
            Button { pick?(index) } label: {
                Text(KeepAwakeInfo.value(index))
                    .font(.system(size: font, weight: index == stop ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(index == stop ? AnyShapeStyle(Ink.amber) : AnyShapeStyle(.secondary))
                    .fixedSize()
                    .frame(width: 44, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .offset(Self.point(Double(index) / Double(last), radius))
        }
    }

    private func drag(size: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let dx = drag.location.x - size / 2, dy = drag.location.y - size / 2
                var angle = atan2(dy, dx) * 180 / .pi - Self.start
                while angle < 0 { angle += 360 }
                // The gap at the bottom snaps to whichever end is nearer.
                if angle > Self.sweep { angle = angle > Self.sweep + (360 - Self.sweep) / 2 ? 0 : Self.sweep }
                dragging.value = angle / Self.sweep
            }
            .onEnded { _ in
                guard let fraction = dragging.value else { return }
                let picked = Int((fraction * Double(last)).rounded())
                withAnimation(Motion.bouncy) {
                    dragging.value = nil
                    pick?(picked)
                }
            }
    }

    fileprivate static func point(_ fraction: Double, _ radius: CGFloat) -> CGSize {
        let angle = (start + sweep * fraction) * .pi / 180
        return CGSize(width: radius * cos(angle), height: radius * sin(angle))
    }
}

private struct DialArc: Shape {
    var fraction: Double
    let radius: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(KeepAwakeDial.start),
                    endAngle: .degrees(KeepAwakeDial.start + KeepAwakeDial.sweep * max(0.0005, fraction)), clockwise: false)
        return path
    }
}

/// The band along the dial's track, so a drag starts only on the ring and the stop labels inside stay clickable.
private struct RingShape: Shape {
    let radius: CGFloat
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        return path.strokedPath(StrokeStyle(lineWidth: width))
    }
}

// MARK: - Tile

private struct HomeVividKey: EnvironmentKey { static let defaultValue = false }

private extension EnvironmentValues {
    var homeVivid: Bool {
        get { self[HomeVividKey.self] }
        set { self[HomeVividKey.self] = newValue }
    }
}

struct HomeTile<Trailing: View, Content: View>: View {
    let module: Module
    var title: String?
    var vivid: Bool
    let trailing: Trailing
    let content: Content

    init(_ module: Module, title: String? = nil, vivid: Bool = false, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.module = module
        self.title = title
        self.vivid = vivid
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeTileHeader(module: module, title: title ?? module.title, vivid: vivid) { trailing }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(vivid ? Color.white : Color.primary)
        .environment(\.homeVivid, vivid)
        .background {
            if vivid {
                VividSurface(colors: module.fill, symbol: module.symbol)
            } else {
                PaperSurface(tint: module.tint)
            }
        }
    }
}

extension HomeTile where Trailing == EmptyView {
    init(_ module: Module, title: String? = nil, vivid: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(module, title: title, vivid: vivid, trailing: { EmptyView() }, content: content)
    }
}

private struct HomeTileHeader<Trailing: View>: View {
    let module: Module
    let title: String
    let vivid: Bool
    @ViewBuilder var trailing: Trailing
    @EnvironmentObject private var navigator: Navigator
    @StateObject private var hovering = Box(false)

    // A narrow widget drops its note first, then its icon, so the title stays readable.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(icon: true, note: true)
            row(icon: true, note: false)
            row(icon: false, note: false)
        }
        .frame(height: 24)
    }

    private func row(icon: Bool, note: Bool) -> some View {
        HStack(spacing: 6) {
            Button { navigator.go(module) } label: {
                HStack(spacing: 7) {
                    if icon { symbol }
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            Spacer(minLength: 4)
            if note { trailing }
            Button { navigator.go(module) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(vivid ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(vivid ? Color.white.opacity(hovering.value ? 0.34 : 0.2)
                                                    : Color.primary.opacity(hovering.value ? 0.12 : 0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .onHover { hovering.value = $0 }
            .help("Open \(module.title)")
            .accessibilityLabel("Open \(module.title)")
        }
    }

    @ViewBuilder private var symbol: some View {
        if vivid {
            Image(systemName: module.symbol)
                .font(.system(size: 11.5, weight: .bold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.24)))
        } else {
            IconTile(symbol: module.symbol, tint: module.tint, size: 24)
        }
    }
}

private struct TileNote: View {
    let text: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text).lineLimit(1)
        }
        .fixedSize()
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private struct StateChip: View {
    let text: String
    var symbol: String?
    var tint: Color
    var ink: Color
    var spinning = false
    var progress: Double?

    var body: some View {
        HStack(spacing: 5) {
            if let progress {
                ProgressRing(progress: progress, tint: ink, size: 12, line: 2)
            } else if spinning {
                HomeSpinner(tint: ink, size: 12, line: 2)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
            }
            Text(text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// MARK: - Record

struct HomeRecordWidget: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        HomeTile(.meetings, title: "Record", vivid: true) {
            note
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 6)
                headline
                RecordWave(recording: model.recording != nil, hearing: model.recording?.hearing ?? false)
                    .frame(height: 40)
                    .padding(.top, 12)
                Spacer(minLength: 12)
                controls
                Rectangle().fill(.white.opacity(0.22)).frame(height: 1).padding(.vertical, 12)
                footer
            }
        }
        .animation(Motion.bouncy, value: model.recording != nil)
        .animation(Motion.snappy, value: model.starting)
    }

    @ViewBuilder private var note: some View {
        if model.recording != nil {
            HStack(spacing: 2) {
                LiveDot(color: .white, size: 6)
                Text("Recording").font(.system(size: 11.5, weight: .semibold))
            }
        } else {
            let offers = model.switches[AppSwitch.offerToRecordCalls] ?? false
            TileNote(text: offers ? "Offers when a call starts" : "Call offers are off", dot: .white.opacity(offers ? 0.85 : 0.4))
        }
    }

    @ViewBuilder private var headline: some View {
        if let recording = model.recording {
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.periodic(from: recording.started, by: 1)) { _ in
                    Text(Meetings.elapsed(since: recording.started))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                HStack(spacing: 0) {
                    RecordingScreenMenu(model: model, fallback: recording.audioOnly ? "Audio only" : "Screen and audio")
                    Text(recording.hearing ? " · hearing sound" : " · no sound yet").lineLimit(1)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
        } else {
            Text("Ready when\nthe call is")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .lineSpacing(-2)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var controls: some View {
        if model.recording != nil {
            Button { model.perform(.stopRecording) } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.coral).frame(width: 12, height: 12)
                    Text("Stop recording").font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    Spacer(minLength: 4)
                    RecordKeys(keys: "⌃⌥⌘R", solid: true)
                }
                .foregroundStyle(Palette.coral)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .buttonStyle(PressStyle())
            .help("Stop recording  ⌃⌥⌘R")
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        } else if model.starting {
            HStack(spacing: 10) {
                HomeSpinner(tint: .white, size: 18, line: 2.5)
                Text("Starting…").font(.system(size: 14.5, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.2)))
        } else {
            HStack(spacing: 10) {
                RecordButton(title: "Screen", symbol: "record.circle.fill", keys: "⌃⌥⌘R", solid: true) {
                    model.perform(.record(audioOnly: false))
                }
                .help("Record the screen and audio")
                RecordButton(title: "Audio", symbol: "waveform", keys: "⌃⌥⌘A", solid: false) {
                    model.perform(.record(audioOnly: true))
                }
                .help("Record audio only")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let progress = model.notesProgress {
            NotesProgressRow(progress: progress) { model.perform(.open(progress.folder)) }
        } else {
            Text("Screen takes the screen under the pointer, all sound and your mic. Audio keeps just the call.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecordButton: View {
    let title: String
    let symbol: String
    let keys: String
    let solid: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                Text(title).font(.system(size: 14.5, weight: .semibold, design: .rounded)).lineLimit(1)
                Spacer(minLength: 2)
                RecordKeys(keys: keys, solid: solid)
            }
            .foregroundStyle(solid ? Palette.coral : .white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(solid ? Color.white : Color.white.opacity(0.2)))
            .shadow(color: .black.opacity(solid ? 0.12 : 0), radius: 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

private struct RecordKeys: View {
    let keys: String
    let solid: Bool

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(solid ? Palette.coral.opacity(0.13) : .white.opacity(0.2)))
    }
}

/// Sound bars across the Record widget: a still wave while idle, live while a recording hears something.
private struct RecordWave: View {
    let recording: Bool
    let hearing: Bool

    var body: some View {
        GeometryReader { g in
            let count = max(12, Int(g.size.width / 10))
            if recording {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: !hearing)) { context in
                    bars(count: count, height: g.size.height, time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(count: count, height: g.size.height, time: nil)
            }
        }
    }

    private func bars(count: Int, height: CGFloat, time: Double?) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                let i = Double(index)
                let level: Double = if let time {
                    hearing ? 0.18 + 0.82 * abs(sin(time * 3.1 + i * 0.52) * cos(time * 1.7 + i * 0.23)) : 0.12
                } else {
                    0.22 + 0.6 * abs(sin(i * 0.52 + 0.8) * cos(i * 0.23 + 0.3))
                }
                Capsule()
                    .fill(.white.opacity(time == nil ? 0.72 : 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(4, height * level))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: hearing)
    }
}

/// The transcript or compression that's under way, with its percentage when it has one.
private struct NotesProgressRow: View {
    let progress: MeetingNotes.Progress
    var onColor = true
    let open: () -> Void

    private var percent: Int? { Recordings.percent(in: progress.detail) }

    private var symbol: String {
        switch progress.title.split(separator: " ").first.map(String.init) ?? "" {
        case "Compressing": "arrow.down.right.and.arrow.up.left"
        case "Transcribing": "text.bubble.fill"
        case "Summarizing": "sparkles"
        case "Downloading": "arrow.down.circle.fill"
        default: "gearshape.fill"
        }
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).frame(width: 14)
                    Text(progress.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let percent {
                        Text("\(percent)%").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    } else {
                        HomeSpinner(tint: onColor ? .white : Palette.coral, size: 13, line: 2)
                    }
                }
                if let percent {
                    ProgressBar(progress: Double(percent) / 100, tint: onColor ? .white : Palette.coral,
                                track: onColor ? .white.opacity(0.22) : Palette.coral.opacity(0.15), height: 4)
                } else {
                    Text(progress.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in Finder")
    }
}

// MARK: - Keep Awake

struct HomeAwakeWidget: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        HomeTile(.keepAwake, vivid: true) {
            VStack(spacing: 0) {
                KeepAwakeDial(stop: model.awakeStop, value: KeepAwakeInfo.value(model.awakeStop), caption: KeepAwakeInfo.caption(model),
                              onColor: true) { model.perform(.keepAwake($0)) }
                    .frame(maxWidth: 170, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                stops
                Text(footnote)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .padding(.top, 10)
            }
        }
    }

    private var footnote: String {
        if let others = KeepAwakeInfo.others(model) { return "\(others) \(model.awakeOthers.count == 1 ? "is" : "are") keeping it awake too" }
        return model.awakeStop == 0 ? "Pick how long to stay awake" : "The display stays on too"
    }

    private var stops: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(MenuModel.awakeStops.indices, id: \.self) { index in
                let on = index == model.awakeStop
                Button { withAnimation(Motion.bouncy) { model.perform(.keepAwake(index)) } } label: {
                    Text(MenuModel.awakeStops[index])
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(on ? Color(hex: 0xD9660A) : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.2)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(index == 0 ? "Off" : index == KeepAwakeInfo.last ? "Until you stop it" : MenuModel.awakeStops[index])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Displays

struct HomeDisplaysWidget: View {
    @EnvironmentObject private var displays: Displays
    @StateObject private var width = Box<CGFloat>(193)

    private var fitting: [DisplayLayout] { displays.config.layouts.filter(displays.fits) }

    private var status: (label: String, name: String, tone: Color?) {
        if let layout = displays.layout(displays.applying) { return ("Arranging as", layout.title, nil) }
        if let layout = fitting.first(where: { displays.notes[$0.id] != nil }) { return ("Didn't fully apply", layout.title, Palette.warn) }
        if let current = displays.current { return ("Arranged as", current.title, nil) }
        let count = displays.live.filter { $0.mirrors == nil }.count
        return (count == 1 ? "1 display" : "\(count) displays", "Not saved", nil)
    }

    var body: some View {
        HomeTile(.displays) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 6)
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            if displays.applying != nil {
                                HomeSpinner(tint: Ink.iris, size: 11, line: 1.5)
                            } else if let tone = status.tone {
                                Circle().fill(tone).frame(width: 6, height: 6)
                            }
                            Text(status.label).lineLimit(1)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        Text(status.name)
                            .font(.system(size: width.value < 170 ? 15 : 17, weight: .bold, design: .rounded))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    DisplayMiniMap(screens: displays.live)
                        .frame(width: min(74, max(48, (width.value - 10) * 0.42)), height: 46)
                }
                Spacer(minLength: 8)
                actions
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0 }
        }
    }

    @ViewBuilder private var actions: some View {
        let others = fitting.filter { $0.id != displays.current?.id }
        if !others.isEmpty {
            HStack(spacing: 6) {
                ForEach(others.prefix(2)) { layout in
                    Button { displays.apply(layout) } label: {
                        Text(layout.title).lineLimit(1)
                    }
                    .buttonStyle(MiniChipStyle(tint: Palette.iris, ink: Ink.iris))
                    .disabled(displays.applying != nil)
                    .help("Arrange your displays as \(layout.title)")
                }
            }
        } else if displays.current == nil {
            Button { displays.saveCurrent() } label: {
                Label("Save this layout", systemImage: "plus").lineLimit(1)
            }
            .buttonStyle(MiniChipStyle(tint: Palette.iris, ink: Ink.iris))
            .help("Remember how your displays are arranged now")
        } else {
            Text(displays.current?.automatic == true ? "Comes back on its own" : "A saved layout")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

private struct MiniChipStyle: ButtonStyle {
    let tint: Color
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.24 : 0.14)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// The connected displays, laid out as macOS arranges them, with the menu bar on the main one.
private struct DisplayMiniMap: View {
    let screens: [LiveDisplay]

    var body: some View {
        GeometryReader { g in
            let list = screens.filter { $0.mirrors == nil }
            let bounds = list.reduce(CGRect.null) { $0.union($1.frame) }
            if !list.isEmpty, bounds.width > 0, bounds.height > 0 {
                let gap: CGFloat = 2
                let scale = min(g.size.width / bounds.width, g.size.height / bounds.height)
                let ox = (g.size.width - bounds.width * scale) / 2, oy = (g.size.height - bounds.height * scale) / 2
                ZStack(alignment: .topLeading) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, screen in
                        let rect = CGRect(x: ox + (screen.frame.minX - bounds.minX) * scale, y: oy + (screen.frame.minY - bounds.minY) * scale,
                                          width: screen.frame.width * scale, height: screen.frame.height * scale).insetBy(dx: gap / 2, dy: gap / 2)
                        ScreenTile(main: screen.frame.origin == .zero, builtIn: screen.display.builtIn, size: rect.size)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ScreenTile: View {
    let main: Bool
    let builtIn: Bool
    let size: CGSize

    var body: some View {
        let r = max(2.5, min(size.width, size.height) * 0.08)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(LinearGradient(colors: main ? [Palette.iris.mixed(with: .white, 0.25), Palette.iris]
                                                   : [Palette.iris.opacity(0.42), Palette.iris.opacity(0.28)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            if main { Rectangle().fill(.white.opacity(0.55)).frame(height: max(2, size.height * 0.08)) }
            if builtIn {
                Capsule().fill(Color.black.opacity(0.5)).frame(width: size.width * 0.16, height: max(1.5, size.height * 0.06))
                    .padding(.top, main ? max(2, size.height * 0.08) : 0)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(main ? 0.45 : 0.25), lineWidth: 0.75) }
        .shadow(color: Palette.iris.opacity(main ? 0.35 : 0), radius: 4, y: 2)
    }
}

// MARK: - Drives

struct HomeDrivesWidget: View {
    @EnvironmentObject private var drives: Drives
    @EnvironmentObject private var navigator: Navigator

    private var all: [Drive] { drives.config.drives }

    var body: some View {
        HomeTile(.drives) {
            if !all.isEmpty {
                let mounted = all.filter { drives.status(of: $0).phase == .mounted }.count
                TileNote(text: "\(mounted) of \(all.count)")
            }
        } content: {
            if all.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 4)
                    Text("Mount a server's folder in Finder, over SSH")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { navigator.go(.drives) } label: { Label("Add a drive", systemImage: "plus") }
                        .buttonStyle(MiniChipStyle(tint: Palette.lime, ink: Ink.lime))
                }
            } else {
                let shown = all.count > 3 ? Array(all.prefix(2)) : all
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { DriveRow(drive: $0) }
                    Spacer(minLength: 0)
                    if all.count > 3 {
                        Button { navigator.go(.drives) } label: {
                            Text("\(all.count - 2) more").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.lime)
                        }
                        .buttonStyle(PressStyle())
                    } else if shown.count < 3 {
                        Text("They mount in ~/Drives").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

private struct DriveRow: View {
    let drive: Drive
    @EnvironmentObject private var drives: Drives

    var body: some View {
        let status = drives.status(of: drive)
        let mounted = status.phase == .mounted
        let busy = status.phase == .connecting || status.phase == .ejecting
        let trouble = status.problem != nil || status.offline
        HStack(spacing: 7) {
            if busy {
                HomeSpinner(tint: Ink.lime, size: 11, line: 1.75)
            } else {
                let color = trouble ? Palette.warn : mounted ? Palette.good : Color.secondary.opacity(0.5)
                Circle().fill(color).frame(width: 7, height: 7)
                    .shadow(color: mounted || trouble ? color.opacity(0.6) : .clear, radius: 3)
            }
            Text(drive.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if mounted {
                iconButton("folder.fill", help: "Open in Finder") { drives.reveal(drive) }
                iconButton("eject.fill", help: "Eject") { drives.eject(drive) }
            } else if !busy {
                Button(trouble ? "Retry" : "Mount") { drives.mount(drive, reveal: true) }
                    .buttonStyle(MiniChipStyle(tint: trouble ? Palette.warn : Palette.lime, ink: trouble ? Ink.amber : Ink.lime))
                    .help(status.problem ?? "Mount \(drive.place) and open it in Finder")
            }
        }
        .frame(height: 24)
        .help(status.problem ?? "")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Ink.lime)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.lime.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
        .accessibilityLabel("\(help) \(drive.title)")
    }
}

// MARK: - Tools

struct HomeToolsWidget: View {
    @EnvironmentObject private var model: MenuModel
    @StateObject private var lit = Box<String?>(nil)

    var body: some View {
        HomeTile(.tools, vivid: true) {
            TileNote(text: "Shortcuts work anywhere")
        } content: {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(ToolsCatalog.all) { tool in
                    button(tool)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.top, 10)
        }
    }

    private func button(_ tool: ToolsCatalog.Tool) -> some View {
        let on = lit.value == tool.id
        return Button {
            model.perform(tool.action)
            withAnimation(Motion.bouncy) { lit.value = tool.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if lit.value == tool.id { withAnimation(Motion.snappy) { lit.value = nil } }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark" : tool.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                Text(tool.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Text(tool.keys).font(.system(size: 10.5, weight: .semibold, design: .rounded)).opacity(0.78).lineLimit(1).fixedSize()
            }
            .foregroundStyle(on ? Palette.sky : .white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Color.white : Color.white.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("\(tool.hint)  \(tool.keys)")
    }
}

// MARK: - iPad

struct HomeIPadWidget: View {
    let ipad: MenuModel.IPad
    @EnvironmentObject private var model: MenuModel

    private var status: (color: Color, text: String) {
        switch ipad.state {
        case .nearby: (Palette.good, "Nearby")
        case .connecting: (Palette.busy, "Connecting…")
        case .disconnecting: (Palette.busy, "Disconnecting…")
        case .connected: (Palette.busy, "A display now")
        case .away: (Color.secondary.opacity(0.6),
                     ipad.seen.map { "Seen \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" } ?? "Not nearby")
        }
    }

    var body: some View {
        HomeTile(.ipad) {
            ShortcutCap(keys: "⌃⌥⌘S").fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 6)
                HStack(spacing: 10) {
                    Image(systemName: ipad.state == .connected ? "ipad.landscape.badge.play" : "ipad.landscape")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(LinearGradient(colors: Module.ipad.fill, startPoint: .top, endPoint: .bottom))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ipad.name).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(status.color).frame(width: 6, height: 6)
                            Text(status.text).lineLimit(1)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                button
            }
        }
    }

    @ViewBuilder private var button: some View {
        switch ipad.state {
        case .nearby:
            Button { model.perform(.toggleSidecar) } label: { Text("Connect").frame(maxWidth: .infinity) }
                .buttonStyle(CapsuleButton(tint: Palette.teal))
        case .connected:
            Button { model.perform(.toggleSidecar) } label: { Text("Disconnect").frame(maxWidth: .infinity) }
                .buttonStyle(CapsuleButton(tint: Palette.teal, soft: true))
        case .connecting, .disconnecting:
            HStack(spacing: 7) {
                HomeSpinner(tint: Ink.teal, size: 13, line: 2)
                Text(ipad.state == .connecting ? "Connecting" : "Disconnecting")
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Ink.teal)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Capsule().fill(Palette.teal.opacity(0.16)))
        case .away:
            Text("Not nearby")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Capsule().fill(Palette.well2))
        }
    }
}

// MARK: - Restart

/// Takes the iPad's place when Sidecar isn't available on this Mac.
struct HomeRestartWidget: View {
    @EnvironmentObject private var model: MenuModel
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        HomeTile(.restart) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let item = Restart.items[index]
                    let done = model.restarted.contains(index)
                    Button { model.perform(.restart(index)) } label: {
                        tile(symbol: done ? "checkmark" : item.symbol, title: item.short, done: done)
                    }
                    .buttonStyle(PressStyle())
                    .help("\(item.title): \(item.hint)")
                }
                Button { navigator.go(.restart) } label: { tile(symbol: "ellipsis", title: "More", done: false) }
                    .buttonStyle(PressStyle())
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.top, 8)
        }
    }

    private func tile(symbol: String, title: String, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(done ? Ink.mint : .secondary)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(done ? Palette.mint.opacity(0.16) : Palette.well))
        .contentShape(Rectangle())
    }
}

// MARK: - Universal Control

struct HomeUniversalControlWidget: View {
    @EnvironmentObject private var model: MenuModel

    private var paired: Bool {
        if case .paired = model.pairing { return true }
        return false
    }

    var body: some View {
        let watcher = model.watcher
        HomeTile(.universalControl) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Circle().fill(watcher.isOn ? watcher.tone.color : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(watcher.isOn ? watcher.status : "Watcher is off")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    ToggleSwitch(isOn: watcher.isOn, tint: Palette.grape, small: true, label: "Universal Control Watcher") {
                        model.perform(.setSwitch(AppSwitch.universalControlWatcher, !watcher.isOn))
                    }
                }
                if !watcher.lastReset.isEmpty {
                    Text(watcher.lastReset)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                Spacer(minLength: 8)
                Button(paired ? "Reset here" : "Reset now") { model.perform(.resetUniversalControl(.local)) }
                    .buttonStyle(CapsuleButton(tint: Palette.grape, soft: true))
                    .help(paired ? "Resets Universal Control on this Mac. Its page can reset the other Mac too." : "Turns Universal Control off and on")
            }
        }
    }
}

// MARK: - Meetings

struct HomeMeetingsWidget: View {
    @EnvironmentObject private var model: MenuModel
    @EnvironmentObject private var recordings: Recordings

    /// The newest two, keeping the one being worked on in view.
    private var shown: [Recordings.Item] {
        var items = Array(recordings.items.prefix(2))
        if let folder = model.notesProgress?.folder.path, !items.contains(where: { $0.folder.path == folder }),
           let busy = recordings.items.first(where: { $0.folder.path == folder }) {
            items = Array(items.prefix(1)) + [busy]
        }
        return items
    }

    var body: some View {
        HomeTile(.meetings) {
            Button { model.perform(.showRecordings) } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("Show the recordings in Finder")
            .accessibilityLabel("Show the recordings in Finder")
        } content: {
            if shown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Spacer(minLength: 4)
                    Text("No meetings yet").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Record a call and its transcript and summary land here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        Spacer(minLength: 6)
                        MeetingRow(item: item, progress: model.notesProgress?.folder.path == item.folder.path ? model.notesProgress : nil)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct MeetingRow: View {
    let item: Recordings.Item
    let progress: MeetingNotes.Progress?
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        Button { navigator.go(.meetings) } label: {
            HStack(spacing: 10) {
                IconTile(symbol: item.audioOnly ? "waveform" : "video.fill", tint: Palette.coral, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(meta).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                chip.fixedSize().layoutPriority(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var meta: String {
        var parts = [Self.when(item.date)]
        if let minutes = item.minutes { parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min") }
        if !item.people.isEmpty { parts.append(item.people.count == 1 ? "1 person" : "\(item.people.count) people") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var chip: some View {
        if let progress {
            let verb = progress.title.split(separator: " ").first.map(String.init) ?? "Working"
            let percent = Recordings.percent(in: progress.detail)
            StateChip(text: percent.map { "\(verb) \($0)%" } ?? verb, tint: Palette.coral, ink: Ink.coral,
                      spinning: percent == nil, progress: percent.map { Double($0) / 100 })
        } else if item.actionItems > 0 {
            StateChip(text: item.actionItems == 1 ? "1 action item" : "\(item.actionItems) action items", symbol: "checkmark.circle.fill",
                      tint: Palette.mint, ink: Ink.mint)
        } else if item.transcribed {
            StateChip(text: "Transcript", symbol: "text.alignleft", tint: Palette.mint, ink: Ink.mint)
        } else {
            StateChip(text: "No transcript", symbol: "minus.circle", tint: Color.secondary, ink: .secondary)
        }
    }

    static func when(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 99
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) + ", " + time }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Links

struct HomeLinksWidget: View {
    @EnvironmentObject private var links: Links
    @EnvironmentObject private var navigator: Navigator

    private var today: [LinkEvent] { links.recent.filter { Calendar.current.isDateInToday($0.date) } }

    var body: some View {
        HomeTile(.links, vivid: true) {
            if links.isDefault { switcher } else { TileNote(text: "Not the default browser") }
        } content: {
            if links.isDefault { counts } else { setup }
        }
    }

    /// The default target in one click.
    private var switcher: some View {
        let targets = links.shownTargets.filter { links.icon(of: $0) != nil }.prefix(4)
        return HStack(spacing: 3) {
            Text("Opens in").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).padding(.trailing, 3)
            ForEach(Array(targets)) { target in
                let current = target == links.primary
                Button { links.config.primary = target } label: {
                    if let icon = links.icon(of: target) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                            .padding(2)
                            .background(Circle().fill(.white.opacity(current ? 0.95 : 0)))
                            .opacity(current ? 1 : 0.85)
                    }
                }
                .buttonStyle(PressStyle())
                .help("Open links in \(links.title(of: target))")
                .accessibilityLabel("Open links in \(links.title(of: target))")
            }
        }
    }

    private var counts: some View {
        let events = today
        let cleaned = events.filter { $0.received != $0.opened }.count
        let groups = Self.targets(events)
        let top = Double(groups.first?.count ?? 1)
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(events.count)")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                    .padding(.bottom, -4)
                Text(events.count == 1 ? "link today" : "links today").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(cleaned == 0 ? "Opening in \(links.title(of: links.primary))" : "\(cleaned) cleaned up")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            if groups.isEmpty {
                Text("Each link shows up here with where it went.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            } else {
                VStack(spacing: 7) {
                    ForEach(groups.prefix(3), id: \.name) { group in
                        HStack(spacing: 7) {
                            Text(Self.short(group.name)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                .frame(maxWidth: 130, alignment: .leading)
                                .layoutPriority(1)
                            ProgressBar(progress: Double(group.count) / top, tint: .white, track: .white.opacity(0.18), height: 7)
                            Text("\(group.count)").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                                .frame(width: 20, alignment: .trailing)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private struct TargetCount {
        let name: String
        let count: Int
    }

    private static func targets(_ events: [LinkEvent]) -> [TargetCount] {
        var counts: [String: Int] = [:]
        for event in events { counts[event.target, default: 0] += 1 }
        let list = counts.map { TargetCount(name: $0.key, count: $0.value) }
        return list.sorted { a, b in a.count == b.count ? a.name < b.name : a.count > b.count }
    }

    /// "Google Chrome · Work" as "Chrome · Work", so profiles fit beside their bars.
    private static func short(_ name: String) -> String {
        for vendor in ["Google ", "Microsoft ", "Mozilla "] where name.hasPrefix(vendor) { return String(name.dropFirst(vendor.count)) }
        return name
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 4)
            Text("Every link in the right browser")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text("Make Gremlin your default browser and it sends each link to the right browser, profile or app.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Set up Links") { navigator.go(.links) }
                .buttonStyle(CapsuleButton(tint: Color(hex: 0xD6336F), white: true))
        }
    }
}

// MARK: - VPN

struct HomeVPNWidget: View {
    @EnvironmentObject private var vpn: VPN
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        let on = vpn.others.filter { $0.state == .on }.count + (vpn.tailscaleOn ? 1 : 0)
        HomeTile(.vpn) {
            if !vpn.tunnels.isEmpty { TileNote(text: on == 0 ? "All off" : "\(on) on", dot: on == 0 ? nil : Palette.good) }
        } content: {
            if vpn.tunnels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 4)
                    Text("Tailscale and WireGuard tunnels show up here once they're set up")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let shown = Array(vpn.tunnels.prefix(3))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { HomeTunnelRow(tunnel: $0) }
                    Spacer(minLength: 0)
                    if vpn.tunnels.count > 3 {
                        Button { navigator.go(.vpn) } label: {
                            Text("\(vpn.tunnels.count - 3) more").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ocean)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

private struct HomeTunnelRow: View {
    let tunnel: VPNTunnel
    @EnvironmentObject private var vpn: VPN

    var body: some View {
        let tailscale = tunnel.app == .tailscale
        let on = tailscale ? vpn.tailscaleOn : tunnel.state == .on
        let busy = tailscale ? vpn.tailscaleBusy : tunnel.busy
        HStack(spacing: 7) {
            if busy {
                HomeSpinner(tint: Ink.ocean, size: 11, line: 1.75)
            } else {
                Circle().fill(on ? Palette.good : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    .shadow(color: on ? Palette.good.opacity(0.6) : .clear, radius: 3)
            }
            Text(tunnel.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            ToggleSwitch(isOn: on, tint: Palette.ocean, small: true, label: tunnel.name) { vpn.toggle(tunnel) }
                .disabled(busy)
        }
        .frame(height: 24)
        .help(tailscale ? "Tailscale" : tunnel.text)
    }
}

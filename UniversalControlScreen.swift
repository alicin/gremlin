import SwiftUI

private typealias Row = DevicesParts.Row
private typealias Step = DevicesParts.Step

struct UniversalControlScreen: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        ScreenCard(module: .universalControl) {
            WatchToggle()
        } content: {
            HStack(alignment: .top, spacing: 18) {
                StatusPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 14) {
                    ResetPanel()
                    PairingPanel()
                    Well("How the fix works", fill: true) {
                        VStack(alignment: .leading, spacing: 11) {
                            Step(number: 1, text: "Reads Universal Control's log and spots the moment it gives up after sleep", tint: Palette.grape)
                            Step(number: 2, text: "Waits 10 seconds, then turns it off for 3 seconds and back on", tint: Palette.grape)
                            Step(number: 3, text: "Still stuck? Tries again after 1 min, 5 min, then every 30 min", tint: Palette.grape)
                            Step(number: 4, text: "With a paired Mac, the one refusing the connection gets the reset", tint: Palette.grape)
                        }
                    }
                }
                .frame(width: 320)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private extension MenuModel {
    var pairedName: String? {
        if case .paired(let name, _) = pairing { return name }
        return nil
    }
}

private struct WatchToggle: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let on = model.watcher.isOn
        HStack(spacing: 10) {
            Text(on ? "Watching" : "Not watching").font(.system(size: 13, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
            ToggleSwitch(isOn: on, tint: Palette.good, label: "Universal Control watcher") {
                model.perform(.setSwitch(AppSwitch.universalControlWatcher, !on))
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(Capsule().fill(.white.opacity(0.2)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        .animation(Motion.snappy, value: on)
    }
}

// MARK: - Status and devices

private struct StatusPanel: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let watcher = model.watcher
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                DeviceMap(tile: 84)
                DeviceMap(tile: 64)
            }
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Pulse(color: watcher.tone.color, live: watcher.isOn && watcher.tone == .good)
                        .padding(.top, 1)
                    Text(watcher.isOn ? watcher.status : "The watcher is off")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(watcher.detail)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
                if !watcher.isOn {
                    Button("Turn on the watcher") { model.perform(.setSwitch(AppSwitch.universalControlWatcher, true)) }
                        .buttonStyle(CapsuleButton(tint: Palette.grape, big: true))
                        .padding(.top, 10)
                }
            }
            .padding(.top, 28)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack(alignment: .bottomTrailing) {
                PaperSurface(tint: Palette.grape, radius: 18)
                DevicesParts.Watermark(symbol: "macbook.and.ipad", tint: Palette.grape, size: 150, opacity: 0.06)
            }
            .clipShape(shape)
        }
        .animation(Motion.snappy, value: watcher)
    }
}

/// A status dot that breathes while everything is fine.
private struct Pulse: View {
    let color: Color
    let live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !live || Motion.reduced)) { context in
            let phase = live ? (sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2 : 0.4
            Circle().fill(color)
                .frame(width: 11, height: 11)
                .background(Circle().fill(color.opacity(0.25)).frame(width: 18 + 6 * phase, height: 18 + 6 * phase))
                .frame(width: 24, height: 24)
        }
        .accessibilityHidden(true)
    }
}

private struct Device: Identifiable {
    enum Health { case good, busy, warning, off }

    let id: String
    let name: String
    let symbol: String
    let detail: String
    let health: Health
    var ghost = false
}

/// This Mac in the middle, with lines out to the iPad and the paired Mac. A dot runs along a line while both ends are fine.
private struct DeviceMap: View {
    let tile: CGFloat
    @EnvironmentObject private var model: MenuModel

    private var devices: (left: Device?, center: Device, right: Device) {
        let watcher = model.watcher
        let center = Device(id: "mac", name: model.thisMac, symbol: "laptopcomputer", detail: "This Mac",
                            health: !watcher.isOn ? .off : watcher.tone == .good ? .good : watcher.tone == .busy ? .busy : .warning)
        let left = model.ipad.map { ipad in
            Device(id: "ipad", name: ipad.name, symbol: "ipad",
                   detail: ipad.state == .connected ? "iPad · a display here" : ipad.state == .away ? "iPad · not nearby" : "iPad · nearby",
                   health: ipad.state == .away ? .off : .good)
        }
        let right: Device = switch model.pairing {
        case .paired(let name, let status):
            Device(id: "peer", name: name, symbol: "macmini", detail: "Paired · \(status)",
                   health: status == MenuModel.reachable ? .good : status == MenuModel.unreachable ? .warning : .off)
        case .pairing:
            Device(id: "peer", name: "Another Mac", symbol: "macmini", detail: "Waiting to pair…", health: .busy, ghost: true)
        case .unpaired:
            Device(id: "peer", name: "Another Mac", symbol: "macmini", detail: "Not paired", health: .off, ghost: true)
        }
        return (left, center, right)
    }

    var body: some View {
        let d = devices
        let live = model.watcher.isOn && !Motion.reduced
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .top, spacing: 0) {
                if let left = d.left {
                    Node(device: left, tile: tile)
                    Wire(phase: live ? 1 - (t.truncatingRemainder(dividingBy: 1.8) / 1.8) : nil,
                         active: left.health == .good && d.center.health != .off, height: tile)
                }
                Node(device: d.center, tile: tile)
                Wire(phase: live ? (t + 0.9).truncatingRemainder(dividingBy: 1.8) / 1.8 : nil,
                     active: d.right.health == .good && d.center.health != .off, dashed: d.right.ghost, height: tile)
                Node(device: d.right, tile: tile)
            }
        }
    }
}

private struct Node: View {
    let device: Device
    let tile: CGFloat

    private var badge: (symbol: String, color: Color) {
        switch device.health {
        case .good: ("checkmark", Palette.good)
        case .busy: ("ellipsis", Palette.busy)
        case .warning: ("exclamationmark", Palette.warn)
        case .off: ("minus", Palette.slate)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tile * 0.28, style: .continuous)
        VStack(spacing: 8) {
            Image(systemName: device.symbol)
                .font(.system(size: tile * 0.38, weight: .medium))
                .foregroundStyle(device.ghost ? AnyShapeStyle(Ink.grape) : AnyShapeStyle(.white))
                .frame(width: tile, height: tile)
                .background {
                    if device.ghost {
                        shape.fill(Palette.grape.opacity(0.08))
                            .overlay { shape.strokeBorder(Palette.grape.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                    } else {
                        shape.fill(LinearGradient(colors: device.health == .off ? Module.restart.fill : Module.universalControl.fill,
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay { shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.75) }
                            .shadow(color: (device.health == .off ? Palette.slate : Palette.grape).opacity(0.35), radius: 10, y: 5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !device.ghost {
                        Image(systemName: badge.symbol)
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(badge.color))
                            .overlay(Circle().strokeBorder(Palette.card, lineWidth: 2.5))
                            .offset(x: 6, y: -6)
                    }
                }
            VStack(spacing: 1) {
                Text(device.name).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                Text(device.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(width: tile + 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name), \(device.detail)")
    }
}

private struct Wire: View {
    /// Where the dot is along the line, 0 to 1, or nil when the watcher is off.
    let phase: Double?
    let active: Bool
    var dashed = false
    var height: CGFloat = 70

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if dashed || !active {
                    Line().stroke(Palette.grape.opacity(dashed ? 0.35 : 0.22), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 6]))
                        .frame(height: 2)
                } else {
                    Capsule().fill(Palette.grape.opacity(0.24)).frame(height: 3)
                }
                if let phase, active, !dashed {
                    Circle().fill(Palette.good).frame(width: 9, height: 9)
                        .shadow(color: Palette.good.opacity(0.8), radius: 4)
                        .offset(x: (g.size.width - 9) * phase)
                }
            }
            .frame(height: g.size.height)
        }
        .frame(minWidth: 18, maxWidth: 150)
        .frame(height: height)
        .padding(.horizontal, -6)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

// MARK: - Reset and pairing

private struct ResetPanel: View {
    @EnvironmentObject private var model: MenuModel

    private var targets: [(title: String, target: UniversalControlWatcher.Target)] {
        guard let name = model.pairedName else { return [("Reset this Mac", .local)] }
        return [("This Mac", .local), (name, .remote), ("Both", .both)]
    }

    var body: some View {
        Well("Reset now") {
            HStack(spacing: 8) {
                ForEach(targets, id: \.title) { item in
                    Button { model.perform(.resetUniversalControl(item.target)) } label: {
                        Text(item.title).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CapsuleButton(tint: Palette.grape, soft: true))
                    .help(help(item.target))
                }
            }
            Label(model.watcher.lastReset, systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func help(_ target: UniversalControlWatcher.Target) -> String {
        switch target {
        case .local: "Turns Universal Control off for 3 seconds and back on, on this Mac"
        case .remote: "Asks \(model.pairedName ?? "the other Mac") to turn Universal Control off and on"
        case .both: "Resets Universal Control on both Macs"
        }
    }
}

private struct PairingPanel: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        Well("Pairing") {
            switch model.pairing {
            case .paired(let name, _):
                Row(symbol: "link", tint: Palette.grape, title: "Paired with \(name)", detail: "Either Mac can reset the other") {
                    Button("Unpair") { model.perform(.unpair) }.buttonStyle(CapsuleButton(neutral: true))
                }
            case .unpaired:
                Row(symbol: "link", tint: Palette.slate, title: "Not paired", detail: "Pair with your other Mac so either one can reset the other")
                Button { model.perform(.startPairing) } label: { Label("Pair another Mac…", systemImage: "plus") }
                    .buttonStyle(CapsuleButton(tint: Palette.grape))
            case .pairing:
                Row(symbol: "link", tint: Palette.grape, title: "Waiting for the other Mac") {
                    DevicesParts.Spinner(tint: Ink.grape, size: 16)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Step(number: 1, text: "On the other Mac, choose Pair another Mac… within 2 minutes", tint: Palette.grape)
                    Step(number: 2, text: "Both Macs show a 6-digit code", tint: Palette.grape)
                    Step(number: 3, text: "Click Pair on both if the codes match", tint: Palette.grape)
                }
                Button("Cancel") { model.perform(.stopPairing) }.buttonStyle(CapsuleButton(neutral: true))
            }
        }
        .animation(Motion.snappy, value: model.pairing)
    }
}

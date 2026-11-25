import AppKit
import SwiftUI

// Cables in the window: the map of the Mac's ports up top, and below it everything about the selected one, from a
// plain verdict down to the raw e-marker words. The technical parts fold away until asked for.
struct CablesScreen: View {
    @EnvironmentObject private var cables: Cables

    var body: some View {
        let stories = Self.stories(cables)
        let story = stories.first { $0.port.id == cables.selected }
        ScreenCard(module: .cables) {
            HStack(spacing: 10) {
                HeaderNote(text: headerText, symbol: cables.chargingPort != nil ? "bolt.fill" : "cable.connector")
                    .contentTransition(.numericText())
                BandToggle(title: "Details", symbol: cables.showsDetails ? "eye.fill" : "eye", on: cables.showsDetails) {
                    withAnimation(Motion.snappy) { cables.showsDetails.toggle() }
                }
                .help(cables.showsDetails ? "Fold the technical details away" : "Show every technical detail")
            }
        } content: {
            VStack(spacing: 16) {
                if stories.isEmpty {
                    Well(padding: 20) {
                        Text("No ports to show").font(.system(size: 15, weight: .semibold))
                        Text("Gremlin reads ports on Apple silicon Macs, which list them in the IOPort registry.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        CableMap(stories: stories, selected: cables.selected, laptop: cables.charging.hasBattery,
                                 liveMilliwatts: cables.charging.inputMilliwatts, fresh: { cables.justConnected($0) }) { id in
                            withAnimation(Motion.snappy) { cables.selected = id }
                        }
                        ToastSetting()
                    }
                }
                if let story {
                    PortDetail(story: story)
                        .id(story.port.id)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .animation(Motion.snappy, value: cables.selected)
        }
        .onAppear {
            cables.watching = true
            cables.refresh()
        }
        .onDisappear { cables.watching = false }
    }

    @MainActor static func stories(_ cables: Cables) -> [PortStory] {
        let charging = cables.chargingPort?.id
        return cables.ports.map { PortStory(port: $0, charging: cables.charging, chargingPort: charging) }
    }

    private var headerText: String {
        if let port = cables.chargingPort {
            let live = cables.charging.inputMilliwatts.map(Units.watts)
            let max = port.contract?.winning.map { Units.watts($0.milliwatts) }
            if let live, let max { return "\(live) of \(max)" }
            return max.map { "Up to \($0)" } ?? "Charging"
        }
        let n = cables.connectedPorts.count
        return n == 0 ? "Nothing plugged in" : n == 1 ? "1 plugged in" : "\(n) plugged in"
    }
}

private struct ToastSetting: View {
    @StateObject private var on = Box(CableToast.enabled)

    var body: some View {
        HStack(spacing: 8) {
            Label("Pick a port or its card to see everything about it", systemImage: "hand.point.up.left")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            Text("Show a card when something's plugged in").font(.system(size: 12)).foregroundStyle(.secondary)
            ToggleSwitch(isOn: on.value, tint: Palette.emerald, small: true, label: "Show a card when something's plugged in") {
                on.value.toggle()
                UserDefaults.standard.set(on.value, forKey: CableToast.enabledKey)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// A toggle that sits on a screen's colored band, like a HeaderNote you can press.
struct BandToggle: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? AnyShapeStyle(Module.cables.ink) : AnyShapeStyle(.white))
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(on ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.2))))
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityValue(on ? "On" : "Off")
    }
}

// MARK: - The selected port

private struct PortDetail: View {
    let story: PortStory
    @EnvironmentObject private var cables: Cables
    @StateObject private var expanded = Box<[String: Bool]>([:])

    private func isOpen(_ key: String) -> Bool { expanded.value[key] ?? cables.showsDetails }

    private func toggle(_ key: String) {
        withAnimation(Motion.snappy) { expanded.value[key] = !isOpen(key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(story: story)
            if !story.insights.isEmpty {
                VStack(spacing: 8) {
                    ForEach(story.insights) { InsightRow(insight: $0) }
                }
            }
            if story.connected {
                ChainRow(links: story.chain)
                tiles
            } else {
                EmptyPort(story: story)
            }
            if isOpen("technical") {
                Technical(story: story)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Spacer()
                Button { toggle("technical") } label: {
                    Label(isOpen("technical") ? "Hide port, cable and chip details" : "Port, cable and chip details",
                          systemImage: isOpen("technical") ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(CapsuleButton(neutral: true))
                Spacer()
            }
        }
        .onChange(of: cables.showsDetails) { expanded.value = [:] }
    }

    @ViewBuilder private var tiles: some View {
        let power = story.port.contract != nil || story.charges
        let data = PortStory.dataRate(story.port) != nil
        if power || data {
            HStack(alignment: .top, spacing: 14) {
                if power {
                    PowerTile(story: story, open: isOpen("power")) { toggle("power") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if data {
                    DataTile(story: story, open: isOpen("data")) { toggle("data") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        let displays = story.port.displays
        let devices = story.port.devices.filter { !$0.hub && $0.classCode != 0x11 }
        if !displays.isEmpty || !devices.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                if !displays.isEmpty {
                    DisplayTile(story: story, open: isOpen("display")) { toggle("display") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !devices.isEmpty {
                    DevicesTile(story: story, devices: devices, open: isOpen("devices")) { toggle("devices") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DetailHeader: View {
    let story: PortStory
    @StateObject private var copied = Box(false)

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: story.symbol, tint: story.connected ? Palette.emerald : Palette.slate, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(story.connected ? story.name : "Nothing in \(story.port.title)")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                if !story.chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(story.chips, id: \.self) { Tag(text: $0) }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 12)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(story.report, forType: .string)
                withAnimation(Motion.snappy) { copied.value = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Motion.snappy) { copied.value = false } }
            } label: {
                Label(copied.value ? "Copied" : "Copy report", systemImage: copied.value ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(CapsuleButton(tint: Palette.emerald, soft: true))
            .help("Copy everything about this port as text")
        }
    }

    private var subtitle: String {
        let place = [story.port.title, story.port.location?.title.lowercased()].compactMap { $0 }.joined(separator: ", ")
        guard story.connected else { return place }
        return [story.maker, story.role, "on \(place)"].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct InsightRow: View {
    let insight: PortStory.Insight

    private var tint: Color {
        switch insight.tone {
        case .good: Palette.good
        case .warn: Palette.warn
        case .info: Palette.sky
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: insight.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.system(size: 13.5, weight: .semibold))
                Text(insight.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(insight.tone == .info ? 0.07 : 0.11)))
    }
}

// MARK: - The chain

private struct ChainRow: View {
    let links: [PortStory.Link]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                if index > 0 { Connector(warn: link.limits != nil || links[index - 1].limits != nil) }
                ChainTile(link: link, first: index == 0)
                    .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Connector: View {
    let warn: Bool

    var body: some View {
        ZStack {
            Capsule().fill(warn ? Palette.warn : Palette.emerald.opacity(0.55)).frame(width: 22, height: 4)
            Circle().fill(warn ? Palette.warn : Palette.emerald).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Palette.page, lineWidth: 2))
        }
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}

private struct ChainTile: View {
    let link: PortStory.Link
    let first: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(link.caption.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let limits = link.limits { Chip(text: limits, color: Palette.warn, symbol: "exclamationmark.triangle.fill") }
            }
            HStack(spacing: 9) {
                IconTile(symbol: link.symbol, tint: link.limits != nil ? Palette.warn : first ? Palette.slate : Palette.emerald, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(link.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    if let subtitle = link.subtitle {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(link.facts, id: \.self) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Palette.emerald.opacity(0.7)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(fact).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(link.limits != nil ? Palette.warn.opacity(0.8) : .clear, lineWidth: 1.5)
        }
    }
}

// MARK: - Tiles

/// A tile with a title, its main content, and technical rows that fold out under it.
private struct Tile<Content: View>: View {
    let title: String
    let symbol: String
    let facts: [PortStory.Fact]
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.emerald)
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                if !facts.isEmpty {
                    Button(action: toggle) {
                        HStack(spacing: 3) {
                            Text(open ? "Less" : "More")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Ink.emerald)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Palette.emerald.opacity(0.12)))
                    }
                    .buttonStyle(PressStyle())
                    .help(open ? "Hide the technical details" : "Show the technical details")
                }
            }
            content
            if open, !facts.isEmpty {
                FactTable(facts: facts)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
    }
}

/// A chip in the module's ink, which stays readable in Dark Mode where `Chip` darkens its color.
private struct Tag: View {
    let text: String
    var quiet = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.emerald))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(quiet ? AnyShapeStyle(Palette.well2) : AnyShapeStyle(Palette.emerald.opacity(0.15))))
    }
}

struct FactTable: View {
    let facts: [PortStory.Fact]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(facts) { fact in
                GridRow {
                    Text(fact.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(fact.value)
                        .font(fact.mono ? .system(size: 11, design: .monospaced) : .system(size: 11.5, weight: .medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.page))
    }
}

private struct PowerTile: View {
    let story: PortStory
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let port = story.port
        let contract = port.contract?.winning
        let charger = port.charger
        let cableLimit = port.cable.flatMap { $0.poweredDevice ? nil : $0.maxMilliwatts }
        let live = story.charges ? story.charging.inputMilliwatts : nil
        Tile(title: story.charges ? "Power in" : "Power", symbol: "bolt.fill", facts: story.powerFacts, open: open, toggle: toggle) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.map(Units.watts) ?? contract.map { Units.watts($0.milliwatts) } ?? "—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(Motion.snappy, value: live)
                    Text(caption(live: live, contract: contract)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let live, let contract, contract.milliwatts > 0 {
                    ZStack {
                        ProgressRing(progress: Double(live) / Double(contract.milliwatts), tint: Palette.emerald, size: 56, line: 6)
                        Image(systemName: "bolt.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(Ink.emerald)
                    }
                }
            }
            if let charger, charger.options.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What the charger offers").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(charger.options.sorted { $0.millivolts < $1.millivolts }) { option in
                        OptionBar(option: option, max: charger.maxMilliwatts, winning: option == contract,
                                  overCable: cableLimit.map { option.milliwatts > $0 } ?? false)
                    }
                    if let cableLimit, cableLimit < charger.maxMilliwatts {
                        Label("The cable carries at most \(Units.watts(cableLimit))", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.amber)
                    }
                }
            }
            if story.charges, let battery = PortStory.batteryLine(story.charging) {
                HStack(spacing: 8) {
                    BatteryGlyph(percent: story.charging.percent ?? 0, charging: story.charging.charging)
                    Text(battery).font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    private func caption(live: Int?, contract: PowerOption?) -> String {
        guard let contract else { return "No power contract yet" }
        let deal = "\(Units.volts(contract.millivolts)) × \(Units.amps(contract.milliamps))"
        if live != nil { return "Drawn right now, of \(Units.watts(contract.milliwatts)) agreed at \(deal)" }
        return story.charges ? "Agreed at \(deal)" : "On standby, agreed at \(deal)"
    }
}

private struct OptionBar: View {
    let option: PowerOption
    let max: Int
    let winning: Bool
    let overCable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(option.title + (option.fixed ? "" : " PPS"))
                .font(.system(size: 11.5, weight: winning ? .semibold : .regular, design: .rounded))
                .foregroundStyle(winning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 96, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(winning ? AnyShapeStyle(Palette.emerald.gradient) : overCable ? AnyShapeStyle(Palette.warn.opacity(0.45)) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: Swift.max(8, g.size.width * CGFloat(option.milliwatts) / CGFloat(Swift.max(1, max))))
                }
            }
            .frame(height: 8)
            Text(Units.watts(option.milliwatts))
                .font(.system(size: 11.5, weight: winning ? .bold : .medium, design: .rounded))
                .foregroundStyle(winning ? AnyShapeStyle(Ink.emerald) : AnyShapeStyle(.secondary))
                .frame(width: 44, alignment: .trailing)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.emerald)
                .opacity(winning ? 1 : 0)
        }
        .help(winning ? "The contract in use" : overCable ? "More than the cable is rated for" : "Offered, not in use")
    }
}

private struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        let symbol = percent >= 88 ? "battery.100percent" : percent >= 63 ? "battery.75percent" : percent >= 38 ? "battery.50percent" : percent >= 13 ? "battery.25percent" : "battery.0percent"
        Image(systemName: charging ? "battery.100percent.bolt" : symbol)
            .font(.system(size: 15))
            .foregroundStyle(percent < 20 && !charging ? AnyShapeStyle(Palette.bad) : AnyShapeStyle(Ink.emerald))
    }
}

private struct DataTile: View {
    let story: PortStory
    let open: Bool
    let toggle: () -> Void

    private struct Bar: Identifiable {
        let label: String
        let bitsPerSecond: Double
        let note: String
        let tint: Color
        var id: String { label }
    }

    var body: some View {
        let port = story.port
        let now = PortStory.dataRate(port)
        let bars = bars(port, now: now?.bitsPerSecond)
        let top = bars.map(\.bitsPerSecond).max() ?? 1
        Tile(title: "Data", symbol: "arrow.left.arrow.right", facts: story.thunderboltFacts + story.usbFacts, open: open, toggle: toggle) {
            VStack(alignment: .leading, spacing: 2) {
                Text(now.map { Units.rate($0.bitsPerSecond) } ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(now?.title.components(separatedBy: " · ").first.map { "\($0) link, right now" } ?? "No data link")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(bars) { bar in
                    HStack(spacing: 10) {
                        Text(bar.label).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                        ProgressBar(progress: bar.bitsPerSecond / top, tint: bar.tint, height: 8)
                        Text(bar.note).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func bars(_ port: CablePort, now: Double?) -> [Bar] {
        var bars: [Bar] = []
        let slow = PortStory.usb2Limited(port) != nil
        if let now { bars.append(Bar(label: "Now", bitsPerSecond: now, note: Units.rate(now), tint: slow ? Palette.warn : Palette.emerald)) }
        if let max = port.maxGbps { bars.append(Bar(label: "This port", bitsPerSecond: max * 1e9, note: Units.rate(max * 1e9), tint: Palette.slate)) }
        if let speed = port.cable?.speed {
            let carries = max(speed.cableBitsPerSecond, (port.thunderbolt?.gbps ?? 0) * 1e9)
            bars.append(Bar(label: "Cable", bitsPerSecond: carries, note: Units.rate(carries), tint: Palette.sky))
        }
        if let device = port.devices.first(where: { $0.depth == 0 && !$0.hub && $0.canDoUSB3 }), slow {
            bars.append(Bar(label: "Device", bitsPerSecond: device.bcdUSB >= 0x0310 ? 10e9 : 5e9, note: "USB 3", tint: Palette.sky))
        }
        return bars
    }
}

private struct DisplayTile: View {
    let story: PortStory
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let displays = story.port.displays
        Tile(title: displays.count == 1 ? "Display" : "Displays", symbol: "display", facts: displays.flatMap(story.displayFacts), open: open, toggle: toggle) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(displays) { display in
                    HStack(spacing: 11) {
                        IconTile(symbol: "display", tint: Palette.emerald, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(display.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            Text(line(display)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func line(_ d: DisplayLink) -> String {
        var parts: [String] = []
        if let name = d.rateName { parts.append(name + (d.lanes.map { " × \($0)" } ?? "")) }
        if let video = d.videoGbps { parts.append(String(format: "%.1f Gb/s for video", video)) }
        parts.append(d.tunneled ? "through Thunderbolt" : d.converter.map { "via \($0)" } ?? "DisplayPort")
        return parts.joined(separator: " · ")
    }
}

private struct DevicesTile: View {
    let story: PortStory
    let devices: [USBDeviceInfo]
    let open: Bool
    let toggle: () -> Void
    @StateObject private var all = Box(false)

    var body: some View {
        let slow = PortStory.usb2Limited(story.port)
        let shown = all.value || devices.count <= 6 ? devices : Array(devices.prefix(5))
        let hubs = story.port.devices.filter(\.hub).count
        Tile(title: devices.count == 1 ? "USB device" : "\(devices.count) USB devices", symbol: "cable.connector.horizontal",
             facts: [], open: open, toggle: toggle) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(shown) { device in
                    HStack(spacing: 10) {
                        IconTile(symbol: device.symbol, tint: device == slow ? Palette.warn : Palette.slate, size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            if let line = vendorLine(device) {
                                Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if let speed = device.linkBitsPerSecond {
                            Text(Units.rate(speed))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(device == slow ? AnyShapeStyle(Ink.amber) : AnyShapeStyle(.secondary))
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(Capsule().fill(Palette.page))
                        }
                    }
                    .help(story.deviceFacts(device).map { "\($0.label): \($0.value)" }.joined(separator: "\n"))
                }
                HStack {
                    if devices.count > 6 {
                        Button(all.value ? "Show fewer" : "Show all \(devices.count)") { withAnimation(Motion.snappy) { all.value.toggle() } }
                            .buttonStyle(CapsuleButton(neutral: true))
                    }
                    Spacer()
                    if hubs > 0 {
                        Text(hubs == 1 ? "1 hub not shown" : "\(hubs) hubs not shown").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Docks show up as a few USB devices of their own, for their buttons, audio and firmware.
    private func vendorLine(_ device: USBDeviceInfo) -> String? {
        if let tb = story.port.thunderbolt, let maker = tb.vendor, device.vendor?.localizedCaseInsensitiveContains(maker) == true,
           device.name.localizedCaseInsensitiveContains("dock") {
            return "\(maker) · part of the dock"
        }
        return device.vendor
    }
}

// MARK: - Empty port and technical details

private struct EmptyPort: View {
    let story: PortStory

    var body: some View {
        let port = story.port
        HStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.emerald.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .frame(width: 84, height: 84)
                .overlay { Capsule().fill(Color.black.opacity(0.8)).frame(width: port.magSafe ? 40 : 30, height: 9) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Plug something in and it shows up here").font(.system(size: 15, weight: .semibold))
                Text("Gremlin reads the cable's chip, the charger's offers and the link the moment it connects.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(PortStory.capabilities(port).components(separatedBy: " · "), id: \.self) { Tag(text: $0.prefix(1).uppercased() + $0.dropFirst(), quiet: true) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
    }
}

private struct Technical: View {
    let story: PortStory

    var body: some View {
        let sections: [(String, String, [PortStory.Fact])] = [
            ("Port", "rectangle.portrait.and.arrow.right", story.portFacts),
            ("Cable chip", "cable.connector", story.cableFacts),
            ("Device's Power Delivery ID", "person.text.rectangle", story.partnerFacts),
        ].filter { !$0.2.isEmpty }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(sections, id: \.0) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Label(section.0, systemImage: section.1)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    FactTable(facts: section.2)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
            }
        }
    }
}

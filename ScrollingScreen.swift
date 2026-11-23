import SwiftUI

// Scrolling in the window: a card per mouse and trackpad with its own direction. Each card lights up while its
// device scrolls, which tells apart two mice with the same receiver name.
struct ScrollingScreen: View {
    @EnvironmentObject private var scrolling: ScrollDirection
    @EnvironmentObject private var model: MenuModel

    static let trackpadSettings = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!

    var body: some View {
        let flipped = scrolling.devices.filter(scrolling.flips).count
        ScreenCard(module: .scrolling) {
            HeaderNote(text: flipped == 0 ? "Same as macOS" : "\(flipped) flipped", symbol: "arrow.up.arrow.down")
        } content: {
            VStack(spacing: 14) {
                if scrolling.needsAccess { access }
                if scrolling.devices.isEmpty {
                    Well(padding: 20) {
                        Text("No mouse or trackpad found").font(.system(size: 15, weight: .semibold))
                        Text("Plug one in or turn it on, and it shows up here.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(scrolling.devices) { ScrollDeviceCard(device: $0) }
                    }
                }
                explainer
            }
        }
        .onAppear {
            scrolling.refresh()
            scrolling.watching = true
        }
        .onDisappear { scrolling.watching = false }
    }

    private var access: some View {
        Well(padding: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "hand.raised.fill", tint: Palette.warn, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flipping needs Accessibility permission").font(.system(size: 13.5, weight: .semibold))
                    Text("Allow Gremlin in Privacy & Security › Accessibility, then come back here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Allow in Settings") { model.perform(.open(ToolsCatalog.accessibilitySettings)) }
                    .buttonStyle(CapsuleButton(tint: Palette.warn, soft: true))
            }
        }
    }

    private var explainer: some View {
        Well(padding: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "info.circle.fill", tint: Palette.slate, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS has one direction for everything").font(.system(size: 13.5, weight: .semibold))
                    Text("Its Natural scrolling setting is \(scrolling.macNatural ? "on" : "off"), for every mouse and trackpad. Gremlin flips the scrolling of any device you set the other way.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Trackpad Settings") { model.perform(.open(Self.trackpadSettings)) }
                    .buttonStyle(CapsuleButton(neutral: true))
            }
        }
    }
}

private struct ScrollDeviceCard: View {
    let device: ScrollDevice
    @EnvironmentObject private var scrolling: ScrollDirection

    var body: some View {
        let natural = scrolling.isNatural(device)
        let connected = scrolling.connected.contains(device.key)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let active = scrolling.lastScrolled[device.key].map { context.date.timeIntervalSince($0) < 3 } ?? false
            Well(padding: 18, fill: true) {
                HStack(alignment: .top) {
                    IconTile(symbol: device.symbol, tint: connected ? Palette.tangerine : Palette.slate, size: 46)
                    Spacer()
                    ToggleSwitch(isOn: natural, tint: Palette.tangerine, label: "Natural scrolling on \(device.title)") {
                        scrolling.setNatural(!natural, for: device)
                    }
                }
                Text(device.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Text(connected ? device.connection : "\(device.connection) · not connected")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollDirectionDiagram(device: device, natural: natural)
                    .padding(.vertical, 4)
                Text(natural ? "Natural scrolling: the content follows your fingers, like on a phone."
                             : "Standard scrolling: rolling down moves down the page.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    pill(active: active)
                    Spacer(minLength: 0)
                    if !connected {
                        Button("Forget") { scrolling.forget(device) }
                            .buttonStyle(CapsuleButton(neutral: true))
                            .help("Drop this device's setting")
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.tangerine.opacity(active ? 0.75 : 0), lineWidth: 2)
            }
            .animation(Motion.snappy, value: active)
        }
        .animation(Motion.snappy, value: natural)
    }

    private func pill(active: Bool) -> some View {
        let flips = scrolling.flips(device)
        let text = active ? "Scrolling now" : flips ? "Gremlin flips it" : "Same as macOS"
        return HStack(spacing: 6) {
            Circle().fill(active || flips ? Palette.tangerine : Palette.slate).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Palette.page))
    }
}

/// Which way the content goes when you scroll down on the device.
struct ScrollDirectionDiagram: View {
    let device: ScrollDevice
    let natural: Bool
    var compact = false

    var body: some View {
        let size: CGFloat = compact ? 11 : 13
        HStack(spacing: compact ? 5 : 8) {
            chip(device.kind == .trackpad ? "hand.point.up.left.fill" : "computermouse.fill", arrow: "arrow.down", tint: .secondary, size: size)
            Image(systemName: "arrow.right").font(.system(size: size - 3, weight: .bold)).foregroundStyle(.tertiary)
            chip("doc.plaintext.fill", arrow: natural ? "arrow.down" : "arrow.up", tint: Ink.tangerine, size: size)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(natural ? "Scrolling down moves the content down" : "Scrolling down moves the content up")
    }

    private func chip(_ symbol: String, arrow: String, tint: some ShapeStyle, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Image(systemName: arrow).fontWeight(.heavy)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 7 : 9)
        .frame(height: compact ? 22 : 26)
        .background(Capsule().fill(Palette.page))
    }
}

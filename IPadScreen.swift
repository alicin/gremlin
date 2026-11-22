import SwiftUI

private typealias Row = DevicesParts.Row

struct IPadScreen: View {
    @EnvironmentObject private var model: MenuModel

    static let keys = "⌃⌥⌘S"

    var body: some View {
        ScreenCard(module: .ipad) {
            if model.ipad != nil { HeaderNote(text: Self.keys, symbol: "keyboard") }
        } content: {
            if let ipad = model.ipad {
                HStack(alignment: .top, spacing: 18) {
                    PadHero(ipad: ipad) { model.perform(.toggleSidecar) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 14) {
                        Well("Shortcut") {
                            HStack(spacing: 12) {
                                DevicesParts.Keys(keys: Self.keys, small: false)
                                Text("Connects or disconnects from anywhere")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Well("How it works", fill: true) {
                            VStack(alignment: .leading, spacing: 14) {
                                Row(symbol: "rectangle.on.rectangle", tint: Palette.teal, title: "Connect makes it a Sidecar display",
                                    detail: "Disconnect gives it back")
                                Row(symbol: "arrow.left.arrow.right", tint: Palette.sky, title: "It always takes the iPad",
                                    detail: "Even from another Mac, or a session this Mac still holds")
                                Row(symbol: "ipad.and.iphone", tint: Palette.iris, title: "Several nearby?", detail: "It picks the first one")
                                Row(symbol: "macbook.and.ipad", tint: Palette.grape, title: "Busy as a display",
                                    detail: "Universal Control can't use it meanwhile, so the watcher leaves it alone")
                                Row(symbol: "shield.lefthalf.filled", tint: Palette.slate, title: "Hides if macOS changes",
                                    detail: "It uses the same calls as Control Center, and hides instead of misbehaving")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Unavailable()
            }
        }
    }
}

private struct PadHero: View {
    let ipad: MenuModel.IPad
    let toggle: () -> Void

    private var busy: Bool { ipad.state == .connecting || ipad.state == .disconnecting }

    private var status: (color: Color, text: String) {
        switch ipad.state {
        case .nearby: (Palette.good, "Nearby · ready to connect")
        case .connecting: (Palette.busy, "Connecting…")
        case .disconnecting: (Palette.busy, "Disconnecting…")
        case .connected: (Palette.busy, "Connected as a display")
        case .away: (Palette.slate, ipad.seen.map { "Not nearby · seen \($0.formatted(.relative(presentation: .named, unitsStyle: .wide)))" }
            ?? "Not nearby")
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            PadDrawing(state: ipad.state)
                .frame(maxWidth: 320)
                .padding(.horizontal, 8)
            VStack(spacing: 5) {
                Text(ipad.name).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                // Refreshes "seen 5 minutes ago" while the screen is open.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    HStack(spacing: 6) {
                        Circle().fill(status.color).frame(width: 7, height: 7)
                        Text(status.text)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
            }
            button
            if ipad.state == .away {
                Text("Wake it and bring it close to connect").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack(alignment: .bottomTrailing) {
                PaperSurface(tint: Palette.teal, radius: 18)
                DevicesParts.Watermark(symbol: "ipad.landscape", tint: Palette.teal, size: 150, opacity: 0.06)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .animation(Motion.bouncy, value: ipad.state)
    }

    @ViewBuilder private var button: some View {
        switch ipad.state {
        case .nearby, .away:
            Button(action: toggle) { Text("Connect").frame(minWidth: 130) }
                .buttonStyle(CapsuleButton(tint: Palette.teal, big: true))
                .disabled(ipad.state == .away)
                .opacity(ipad.state == .away ? 0.45 : 1)
        case .connected:
            Button(action: toggle) { Text("Disconnect").frame(minWidth: 130) }
                .buttonStyle(CapsuleButton(tint: Palette.teal, soft: true, big: true))
        case .connecting, .disconnecting:
            HStack(spacing: 8) {
                DevicesParts.Spinner(tint: Ink.teal)
                Text(ipad.state == .connecting ? "Connecting" : "Disconnecting")
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Ink.teal)
            .frame(minWidth: 130)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Capsule().fill(Palette.teal.opacity(0.14)))
        }
    }
}

/// The iPad in its module color, with what its screen is doing.
private struct PadDrawing: View {
    let state: MenuModel.IPad.State

    var body: some View {
        let away = state == .away
        let connected = state == .connected
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: away ? Module.restart.fill : Module.ipad.fill, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .shadow(color: (away ? Palette.slate : Palette.teal).opacity(0.35), radius: 16, y: 8)
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(connected ? AnyShapeStyle(Palette.page) : AnyShapeStyle(.white.opacity(0.18)))
                .overlay { if connected { MiniDesktop().padding(12) } }
                .padding(14)
            if !connected {
                Image(systemName: away ? "moon.zzz.fill" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white.opacity(away ? 0.75 : 1))
                    .symbolEffect(.variableColor.iterative, isActive: state == .connecting || state == .disconnecting)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .aspectRatio(1.45, contentMode: .fit)
        .opacity(away ? 0.8 : 1)
        .accessibilityHidden(true)
    }
}

/// A Mac desktop in miniature, for an iPad that is showing one.
private struct MiniDesktop: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().frame(width: 6, height: 6)
                Capsule().frame(width: 22, height: 4)
                Capsule().frame(width: 16, height: 4)
                Spacer()
                Capsule().frame(width: 26, height: 4)
            }
            .foregroundStyle(Color.primary.opacity(0.22))
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    window(Palette.teal).frame(width: g.size.width * 0.58, height: g.size.height * 0.72)
                    window(Palette.sky).frame(width: g.size.width * 0.5, height: g.size.height * 0.62)
                        .offset(x: g.size.width * 0.44, y: g.size.height * 0.3)
                }
            }
        }
    }

    private func window(_ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Palette.card)
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous)
                    .fill(tint.gradient)
                    .frame(height: 12)
            }
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1) }
            .shadow(color: Palette.shadow, radius: 5, y: 2)
    }
}

private struct Unavailable: View {
    var body: some View {
        Well(padding: 32, fill: true) {
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                IconTile(symbol: "ipad.landscape", tint: Palette.slate, size: 64)
                Text("Sidecar isn't available").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Gremlin uses the same private calls as the Displays menu in Control Center. This version of macOS doesn't have them, so the iPad stays out of the way instead of misbehaving.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

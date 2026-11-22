import SwiftUI

private typealias Row = DevicesParts.Row

struct RestartScreen: View {
    @EnvironmentObject private var model: MenuModel

    private static let columns = 3

    var body: some View {
        ScreenCard(module: .restart) {
            RestartAllButton()
        } content: {
            VStack(spacing: 12) {
                ForEach(Array(stride(from: 0, to: Restart.items.count, by: Self.columns)), id: \.self) { start in
                    HStack(spacing: 12) {
                        ForEach(start..<min(start + Self.columns, Restart.items.count), id: \.self) { PartTile(index: $0) }
                    }
                }
                watchdog
            }
        }
    }

    private var watchdog: some View {
        let key = AppSwitch.notificationCenterWatchdog
        let on = model.switches[key] ?? false
        return Well(padding: 14) {
            Row(symbol: "bell.badge.fill", tint: on ? Palette.mint : Palette.slate, title: "Fix stuck Notification Center",
                detail: "Restarts it by itself when a frozen banner keeps it above 90% CPU for 30 seconds") {
                ToggleSwitch(isOn: on, tint: Palette.mint, label: "Fix stuck Notification Center") { model.perform(.setSwitch(key, !on)) }
            }
        }
    }
}

/// Restarting everything also empties the clipboard, so the button asks for a second click.
private struct RestartAllButton: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let armed = model.confirmRestartAll
        let everything = model.restarted.count == Restart.items.count
        HStack(spacing: 12) {
            if armed {
                Text("This empties the clipboard too")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .transition(.opacity.combined(with: .offset(x: 12)))
            }
            Button { model.perform(.restartAll) } label: {
                Label(armed ? "Click again to restart all" : everything ? "Everything restarted" : "Restart all",
                      systemImage: armed ? "exclamationmark.triangle.fill" : everything ? "checkmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(CapsuleButton(tint: armed ? Palette.coral : Palette.slate.mixed(with: .black, 0.12), white: !armed, big: true))
            .help("Restarts every part below. It also empties the clipboard, so it takes a second click.")
        }
        .animation(Motion.snappy, value: armed)
    }
}

private struct PartTile: View {
    let index: Int
    @EnvironmentObject private var model: MenuModel

    // The README's "Try it when" column, cut to fit two lines in the narrowest window.
    private static let when = [
        "Dock": "Mission Control, Spaces or ⌃\u{2011}number keys stop working",
        "Finder": "Finder windows or the desktop stop responding",
        "Menu Bar": "Menu bar items are missing or frozen",
        "Control Center": "Control Center or its menu bar icons misbehave",
        "Notification Center": "Banners freeze or notifications stop showing",
        "Window Manager": "Stage Manager or window tiling gets stuck",
        "Clipboard": "Copy, paste or drag and drop stop working",
        "Universal Clipboard": "Copying on one device no longer pastes on another",
        "iCloud Drive": "iCloud Drive stops syncing",
    ]
    private static let caveats = ["Clipboard": "Empties it."]

    var body: some View {
        let item = Restart.items[index]
        let done = model.restarted.contains(index)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button { model.perform(.restart(index)) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    IconTile(symbol: item.symbol, tint: done ? Palette.mint : Palette.slate, size: 38)
                    Spacer()
                    Image(systemName: done ? "checkmark" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(done ? AnyShapeStyle(Ink.mint) : AnyShapeStyle(.secondary))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.page))
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer(minLength: 10)
                Text(item.title).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                Group {
                    if done {
                        Text("Restarted").fontWeight(.semibold).foregroundStyle(Ink.mint)
                    } else if let caveat = Self.caveats[item.title] {
                        Text("\(Self.when[item.title] ?? item.hint). \(Text(caveat).fontWeight(.semibold).foregroundStyle(Ink.amber))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.when[item.title] ?? item.hint).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack(alignment: .bottomTrailing) {
                    shape.fill(Palette.well)
                    if done { shape.fill(Palette.mint.opacity(0.12)) }
                    DevicesParts.Watermark(symbol: item.symbol, tint: done ? Palette.mint : Palette.slate, size: 84, opacity: done ? 0.1 : 0.07)
                }
                .clipShape(shape)
            }
            .overlay { if done { shape.strokeBorder(Palette.mint.opacity(0.35), lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(DevicesParts.TileStyle())
        .hoverLift(1.02)
        .help("Restarts \(item.processes.joined(separator: ", then "))")
        .accessibilityLabel("Restart \(item.title)")
        .accessibilityValue(done ? "Restarted" : "")
        .animation(Motion.bouncy, value: done)
    }
}

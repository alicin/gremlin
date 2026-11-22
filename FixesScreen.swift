import SwiftUI

// The watchers that fix macOS bugs as they happen, each with what goes wrong and what Gremlin does about it.
struct FixesScreen: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let on = Fix.all.filter { model.switches[$0.key] ?? false }.count
        ScreenCard(module: .fixes) {
            HeaderNote(text: "\(on) of \(Fix.all.count) on", symbol: on == 0 ? "shield.slash.fill" : "checkmark.shield.fill")
        } content: {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    ForEach(Fix.all) { FixCard(fix: $0) }
                }
                Well(padding: 16) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "doc.text.magnifyingglass", tint: Palette.slate, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Everything a fix does is logged").font(.system(size: 13.5, weight: .semibold))
                            Text("~/Library/Logs/Gremlin.log").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Open Log") { model.perform(.open(Log.url)) }
                            .buttonStyle(CapsuleButton(neutral: true))
                    }
                }
            }
        }
    }
}

private struct Fix: Identifiable {
    let key: String
    let title: String
    let symbol: String
    let bug: String
    let fix: String

    var id: String { key }

    static let all = [
        Fix(key: AppSwitch.autoFixFocus, title: "Auto-Fix Lost Focus", symbol: "scope",
            bug: "The menu bar shows one app while your typing goes nowhere, or to a window behind it. It happens most after switching Spaces or using Universal Control.",
            fix: "When the front app has windows on screen but none has focus for 3 seconds, Gremlin hands focus back and raises the window."),
        Fix(key: AppSwitch.notificationCenterWatchdog, title: "Fix Stuck Notification Center", symbol: "bell.badge.fill",
            bug: "On macOS 27, a banner can freeze halfway in while Notification Center spins at full CPU until it's killed.",
            fix: "When it stays above 90% CPU for 30 seconds, Gremlin restarts it, and macOS brings it straight back."),
        Fix(key: AppSwitch.universalControlWatcher, title: "Universal Control Watcher", symbol: "macbook.and.ipad",
            bug: "After a Mac wakes up, devices sometimes fail their first handshake and macOS gives up, leaving the pointer stuck on one side.",
            fix: "Gremlin reads Universal Control's logs, spots the moment it gives up and toggles it for you. A paired Mac can do it for the other."),
    ]
}

private struct FixCard: View {
    let fix: Fix
    @EnvironmentObject private var model: MenuModel

    private var on: Bool { model.switches[fix.key] ?? false }
    private var needsAccess: Bool { fix.key == AppSwitch.autoFixFocus && !model.accessibility }

    private var status: (color: Color, text: String) {
        switch fix.key {
        case AppSwitch.autoFixFocus:
            if needsAccess { return (Palette.warn, on ? "On · needs Accessibility" : "Off · needs Accessibility") }
            return on ? (Palette.good, "On · watching the front window") : (Palette.slate, "Off")
        case AppSwitch.universalControlWatcher:
            return on && model.watcher.isOn ? (model.watcher.tone.color, "On · \(KeepAwakeInfo.lowered(model.watcher.status))") : on ? (Palette.good, "On") : (Palette.slate, "Off")
        default:
            return on ? (Palette.good, "On · watching its CPU") : (Palette.slate, "Off")
        }
    }

    var body: some View {
        Well(padding: 20, fill: true) {
            HStack(alignment: .top) {
                IconTile(symbol: fix.symbol, tint: on ? Palette.mint : Palette.slate, size: 50)
                Spacer()
                ToggleSwitch(isOn: on, tint: Palette.mint, label: fix.title) { model.perform(.setSwitch(fix.key, !on)) }
            }
            Text(fix.title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            paragraph("What goes wrong", fix.bug)
            paragraph("What Gremlin does", fix.fix)
            Spacer(minLength: 6)
            if fix.key == AppSwitch.universalControlWatcher, on, !model.watcher.lastReset.isEmpty {
                Text(model.watcher.lastReset).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if needsAccess {
                Button("Allow in Settings") { model.perform(.open(ToolsCatalog.accessibilitySettings)) }
                    .buttonStyle(CapsuleButton(tint: Palette.warn, soft: true))
                    .help("Opens Privacy & Security › Accessibility")
            }
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Palette.page))
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: fix.symbol)
                .font(.system(size: 120, weight: .bold))
                .foregroundStyle(Palette.mint.opacity(on ? 0.08 : 0.035))
                .rotationEffect(.degrees(-12))
                .offset(x: 18, y: 14)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(Motion.snappy, value: on)
    }

    private func paragraph(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

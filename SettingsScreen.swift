import AppKit
import SwiftUI

private typealias Row = DevicesParts.Row

struct SettingsScreen: View {
    @EnvironmentObject private var model: MenuModel
    @EnvironmentObject private var navigator: Navigator

    private static let anywhere = [
        ("Record the screen", "⌃⌥⌘R"),
        ("Record audio only", "⌃⌥⌘A"),
        ("Grab Text", "⇧⌘1"),
        ("Pick Color", "⇧⌘2"),
        ("Plain Paste", "⌃⌥⌘V"),
        ("Fix Focus", "⌃⌥⌘F"),
        ("Connect the iPad", "⌃⌥⌘S"),
        ("Open the copied link", "⌃⌥⌘L"),
        ("Show the shelf", "⌃⌥⌘G"),
    ]
    private static let inWindow = [("Search", "⌘K"), ("Settings", "⌘,")]

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        ScreenCard(module: .settings) {
            EmptyView()
        } content: {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 14) {
                    everyday
                    fixes
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 14) {
                    shortcuts
                    about
                }
                .frame(width: 320)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var everyday: some View {
        Well("Everyday") {
            VStack(spacing: 14) {
                Row(symbol: "power", tint: Palette.mint, title: "Start at login", detail: "Gremlin opens when you log in") {
                    ToggleSwitch(isOn: model.login, tint: Palette.accent, label: "Start at login") { model.perform(.setLogin(!model.login)) }
                }
                toggle(AppSwitch.offerToRecordCalls, symbol: "phone.arrow.up.right.fill", tint: Palette.coral,
                       title: "Offer to record calls", detail: "Asks when a call takes the mic")
                Row(symbol: "character.bubble.fill", tint: Palette.iris, title: "Transcript language", detail: "Automatic lets whisper detect it") {
                    LanguageMenu()
                }
                Row(symbol: "folder.fill", tint: Palette.sky, title: "Recordings", detail: "~/Movies/Meetings") {
                    Button("Show in Finder") { model.perform(.showRecordings) }.buttonStyle(CapsuleButton(neutral: true))
                }
            }
        }
    }

    private var fixes: some View {
        Well(fill: true) {
            DevicesParts.Heading(title: "Background fixes") {
                Button { navigator.go(.fixes) } label: {
                    HStack(spacing: 3) {
                        Text("Fixes")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.mint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("What each fix watches for")
            }
            VStack(spacing: 14) {
                toggle(AppSwitch.autoFixFocus, symbol: "scope", title: "Auto-fix lost focus",
                       detail: model.accessibility ? "Gives keystrokes back to the front window" : "Needs Accessibility permission")
                toggle(AppSwitch.notificationCenterWatchdog, symbol: "bell.badge.fill", title: "Fix stuck Notification Center",
                       detail: "Restarts it when it spins at full CPU")
                toggle(AppSwitch.universalControlWatcher, symbol: "macbook.and.ipad", title: "Universal Control watcher",
                       detail: "Resets it when a device gives up")
            }
        }
    }

    private var shortcuts: some View {
        Well("Shortcuts", trailing: "Work anywhere", fill: true) {
            VStack(spacing: 7) {
                ForEach(Self.anywhere, id: \.0) { shortcut($0.0, $0.1) }
                HStack {
                    Text("In this window").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 6)
                ForEach(Self.inWindow, id: \.0) { shortcut($0.0, $0.1) }
            }
        }
    }

    private var about: some View {
        Well(padding: 16) {
            HStack(spacing: 12) {
                AppIconView(size: 46).shadow(color: Palette.indigo.opacity(0.3), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gremlin").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Version \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Quit Gremlin") { model.perform(.quit) }
                    .buttonStyle(CapsuleButton(tint: Palette.coral, soft: true))
                    .help("Quit Gremlin  ⌘Q")
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Everything it does is logged to").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text("~/Library/Logs/Gremlin.log").font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.85).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Open") { NSWorkspace.shared.open(Log.url) }
                    .buttonStyle(CapsuleButton(neutral: true))
                    .help("Opens the log in Console")
            }
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            DevicesParts.Keys(keys: keys)
        }
    }

    private func toggle(_ key: String, symbol: String, tint: Color? = nil, title: String, detail: String) -> some View {
        let on = model.switches[key] ?? false
        return Row(symbol: symbol, tint: tint ?? (on ? Palette.mint : Palette.slate), title: title, detail: detail) {
            ToggleSwitch(isOn: on, tint: Palette.accent, label: title) { model.perform(.setSwitch(key, !on)) }
        }
    }
}

private struct LanguageMenu: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let current = MenuModel.languages.first { $0.code == model.language }?.name ?? model.language ?? "Automatic"
        Menu {
            ForEach(MenuModel.languages, id: \.name) { language in
                Button {
                    model.perform(.setLanguage(language.code))
                } label: {
                    if language.code == model.language { Label(language.name, systemImage: "checkmark") } else { Text(language.name) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(current).font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(Palette.page))
            .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

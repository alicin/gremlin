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
                    MeetingSyncWell()
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

private struct MeetingSyncWell: View {
    @EnvironmentObject private var model: MenuModel
    @StateObject private var clientID = Box("")
    @StateObject private var secret = Box("")
    @StateObject private var changing = Box(false)

    var body: some View {
        let sync = model.sync
        Well("Sync meetings", trailing: "Google Drive") {
            VStack(alignment: .leading, spacing: 12) {
                Row(symbol: "arrow.triangle.2.circlepath", tint: sync.connected ? Palette.sky : Palette.slate,
                    title: sync.account ?? "Google Drive", detail: sync.summary) {
                    actions(sync)
                }
                if let problem = sync.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Ink.coral).fixedSize(horizontal: false, vertical: true)
                }
                if !sync.connected, !sync.signingIn, !sync.hasClient || changing.value { setup(sync) }
                Text("Each meeting goes to a Gremlin Meetings folder in Drive, and every Mac signed in to the same account gets it. "
                     + "The copies on this Mac stay, and nothing gets deleted on either side.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func actions(_ sync: MeetingSync.Status) -> some View {
        if sync.signingIn {
            Button("Cancel") { model.perform(.cancelDriveSignIn) }.buttonStyle(CapsuleButton(neutral: true))
        } else if sync.connected {
            HStack(spacing: 8) {
                if sync.syncing {
                    DevicesParts.Spinner(tint: Palette.sky, size: 16)
                } else {
                    Button("Sync Now") { model.perform(.syncMeetings) }.buttonStyle(CapsuleButton(tint: Palette.sky, soft: true))
                }
                Button("Sign Out") { model.perform(.signOutOfDrive) }.buttonStyle(CapsuleButton(neutral: true))
            }
        } else if sync.hasClient, !changing.value {
            HStack(spacing: 8) {
                Button("Sign In") { model.perform(.signInToDriveAgain) }.buttonStyle(CapsuleButton(tint: Palette.sky))
                Menu {
                    Button("Use a Different Google App") { changing.value = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func setup(_ sync: MeetingSync.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if sync.clipboardHasClient {
                Button("Use Clipboard's Google App") { model.perform(.signInToDriveWithClipboard) }
                    .buttonStyle(CapsuleButton(tint: Palette.sky))
                    .help("Signs in with the client ID and secret Clipboard syncs with. macOS asks before Gremlin can read them.")
                Text("Or enter the client ID and secret from your Google Cloud project:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter the client ID and secret from your Google Cloud project, the same on every Mac:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("", text: $clientID.value, prompt: Text("Client ID")).syncField()
            SecureField("", text: $secret.value, prompt: Text("Client secret")).syncField()
            HStack(spacing: 8) {
                Button("Sign In") {
                    model.perform(.signInToDrive(id: clientID.value, secret: secret.value))
                    secret.value = ""
                    changing.value = false
                }
                .buttonStyle(CapsuleButton(tint: Palette.sky))
                .disabled(clientID.value.trimmingCharacters(in: .whitespaces).isEmpty || secret.value.trimmingCharacters(in: .whitespaces).isEmpty)
                if changing.value {
                    Button("Cancel") { changing.value = false }.buttonStyle(CapsuleButton(neutral: true))
                }
            }
        }
        .onAppear { if clientID.value.isEmpty { clientID.value = sync.clientID } }
    }
}

private extension View {
    func syncField() -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(Palette.page))
            .overlay(shape.strokeBorder(Palette.stroke, lineWidth: 1))
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

import AppKit
import SwiftUI

// Drives in the window: a card for each drive, vivid while it's mounted, and an editor that slides in beside them.
// The editor keeps its own selection rather than `Drives.editing`, which the menu bar panel's drive page uses.

private enum Leaf {
    static let fill = Palette.lime
    static let deep = Palette.lime.mixed(with: .black, 0.3)
    static let ink = Ink.lime
    static let night = Palette.lime.mixed(with: .black, 0.5)
    // Deeper than the module's fill, so white text on a mounted drive stays readable.
    static let vivid = [Palette.lime.mixed(with: .white, 0.06), Palette.lime.mixed(with: .black, 0.1), Palette.lime.mixed(with: .black, 0.28)]
}

struct DrivesScreen: View {
    @EnvironmentObject private var drives: Drives
    @StateObject private var editing = Box<UUID?>(nil)
    @StateObject private var created = Box<UUID?>(nil)

    private var editor: UUID? {
        guard let id = editing.value, drives.config.drives.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        ScreenCard(module: .drives, scrolls: false) {
            Button(action: add) { Label("Add drive", systemImage: "plus") }
                .buttonStyle(CapsuleButton(tint: Leaf.deep, white: true))
        } content: {
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.vertical) {
                    DriveBoard(editing: editor, edit: open, add: add).padding(18)
                }
                .scrollIndicators(.automatic)
                if let id = editor {
                    DriveEditor(id: id, isNew: created.value == id, close: close, remove: remove)
                        .id(id)
                        .frame(width: 330)
                        .padding([.top, .bottom, .trailing], 18)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(-18)
        }
        .onAppear { drives.refresh() }
        .onDisappear(perform: dropBlank)
    }

    private func add() {
        let drive = drives.add(host: "")
        open(drive.id)
        created.value = drive.id
    }

    private func open(_ id: UUID) {
        guard id != editing.value else { return }
        dropBlank()
        withAnimation(Motion.snappy) { editing.value = id }
    }

    private func close() {
        dropBlank()
        withAnimation(Motion.snappy) { editing.value = nil }
    }

    private func remove(_ drive: Drive) {
        withAnimation(Motion.snappy) { editing.value = nil }
        drives.remove(drive)
    }

    // A drive left without a host was never really added.
    private func dropBlank() {
        guard let drive = drives.config.drives.first(where: { $0.id == editing.value }),
              drive.host.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        drives.remove(drive)
    }
}

// MARK: - State

private enum DriveState: Equatable {
    case noHost, off, failed, connecting, mounted, offline, inUse, stuck, ejecting

    init(_ drive: Drive, _ status: Drives.Status) {
        switch status.phase {
        case .connecting: self = .connecting
        case .ejecting: self = .ejecting
        case .mounted: self = status.offline ? .offline : status.inUse ? .inUse : status.problem != nil ? .stuck : .mounted
        case .off:
            if status.problem != nil { self = .failed }
            else { self = drive.host.trimmingCharacters(in: .whitespaces).isEmpty ? .noHost : .off }
        }
    }

    var label: String {
        switch self {
        case .noHost: "No host yet"
        case .off: "Not mounted"
        case .failed: "Couldn't mount"
        case .connecting: "Connecting"
        case .mounted: "Mounted"
        case .offline: "Offline"
        case .inUse: "In use"
        case .stuck: "Still mounted"
        case .ejecting: "Ejecting"
        }
    }

    var busy: Bool { self == .connecting || self == .ejecting }
    var warning: Bool { [.failed, .offline, .inUse, .stuck].contains(self) }
    var isMounted: Bool { [.mounted, .offline, .inUse, .stuck].contains(self) }
}

// MARK: - Board

private struct DriveBoard: View {
    let editing: UUID?
    let edit: (UUID) -> Void
    let add: () -> Void
    @EnvironmentObject private var drives: Drives

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if drives.config.drives.isEmpty {
                EmptyDrives(add: add)
            } else {
                TileGrid(minWidth: 240, spacing: 14) {
                    ForEach(drives.config.drives) { drive in
                        DriveCard(drive: drive, selected: editing == drive.id) { edit(drive.id) }
                    }
                    if editing == nil { AddTile(add: add) }
                }
            }
            TileGrid(minWidth: 320, spacing: 14) {
                OnThisMac()
                HowItWorks()
            }
        }
    }
}

private struct DriveCard: View {
    let drive: Drive
    let selected: Bool
    let edit: () -> Void
    @EnvironmentObject private var drives: Drives

    var body: some View {
        let status = drives.status(of: drive)
        let state = DriveState(drive, status)
        let vivid = state == .mounted
        let sub: Color = vivid ? .white.opacity(0.82) : .secondary
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                DriveIcon(state: state, vivid: vivid)
                Spacer(minLength: 8)
                StateChip(state: state, vivid: vivid)
            }
            .padding(.bottom, 14)
            HStack(spacing: 6) {
                Text(drive.title.isEmpty ? "New drive" : drive.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if drive.readOnly {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(sub).help("Read only")
                }
            }
            if !drive.host.isEmpty {
                Text(drive.place)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(sub)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 3)
            }
            if let line = detail(state) {
                Label(line.text, systemImage: line.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(vivid ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            Rectangle().fill(vivid ? Color.white.opacity(0.24) : Palette.stroke).frame(height: 1).padding(.vertical, 14)
            VStack(spacing: 10) {
                row("Folder") {
                    Text(drive.folder.isEmpty ? "Home folder" : drive.folder)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(sub).lineLimit(1).truncationMode(.head)
                }
                row("Mount when Gremlin starts") {
                    ToggleSwitch(isOn: drive.mountAtLaunch, tint: vivid ? Leaf.night : Leaf.fill, small: true, label: "Mount when Gremlin starts") {
                        drives.update(drive.id) { $0.mountAtLaunch.toggle() }
                    }
                }
                row("Read only") {
                    ToggleSwitch(isOn: drive.readOnly, tint: vivid ? Leaf.night : Leaf.fill, small: true, label: "Read only") {
                        drives.update(drive.id) { $0.readOnly.toggle() }
                    }
                }
            }
            Spacer(minLength: 16)
            if let problem = problem(state, status) {
                Text(problem)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
            DriveActions(drive: drive, state: state, vivid: vivid, edit: edit)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(vivid ? Color.white : Color.primary)
        .background {
            if vivid {
                VividSurface(colors: Leaf.vivid, symbol: "externaldrive.fill.badge.wifi", radius: 22)
            } else {
                PaperSurface(tint: state.warning ? Palette.warn : Palette.lime, radius: 22)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Palette.lime, lineWidth: 2)
                    .padding(-4)
            }
        }
        .animation(Motion.snappy, value: state)
    }

    private func row(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            value()
        }
        .frame(minHeight: 20)
    }

    private func detail(_ state: DriveState) -> (text: String, symbol: String)? {
        switch state {
        case .mounted, .offline, .inUse, .stuck:
            ("~/Drives/\(drives.mountPoint(of: drive)?.lastPathComponent ?? Drives.safeName(drive.title))", "folder.fill")
        case .connecting: ("Connecting to \(drive.host)…", "network")
        case .ejecting: ("Ejecting…", "eject.fill")
        default: nil
        }
    }

    private func problem(_ state: DriveState, _ status: Drives.Status) -> String? {
        switch state {
        case .inUse: "An app has a file open on it."
        case .failed, .offline, .stuck: status.problem
        default: nil
        }
    }
}

private struct DriveIcon: View {
    let state: DriveState
    let vivid: Bool

    var body: some View {
        if vivid {
            Image(systemName: "externaldrive.fill.badge.wifi")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
        } else {
            IconTile(symbol: state.isMounted ? "externaldrive.fill.badge.exclamationmark" : "externaldrive.fill",
                     tint: state.warning ? Palette.amber : state.busy ? Palette.lime : Palette.slate, size: 44)
        }
    }
}

private struct StateChip: View {
    let state: DriveState
    let vivid: Bool

    var body: some View {
        let ink: Color = vivid ? .white : state.warning ? Ink.amber : state.busy ? Ink.sky : .secondary
        let fill: Color = vivid ? .white.opacity(0.22) : state.warning ? Palette.warn.opacity(0.15) : state.busy ? Palette.busy.opacity(0.14) : Color.primary.opacity(0.07)
        HStack(spacing: 5) {
            if state.busy {
                Spin(tint: ink, size: 10, line: 1.6)
            } else {
                Circle().fill(vivid ? Color.white : state.warning ? Palette.warn : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
            }
            Text(state.label).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(fill))
    }
}

private struct DriveActions: View {
    let drive: Drive
    let state: DriveState
    let vivid: Bool
    let edit: () -> Void
    @EnvironmentObject private var drives: Drives

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .noHost:
                Button("Add a host", action: edit).buttonStyle(CapsuleButton(tint: Leaf.deep))
            case .off:
                Button("Mount") { drives.mount(drive, reveal: true) }.buttonStyle(CapsuleButton(tint: Leaf.deep))
            case .failed:
                Button("Try again") { drives.mount(drive, reveal: true) }.buttonStyle(CapsuleButton(tint: Leaf.deep))
            case .connecting:
                Button("Cancel") { drives.cancel(drive) }.buttonStyle(CapsuleButton(neutral: true))
            case .mounted:
                Button { drives.reveal(drive) } label: { Label("Open", systemImage: "folder") }
                    .buttonStyle(CapsuleButton(tint: Leaf.deep, white: true))
                Button("Eject") { drives.eject(drive) }.buttonStyle(OnColorCapsule())
            case .offline:
                Button("Reconnect") { drives.reconnect(drive) }.buttonStyle(CapsuleButton(tint: Leaf.deep))
                Button("Eject") { drives.eject(drive) }.buttonStyle(CapsuleButton(neutral: true))
            case .inUse:
                Button("Eject anyway") { drives.eject(drive, force: true) }.buttonStyle(CapsuleButton(tint: Palette.coral))
                Button("Open") { drives.reveal(drive) }.buttonStyle(CapsuleButton(neutral: true))
            case .stuck:
                Button("Eject") { drives.eject(drive) }.buttonStyle(CapsuleButton(tint: Leaf.deep))
                Button("Open") { drives.reveal(drive) }.buttonStyle(CapsuleButton(neutral: true))
            case .ejecting:
                EmptyView()
            }
            Spacer(minLength: 0)
            if state != .noHost {
                Button(action: edit) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(RoundButton(onColor: vivid))
                .help("Edit \(drive.title)")
                .accessibilityLabel("Edit \(drive.title)")
            }
        }
        .frame(height: 30)
    }
}

private struct AddTile: View {
    let add: () -> Void
    @EnvironmentObject private var drives: Drives

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 16) {
            Button(action: add) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Leaf.ink)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Leaf.fill.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add a drive").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Any folder on a server you can ssh into")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(1.01)
            if !drives.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("From your SSH config").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    SuggestionChips()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Leaf.fill.opacity(0.05)))
        .overlay(shape.strokeBorder(Leaf.fill.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

private struct SuggestionChips: View {
    @EnvironmentObject private var drives: Drives
    private let shown = 6

    var body: some View {
        let hosts = drives.suggestions
        Flow(spacing: 6) {
            ForEach(hosts.prefix(shown), id: \.self) { host in
                Button { withAnimation(Motion.bouncy) { _ = drives.add(host: host) } } label: {
                    Label(host, systemImage: "plus").lineLimit(1)
                }
                .buttonStyle(SoftCapsule(fill: Leaf.fill, ink: Leaf.ink))
                .help("Add \(host) as a drive")
            }
            if hosts.count > shown {
                Menu {
                    ForEach(hosts.dropFirst(shown), id: \.self) { host in
                        Button(host) { withAnimation(Motion.bouncy) { _ = drives.add(host: host) } }
                    }
                } label: {
                    Text("\(hosts.count - shown) more").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(Capsule().fill(Palette.well2))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

private struct EmptyDrives: View {
    let add: () -> Void
    @EnvironmentObject private var drives: Drives

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            IconTile(symbol: "externaldrive.fill.badge.wifi", tint: Palette.lime, size: 64)
            VStack(alignment: .leading, spacing: 8) {
                Text("Mount a server's folder in Finder").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("A drive is a folder on a server you can ssh into, mounted so it shows up in Finder like a disk. It lives in ~/Drives, so Terminal and every app can use it too.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                HStack(alignment: .top, spacing: 10) {
                    Button(action: add) { Label("Add drive", systemImage: "plus") }.buttonStyle(CapsuleButton(tint: Leaf.deep))
                    if !drives.suggestions.isEmpty { SuggestionChips() }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperSurface(tint: Palette.lime, radius: 22))
    }
}

private struct OnThisMac: View {
    @EnvironmentObject private var drives: Drives

    var body: some View {
        Well("On this Mac", fill: true) {
            InfoRow(symbol: "folder.fill", tint: Palette.sky, title: "~/Drives",
                    detail: "A folder for each drive, so every app can use it.") {
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: Drives.mountFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Drives.mountFolder)
                }
                .buttonStyle(CapsuleButton(neutral: true))
            }
            InfoRow(symbol: "doc.badge.gearshape.fill", tint: Palette.slate, title: "Keep Mac files here",
                    detail: "Finder's ._ files and .DS_Store stay on this Mac, so the server stays clean."
                        + (drives.anyMounted ? " Applies the next time a drive mounts." : "")) {
                ToggleSwitch(isOn: drives.config.keepMacFiles, tint: Leaf.fill, label: "Keep Mac files here") {
                    drives.config.keepMacFiles.toggle()
                }
            }
            InfoRow(symbol: "eject.fill", tint: Palette.iris, title: "Ejected when Gremlin quits",
                    detail: "Every drive comes off first. Ejecting from Finder works too.")
        }
    }
}

private struct HowItWorks: View {
    var body: some View {
        Well("Connects like ssh", fill: true) {
            InfoRow(symbol: "terminal.fill", tint: Palette.indigoLift, title: "Your ssh config, keys and agent",
                    detail: "ProxyJump too. A host that works in Terminal works here, and Gremlin asks if it wants a password.")
            InfoRow(symbol: "shippingbox.fill", tint: Palette.amber, title: "Nothing to install",
                    detail: "No macFUSE on the Mac. The server only needs SFTP, which comes with OpenSSH.")
            InfoRow(symbol: "arrow.triangle.2.circlepath", tint: Palette.teal, title: "Comes back by itself",
                    detail: "After sleep or a network change, the next read or write reconnects.")
        }
    }
}

// MARK: - Editor

private struct DriveEditor: View {
    let id: UUID
    let isNew: Bool
    let close: () -> Void
    let remove: (Drive) -> Void
    @EnvironmentObject private var drives: Drives
    @StateObject private var saved = Box(false)
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, host, folder }

    var body: some View {
        if let drive = drives.config.drives.first(where: { $0.id == id }) {
            let state = DriveState(drive, drives.status(of: drive))
            EditorPanel(module: .drives, symbol: "externaldrive.fill", caption: isNew ? "Add a drive" : "Edit drive",
                        title: drive.title.isEmpty ? "New drive" : drive.title, done: close) {
                Well("Server", padding: 14) {
                    field("Name", prompt: drive.host.isEmpty ? "Shown in Finder" : drive.host, text: text(\.name), focus: .name)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Host").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if !drives.sshHosts.isEmpty { hostMenu(drive) }
                        }
                        TextField("", text: text(\.host), prompt: Text("user@host, or a config Host"))
                            .modifier(FieldBox(focused: focus == .host, mono: true))
                            .focused($focus, equals: .host)
                    }
                    field("Folder", prompt: "Home folder", text: text(\.folder), focus: .folder, mono: true)
                    Text("Gremlin connects the way ssh does in Terminal, with your config, keys, agent and ProxyJump.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Well("Options", padding: 14) {
                    option("Mount when Gremlin starts", "And again when the network comes back", on: drive.mountAtLaunch) {
                        drives.update(id) { $0.mountAtLaunch.toggle() }
                    }
                    option("Read only", "Files on the server can't be changed from here", on: drive.readOnly) {
                        drives.update(id) { $0.readOnly.toggle() }
                    }
                    if saved.value {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Saved password").font(.system(size: 13, weight: .semibold))
                                Text("In your Keychain").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Forget") {
                                Askpass.forget(host: drive.host)
                                saved.value = false
                            }
                            .buttonStyle(CapsuleButton(neutral: true))
                        }
                    }
                }
                if state.isMounted {
                    Label("Changes apply the next time it mounts.", systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if let problem = drives.status(of: drive).problem, state != .inUse {
                    Text(problem)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                actions(drive, state)
            }
            .onAppear {
                saved.value = Askpass.hasSaved(host: drive.host)
                if isNew {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focus = .host }
                }
            }
        }
    }

    private func text(_ key: WritableKeyPath<Drive, String>) -> Binding<String> {
        Binding(get: { drives.config.drives.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in drives.update(id) { $0[keyPath: key] = value } })
    }

    private func field(_ title: String, prompt: String, text: Binding<String>, focus field: Field, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt))
                .modifier(FieldBox(focused: focus == field, mono: mono))
                .focused($focus, equals: field)
        }
    }

    private func hostMenu(_ drive: Drive) -> some View {
        Menu {
            ForEach(drives.sshHosts, id: \.self) { host in
                Button(host) {
                    drives.update(id) { drive in
                        if drive.name.isEmpty || drive.name == drive.host { drive.name = host }
                        drive.host = host
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("From SSH config")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Leaf.ink)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func option(_ title: String, _ detail: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ToggleSwitch(isOn: on, tint: Leaf.fill, label: title, action: toggle)
        }
    }

    @ViewBuilder private func actions(_ drive: Drive, _ state: DriveState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .noHost, .off, .failed:
                let ready = !drive.host.trimmingCharacters(in: .whitespaces).isEmpty
                Button { drives.mount(drive, reveal: true) } label: { Text(state == .failed ? "Try again" : "Mount").frame(maxWidth: .infinity) }
                    .buttonStyle(CapsuleButton(tint: Leaf.deep))
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.45)
            case .connecting:
                Button { drives.cancel(drive) } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(CapsuleButton(neutral: true))
            case .mounted, .offline, .inUse, .stuck, .ejecting:
                Button { drives.eject(drive, force: state == .inUse) } label: {
                    Text(state == .ejecting ? "Ejecting…" : state == .inUse ? "Eject anyway" : "Eject").frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButton(tint: state == .inUse ? Palette.coral : Leaf.deep, neutral: state != .inUse))
                .disabled(state == .ejecting)
            }
            RemoveButton(title: "Remove drive") { remove(drive) }
        }
    }
}

// MARK: - Pieces

private struct EditorPanel<Content: View, Footer: View>: View {
    let module: Module
    let symbol: String
    let caption: String
    let title: String
    let done: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption).font(.system(size: 11.5, weight: .semibold)).opacity(0.85)
                    Text(title).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Done", action: done)
                    .buttonStyle(CapsuleButton(tint: module.tint.mixed(with: .black, 0.3), white: true))
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 66)
            .background(VividSurface(colors: module.fill, symbol: symbol, radius: 0, glow: false))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(14)
            }
            .scrollIndicators(.automatic)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Rectangle().fill(Palette.stroke).frame(height: 1) }
        }
        .clipShape(shape)
        .background(PaperSurface(tint: module.tint, radius: 22))
    }
}

private struct InfoRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

private extension InfoRow where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}

private struct FieldBox: ViewModifier {
    let focused: Bool
    var mono = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: mono ? .monospaced : .default))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(Palette.page))
            .overlay(shape.strokeBorder(focused ? Leaf.fill : Palette.stroke, lineWidth: focused ? 1.5 : 1))
            .animation(Motion.snappy, value: focused)
    }
}

// Removing asks for a second click, since there's no undo.
private struct RemoveButton: View {
    let title: String
    let action: () -> Void
    @StateObject private var armed = Box(false)

    var body: some View {
        Button {
            if armed.value { return action() }
            withAnimation(Motion.snappy) { armed.value = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation(Motion.snappy) { armed.value = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash").font(.system(size: 12.5, weight: .semibold))
                if armed.value { Text("Remove?").font(.system(size: 13, weight: .semibold, design: .rounded)).fixedSize() }
            }
            .foregroundStyle(armed.value ? Color.white : Ink.coral)
            .padding(.horizontal, armed.value ? 12 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(Capsule().fill(armed.value ? AnyShapeStyle(Palette.coral.gradient) : AnyShapeStyle(Palette.coral.opacity(0.14))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct SoftCapsule: ButtonStyle {
    let fill: Color
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(ink)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(fill.opacity(0.16)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

private struct OnColorCapsule: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(.white.opacity(0.22)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

private struct RoundButton: ButtonStyle {
    var onColor = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(onColor ? Color.white : Color.primary)
            .background(Circle().fill(onColor ? Color.white.opacity(0.22) : Palette.well2))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

private struct Spin: View {
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

/// Columns at least `minWidth` wide, as many as fit and no more than there are tiles, with each row as tall as its tallest tile.
private struct TileGrid: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat = 14

    private func measure(_ width: CGFloat, _ subviews: Subviews) -> (columns: Int, width: CGFloat, heights: [CGFloat]) {
        let columns = max(1, min(subviews.count, Int((width + spacing) / (minWidth + spacing))))
        let column = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
        return (columns, column, heights)
    }

    private func width(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return minWidth * 2 + spacing }
        return width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = measure(width(proposal), subviews)
        return CGSize(width: width(proposal), height: size.heights.reduce(0, +) + spacing * CGFloat(max(0, size.heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = measure(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in size.heights.enumerated() {
            for column in 0..<size.columns {
                let index = row * size.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (size.width + spacing), y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: size.width, height: height))
            }
            y += height + spacing
        }
    }
}

/// Lays its views out left to right, wrapping onto new lines.
private struct Flow: Layout {
    var spacing: CGFloat = 6

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }
}

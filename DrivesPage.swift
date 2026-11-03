import SwiftUI

private extension View {
    func driveField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .surface(.control, radius: 9)
    }
}

private extension Drives.Status {
    var tone: Tone {
        if problem != nil || offline || inUse { return .warning }
        switch phase {
        case .off: return .off
        case .connecting, .ejecting: return .busy
        case .mounted: return .good
        }
    }

    var isBusy: Bool { phase == .connecting || phase == .ejecting }
}

private struct StatusDot: View {
    let status: Drives.Status

    var body: some View {
        if status.isBusy {
            Spinner(size: 12, line: 1.5)
        } else {
            Dot(tone: status.tone)
        }
    }
}

// MARK: Main page

struct DrivesCard: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var drives: Drives
    @Environment(\.glass) private var look

    private var summary: (tone: Tone, text: String) {
        let all = drives.config.drives
        guard !all.isEmpty else { return (.off, "Mount a server's folder in Finder") }
        if let drive = all.first(where: { drives.status(of: $0).problem != nil || drives.status(of: $0).offline }) {
            return (.warning, drives.status(of: drive).phase == .mounted ? "\(drive.title) is offline" : "Couldn't mount \(drive.title)")
        }
        let mounted = all.filter { drives.status(of: $0).phase == .mounted }
        if all.contains(where: { drives.status(of: $0).phase == .connecting }) { return (.busy, "Connecting…") }
        switch mounted.count {
        case 0: return (.off, "None mounted")
        case 1: return (.good, "\(mounted[0].title) is mounted")
        default: return (.good, "\(mounted.count) mounted")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.go(.drives) } label: {
                HStack(spacing: 12) {
                    TileIcon(symbol: "externaldrive.connected.to.line.below")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drives").font(.system(size: 13, weight: .bold))
                        HStack(spacing: 6) {
                            Dot(tone: summary.tone)
                            Text(summary.text).lineLimit(1)
                        }
                        .font(.system(size: 11)).foregroundStyle(look.sub)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(look.sub)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            if !drives.config.drives.isEmpty {
                HStack(spacing: 6) {
                    ForEach(drives.config.drives.prefix(3)) { DriveChip(drive: $0, drives: drives) }
                    if drives.config.drives.count > 3 {
                        Button("+\(drives.config.drives.count - 3)") { model.go(.drives) }.buttonStyle(PillStyle())
                    }
                }
            }
        }
        .padding(12)
        .surface(.card)
    }
}

// A click mounts a drive, or opens one that's mounted.
private struct DriveChip: View {
    let drive: Drive
    @ObservedObject var drives: Drives

    var body: some View {
        let status = drives.status(of: drive)
        let mounted = status.phase == .mounted
        HStack(spacing: 0) {
            Button {
                mounted ? drives.reveal(drive) : drives.mount(drive, reveal: true)
            } label: {
                HStack(spacing: 6) {
                    StatusDot(status: status)
                    Text(drive.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, mounted ? 2 : 12)
                .frame(height: 30)
            }
            .buttonStyle(PressStyle())
            .disabled(status.isBusy)
            .help(mounted ? "Open in Finder" : "Mount \(drive.place)")
            if mounted {
                Button { drives.eject(drive) } label: {
                    Image(systemName: "eject.fill").font(.system(size: 10, weight: .bold)).frame(width: 26, height: 30)
                }
                .buttonStyle(PressStyle())
                .help("Eject")
                .accessibilityLabel("Eject \(drive.title)")
            }
        }
        .surface(.control, radius: 15)
    }
}

// MARK: Drives

struct DrivesPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var drives: Drives
    @Environment(\.glass) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Drives", back: { model.go(.main) }) {
                Button { edit(drives.add(host: "")) } label: { Image(systemName: "plus") }
                    .buttonStyle(RoundStyle())
                    .accessibilityLabel("Add Drive")
            }
            if drives.config.drives.isEmpty {
                Text("A drive is a folder on a server you can ssh into, mounted so it shows up in Finder like a disk. Gremlin connects the way ssh does in Terminal, with your ~/.ssh/config, keys and agent.")
                    .font(.system(size: 12)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface(.card)
            }
            ForEach(drives.config.drives) { drive in
                DriveRow(drive: drive, drives: drives) { edit(drive) }
            }
            if !drives.suggestions.isEmpty {
                PageGroup(title: "From your SSH config") {
                    ForEach(drives.suggestions, id: \.self) { host in
                        PageRow(title: host, detail: nil) {
                            Button("Add") { drives.add(host: host) }.buttonStyle(PillStyle())
                        }
                    }
                }
            }
            PageGroup(title: "On this Mac") {
                PageRow(title: "Keep Mac files here", detail: "._ files and .DS_Store stay off the server") {
                    GlassSwitch(label: "Keep Mac files here", isOn: drives.config.keepMacFiles) { drives.config.keepMacFiles.toggle() }
                }
                PageRow(title: "Mounted in", detail: "A folder for each drive") {
                    Button {
                        try? FileManager.default.createDirectory(at: Drives.mountFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Drives.mountFolder)
                        model.perform(.closePanel)
                    } label: {
                        Text("~/Drives ›")
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    private func edit(_ drive: Drive) {
        drives.editing = drive.id
        model.go(.drive)
    }
}

private struct DriveRow: View {
    let drive: Drive
    @ObservedObject var drives: Drives
    let edit: () -> Void
    @Environment(\.glass) private var look

    private func detail(_ status: Drives.Status) -> String {
        switch status.phase {
        case .off: drive.host.isEmpty ? "No host yet" : drive.place
        case .connecting: "Connecting to \(drive.host)…"
        case .mounted: status.offline ? "Offline · \(drive.place)" : "Mounted · ~/Drives/\(drives.mountPoint(of: drive)?.lastPathComponent ?? drive.title)"
        case .ejecting: "Ejecting…"
        }
    }

    var body: some View {
        let status = drives.status(of: drive)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: edit) {
                    HStack(spacing: 10) {
                        TileIcon(symbol: status.phase == .mounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(drive.title.isEmpty ? "New Drive" : drive.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                if drive.readOnly { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(look.sub) }
                            }
                            HStack(spacing: 6) {
                                StatusDot(status: status)
                                Text(detail(status)).lineLimit(1)
                            }
                            .font(.system(size: 11)).foregroundStyle(look.sub)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Edit \(drive.title)")
                switch status.phase {
                case .off:
                    Button("Mount") { drives.mount(drive, reveal: true) }.buttonStyle(PillStyle(kind: .primary))
                case .connecting:
                    Button("Cancel") { drives.cancel(drive) }.buttonStyle(PillStyle())
                case .mounted:
                    if status.offline {
                        Button("Reconnect") { drives.reconnect(drive) }.buttonStyle(PillStyle())
                    } else {
                        Button("Open") { drives.reveal(drive) }.buttonStyle(PillStyle())
                    }
                    Button { drives.eject(drive) } label: { Image(systemName: "eject.fill") }
                        .buttonStyle(RoundStyle())
                        .help("Eject")
                        .accessibilityLabel("Eject \(drive.title)")
                case .ejecting:
                    EmptyView()
                }
            }
            if status.inUse {
                HStack(spacing: 8) {
                    Text("An app has a file open on it.").font(.system(size: 11)).foregroundStyle(look.sub)
                    Spacer(minLength: 0)
                    Button("Eject Anyway") { drives.eject(drive, force: true) }.buttonStyle(PillStyle(kind: .danger))
                }
            } else if let problem = status.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .surface(status.problem != nil && status.phase == .off ? .warning : .card)
    }
}

// MARK: Drive

struct DrivePage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var drives: Drives
    @Environment(\.glass) private var look
    private let saved = State(initialValue: false)

    private var index: Int? { drives.config.drives.firstIndex { $0.id == drives.editing } }

    var body: some View {
        if let index {
            let drive = $drives.config.drives[index]
            let status = drives.status(of: drive.wrappedValue)
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: drive.wrappedValue.title.isEmpty ? "New Drive" : drive.wrappedValue.title, back: back) { EmptyView() }
                PageGroup(title: "Server") {
                    labeled("Name") { TextField("Shown in Finder", text: drive.name).driveField() }
                    labeled("Host") {
                        HStack(spacing: 6) {
                            TextField("user@host, or a Host from ~/.ssh/config", text: drive.host).driveField()
                            if !drives.sshHosts.isEmpty {
                                Menu {
                                    ForEach(drives.sshHosts, id: \.self) { host in
                                        Button(host) {
                                            if drive.wrappedValue.name.isEmpty || drive.wrappedValue.name == drive.wrappedValue.host {
                                                drive.wrappedValue.name = host
                                            }
                                            drive.wrappedValue.host = host
                                        }
                                    }
                                } label: {
                                    Text("SSH config ›").font(.system(size: 12)).foregroundStyle(look.sub)
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .fixedSize()
                            }
                        }
                    }
                    labeled("Folder") { TextField("Home folder", text: drive.folder).driveField() }
                    Text("Gremlin connects the way ssh does in Terminal, with your config, keys, agent and ProxyJump. It asks if the server wants a password.")
                        .font(.system(size: 11)).foregroundStyle(look.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PageGroup(title: "Options") {
                    PageRow(title: "Mount when Gremlin starts", detail: "And again when the network comes back") {
                        GlassSwitch(label: "Mount when Gremlin starts", isOn: drive.wrappedValue.mountAtLaunch) { drive.wrappedValue.mountAtLaunch.toggle() }
                    }
                    PageRow(title: "Read only", detail: "Files on the server can't be changed from here") {
                        GlassSwitch(label: "Read only", isOn: drive.wrappedValue.readOnly) { drive.wrappedValue.readOnly.toggle() }
                    }
                    if saved.wrappedValue {
                        PageRow(title: "Saved password", detail: "In your Keychain") {
                            Button("Forget") {
                                Askpass.forget(host: drive.wrappedValue.host)
                                saved.wrappedValue = false
                            }
                            .buttonStyle(PillStyle())
                        }
                    }
                }
                if status.phase == .mounted {
                    Text("Changes apply the next time it mounts.").font(.system(size: 11)).foregroundStyle(look.sub)
                }
                HStack(spacing: 8) {
                    switch status.phase {
                    case .off:
                        Button("Mount") { drives.mount(drive.wrappedValue, reveal: true) }
                            .buttonStyle(PillStyle(kind: .primary, wide: true))
                            .disabled(drive.wrappedValue.host.isEmpty)
                    case .connecting:
                        Button("Cancel") { drives.cancel(drive.wrappedValue) }.buttonStyle(PillStyle(wide: true))
                    case .mounted, .ejecting:
                        Button("Eject") { drives.eject(drive.wrappedValue) }.buttonStyle(PillStyle(wide: true))
                            .disabled(status.phase == .ejecting)
                    }
                    Button("Remove Drive") {
                        let removed = drive.wrappedValue
                        model.go(.drives)
                        drives.editing = nil
                        drives.remove(removed)
                    }
                    .buttonStyle(PillStyle(kind: .danger, wide: true))
                }
                if let problem = status.problem, !status.inUse {
                    Text(problem).font(.system(size: 11)).foregroundStyle(look.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { saved.wrappedValue = Askpass.hasSaved(host: drive.wrappedValue.host) }
        }
    }

    // A drive left without a host was never really added.
    private func back() {
        model.go(.drives)
        if let index, drives.config.drives[index].host.trimmingCharacters(in: .whitespaces).isEmpty {
            drives.remove(drives.config.drives[index])
        }
    }

    private func labeled(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).frame(width: 46, alignment: .leading)
            field()
        }
    }
}

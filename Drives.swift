import AppKit
import Network

struct Drive: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var folder = ""
    var mountAtLaunch = false
    var readOnly = false

    init(name: String, host: String) {
        self.name = name
        self.host = host
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        folder = try values.decodeIfPresent(String.self, forKey: .folder) ?? ""
        mountAtLaunch = try values.decodeIfPresent(Bool.self, forKey: .mountAtLaunch) ?? false
        readOnly = try values.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    var title: String { name.isEmpty ? host : name }
    var place: String { folder.isEmpty ? host : "\(host):\(folder)" }
}

struct DriveConfig: Codable {
    var drives: [Drive] = []
    var keepMacFiles = true

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        drives = try values.decodeIfPresent([Drive].self, forKey: .drives) ?? []
        keepMacFiles = try values.decodeIfPresent(Bool.self, forKey: .keepMacFiles) ?? true
    }
}

// Mounts folders on SSH servers as volumes in Finder. Each drive gets its own SFTP connection and a small NFS server
// on 127.0.0.1 that macOS mounts in ~/Drives.
@MainActor
final class Drives: ObservableObject {
    enum Phase {
        case off
        case connecting
        case mounted
        case ejecting
    }

    struct Status: Equatable {
        var phase = Phase.off
        var problem: String?
        var offline = false
        var inUse = false
    }

    private struct Session {
        let fs: DriveFS
        var server: NFSServer?
        var point: URL?
    }

    static let mountFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Drives")

    @Published var config: DriveConfig { didSet { save() } }
    @Published private(set) var statuses: [UUID: Status] = [:]
    @Published private(set) var sshHosts: [String] = []
    @Published var editing: UUID?

    private let folder: URL
    private var sessions: [UUID: Session] = [:]
    private let network = NWPathMonitor()
    private var lastNetwork: NWPath.Status?
    private var watchers: [NSObjectProtocol] = []
    private var poll: Timer?

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Gremlin")) {
        self.folder = folder
        let file = folder.appendingPathComponent("drives.json")
        if let data = try? Data(contentsOf: file) {
            do {
                config = try JSONDecoder().decode(DriveConfig.self, from: data)
            } catch {
                Log.write("Couldn't read drives.json, setting it aside: \(error)")
                try? FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("drives-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
                config = DriveConfig()
            }
        } else {
            config = DriveConfig()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: folder.appendingPathComponent("drives.json"), options: .atomic)
        } catch {
            Log.write("Couldn't save drives.json: \(error)")
        }
    }

    // MARK: Lifecycle

    func start() {
        Self.leftoverMounts().forEach { Self.forceUnmount($0) }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        watchers = [
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noticeEjects() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.networkChanged() }
            },
        ]
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, path.status != self.lastNetwork else { return }
                let first = self.lastNetwork == nil
                self.lastNetwork = path.status
                if !first, path.status == .satisfied { self.networkChanged() }
            }
        }
        network.start(queue: .main)
        for drive in config.drives where drive.mountAtLaunch { mount(drive, reveal: false) }
    }

    func refresh() {
        sshHosts = SSHConfig.hosts()
        noticeEjects()
    }

    var anyMounted: Bool { !sessions.isEmpty }

    func status(of drive: Drive) -> Status { statuses[drive.id] ?? Status() }

    func mountPoint(of drive: Drive) -> URL? { sessions[drive.id]?.point }

    var suggestions: [String] {
        let used = Set(config.drives.map(\.host))
        return sshHosts.filter { !used.contains($0) }
    }

    // MARK: Drives

    @discardableResult
    func add(host: String) -> Drive {
        var drive = Drive(name: host, host: host)
        if host.isEmpty { drive.name = "" }
        config.drives.append(drive)
        return drive
    }

    func update(_ id: UUID, _ change: (inout Drive) -> Void) {
        guard let index = config.drives.firstIndex(where: { $0.id == id }) else { return }
        change(&config.drives[index])
    }

    func remove(_ drive: Drive) {
        let finish = { [weak self] in
            guard let self else { return }
            config.drives.removeAll { $0.id == drive.id }
            statuses[drive.id] = nil
            if !config.drives.contains(where: { $0.host == drive.host }) { Askpass.forget(host: drive.host) }
            let overlay = overlayFolder(drive)
            if FileManager.default.fileExists(atPath: overlay.path) { try? FileManager.default.trashItem(at: overlay, resultingItemURL: nil) }
        }
        guard sessions[drive.id] != nil else { return finish() }
        eject(drive, force: true, then: finish)
    }

    // MARK: Mounting

    func mount(_ drive: Drive, reveal: Bool) {
        if let point = sessions[drive.id]?.point {
            if reveal { NSWorkspace.shared.open(point) }
            return
        }
        guard sessions[drive.id] == nil else { return }
        guard Self.isUsable(drive.host) else {
            return set(drive.id) { $0 = Status(problem: "Add a host to connect to") }
        }
        set(drive.id) { $0 = Status(phase: .connecting) }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("gremlin-askpass-\(drive.id.uuidString)")
        let environment = Askpass.environment(host: drive.host, name: drive.title, state: state)
        let host = drive.host
        let fs = DriveFS(folder: drive.folder, readOnly: drive.readOnly, keepMacFiles: config.keepMacFiles, overlay: overlayFolder(drive).path,
                         fsid: withUnsafeBytes(of: drive.id.uuid) { $0.loadUnaligned(as: UInt64.self) }) {
            // Each new connection gets one go at a saved password before asking.
            try? FileManager.default.removeItem(at: state)
            return SFTPClient(executable: "/usr/bin/ssh", arguments: Self.sshArguments(host), environment: environment)
        }
        fs.onConnection = { [weak self] change in
            Task { @MainActor in self?.connection(drive.id, change) }
        }
        sessions[drive.id] = Session(fs: fs)
        Task {
            do {
                try await fs.connect()
                guard sessions[drive.id]?.fs === fs else { return }
                let server = try NFSServer(fs: fs, export: "/" + Self.safeName(drive.title))
                sessions[drive.id]?.server = server
                let point = try makeMountPoint(for: drive)
                server.allowMount(true)
                let result = await Self.run("/sbin/mount_nfs", ["-o", Self.mountOptions(port: server.port, readOnly: drive.readOnly),
                                                               "127.0.0.1:/" + Self.safeName(drive.title), point.path])
                server.allowMount(false)
                guard result.status == 0 else {
                    rmdir(point.path)
                    throw SFTPError(code: SFTPError.failure, message: result.output.isEmpty ? "macOS couldn't mount it" : result.output)
                }
                guard sessions[drive.id]?.fs === fs else {
                    Self.forceUnmount(point)
                    return
                }
                sessions[drive.id]?.point = point
                set(drive.id) { $0 = Status(phase: .mounted) }
                Log.write("Mounted \(drive.place) at \(point.path)")
                if reveal { NSWorkspace.shared.open(point) }
            } catch {
                guard sessions[drive.id]?.fs === fs else { return }
                close(drive.id)
                let message = Self.explain((error as? SFTPError)?.message ?? error.localizedDescription, host: host)
                Log.write("Couldn't mount \(drive.place): \(message)")
                set(drive.id) { $0 = Status(problem: message) }
            }
        }
    }

    func cancel(_ drive: Drive) {
        guard sessions[drive.id]?.point == nil else { return }
        close(drive.id)
        set(drive.id) { $0 = Status() }
    }

    func reveal(_ drive: Drive) {
        if let point = mountPoint(of: drive) { NSWorkspace.shared.open(point) }
    }

    func reconnect(_ drive: Drive) {
        guard let fs = sessions[drive.id]?.fs else { return }
        Task { await fs.check() }
    }

    func eject(_ drive: Drive, force: Bool = false, then: (() -> Void)? = nil) {
        guard let point = sessions[drive.id]?.point else {
            cancel(drive)
            then?()
            return
        }
        set(drive.id) { $0.phase = .ejecting }
        Task {
            if let code = await Self.unmount(point, force: force), !Self.isGone(point) {
                set(drive.id) {
                    $0.phase = .mounted
                    $0.inUse = code == EBUSY
                    $0.problem = code == EBUSY ? nil : String(cString: strerror(code))
                }
                return
            }
            close(drive.id)
            set(drive.id) { $0 = Status() }
            then?()
        }
    }

    // Quitting leaves nothing mounted: a mount whose server is gone hangs whatever touches it until macOS gives up.
    func ejectAll(then: @escaping () -> Void) {
        let points = sessions.compactMap { id, session in session.point.map { (id, $0) } }
        guard !points.isEmpty else {
            sessions.keys.forEach(close)
            return then()
        }
        Task {
            for (_, point) in points {
                if await Self.unmount(point, force: false) != nil { _ = await Self.unmount(point, force: true) }
            }
            sessions.keys.forEach(close)
            then()
        }
    }

    private func close(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.server?.stop()
        session.fs.close()
        if let point = session.point {
            rmdir(point.path)
            rmdir(Self.mountFolder.path)
        }
        updatePoll()
    }

    private func connection(_ id: UUID, _ change: DriveFS.Connection) {
        guard sessions[id]?.point != nil else { return }
        set(id) {
            switch change {
            case .connected:
                $0.offline = false
                $0.problem = nil
            case .lost:
                $0.offline = true
                $0.problem = "Lost the connection. It comes back when you use the drive."
            case .failed(let message):
                $0.offline = true
                $0.problem = Self.explain(message, host: config.drives.first { $0.id == id }?.host ?? "")
            }
        }
    }

    private func networkChanged() {
        for (id, session) in sessions where session.point != nil {
            Task { await session.fs.check() }
            set(id) { $0.offline = false }
        }
        for drive in config.drives where drive.mountAtLaunch && sessions[drive.id] == nil && status(of: drive).problem != nil {
            mount(drive, reveal: false)
        }
    }

    // Finder's eject button unmounts without asking Gremlin.
    private func noticeEjects() {
        for (id, session) in sessions {
            guard let point = session.point, Self.isGone(point), statuses[id]?.phase != .ejecting else { continue }
            close(id)
            set(id) { $0 = Status() }
        }
        updatePoll()
    }

    private func updatePoll() {
        let needed = sessions.values.contains { $0.point != nil }
        if needed, poll == nil {
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.noticeEjects() }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        } else if !needed {
            poll?.invalidate()
            poll = nil
        }
    }

    private func set(_ id: UUID, _ change: (inout Status) -> Void) {
        var status = statuses[id] ?? Status()
        change(&status)
        statuses[id] = status
    }

    private func overlayFolder(_ drive: Drive) -> URL {
        folder.appendingPathComponent("Drives").appendingPathComponent(drive.id.uuidString)
    }

    private func makeMountPoint(for drive: Drive) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: Self.mountFolder, withIntermediateDirectories: true)
        let base = Self.safeName(drive.title)
        let taken = Set(sessions.values.compactMap { $0.point?.lastPathComponent })
        for number in 1...50 {
            let name = number == 1 ? base : "\(base) \(number)"
            let point = Self.mountFolder.appendingPathComponent(name)
            guard !taken.contains(name), !Self.isMountPoint(point) else { continue }
            if (try? manager.contentsOfDirectory(atPath: point.path))?.isEmpty == false { continue }
            try manager.createDirectory(at: point, withIntermediateDirectories: true)
            return point
        }
        throw SFTPError(code: SFTPError.failure, message: "No free folder for it in ~/Drives")
    }

    // MARK: System

    private static func sshArguments(_ host: String) -> [String] {
        // The user's config applies as it is, minus what doesn't fit a file connection: forwardings that would clash
        // with a terminal session, a remote command, a terminal, and becoming the master a terminal session relies on.
        let options = ["ServerAliveInterval=15", "ServerAliveCountMax=3", "ConnectTimeout=15", "ClearAllForwardings=yes",
                       "RemoteCommand=none", "RequestTTY=no", "PermitLocalCommand=no", "ControlMaster=no", "LogLevel=ERROR"]
        return options.flatMap { ["-o", $0] } + ["-x", "-a", "-T", "-s", "--", host, "sftp"]
    }

    private static func mountOptions(port: UInt16, readOnly: Bool) -> String {
        // soft and deadtimeout keep apps from hanging if Gremlin dies with the drive mounted. nfc sends names the way
        // Linux spells them, so ş and ü match files made there.
        var options = ["vers=3", "tcp", "port=\(port)", "mountport=\(port)", "noresvport", "soft", "intr", "deadtimeout=45",
                       "rdirplus", "locallocks", "nfc", "rsize=131072", "wsize=131072", "acregmax=15", "acdirmin=2", "acdirmax=10"]
        if readOnly { options.append("rdonly") }
        return options.joined(separator: ",")
    }

    private static func isUsable(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && !host.contains(where: \.isWhitespace)
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Drive" : cleaned
    }

    private static func explain(_ message: String, host: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).last.map(String.init) ?? message
        if line.contains("Permission denied") { return "The server turned down the login. Check that ssh \(host) works in Terminal." }
        if line.contains("Could not resolve hostname") { return "Couldn't find \(host). Is the name right?" }
        if line.contains("Host key verification failed") { return "The server's key didn't match the one ssh knows. Check it in Terminal." }
        if line.contains("Connection refused") { return "\(host) isn't taking SSH connections." }
        if line.contains("timed out") { return "\(host) didn't answer." }
        if line.contains("subsystem request failed") { return "\(host) doesn't offer SFTP." }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func run(_ path: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    // nil once it's unmounted, or the errno.
    private static func unmount(_ point: URL, force: Bool) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                sync()
                let result = Darwin.unmount(point.path, force ? MNT_FORCE : 0)
                continuation.resume(returning: result == 0 ? nil : errno)
            }
        }
    }

    private static func forceUnmount(_ point: URL) {
        Log.write("Unmounting \(point.path), left from before")
        Darwin.unmount(point.path, MNT_FORCE)
        rmdir(point.path)
    }

    private static func mounts() -> [(from: String, on: String, type: String)] {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        return (0..<Int(count)).map { index in
            var entry = list[index]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return (from, on, type)
        }
    }

    private static func isMountPoint(_ point: URL) -> Bool {
        mounts().contains { $0.on == point.path }
    }

    private static func isGone(_ point: URL) -> Bool { !isMountPoint(point) }

    private static func leftoverMounts() -> [URL] {
        mounts().filter { $0.type == "nfs" && $0.from.hasPrefix("127.0.0.1:/") && $0.on.hasPrefix(mountFolder.path + "/") }
            .map { URL(fileURLWithPath: $0.on) }
    }
}

// The Host names in ~/.ssh/config and the files it includes, to offer as drives.
enum SSHConfig {
    static func hosts() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var hosts: [String] = []
        var seen: Set<String> = []
        func read(_ path: String, depth: Int) {
            guard depth < 6, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                guard let keyword = words.first?.lowercased(), !keyword.hasPrefix("#") else { continue }
                if keyword == "host" {
                    for name in words.dropFirst() where !name.contains(where: { "*?!".contains($0) }) && seen.insert(name).inserted {
                        hosts.append(name)
                    }
                } else if keyword == "include" {
                    for pattern in words.dropFirst() {
                        var expanded = pattern.hasPrefix("~/") ? home + pattern.dropFirst(1) : pattern
                        if !expanded.hasPrefix("/") { expanded = home + "/.ssh/" + expanded }
                        for file in glob(expanded) { read(file, depth: depth + 1) }
                    }
                }
            }
        }
        read(home + "/.ssh/config", depth: 0)
        return hosts
    }

    private static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }
}

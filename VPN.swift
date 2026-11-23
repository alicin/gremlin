import AppKit
import SystemConfiguration

struct VPNTunnel: Identifiable, Equatable {
    enum App: Equatable {
        case wireguard
        case tailscale
        case other
    }

    enum State: Equatable {
        case off
        case connecting
        case on
        case disconnecting
    }

    var id: String
    var name: String
    var app: App
    var state: State
    var since: Date?

    var busy: Bool { state == .connecting || state == .disconnecting }

    var text: String {
        switch state {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .disconnecting: "Disconnecting…"
        case .on: since.map { "Connected · " + VPN.duration(since: $0) } ?? "Connected"
        }
    }
}

struct TailscaleState: Equatable {
    struct Peer: Equatable, Identifiable {
        var id: String
        var name: String
        var dnsName: String?
        var address: String?
        var os: String
        var online: Bool
        var exitNodeOption: Bool
        var exitNode: Bool

        var symbol: String {
            switch os.lowercased() {
            case "macos": "laptopcomputer"
            case "ios": "iphone"
            case "android": "candybarphone"
            case "windows": "pc"
            case "tvos": "appletv.fill"
            default: "server.rack"
            }
        }
    }

    var backend: String
    var name: String
    var address: String?
    var tailnet: String?
    var peers: [Peer]
    var health: [String]

    var running: Bool { backend == "Running" }
    var needsLogin: Bool { backend == "NeedsLogin" || backend == "NeedsMachineAuth" }
    var exitNode: Peer? { peers.first(where: \.exitNode) }
    var exitNodes: [Peer] { peers.filter(\.exitNodeOption) }
}

// The CLI comes with the Tailscale app. Calls time out, since `tailscale up` waits forever for a login.
enum TailscaleCLI {
    static let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]

    static var binary: String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func run(_ arguments: [String], timeout: TimeInterval = 12) async -> (ok: Bool, output: String) {
        guard let binary else { return (false, "Tailscale isn't installed.") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    return continuation.resume(returning: (false, error.localizedDescription))
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationReason == .exit && process.terminationStatus == 0, output))
            }
        }
    }

    static func status() async -> TailscaleState? {
        let result = await run(["status", "--json"])
        guard let data = result.output.data(using: .utf8), let raw = try? JSONDecoder().decode(RawStatus.self, from: data) else { return nil }
        let peers = (raw.peers ?? [:]).values.map { node in
            TailscaleState.Peer(id: node.id ?? node.dnsName ?? UUID().uuidString, name: node.shortName, dnsName: node.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                                address: node.ips?.first { !$0.contains(":") } ?? node.ips?.first, os: node.os ?? "",
                                online: node.online ?? false, exitNodeOption: node.exitNodeOption ?? false, exitNode: node.exitNode ?? false)
        }
        return TailscaleState(backend: raw.backend ?? "NoState", name: raw.me?.shortName ?? "This Mac",
                              address: raw.me?.ips?.first { !$0.contains(":") }, tailnet: raw.tailnet?.name,
                              peers: peers.sorted { a, b in a.online != b.online ? a.online : a.name.localizedStandardCompare(b.name) == .orderedAscending },
                              health: raw.health ?? [])
    }

    private struct RawStatus: Decodable {
        struct Node: Decodable {
            var id: String?
            var hostName: String?
            var dnsName: String?
            var ips: [String]?
            var os: String?
            var online: Bool?
            var exitNode: Bool?
            var exitNodeOption: Bool?

            enum CodingKeys: String, CodingKey {
                case id = "ID", hostName = "HostName", dnsName = "DNSName", ips = "TailscaleIPs", os = "OS", online = "Online"
                case exitNode = "ExitNode", exitNodeOption = "ExitNodeOption"
            }

            var shortName: String {
                if let first = dnsName?.split(separator: ".").first, !first.isEmpty { return String(first) }
                return hostName ?? "Device"
            }
        }

        struct Tailnet: Decodable {
            var name: String?

            enum CodingKeys: String, CodingKey { case name = "Name" }
        }

        var backend: String?
        var health: [String]?
        var me: Node?
        var peers: [String: Node]?
        var tailnet: Tailnet?

        enum CodingKeys: String, CodingKey {
            case backend = "BackendState", health = "Health", me = "Self", peers = "Peer", tailnet = "CurrentTailnet"
        }
    }
}

// Turns WireGuard tunnels, Tailscale and any other VPN in System Settings on and off, so their own menu bar items
// can go. Tunnels are the system's VPN services, which work while their apps aren't running.
@MainActor
final class VPN: ObservableObject {
    @Published var tunnels: [VPNTunnel] = []
    @Published var tailscale: TailscaleState?
    @Published private(set) var tailscaleBusy = false
    @Published private(set) var problem: String?

    static let wireGuardApp = URL(fileURLWithPath: "/Applications/WireGuard.app")
    static let tailscaleApp = URL(fileURLWithPath: "/Applications/Tailscale.app")
    static let menuBarSettings = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    nonisolated static let tailscaleWanted = "tailscaleWanted"

    private let readTailscale: () async -> TailscaleState?
    private var preferences: SCPreferences?
    private var connections: [String: SCNetworkConnection] = [:]
    private var since: [String: Date] = [:]
    private var checkingTailscale = false

    init(readTailscale: @escaping () async -> TailscaleState? = { await TailscaleCLI.status() }) {
        self.readTailscale = readTailscale
    }

    var tailscaleInstalled: Bool { TailscaleCLI.binary != nil }
    var tailscaleTunnel: VPNTunnel? { tunnels.first { $0.app == .tailscale } }
    var others: [VPNTunnel] { tunnels.filter { $0.app != .tailscale } }

    /// Tailscale counts as on when its tunnel is up and it wants to run, which `tailscale down` turns off.
    var tailscaleOn: Bool { tailscaleTunnel?.state == .on && tailscale?.running != false }

    func start() {
        var context = SCPreferencesContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let preferences = SCPreferencesCreate(nil, "Gremlin" as CFString, nil) else { return }
        self.preferences = preferences
        SCPreferencesSetCallback(preferences, { _, _, info in
            guard let info else { return }
            let vpn = Unmanaged<VPN>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { vpn.reload() }
        }, &context)
        SCPreferencesScheduleWithRunLoop(preferences, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        reload()
        restoreTailscale()
    }

    func stop() {
        for connection in connections.values { SCNetworkConnectionUnscheduleFromRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) }
        connections = [:]
        if let preferences { SCPreferencesUnscheduleFromRunLoop(preferences, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) }
        preferences = nil
    }

    func refresh() {
        reload()
        checkTailscale()
    }

    func checkTailscale() {
        guard tailscaleInstalled, !checkingTailscale else { return }
        checkingTailscale = true
        Task {
            let state = await readTailscale()
            checkingTailscale = false
            if state != tailscale { tailscale = state }
        }
    }

    func toggle(_ tunnel: VPNTunnel) {
        tunnel.app == .tailscale ? setTailscale(!tailscaleOn) : (tunnel.state == .off ? connect(tunnel) : disconnect(tunnel))
    }

    func connect(_ tunnel: VPNTunnel) {
        guard let connection = connections[tunnel.id] else { return }
        problem = nil
        Log.write("Connecting the VPN \(tunnel.name)")
        if !SCNetworkConnectionStart(connection, nil, false) {
            problem = "Couldn't connect \(tunnel.name): \(String(cString: SCErrorString(SCError())))"
            Log.write(problem!)
        }
        update(tunnel.id)
    }

    func disconnect(_ tunnel: VPNTunnel) {
        guard let connection = connections[tunnel.id] else { return }
        problem = nil
        Log.write("Disconnecting the VPN \(tunnel.name)")
        if !SCNetworkConnectionStop(connection, true) {
            problem = "Couldn't disconnect \(tunnel.name): \(String(cString: SCErrorString(SCError())))"
            Log.write(problem!)
        }
        update(tunnel.id)
    }

    // `up` and `down` are what Tailscale's own switch does. With its tunnel stopped, nothing answers the CLI,
    // so the tunnel starts first.
    func setTailscale(_ on: Bool) {
        guard !tailscaleBusy else { return }
        if on, tailscale?.needsLogin == true {
            NSWorkspace.shared.open(Self.tailscaleApp)
            return
        }
        tailscaleBusy = true
        UserDefaults.standard.set(on, forKey: Self.tailscaleWanted)
        Log.write(on ? "Turning Tailscale on" : "Turning Tailscale off")
        Task { await switchTailscale(on) }
    }

    @discardableResult
    private func switchTailscale(_ on: Bool) async -> Bool {
        tailscaleBusy = true
        problem = nil
        if on, let tunnel = tailscaleTunnel, tunnel.state != .on, let connection = connections[tunnel.id] {
            SCNetworkConnectionStart(connection, nil, false)
            for _ in 0..<30 where SCNetworkConnectionGetStatus(connection) != .connected {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let result = await TailscaleCLI.run([on ? "up" : "down"])
        if !result.ok {
            problem = Self.tailscaleProblem(result.output, on: on)
            Log.write("Tailscale \(on ? "up" : "down") failed: \(result.output)")
        }
        tailscale = await readTailscale()
        tailscaleBusy = false
        return result.ok
    }

    // Without its app, nothing turns Tailscale on at login, so Gremlin puts back the state last chosen with its switch.
    // Tailscale can still be starting then, hence the retries.
    private func restoreTailscale() {
        guard tailscaleInstalled else { return }
        Task {
            for delay in [0, 10, 30] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                let state = await readTailscale()
                if let state { tailscale = state }
                guard let wanted = UserDefaults.standard.object(forKey: Self.tailscaleWanted) as? Bool else {
                    guard let state, state.running || state.backend == "Stopped" else { continue }
                    UserDefaults.standard.set(state.running, forKey: Self.tailscaleWanted)
                    return
                }
                guard state?.needsLogin != true, (state?.running == true) != wanted else { return }
                guard !tailscaleBusy else { continue }
                Log.write(wanted ? "Turning Tailscale back on, as it was left" : "Turning Tailscale off, as it was left")
                if await switchTailscale(wanted) { return }
            }
        }
    }

    func useExitNode(_ peer: TailscaleState.Peer?) {
        guard !tailscaleBusy else { return }
        tailscaleBusy = true
        problem = nil
        Log.write(peer.map { "Using \($0.name) as the Tailscale exit node" } ?? "Stopped using a Tailscale exit node")
        Task {
            let result = await TailscaleCLI.run(["set", "--exit-node=\(peer?.address ?? "")"])
            if !result.ok { problem = Self.firstLine(result.output) }
            tailscale = await readTailscale()
            tailscaleBusy = false
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func dismissProblem() { problem = nil }

    private func reload() {
        guard let preferences else { return }
        SCPreferencesSynchronize(preferences)
        let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? []
        var found: [VPNTunnel] = []
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let interface = SCNetworkServiceGetInterface(service), SCNetworkInterfaceGetInterfaceType(interface) as String? == "VPN",
                  let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            let path = "/\(kSCPrefNetworkServices)/\(id)/\(kSCEntNetInterface)" as CFString
            let subtype = (SCPreferencesPathGetValue(preferences, path) as? [String: Any])?["SubType"] as? String ?? ""
            let app: VPNTunnel.App = subtype.hasPrefix("com.wireguard") ? .wireguard : subtype.hasPrefix("io.tailscale") ? .tailscale : .other
            found.append(VPNTunnel(id: id, name: SCNetworkServiceGetName(service) as String? ?? "VPN", app: app, state: .off))
        }
        for id in connections.keys where !found.contains(where: { $0.id == id }) {
            if let connection = connections.removeValue(forKey: id) {
                SCNetworkConnectionUnscheduleFromRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            }
        }
        for tunnel in found where connections[tunnel.id] == nil { watch(tunnel.id) }
        tunnels = found.map { tunnel in
            var tunnel = tunnel
            if let connection = connections[tunnel.id] { (tunnel.state, tunnel.since) = Self.state(of: connection) }
            return tunnel
        }
        .sorted { a, b in
            if (a.app == .tailscale) != (b.app == .tailscale) { return a.app == .tailscale }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func watch(_ id: String) {
        var context = SCNetworkConnectionContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, { connection, _, info in
            guard let info, let id = SCNetworkConnectionCopyServiceID(connection) as String? else { return }
            let vpn = Unmanaged<VPN>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { vpn.update(id) }
        }, &context) else { return }
        SCNetworkConnectionScheduleWithRunLoop(connection, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        connections[id] = connection
    }

    private func update(_ id: String) {
        guard let index = tunnels.firstIndex(where: { $0.id == id }), let connection = connections[id] else { return }
        let (state, since) = Self.state(of: connection)
        guard tunnels[index].state != state || tunnels[index].since != since else { return }
        tunnels[index].state = state
        tunnels[index].since = since
        if tunnels[index].app == .tailscale { checkTailscale() }
    }

    private static func state(of connection: SCNetworkConnection) -> (VPNTunnel.State, Date?) {
        let state: VPNTunnel.State = switch SCNetworkConnectionGetStatus(connection) {
        case .connected: .on
        case .connecting: .connecting
        case .disconnecting: .disconnecting
        default: .off
        }
        guard state == .on, let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] else { return (state, nil) }
        return (state, status["LastStatusChangeTime"] as? Date)
    }

    nonisolated static func duration(since date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 || hours >= 10 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) days"
    }

    private static func tailscaleProblem(_ output: String, on: Bool) -> String {
        if output.contains("failed to connect to local Tailscale") || output.contains("is Tailscale running") {
            return "Tailscale isn't running. Open the Tailscale app once, then try again."
        }
        if output.contains("To authenticate") || output.contains("NeedsLogin") { return "Tailscale needs you to log in. Open the Tailscale app to do it." }
        return firstLine(output).isEmpty ? "Tailscale didn't \(on ? "start" : "stop")." : firstLine(output)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

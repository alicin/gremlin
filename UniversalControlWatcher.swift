import Foundation
import UserNotifications

// Works around a macOS 27.0 bug: after the other Mac wakes, Universal Control's initial
// sync can fail all its retries, and then it never talks to that peer again until the
// setting is toggled. See README.md for the log lines this relies on.
final class UniversalControlWatcher: Feature {
    enum Target {
        case local
        case remote
        case both
    }

    enum Phase {
        case watching
        case scheduled(Date, Target)
        case resetting(Target)
        case gaveUp(retryAt: Date)
        case peerHandling
    }

    private enum Side {
        case here
        case there
    }

    private enum Sync {
        case finalRetry
        case finalRetryFailed
    }

    var onChange: (() -> Void)?
    var link: PeerLink?

    private(set) var isRunning = false
    private(set) var phase = Phase.watching
    private var streamRunning = false

    // The error Universal Control logs when the other Mac resets the connection during pairing verification.
    private static let refusedError = "-71143"
    private let backoff: [TimeInterval] = [10, 60, 300]
    private let retryInterval: TimeInterval = 1800
    private let recoveryTimeout: TimeInterval = 300
    private let peerTimeout: TimeInterval = 600
    private var failedResets = 0
    private var plan: [Target] = []
    private var stuckPeer: String?
    private var available: [String: Bool] = [:]
    private var sync: [String: Sync] = [:]
    private var lastError: [String: String] = [:]

    private var process: Process?
    private var pendingReset: DispatchWorkItem?
    private var resetTimeout: DispatchWorkItem?
    // A flip on either Mac makes Universal Control report the other one unavailable and then available again.
    private var ownFlipUntil = Date.distantPast

    private let defaults = UserDefaults.standard
    private let lastResetKey = "universalControlLastReset"
    private let lastOutcomeKey = "universalControlLastResetOutcome"
    private let lastWhereKey = "universalControlLastResetWhere"
    private let flippingKey = "universalControlFlipInProgress"
    private let selfIDKey = "universalControlSelfID"

    init() {
        if defaults.bool(forKey: flippingKey) {
            Log.write("Universal Control was left disabled by an interrupted reset, enabling it")
            finishFlip()
        }
    }

    var selfID: String? { defaults.string(forKey: selfIDKey) }

    // MARK: Feature

    func start() {
        guard !isRunning else { return }
        isRunning = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Log.write("Watcher started")
        startStream()
        if selfID == nil { findSelfID() }
        onChange?()
    }

    func stop() {
        if defaults.bool(forKey: flippingKey) { finishFlip() }
        guard isRunning else { return }
        isRunning = false
        pendingReset?.cancel()
        resetTimeout?.cancel()
        phase = .watching
        stuckPeer = nil
        failedResets = 0
        available = [:]
        sync = [:]
        let process = self.process
        self.process = nil
        streamRunning = false
        process?.terminate()
        Log.write("Watcher stopped")
        onChange?()
    }

    // MARK: Menu text

    var statusText: String {
        guard isRunning else { return "Off" }
        guard streamRunning else { return "Log stream stopped, restarting…" }
        let peer = stuckPeer ?? "Mac"
        switch phase {
        case .watching: return "Watching"
        case .scheduled(let date, let target): return "\(peer) stuck, resetting \(place(target)) at \(Self.time(date, seconds: true))"
        case .resetting(let target): return "Reset \(place(target)), waiting for reconnect…"
        case .gaveUp(let date): return "Still stuck, trying again at \(Self.time(date, seconds: false))"
        case .peerHandling: return "\(peer) stuck, \(remoteName) is handling it"
        }
    }

    var lastResetText: String {
        guard let date = defaults.object(forKey: lastResetKey) as? Date else { return "Last reset: never" }
        var text = "Last reset: "
        if !Calendar.current.isDateInToday(date) { text += date.formatted(.dateTime.month(.abbreviated).day()) + " " }
        text += Self.time(date, seconds: false)
        if let place = defaults.string(forKey: lastWhereKey), !place.isEmpty { text += " \(place)" }
        if let outcome = defaults.string(forKey: lastOutcomeKey) { text += ", \(outcome)" }
        return text
    }

    private var remoteName: String { link?.paired?.name ?? "the other Mac" }

    private func place(_ target: Target) -> String {
        switch target {
        case .local: return link?.paired == nil ? "" : "here"
        case .remote: return "on \(remoteName)"
        case .both: return "on both Macs"
        }
    }

    // MARK: Reset

    func resetNow(_ target: Target = .local) {
        Log.write("Manual reset \(place(target))")
        reset(target)
    }

    private func reset(_ target: Target) {
        pendingReset?.cancel()
        resetTimeout?.cancel()
        if isRunning { phase = .resetting(target) }
        defaults.set(Date(), forKey: lastResetKey)
        defaults.set(place(target), forKey: lastWhereKey)
        defaults.set(isRunning ? "waiting" : nil, forKey: lastOutcomeKey)
        ownFlipUntil = Date().addingTimeInterval(15)
        if target != .remote { flip() }
        if target != .local { resetRemote(fallBack: target == .remote) }

        guard isRunning else {
            onChange?()
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, case .resetting = self.phase else { return }
            Log.write("No reconnect or failure seen within \(Int(self.recoveryTimeout))s of the reset")
            self.defaults.set("no reconnect seen", forKey: self.lastOutcomeKey)
            self.phase = .watching
            self.onChange?()
        }
        resetTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + recoveryTimeout, execute: timeout)
        onChange?()
    }

    private func flip() {
        Log.write("Resetting Universal Control")
        defaults.set(true, forKey: flippingKey)
        setDisabled(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.defaults.bool(forKey: self.flippingKey) else { return }
            self.finishFlip()
        }
    }

    private func resetRemote(fallBack: Bool) {
        let name = remoteName
        guard let link, link.paired != nil else {
            if fallBack { flip() }
            return
        }
        Log.write("Asking \(name) to reset Universal Control")
        link.request(Message(type: "reset")) { [weak self] reply in
            guard reply?.ok != true else { return }
            Log.write("Couldn't reach \(name)" + (fallBack ? ", resetting here instead" : ""))
            guard fallBack, let self else { return }
            self.defaults.set(self.place(.local), forKey: self.lastWhereKey)
            self.onChange?()
            self.flip()
        }
    }

    private func setDisabled(_ disabled: Bool) {
        let domain = "com.apple.universalcontrol" as CFString
        CFPreferencesSetValue("Disable" as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private func finishFlip() {
        setDisabled(false)
        defaults.removeObject(forKey: flippingKey)
    }

    // MARK: The other Mac

    func handle(_ message: Message) -> Message {
        var reply = Message(type: "reply")
        let name = message.name ?? "The other Mac"
        switch message.type {
        case "reset":
            Log.write("\(name) asked for a reset")
            ownFlipUntil = Date().addingTimeInterval(15)
            defaults.set(Date(), forKey: lastResetKey)
            defaults.set("", forKey: lastWhereKey)
            defaults.set("asked by \(name)", forKey: lastOutcomeKey)
            flip()
            reply.ok = true
            onChange?()
        case "stuck":
            guard isRunning else {
                reply.ok = false
                break
            }
            Log.write("\(name) says Universal Control is stuck (\(message.error ?? "no error"))")
            let peer = message.ucID ?? link?.paired?.ucID ?? "peer"
            stuck(peer, refusedBy: message.error == Self.refusedError ? .here : nil, reported: true)
            reply.ok = true
        default:
            break
        }
        reply.status = statusText
        return reply
    }

    // With two paired Macs, only one runs the resets, so they don't toggle each other at the same time.
    private var isCoordinator: Bool {
        guard let link, let paired = link.paired else { return true }
        return link.id < paired.id
    }

    private func canReach(_ peer: String) -> Bool {
        guard let paired = link?.paired else { return false }
        return paired.ucID == nil || paired.ucID == peer
    }

    private func report(_ peer: String) {
        stuckPeer = peer
        phase = .peerHandling
        Log.write("\(peer) stuck, telling \(remoteName)")
        var message = Message(type: "stuck")
        message.error = lastError[peer]
        link?.request(message) { [weak self] reply in
            guard let self, case .peerHandling = self.phase else { return }
            if reply?.ok == true {
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, case .peerHandling = self.phase else { return }
                    Log.write("\(self.remoteName) didn't fix it within \(Int(self.peerTimeout / 60))m")
                    self.settle()
                }
                self.resetTimeout?.cancel()
                self.resetTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + self.peerTimeout, execute: timeout)
            } else {
                Log.write("Couldn't reach \(self.remoteName), handling it here")
                self.phase = .watching
                self.stuck(peer, refusedBy: nil, reported: true, alone: true)
            }
        }
        onChange?()
    }

    private func refusal(_ peer: String) -> Side? {
        lastError[peer] == Self.refusedError ? .there : nil
    }

    // MARK: Events

    private func handle(_ message: String) {
        let circlePrefix = "In-Circle Devices: ["
        if message.hasPrefix(circlePrefix) {
            let peers = message.dropFirst(circlePrefix.count).dropLast()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            peers.forEach(joined)
            return
        }
        if message.hasPrefix("Increment Sync Clock: ") { return learnSelfID(message) }

        guard message.hasPrefix("IDS "), let colon = message.firstIndex(of: ":") else { return }
        let peer = String(message[message.index(message.startIndex, offsetBy: 4)..<colon])
        guard peer.count == 8, peer.allSatisfy(\.isHexDigit) else { return }
        let event = message[colon...].dropFirst().trimmingCharacters(in: .whitespaces)

        if event == "Initial Sync" {
            sync[peer] = nil
        } else if event.hasPrefix("Initial Sync (Retry "), isFinalRetry(event) {
            Log.write(message)
            sync[peer] = .finalRetry
        } else if event.hasPrefix("Initial Sync Failed") {
            lastError[peer] = Self.errorCode(event)
            guard case .finalRetry = sync[peer] else { return }
            Log.write(message)
            sync[peer] = .finalRetryFailed
        } else if event.hasPrefix("available=") {
            let isAvailable = event.hasPrefix("available=true")
            available[peer] = isAvailable
            if case .finalRetryFailed = sync[peer], isAvailable, event.hasSuffix("valid=false") {
                Log.write(message)
                sync[peer] = nil
                stuck(peer, refusedBy: refusal(peer), reported: false)
            }
        } else if event == "Device Available" {
            deviceAvailable(peer, message: message)
        } else if event == "Device Unavailable" || event == "Device Lost" {
            deviceGone(peer, message: message)
        }
    }

    private func isFinalRetry(_ event: String) -> Bool {
        let numbers = event.split(whereSeparator: { !$0.isNumber })
        return numbers.count == 2 && numbers[0] == numbers[1]
    }

    private static func errorCode(_ event: String) -> String? {
        guard let open = event.firstIndex(of: "("), let close = event[open...].firstIndex(of: ")") else { return nil }
        return String(event[event.index(after: open)..<close])
    }

    private var inOwnFlip: Bool { Date() < ownFlipUntil }

    private func stuck(_ peer: String, refusedBy side: Side?, reported: Bool, alone: Bool = false) {
        switch phase {
        case .scheduled, .gaveUp:
            return
        case .peerHandling:
            return report(peer)
        case .resetting:
            failedResets += 1
            Log.write("Reset \(failedResets) didn't help")
            defaults.set("didn't recover", forKey: lastOutcomeKey)
        case .watching:
            if !reported, !isCoordinator, canReach(peer) { return report(peer) }
            failedResets = 0
            if canReach(peer), !alone {
                plan = side == .there ? [.remote, .local, .both] : [.local, .remote, .both]
            } else {
                plan = [.local, .local, .local]
            }
        }
        stuckPeer = peer
        resetTimeout?.cancel()
        guard failedResets < plan.count else { return giveUp(peer) }

        let target = plan[failedResets]
        let delay = backoff[min(failedResets, backoff.count - 1)]
        if failedResets > 0 { notify("Reset didn't reconnect \(peer). Trying again \(place(target)) in \(Self.duration(delay)).") }
        Log.write("\(peer) stuck, resetting \(place(target)) in \(Self.duration(delay))")
        schedule(target, after: delay)
        phase = .scheduled(Date().addingTimeInterval(delay), target)
        onChange?()
    }

    private func giveUp(_ peer: String) {
        let retryAt = Date().addingTimeInterval(retryInterval)
        if failedResets == plan.count {
            let hint = link?.paired == nil ? " Try toggling Universal Control on the other Mac." : ""
            notify("Still stuck after \(plan.count) resets. Trying again every \(Int(retryInterval / 60)) minutes.\(hint)")
        }
        Log.write("\(peer) still stuck, trying again at \(Self.time(retryAt, seconds: false))")
        schedule(plan.contains(.remote) ? .both : .local, after: retryInterval)
        phase = .gaveUp(retryAt: retryAt)
        onChange?()
    }

    private func schedule(_ target: Target, after delay: TimeInterval) {
        pendingReset?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reset(target) }
        pendingReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func joined(_ peer: String) {
        available[peer] = true
        sync[peer] = nil
        switch phase {
        case .resetting:
            Log.write("\(peer) reconnected after reset")
            defaults.set("recovered", forKey: lastOutcomeKey)
            notify("Reconnected \(peer) after a reset.")
        case .scheduled, .gaveUp, .peerHandling:
            guard stuckPeer == peer else { return }
            Log.write("\(peer) reconnected")
        case .watching:
            return
        }
        settle()
    }

    private func deviceAvailable(_ peer: String, message: String) {
        available[peer] = true
        sync[peer] = nil
        guard !inOwnFlip else { return }
        Log.write(message)
        guard stuckPeer == peer else { return }
        if case .resetting = phase { return }
        settle()
    }

    private func deviceGone(_ peer: String, message: String) {
        guard !inOwnFlip else { return }
        Log.write(message)
        available[peer] = false
        sync[peer] = nil
        guard stuckPeer == peer else { return }
        settle()
    }

    private func settle() {
        pendingReset?.cancel()
        resetTimeout?.cancel()
        phase = .watching
        stuckPeer = nil
        failedResets = 0
        onChange?()
    }

    private func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Universal Control"
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: This Mac's ID

    // Universal Control only bumps its own entry in the sync clock, e.g. "[592575D1: 480, C2D1D741: 383] -> [592575D1: 481, C2D1D741: 383]".
    private func learnSelfID(_ message: String) {
        let sides = message.dropFirst("Increment Sync Clock: ".count).components(separatedBy: " -> ")
        guard sides.count == 2 else { return }
        let before = Self.clock(sides[0])
        guard let id = Self.clock(sides[1]).first(where: { before[$0.key] != $0.value })?.key, id != selfID else { return }
        defaults.set(id, forKey: selfIDKey)
        Log.write("This Mac is \(id) in Universal Control")
    }

    private static func clock(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).components(separatedBy: ", ") {
            let parts = entry.components(separatedBy: ": ")
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    private func findSelfID() {
        DispatchQueue.global().async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--last", "1d", "--style", "ndjson", "--predicate",
                                 #"process == "UniversalControl" AND eventMessage BEGINSWITH "Increment Sync Clock""#]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let last = output.split(separator: 0x0A).reversed().lazy.compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["eventMessage"] as? String
            }.first
            guard let last else { return }
            DispatchQueue.main.async { self?.learnSelfID(last) }
        }
    }

    // MARK: Log stream

    private func startStream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate", #"process == "UniversalControl" AND category == "SYNC""#]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let message = object["eventMessage"] as? String else { continue }
                DispatchQueue.main.async { self?.handle(message) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.streamEnded(ended) }
        }

        do {
            try process.run()
            self.process = process
            streamRunning = true
        } catch {
            Log.write("Couldn't start log stream: \(error.localizedDescription)")
            streamEnded(process)
        }
    }

    private func streamEnded(_ ended: Process) {
        guard isRunning, process === ended || process == nil else { return }
        process = nil
        streamRunning = false
        Log.write("Log stream exited, restarting in 5s")
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isRunning, self.process == nil else { return }
            self.startStream()
            self.onChange?()
        }
    }

    // MARK: Formatting

    private static func time(_ date: Date, seconds: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
    }
}

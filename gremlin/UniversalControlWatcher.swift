import Foundation
import UserNotifications

// Works around a macOS 27.0 bug: after the other Mac wakes, Universal Control's initial
// sync can fail all its retries, and then it never talks to that peer again until the
// setting is toggled. See README.md for the log lines this relies on.
final class UniversalControlWatcher: Feature {
    enum Phase {
        case watching
        case scheduled(Date)
        case resetting
        case gaveUp
    }

    private enum Sync {
        case finalRetry
        case finalRetryFailed
    }

    var onChange: (() -> Void)?

    private(set) var isRunning = false
    private(set) var phase = Phase.watching
    private var streamRunning = false

    private let backoff: [TimeInterval] = [10, 60, 300]
    private let recoveryTimeout: TimeInterval = 300
    private var failedResets = 0
    private var stuckPeer: String?
    private var available: [String: Bool] = [:]
    private var sync: [String: Sync] = [:]

    private var process: Process?
    private var pendingReset: DispatchWorkItem?
    private var resetTimeout: DispatchWorkItem?
    // Our own flip makes Universal Control report every peer unavailable and then available again.
    private var ownFlipUntil = Date.distantPast

    private let defaults = UserDefaults.standard
    private let lastResetKey = "universalControlLastReset"
    private let lastOutcomeKey = "universalControlLastResetOutcome"
    private let flippingKey = "universalControlFlipInProgress"

    init() {
        if defaults.bool(forKey: flippingKey) {
            Log.write("Universal Control was left disabled by an interrupted reset, enabling it")
            finishFlip()
        }
    }

    // MARK: Feature

    func start() {
        guard !isRunning else { return }
        isRunning = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Log.write("Watcher started")
        startStream()
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
        switch phase {
        case .watching: return "Watching"
        case .scheduled(let date): return "\(stuckPeer ?? "Mac") stuck, resetting at \(Self.time(date, seconds: true))"
        case .resetting: return "Reset, waiting for reconnect…"
        case .gaveUp: return "Gave up after \(backoff.count) resets, waiting for the Mac to come back"
        }
    }

    var lastResetText: String {
        guard let date = defaults.object(forKey: lastResetKey) as? Date else { return "Last reset: never" }
        var text = "Last reset: "
        if !Calendar.current.isDateInToday(date) { text += date.formatted(.dateTime.month(.abbreviated).day()) + " " }
        text += Self.time(date, seconds: false)
        if let outcome = defaults.string(forKey: lastOutcomeKey) { text += ", \(outcome)" }
        return text
    }

    // MARK: Reset

    func resetNow() {
        Log.write("Manual reset")
        reset()
    }

    private func reset() {
        pendingReset?.cancel()
        resetTimeout?.cancel()
        if isRunning { phase = .resetting }
        defaults.set(Date(), forKey: lastResetKey)
        defaults.set(isRunning ? "waiting" : nil, forKey: lastOutcomeKey)
        ownFlipUntil = Date().addingTimeInterval(10)
        Log.write("Resetting Universal Control")
        defaults.set(true, forKey: flippingKey)
        setDisabled(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.defaults.bool(forKey: self.flippingKey) else { return }
            self.finishFlip()
        }

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

    private func setDisabled(_ disabled: Bool) {
        let domain = "com.apple.universalcontrol" as CFString
        CFPreferencesSetValue("Disable" as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private func finishFlip() {
        setDisabled(false)
        defaults.removeObject(forKey: flippingKey)
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

        guard message.hasPrefix("IDS "), let colon = message.firstIndex(of: ":") else { return }
        let peer = String(message[message.index(message.startIndex, offsetBy: 4)..<colon])
        guard peer.count == 8, peer.allSatisfy(\.isHexDigit) else { return }
        let event = message[colon...].dropFirst().trimmingCharacters(in: .whitespaces)

        if event == "Initial Sync" {
            sync[peer] = nil
        } else if event.hasPrefix("Initial Sync (Retry "), isFinalRetry(event) {
            Log.write(message)
            sync[peer] = .finalRetry
        } else if event.hasPrefix("Initial Sync Failed"), case .finalRetry = sync[peer] {
            Log.write(message)
            sync[peer] = .finalRetryFailed
        } else if event.hasPrefix("available=") {
            let isAvailable = event.hasPrefix("available=true")
            available[peer] = isAvailable
            if case .finalRetryFailed = sync[peer], isAvailable, event.hasSuffix("valid=false") {
                Log.write(message)
                sync[peer] = nil
                stuck(peer)
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

    private var inOwnFlip: Bool { Date() < ownFlipUntil }

    private func stuck(_ peer: String) {
        if case .resetting = phase {
            failedResets += 1
            Log.write("Reset \(failedResets) didn't help")
            defaults.set("didn't recover", forKey: lastOutcomeKey)
        } else if case .scheduled = phase {
            return
        } else if case .gaveUp = phase {
            return
        }
        stuckPeer = peer
        resetTimeout?.cancel()

        guard failedResets < backoff.count else {
            phase = .gaveUp
            Log.write("Giving up until \(peer) goes away and comes back")
            notify("Still stuck after \(backoff.count) resets. Toggle Universal Control on the other Mac.")
            onChange?()
            return
        }

        let delay = backoff[failedResets]
        if failedResets > 0 { notify("Reset didn't reconnect \(peer). Trying again in \(Self.duration(delay)).") }
        Log.write("\(peer) stuck, resetting in \(Self.duration(delay))")
        let work = DispatchWorkItem { [weak self] in self?.reset() }
        pendingReset = work
        phase = .scheduled(Date().addingTimeInterval(delay))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        onChange?()
    }

    private func joined(_ peer: String) {
        available[peer] = true
        sync[peer] = nil
        switch phase {
        case .resetting:
            Log.write("\(peer) reconnected after reset")
            defaults.set("recovered", forKey: lastOutcomeKey)
            notify("Reconnected \(peer) after a reset.")
        case .scheduled, .gaveUp:
            guard stuckPeer == peer else { return }
            Log.write("\(peer) reconnected on its own")
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

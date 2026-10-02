import AppKit
import IOKit.pwr_mgt

final class KeepAwake {
    static let choices: [(title: String, duration: TimeInterval?)] = [
        ("30 Minutes", 1800),
        ("1 Hour", 3600),
        ("2 Hours", 7200),
        ("4 Hours", 14400),
        ("Indefinitely", nil),
    ]

    var onChange: (() -> Void)?
    private(set) var until: Date?
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let key = "keepAwakeUntil"

    init() {
        if let saved = defaults.object(forKey: key) as? Date, saved > Date() { keep(until: saved) }
    }

    var isOn: Bool { until != nil }

    var title: String {
        guard let until else { return "Keep Awake" }
        if until == .distantFuture { return "Keep Awake: On" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "Keep Awake: Until \(formatter.string(from: until))"
    }

    func keep(for duration: TimeInterval?) {
        keep(until: duration.map { Date().addingTimeInterval($0) } ?? .distantFuture)
    }

    private func keep(until date: Date) {
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Gremlin Keep Awake" as CFString, &assertion)
        }
        until = date
        defaults.set(date, forKey: key)
        timer?.invalidate()
        if date != .distantFuture {
            timer = Timer.scheduledTimer(withTimeInterval: date.timeIntervalSinceNow, repeats: false) { [weak self] _ in self?.stop() }
        }
        Log.write(title)
        onChange?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        until = nil
        defaults.removeObject(forKey: key)
        onChange?()
    }

    // Other processes holding the Mac awake, e.g. a video call or caffeinate.
    static func others() -> [String] {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let blocking: Set<String> = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
                                     "NoIdleSleepAssertion", "NoDisplaySleepAssertion"]
        var names: [String] = []
        for (pid, list) in byProcess where pid.int32Value != getpid() {
            guard list.contains(where: { blocking.contains($0["AssertType"] as? String ?? "") }) else { continue }
            var buffer = [CChar](repeating: 0, count: 1024)
            let name = NSRunningApplication(processIdentifier: pid.int32Value)?.localizedName
                ?? (proc_name(pid.int32Value, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil)
            // powerd always holds one while the display is on.
            if let name, name != "powerd", !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }
}

import AppKit

// All of these run as the user and launchd starts them again, so killall is a restart.
enum Restart {
    struct Item {
        let title: String
        let short: String
        let hint: String
        let symbol: String
        let processes: [String]
    }

    static let items = [
        Item(title: "Dock", short: "Dock", hint: "Mission Control stuck", symbol: "dock.rectangle", processes: ["Dock"]),
        Item(title: "Finder", short: "Finder", hint: "Windows frozen", symbol: "finder", processes: ["Finder"]),
        Item(title: "Menu Bar", short: "Menu Bar", hint: "Items missing or frozen", symbol: "menubar.rectangle", processes: ["SystemUIServer"]),
        Item(title: "Control Center", short: "Control", hint: "Its icons misbehave", symbol: "switch.2", processes: ["ControlCenter"]),
        Item(title: "Notification Center", short: "Alerts", hint: "Banners frozen", symbol: "bell", processes: ["NotificationCenter"]),
        Item(title: "Window Manager", short: "Windows", hint: "Stage Manager stuck", symbol: "macwindow.on.rectangle",
             processes: ["WindowManager"]),
        Item(title: "Clipboard", short: "Clipboard", hint: "Paste broken · empties it", symbol: "clipboard", processes: ["pboard"]),
        // Universal Clipboard only recovers when useractivityd goes first.
        Item(title: "Universal Clipboard", short: "Handoff", hint: "Pasting across devices", symbol: "laptopcomputer.and.iphone",
             processes: ["useractivityd", "pboard"]),
        Item(title: "iCloud Drive", short: "iCloud", hint: "Sync stopped", symbol: "icloud", processes: ["bird"]),
    ]

    static var all: [String] {
        items.flatMap(\.processes).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func restart(_ title: String, _ processes: [String]) {
        Log.write("Restarting \(title)")
        DispatchQueue.global().async {
            for (index, name) in processes.enumerated() {
                if index > 0 { Thread.sleep(forTimeInterval: 0.5) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = [name]
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
    }
}

// Seen on macOS 27.0: a banner freezes halfway in and NotificationCenter spins at 100% CPU until it is killed.
final class NotificationCenterWatchdog: Feature {
    private var timer: Timer?
    private var last: (pid: pid_t, cpu: UInt64, date: Date)?
    private var busySamples = 0
    private let interval: TimeInterval = 10

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        last = nil
        busySamples = 0
    }

    private func sample() {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier,
              let cpu = Self.cpuTime(pid) else { return last = nil }
        defer { last = (pid, cpu, Date()) }
        guard let last, last.pid == pid else { return busySamples = 0 }
        let usage = Double(cpu - last.cpu) / 1e9 / Date().timeIntervalSince(last.date)
        busySamples = usage > 0.9 ? busySamples + 1 : 0
        guard busySamples >= 3 else { return }
        busySamples = 0
        Log.write("Notification Center at \(Int(usage * 100))% CPU for 30s")
        Restart.restart("Notification Center", ["NotificationCenter"])
    }

    // Nanoseconds of CPU time. rusage reports Mach ticks, which aren't nanoseconds on Apple silicon.
    private static func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        return (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

import AppKit
import ApplicationServices

// macOS sometimes ends up with the menu bar showing one app while keystrokes go nowhere or to
// another window, often after Space switches or Universal Control. Switching away and back clears it.
final class Focus: Feature {
    private(set) var isRunning = false
    private var timer: Timer?
    private var suspect: (pid: pid_t, count: Int)?
    private var lastFix: (bundle: String, date: Date)?
    // Apps whose windows don't report focus properly would otherwise be "fixed" over and over.
    private var ignored: Set<String> = []

    // MARK: Fix

    func fix() {
        guard let target = targetApp() else { return }
        Log.write("Fixing focus for \(target.localizedName ?? "app")")
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.yieldActivation(to: target)
            target.activate()
            self.raiseFrontWindow(of: target)
        }
    }

    private func targetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
           Self.windows().contains(where: { $0.pid == front.processIdentifier }) {
            return front
        }
        return Self.windows().first.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
    }

    private func raiseFrontWindow(of app: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let window = (value as? [AXUIElement])?.first else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: Auto-fix

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            Log.write("Auto-fix lost focus is waiting for Accessibility permission")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        suspect = nil
    }

    // Lost focus: the frontmost app has windows on screen, but none of them is focused, or another
    // app's window is on top of them on the same display. It has to last 3 seconds to count.
    private func check() {
        guard AXIsProcessTrusted(), !Self.screenLocked,
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              let bundle = front.bundleIdentifier, !ignored.contains(bundle) else { return suspect = nil }
        let windows = Self.windows()
        guard let own = windows.first(where: { $0.pid == front.processIdentifier }) else { return suspect = nil }
        let onTop = windows.first(where: { $0.display == own.display })
        guard onTop?.pid != front.processIdentifier || !hasFocusedWindow(front) else { return suspect = nil }

        let count = suspect?.pid == front.processIdentifier ? suspect!.count + 1 : 1
        suspect = (front.processIdentifier, count)
        guard count >= 3 else { return }
        suspect = nil

        if let lastFix, lastFix.bundle == bundle, Date().timeIntervalSince(lastFix.date) < 15 {
            ignored.insert(bundle)
            Log.write("Focus fixes don't stick for \(front.localizedName ?? bundle), leaving it alone until Gremlin restarts")
            return
        }
        lastFix = (bundle, Date())
        Log.write("Lost focus detected in \(front.localizedName ?? bundle)")
        fix()
    }

    private func hasFocusedWindow(_ app: NSRunningApplication) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                                   kAXFocusedWindowAttribute as CFString, &value)
        // Only a definite "no focused window" counts; apps that don't answer are given the benefit of the doubt.
        return result != .noValue
    }

    // MARK: Windows

    private struct Window {
        let pid: pid_t
        let display: CGDirectDisplayID
    }

    // Normal on-screen windows, front to back.
    private static func windows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 50, rect.height > 50 else { return nil }
            var display: CGDirectDisplayID = 0
            var count: UInt32 = 0
            CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &display, &count)
            return Window(pid: pid, display: display)
        }
    }

    private static var screenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

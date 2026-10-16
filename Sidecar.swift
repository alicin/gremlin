import Foundation
import UserNotifications

// SidecarCore is private, so every selector is checked first and the feature hides itself if one is missing.
final class Sidecar {
    private typealias DeviceCall = @convention(c) (NSObject, Selector, NSObject, @escaping @convention(block) (NSError?) -> Void) -> Void

    var onChange: (() -> Void)?
    private var pending: String?
    private let manager = Sidecar.loadManager()

    private static func loadManager() -> NSObject? {
        dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY)
        let shared = NSSelectorFromString("sharedManager")
        guard let type = NSClassFromString("SidecarDisplayManager") as? NSObject.Type, type.responds(to: shared),
              let manager = type.perform(shared)?.takeUnretainedValue() as? NSObject else { return nil }
        let selectors = ["devices", "connectedDevices", "connectToDevice:completion:", "disconnectFromDevice:completion:"]
        return selectors.allSatisfy { manager.responds(to: NSSelectorFromString($0)) } ? manager : nil
    }

    var isAvailable: Bool { manager != nil }

    var canToggle: Bool { pending == nil && target != nil }

    var title: String {
        if let pending { return pending }
        guard let target else { return "Use iPad as Display" }
        return target.connected ? "Disconnect \(Self.name(target.device))" : "Use \(Self.name(target.device)) as Display"
    }

    // An iPad already showing this Mac, otherwise the first one nearby. Connecting takes it over from another Mac.
    private var target: (device: NSObject, connected: Bool)? {
        if let device = list("connectedDevices").first { return (device, true) }
        return list("devices").first.map { ($0, false) }
    }

    func toggle() {
        guard manager != nil, pending == nil else { return }
        guard let target else { return notify("No iPad nearby.") }
        let name = Self.name(target.device)
        let verb = target.connected ? "disconnect" : "connect to"
        pending = target.connected ? "Disconnecting \(name)…" : "Connecting to \(name)…"
        Log.write("Sidecar: \(verb) \(name)")
        onChange?()
        let done: (NSError?) -> Void = { error in
            self.pending = nil
            if let error {
                Log.write("Sidecar: couldn't \(verb) \(name): \(error.localizedDescription)")
                self.notify("Couldn't \(verb) \(name): \(error.localizedDescription)")
            }
            self.onChange?()
        }
        target.connected ? call("disconnectFromDevice:completion:", target.device, done) : grab(target.device, done)
    }

    // An iPad showing another Mac switches over by itself, but a session this Mac still holds refuses a new one.
    // The error codes aren't public, so any failure drops the session and tries once more.
    private func grab(_ device: NSObject, retry: Bool = true, _ done: @escaping (NSError?) -> Void) {
        call("connectToDevice:completion:", device) { error in
            guard let error, retry else { return done(error) }
            Log.write("Sidecar: \(error.localizedDescription) Dropping the old session and retrying")
            self.call("disconnectFromDevice:completion:", device) { _ in self.grab(device, retry: false, done) }
        }
    }

    private func call(_ name: String, _ device: NSObject, _ completion: @escaping (NSError?) -> Void) {
        guard let manager else { return }
        let selector = NSSelectorFromString(name)
        let call = unsafeBitCast(manager.method(for: selector), to: DeviceCall.self)
        call(manager, selector, device) { error in DispatchQueue.main.async { completion(error) } }
    }

    private func list(_ selector: String) -> [NSObject] {
        manager?.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? [NSObject] ?? []
    }

    private static func name(_ device: NSObject) -> String {
        let selector = NSSelectorFromString("name")
        guard device.responds(to: selector) else { return "iPad" }
        return device.perform(selector)?.takeUnretainedValue() as? String ?? "iPad"
    }

    private func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sidecar"
        content.body = body
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

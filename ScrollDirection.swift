import AppKit
import IOKit
import os

struct ScrollDevice: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case trackpad
        case mouse
    }

    var key: String
    var name: String
    var kind: Kind
    var builtIn = false
    var transport: String?
    /// Nil follows macOS.
    var natural: Bool?

    var id: String { key }

    var title: String { builtIn && kind == .trackpad ? "Built-in Trackpad" : name }

    var symbol: String {
        switch kind {
        case .trackpad: "rectangle.and.hand.point.up.left.filled"
        case .mouse: name.localizedCaseInsensitiveContains("Magic Mouse") ? "magicmouse.fill" : "computermouse.fill"
        }
    }

    var connection: String {
        if builtIn { return "Built-in" }
        guard let transport, !transport.isEmpty else { return kind == .trackpad ? "Trackpad" : "Mouse" }
        return transport.hasPrefix("Bluetooth") ? "Bluetooth" : transport
    }
}

// Pointer devices as IOKit knows them. One device can have several HID services, which share a key.
enum PointerHardware {
    static func connected() -> [ScrollDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [String: ScrollDevice] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let page = own(service, "PrimaryUsagePage") as? Int
            let usage = own(service, "PrimaryUsage") as? Int
            guard page == 1, usage == 1 || usage == 2, let device = describe(service) else { continue }
            if found[device.key] == nil || device.kind == .trackpad { found[device.key] = device }
        }
        return Array(found.values)
    }

    /// The device behind a scroll event's sender, which is a HID service's registry ID.
    static func device(sender: UInt64) -> ScrollDevice? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return describe(service)
    }

    private static func describe(_ service: io_service_t) -> ScrollDevice? {
        let className = IOObjectCopyClass(service).takeRetainedValue() as String
        let name = (inherited(service, "Product") as? String)?.trimmingCharacters(in: .whitespaces)
        let vendor = inherited(service, "VendorID") as? Int ?? 0
        let product = inherited(service, "ProductID") as? Int ?? 0
        let pairs = own(service, "DeviceUsagePairs") as? [[String: Int]] ?? []
        let touchpad = pairs.contains { $0["DeviceUsagePage"] == 13 && $0["DeviceUsage"] == 5 }
        let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Pointer"
        let trackpad = touchpad || className.contains("Trackpad") || label.contains("Trackpad")
        return ScrollDevice(key: "\(vendor):\(product):\(label)", name: label, kind: trackpad ? .trackpad : .mouse,
                            builtIn: inherited(service, "Built-In") as? Bool ?? false, transport: inherited(service, "Transport") as? String)
    }

    private static func own(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue()
    }

    private static func inherited(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, nil,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}

enum ScrollEvent {
    private typealias CopyHIDEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias SenderID = @convention(c) (CFTypeRef) -> UInt64

    // Neither is public, but there's no other way to tell which device sent a scroll. Without them nothing is flipped.
    private static let copyHIDEvent = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventCopyIOHIDEvent").map { unsafeBitCast($0, to: CopyHIDEvent.self) }
    private static let senderID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventGetSenderID").map { unsafeBitCast($0, to: SenderID.self) }

    // macOS marks events natural scrolling has flipped in this undocumented field. It's checked against NSEvent once
    // and left alone if it ever moves.
    static let invertedField: CGEventField? = {
        guard let field = CGEventField(rawValue: 137),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) else { return nil }
        event.setIntegerValueField(field, value: 1)
        guard NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true else { return nil }
        event.setIntegerValueField(field, value: 0)
        return NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == false ? field : nil
    }()

    static func sender(of event: CGEvent) -> UInt64 {
        guard let copyHIDEvent, let senderID, let hid = copyHIDEvent(event)?.takeRetainedValue() else { return 0 }
        return senderID(hid)
    }

    static func isNatural(_ event: CGEvent) -> Bool {
        if let invertedField { return event.getIntegerValueField(invertedField) != 0 }
        return NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
    }

    static func flip(_ event: CGEvent, natural: Bool) {
        let line = (event.getIntegerValueField(.scrollWheelEventDeltaAxis1), event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let fixed = (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        let point = (event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        // Setting a line delta recomputes the other two from it, so it goes first.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line.0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -line.1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed.0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed.1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point.0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point.1)
        if let invertedField { event.setIntegerValueField(invertedField, value: natural ? 1 : 0) }
    }
}

// The event tap runs on its own thread, so a busy main thread can't make macOS give up on it and lag the scrolling.
final class ScrollTap: @unchecked Sendable {
    private struct State {
        var port: CFMachPort?
        var loop: CFRunLoop?
        var natural: [String: Bool] = [:]
        var keys: [UInt64: String] = [:]
        var reported: [String: TimeInterval] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var senderOf: @Sendable (CGEvent) -> UInt64 = { ScrollEvent.sender(of: $0) }
    var onNewDevice: (@Sendable (ScrollDevice) -> Void)?
    var onScroll: (@Sendable (String) -> Void)?

    var isRunning: Bool { state.withLock { $0.port != nil } }

    func set(_ natural: [String: Bool]) {
        state.withLock { $0.natural = natural }
    }

    func forgetSenders() {
        state.withLock { $0.keys = [:] }
    }

    /// False when macOS won't allow the tap, which takes Accessibility permission.
    func start() -> Bool {
        if isRunning { return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: scrollTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        state.withLock { $0.port = port }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            self?.state.withLock { $0.loop = loop }
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Gremlin scroll direction"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        let (port, loop) = state.withLock { s in
            defer { s.port = nil; s.loop = nil }
            return (s.port, s.loop)
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = state.withLock({ $0.port }) { CGEvent.tapEnable(tap: port, enable: true) }
        case .scrollWheel:
            process(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func process(_ event: CGEvent) {
        let sender = senderOf(event)
        guard sender != 0 else { return }
        let key: String
        if let known = state.withLock({ $0.keys[sender] }) {
            key = known
        } else {
            let device = PointerHardware.device(sender: sender)
            let found = device?.key ?? ""
            state.withLock { $0.keys[sender] = found }
            if let device { onNewDevice?(device) }
            key = found
        }
        guard !key.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let (natural, report) = state.withLock { s in
            let report = now - (s.reported[key] ?? 0) > 1
            if report { s.reported[key] = now }
            return (s.natural[key], report)
        }
        if report { onScroll?(key) }
        guard let natural, ScrollEvent.isNatural(event) != natural else { return }
        ScrollEvent.flip(event, natural: natural)
    }
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ScrollTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
}

// macOS has one Natural Scrolling setting for every mouse and trackpad. This flips the scrolling of each device set
// the other way, like Scroll Reverser, and only taps scroll events while one is.
@MainActor
final class ScrollDirection: ObservableObject {
    @Published private(set) var devices: [ScrollDevice] = []
    @Published private(set) var connected: Set<String> = []
    @Published private(set) var lastScrolled: [String: Date] = [:]
    @Published private(set) var macNatural = true
    @Published private(set) var needsAccess = false

    /// The screen showing devices, which taps scrolls so each one lights up as it's used.
    var watching = false {
        didSet { if watching != oldValue { apply() } }
    }

    private let tap = ScrollTap()
    private let tapping: Bool
    private let file: URL
    private var remembered: [ScrollDevice]
    // Devices that scroll but aren't a mouse or trackpad by their HID usage, like a tablet, until they disconnect.
    private var others: [ScrollDevice] = []
    private var hotplug: IONotificationPortRef?
    private var hotplugIterators: [io_iterator_t] = []
    private var settling: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    /// Without tapping, it shows the devices and settings but never touches a scroll.
    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Gremlin"), tapping: Bool = true) {
        self.tapping = tapping
        file = folder.appendingPathComponent("scrolling.json")
        remembered = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([ScrollDevice].self, from: $0) } ?? []
        tap.onNewDevice = { [weak self] device in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.met(device) } }
        }
        tap.onScroll = { [weak self] key in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastScrolled[key] = Date() } }
        }
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("SwipeScrollDirectionDidChangeNotification"), object: nil,
                                                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watchHotplug()
        refresh()
    }

    func stop() {
        tap.stop()
        observer.map(DistributedNotificationCenter.default().removeObserver)
        hotplugIterators.forEach { IOObjectRelease($0) }
        hotplugIterators = []
        hotplug.map(IONotificationPortDestroy)
        hotplug = nil
    }

    func refresh() {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        macNatural = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
        var live = PointerHardware.connected()
        live += others.filter { other in !live.contains { $0.key == other.key } }
        connected = Set(live.map(\.key))
        var all = live.map { device in
            var device = device
            device.natural = remembered.first { $0.key == device.key }?.natural
            return device
        }
        all += remembered.filter { saved in !all.contains { $0.key == saved.key } }
        devices = all.sorted { a, b in
            if a.builtIn != b.builtIn { return a.builtIn }
            if connected.contains(a.key) != connected.contains(b.key) { return connected.contains(a.key) }
            if a.kind != b.kind { return a.kind == .trackpad }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        apply()
    }

    func isNatural(_ device: ScrollDevice) -> Bool { device.natural ?? macNatural }

    /// Whether Gremlin flips this device's scrolling.
    func flips(_ device: ScrollDevice) -> Bool { device.natural.map { $0 != macNatural } ?? false }

    func setNatural(_ natural: Bool, for device: ScrollDevice) {
        remembered.removeAll { $0.key == device.key }
        var saved = device
        saved.natural = natural
        remembered.append(saved)
        Log.write("Scrolling on \(device.title) set to \(natural ? "natural" : "standard")")
        save()
        refresh()
    }

    func forget(_ device: ScrollDevice) {
        remembered.removeAll { $0.key == device.key }
        save()
        refresh()
    }

    private func met(_ device: ScrollDevice) {
        guard !connected.contains(device.key) else { return }
        if !PointerHardware.connected().contains(where: { $0.key == device.key }) { others.append(device) }
        refresh()
    }

    private func apply() {
        tap.set(Dictionary(uniqueKeysWithValues: devices.compactMap { device in device.natural.map { (device.key, $0) } }))
        let needed = tapping && (watching || devices.contains(where: flips))
        if needed, !tap.isRunning {
            let started = tap.start()
            needsAccess = !started && devices.contains(where: flips)
            if started, devices.contains(where: flips) { Log.write("Flipping scrolling for \(devices.filter(flips).map(\.title).joined(separator: ", "))") }
        } else if !needed, tap.isRunning {
            tap.stop()
            needsAccess = false
        } else if !needed {
            needsAccess = false
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(remembered).write(to: file, options: .atomic)
        } catch {
            Log.write("Couldn't save scrolling.json: \(error)")
        }
    }

    // Pointer devices come and go with USB and Bluetooth; a burst of HID services settles before the list updates.
    private func watchHotplug() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        hotplug = port
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let changed: IOServiceMatchingCallback = { info, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let info else { return }
            let directions = Unmanaged<ScrollDirection>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { directions.hardwareChanged() }
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOHIDEventService"), changed, me, &iterator) == KERN_SUCCESS else { continue }
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            hotplugIterators.append(iterator)
        }
    }

    private func hardwareChanged() {
        settling?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.others = []
                self?.tap.forgetSenders()
                self?.refresh()
            }
        }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

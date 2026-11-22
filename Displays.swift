import AppKit
import CoreGraphics

struct DisplayIdentity: Codable, Hashable, Sendable {
    var name: String
    var builtIn = false
    var vendor: UInt32 = 0
    var model: UInt32 = 0
    var serial: UInt32 = 0

    // macOS numbers displays that share a name, "LG HDR 4K (1)" and "(2)", in the order they show up, so a hub can
    // swap the numbers. The built-in display's name differs between macOS's own lists.
    var group: String {
        if builtIn { return "built-in" }
        guard let range = name.range(of: #" \(\d+\)$"#, options: .regularExpression) else { return name.lowercased() }
        return name[..<range.lowerBound].lowercased()
    }

    var key: String { "\(group)#\(vendor)-\(model)-\(serial)" }
}

struct DisplayMode: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refresh: Double

    init(_ mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refresh = mode.refreshRate
    }

    var hiDPI: Bool { pixelWidth > width }

    func same(as other: DisplayMode) -> Bool {
        width == other.width && height == other.height && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && abs(refresh - other.refresh) < 0.5
    }

    var text: String {
        "\(width) × \(height)" + (refresh > 0 ? " · \(Int(refresh.rounded())) Hz" : "") + (hiDPI ? "" : " · low resolution")
    }
}

struct SavedDisplay: Codable, Equatable, Sendable {
    var display: DisplayIdentity
    var x: Int
    var y: Int
    var mode: DisplayMode
    var rotation = 0
    // The index of the display this one mirrors.
    var mirrors: Int?

    var main: Bool { x == 0 && y == 0 && mirrors == nil }
    var frame: CGRect { CGRect(x: x, y: y, width: mode.width, height: mode.height) }

    var detail: String {
        var parts = [mode.text]
        if rotation != 0 { parts.append("rotated \(rotation)°") }
        return parts.joined(separator: " · ")
    }
}

struct DisplayLayout: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var displays: [SavedDisplay]
    var automatic = false

    init(name: String, displays: [SavedDisplay]) {
        self.name = name
        self.displays = displays
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        displays = try values.decodeIfPresent([SavedDisplay].self, forKey: .displays) ?? []
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
    }

    var title: String { name.isEmpty ? "Layout" : name }
    var keys: [String] { displays.map(\.display.key).sorted() }
}

struct DisplayConfig: Codable {
    var layouts: [DisplayLayout] = []

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layouts = try values.decodeIfPresent([DisplayLayout].self, forKey: .layouts) ?? []
    }
}

struct LiveDisplay: Sendable {
    let id: CGDirectDisplayID
    let display: DisplayIdentity
    let frame: CGRect
    let mode: DisplayMode?
    let rotation: Int
    let mirrors: CGDirectDisplayID?
}

// Positions, resolutions and mirroring go through CoreGraphics. Rotation has no public API, so it goes through the
// MonitorPanel framework System Settings uses, checked first like Sidecar.
enum DisplayHardware {
    private typealias IntGetter = @convention(c) (NSObject, Selector) -> Int32
    private typealias IntSetter = @convention(c) (NSObject, Selector, Int32) -> Void
    private typealias BoolGetter = @convention(c) (NSObject, Selector) -> Bool

    private static let monitorPanel: NSObject.Type? = {
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
        guard let manager = NSClassFromString("MPDisplayMgr") as? NSObject.Type,
              manager.instancesRespond(to: NSSelectorFromString("displays")),
              let display = NSClassFromString("MPDisplay") as? NSObject.Type else { return nil }
        let selectors = ["displayID", "displayName", "orientation", "setOrientation:"]
        return selectors.allSatisfy { display.instancesRespond(to: NSSelectorFromString($0)) } ? manager : nil
    }()

    private static let cache = NSLock()
    nonisolated(unsafe) private static var names: [CGDirectDisplayID: String] = [:]

    private static func panelDisplays() -> [NSObject] {
        (monitorPanel?.init().value(forKey: "displays") as? [NSObject]) ?? []
    }

    private static func int(_ object: NSObject, _ name: String) -> Int32 {
        let selector = NSSelectorFromString(name)
        return unsafeBitCast(object.method(for: selector), to: IntGetter.self)(object, selector)
    }

    // The names System Settings shows. Reading them takes a while, so they're read again only after displays change.
    static func readNames() {
        var found: [CGDirectDisplayID: String] = [:]
        for display in panelDisplays() {
            if let name = display.value(forKey: "displayName") as? String { found[CGDirectDisplayID(int(display, "displayID"))] = name }
        }
        cache.lock()
        names = found
        cache.unlock()
    }

    static var canRotate: Bool { monitorPanel != nil }

    static func online() -> [LiveDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        cache.lock()
        let known = names
        cache.unlock()
        var screens: [CGDirectDisplayID: String] = [:]
        if Thread.isMainThread {
            for screen in NSScreen.screens {
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID { screens[id] = screen.localizedName }
            }
        }
        return ids.prefix(Int(count)).map { id in
            let master = CGDisplayMirrorsDisplay(id)
            let identity = DisplayIdentity(name: known[id] ?? screens[id] ?? "Display \(id)", builtIn: CGDisplayIsBuiltin(id) != 0,
                                           vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
            return LiveDisplay(id: id, display: identity, frame: CGDisplayBounds(id), mode: CGDisplayCopyDisplayMode(id).map(DisplayMode.init),
                               rotation: Int(CGDisplayRotation(id).rounded()), mirrors: master == kCGNullDirectDisplay ? nil : master)
        }
    }

    // The main display first, then left to right.
    static func snapshot(_ live: [LiveDisplay]) -> [SavedDisplay] {
        let ordered = live.filter { $0.mode != nil }.sorted { a, b in
            let mainA = a.frame.origin == .zero && a.mirrors == nil, mainB = b.frame.origin == .zero && b.mirrors == nil
            if mainA != mainB { return mainA }
            return (a.frame.minX, a.frame.minY) < (b.frame.minX, b.frame.minY)
        }
        return ordered.map { display in
            SavedDisplay(display: display.display, x: Int(display.frame.minX), y: Int(display.frame.minY), mode: display.mode!,
                         rotation: display.rotation, mirrors: display.mirrors.flatMap { master in ordered.firstIndex { $0.id == master } })
        }
    }

    // Matches by name. Displays that share a name are told apart by serial number, then by macOS's number.
    static func match(_ saved: [DisplayIdentity], to live: [LiveDisplay]) -> [Int: LiveDisplay] {
        var result: [Int: LiveDisplay] = [:]
        var free = live
        func take(_ index: Int, _ found: LiveDisplay) {
            result[index] = found
            free.removeAll { $0.id == found.id }
        }
        for (group, indices) in Dictionary(grouping: saved.indices, by: { saved[$0].group }).sorted(by: { $0.key < $1.key }) {
            for index in indices where saved[index].serial != 0 {
                let wanted = saved[index]
                guard indices.filter({ saved[$0].serial == wanted.serial }).count == 1 else { continue }
                let same = free.filter { $0.display.group == group && $0.display.vendor == wanted.vendor && $0.display.serial == wanted.serial }
                if same.count == 1 { take(index, same[0]) }
            }
            for index in indices where result[index] == nil {
                if let found = free.first(where: { $0.display.group == group && $0.display.name == saved[index].name }) { take(index, found) }
            }
            for index in indices where result[index] == nil {
                if let found = free.first(where: { $0.display.group == group }) { take(index, found) }
            }
        }
        return result
    }

    static func isCurrent(_ layout: DisplayLayout, _ live: [LiveDisplay]) -> Bool {
        guard !layout.displays.isEmpty, live.count == layout.displays.count else { return false }
        let matched = match(layout.displays.map(\.display), to: live)
        guard matched.count == layout.displays.count else { return false }
        return layout.displays.indices.allSatisfy { index in
            let saved = layout.displays[index], display = matched[index]!
            let master = saved.mirrors.flatMap { matched[$0]?.id }
            guard display.rotation == saved.rotation, display.mirrors == master, display.mode?.same(as: saved.mode) == true else { return false }
            return master != nil || (Int(display.frame.minX) == saved.x && Int(display.frame.minY) == saved.y)
        }
    }

    static func bestMode(for wanted: DisplayMode, on id: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let all = ((CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []).filter { $0.isUsableForDesktopGUI() }
        let sized = all.filter { $0.width == wanted.width && $0.height == wanted.height }
        let exact = sized.filter { $0.pixelWidth == wanted.pixelWidth && $0.pixelHeight == wanted.pixelHeight }
        let density = sized.filter { ($0.pixelWidth > $0.width) == wanted.hiDPI }
        let pool = !exact.isEmpty ? exact : !density.isEmpty ? density : sized
        return pool.min { abs($0.refreshRate - wanted.refresh) < abs($1.refreshRate - wanted.refresh) }
    }

    private static func rotate(_ id: CGDirectDisplayID, to degrees: Int) -> Bool {
        guard let display = panelDisplays().first(where: { CGDirectDisplayID(int($0, "displayID")) == id }) else { return false }
        let can = NSSelectorFromString("canChangeOrientation")
        if display.responds(to: can), unsafeBitCast(display.method(for: can), to: BoolGetter.self)(display, can) == false { return false }
        let selector = NSSelectorFromString("setOrientation:")
        unsafeBitCast(display.method(for: selector), to: IntSetter.self)(display, selector, Int32(degrees))
        return true
    }

    private static func wait(until done: () -> Bool, seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { usleep(100_000) }
    }

    private static let helperMarker = "GREMLIN_APPLY_DISPLAYS"

    private struct HelperRequest: Codable {
        let layout: DisplayLayout
        let ids: [Int: CGDirectDisplayID]
    }

    // Once a process has rotated a display and changed the configuration, macOS can stop updating the rotation it reads
    // back, so each layout is applied by a short-lived copy of Gremlin. Blocks until it's done.
    static func applyInHelper(_ layout: DisplayLayout, matched: [Int: LiveDisplay]) -> [String] {
        let failed = ["Gremlin couldn't change the displays."]
        guard let executable = Bundle.main.executablePath,
              let request = try? JSONEncoder().encode(HelperRequest(layout: layout, ids: matched.mapValues(\.id))) else { return failed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = ProcessInfo.processInfo.environment.merging([helperMarker: "1"]) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            Log.write("Couldn't start the display helper: \(error)")
            return failed
        }
        input.fileHandleForWriting.write(request)
        try? input.fileHandleForWriting.close()
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return (try? JSONDecoder().decode([String].self, from: answer)) ?? failed
    }

    // Returns at once unless Gremlin started this process to apply a layout.
    static func applyIfAsked() {
        guard ProcessInfo.processInfo.environment[helperMarker] != nil else { return }
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: FileHandle.standardInput.readDataToEndOfFile()) else { exit(1) }
        Thread {
            readNames()
            let live = online()
            let problems = apply(request.layout, matched: request.ids.compactMapValues { id in live.first { $0.id == id } })
            FileHandle.standardOutput.write((try? JSONEncoder().encode(problems)) ?? Data("[]".utf8))
            exit(0)
        }.start()
        RunLoop.main.run()
        exit(0)
    }

    // Blocks while the displays reconfigure, so it runs off the main thread. Returns what didn't work.
    static func apply(_ layout: DisplayLayout, matched: [Int: LiveDisplay]) -> [String] {
        var problems: [String] = []
        func turned(_ index: Int) -> Bool { Int(CGDisplayRotation(matched[index]!.id).rounded()) == layout.displays[index].rotation }
        let turns = matched.keys.filter { layout.displays[$0].mirrors == nil && !turned($0) }
        if !turns.isEmpty, canRotate {
            // On the main thread, as System Settings calls it.
            let rotateAll = { turns.filter { rotate(matched[$0]!.id, to: layout.displays[$0].rotation) } }
            let started = Thread.isMainThread ? rotateAll() : DispatchQueue.main.sync(execute: rotateAll)
            wait(until: { started.allSatisfy(turned) }, seconds: 5)
        }
        // A display left at the wrong angle can't take the saved resolution, which is sized for the saved one.
        let unturned = Set(turns.filter { !turned($0) })
        for index in unturned.sorted() {
            problems.append(canRotate ? "\(matched[index]!.display.name) can't be rotated." : "Gremlin can't rotate displays on this version of macOS.")
        }

        // Positions are relative to the main display. Without it, the current main display stays where it is.
        var offset = (x: 0, y: 0)
        if !layout.displays.indices.contains(where: { layout.displays[$0].main && matched[$0] != nil }),
           let index = matched.first(where: { $0.value.id == CGMainDisplayID() })?.key {
            offset = (layout.displays[index].x, layout.displays[index].y)
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return problems + ["macOS wouldn't change the displays."] }
        for (index, display) in matched.sorted(by: { $0.key < $1.key }) {
            let saved = layout.displays[index]
            let master = saved.mirrors.flatMap { matched[$0]?.id } ?? kCGNullDirectDisplay
            if CGDisplayMirrorsDisplay(display.id) != master {
                CGConfigureDisplayMirrorOfDisplay(config, display.id, master)
            }
            if !unturned.contains(index), CGDisplayCopyDisplayMode(display.id).map({ DisplayMode($0).same(as: saved.mode) }) != true {
                if let mode = bestMode(for: saved.mode, on: display.id) {
                    CGConfigureDisplayWithDisplayMode(config, display.id, mode, nil)
                } else {
                    problems.append("\(display.display.name) can't show \(saved.mode.width) × \(saved.mode.height).")
                }
            }
            if master == kCGNullDirectDisplay {
                CGConfigureDisplayOrigin(config, display.id, Int32(saved.x - offset.x), Int32(saved.y - offset.y))
            }
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success {
            CGCancelDisplayConfiguration(config)
            problems.append("macOS wouldn't change the displays (error \(result.rawValue)).")
        }
        return problems
    }
}

// Saves how the displays are arranged, with their resolutions, and puts them back, by hand or when they connect.
@MainActor
final class Displays: ObservableObject {
    @Published var config: DisplayConfig { didSet { save() } }
    @Published private(set) var live: [LiveDisplay] = []
    @Published private(set) var applying: UUID?
    @Published private(set) var notes: [UUID: String] = [:]
    @Published var editing: UUID?

    private let folder: URL
    private var connected: [String]?
    private var woke = false
    private var settling: DispatchWorkItem?
    private var watchers: [NSObjectProtocol] = []

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Gremlin")) {
        self.folder = folder
        let file = folder.appendingPathComponent("displays.json")
        if let data = try? Data(contentsOf: file) {
            do {
                config = try JSONDecoder().decode(DisplayConfig.self, from: data)
            } catch {
                Log.write("Couldn't read displays.json, setting it aside: \(error)")
                try? FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("displays-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
                config = DisplayConfig()
            }
        } else {
            config = DisplayConfig()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: folder.appendingPathComponent("displays.json"), options: .atomic)
        } catch {
            Log.write("Couldn't save displays.json: \(error)")
        }
    }

    func start() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard let info, !flags.contains(.beginConfigurationFlag) else { return }
            let displays = Unmanaged<Displays>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { displays.changed() } }
        }, Unmanaged.passUnretained(self).toOpaque())
        watchers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.woke = true
                    self?.changed(after: 3)
                }
            },
        ]
        DisplayHardware.readNames()
        settle()
    }

    func refresh() {
        live = DisplayHardware.online()
    }

    // A hub brings displays up one at a time, so this waits for them to settle.
    private func changed(after delay: Double = 2) {
        settling?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settle() } }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Only when displays come or go, or after sleep, so arranging them by hand isn't undone.
    private func settle(tries: Int = 0) {
        DisplayHardware.readNames()
        refresh()
        // A display that just connected can have no mode yet, or be named Unknown Display until macOS reads its EDID.
        if tries < 5, live.contains(where: { $0.mode == nil || $0.display.name.hasPrefix("Unknown Display") }) {
            settling?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settle(tries: tries + 1) } }
            settling = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }
        let keys = live.map(\.display.key).sorted()
        let changed = keys != connected || woke
        connected = keys
        woke = false
        guard changed, applying == nil,
              let layout = config.layouts.first(where: { $0.automatic && $0.keys == keys }),
              !DisplayHardware.isCurrent(layout, live) else { return }
        Log.write("Displays changed, applying \(layout.title)")
        apply(layout)
    }

    var current: DisplayLayout? {
        config.layouts.first { DisplayHardware.isCurrent($0, live) }
    }

    func layout(_ id: UUID?) -> DisplayLayout? {
        config.layouts.first { $0.id == id }
    }

    func missing(_ layout: DisplayLayout) -> [SavedDisplay] {
        let matched = DisplayHardware.match(layout.displays.map(\.display), to: live)
        return layout.displays.indices.filter { matched[$0] == nil }.map { layout.displays[$0] }
    }

    func fits(_ layout: DisplayLayout) -> Bool {
        missing(layout).isEmpty
    }

    @discardableResult
    func saveCurrent() -> DisplayLayout {
        refresh()
        let displays = DisplayHardware.snapshot(live)
        var layout = DisplayLayout(name: uniqueName(Self.suggestedName(displays)), displays: displays)
        layout.automatic = !config.layouts.contains { $0.automatic && $0.keys == layout.keys }
        config.layouts.append(layout)
        return layout
    }

    func replace(_ layout: DisplayLayout) {
        refresh()
        guard let index = config.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        config.layouts[index].displays = DisplayHardware.snapshot(live)
        notes[layout.id] = nil
        if config.layouts[index].automatic { setAutomatic(config.layouts[index], true) }
    }

    func remove(_ layout: DisplayLayout) {
        config.layouts.removeAll { $0.id == layout.id }
        notes[layout.id] = nil
    }

    // One layout per set of displays applies itself.
    func setAutomatic(_ layout: DisplayLayout, _ on: Bool) {
        for index in config.layouts.indices {
            if config.layouts[index].id == layout.id {
                config.layouts[index].automatic = on
            } else if on, config.layouts[index].keys == layout.keys {
                config.layouts[index].automatic = false
            }
        }
    }

    func apply(_ layout: DisplayLayout) {
        guard applying == nil else { return }
        refresh()
        let matched = DisplayHardware.match(layout.displays.map(\.display), to: live)
        guard !matched.isEmpty else {
            notes[layout.id] = "None of its displays are connected."
            return
        }
        let missing = layout.displays.indices.filter { matched[$0] == nil }.map { layout.displays[$0].display.name }
        applying = layout.id
        notes[layout.id] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var problems = DisplayHardware.applyInHelper(layout, matched: matched)
            if !missing.isEmpty {
                problems.append("\(ListFormatter.localizedString(byJoining: missing)) \(missing.count == 1 ? "isn't" : "aren't") connected.")
            }
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.applying = nil
                    self.refresh()
                    self.connected = self.live.map(\.display.key).sorted()
                    if problems.isEmpty, missing.isEmpty, !DisplayHardware.isCurrent(layout, self.live) {
                        problems.append("Some displays didn't take their place.")
                    }
                    self.notes[layout.id] = problems.isEmpty ? nil : problems.joined(separator: " ")
                    Log.write(problems.isEmpty ? "Applied display layout \(layout.title)" : "Applied display layout \(layout.title): \(problems.joined(separator: " "))")
                }
            }
        }
    }

    private static func suggestedName(_ displays: [SavedDisplay]) -> String {
        let others = displays.filter { !$0.display.builtIn }
        let builtIn = displays.contains { $0.display.builtIn }
        switch (builtIn, others.count) {
        case (true, 0): return "Built-in only"
        case (true, 1): return "Built-in + \(others[0].display.name)"
        case (true, _): return "Built-in + \(others.count) displays"
        case (false, 1): return others[0].display.name
        default: return "\(others.count) displays"
        }
    }

    private func uniqueName(_ name: String) -> String {
        let taken = Set(config.layouts.map(\.name))
        guard taken.contains(name) else { return name }
        return (2...).lazy.map { "\(name) \($0)" }.first { !taken.contains($0) }!
    }
}

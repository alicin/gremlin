import AppKit
import IOKit

// What's plugged into each port: the cable, the charger and the devices behind it, read from the IOPort registry
// plane that Apple Silicon Macs publish for their USB-C and MagSafe ports. Nothing here needs root.

// MARK: - Units

enum Units {
    static func watts(_ milliwatts: Int) -> String {
        let w = Double(milliwatts) / 1000
        return w >= 10 || w == w.rounded() ? "\(Int(w.rounded())) W" : String(format: "%.1f W", w)
    }

    static func volts(_ millivolts: Int) -> String {
        let v = Double(millivolts) / 1000
        return v == v.rounded() ? "\(Int(v)) V" : String(format: "%.1f V", v)
    }

    static func amps(_ milliamps: Int) -> String {
        let a = Double(milliamps) / 1000
        return a == a.rounded() ? "\(Int(a)) A" : String(format: "%.2g A", a)
    }

    static func rate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1e9 {
            let g = bitsPerSecond / 1e9
            return g == g.rounded() ? "\(Int(g)) Gb/s" : String(format: "%.1f Gb/s", g)
        }
        let m = bitsPerSecond / 1e6
        return m == m.rounded() ? "\(Int(m)) Mb/s" : String(format: "%.1f Mb/s", m)
    }

    static func hex(_ value: UInt32) -> String { String(format: "0x%08X", value) }
    static func hex16(_ value: Int) -> String { String(format: "0x%04X", value) }
}

// MARK: - USB Power Delivery

/// A USB data speed as USB PD names it in cable and device VDOs.
enum USBSpeed: Int, Comparable, Sendable {
    case usb2, gen1, gen2, gen3, gen4

    init?(field: UInt32) {
        guard let speed = USBSpeed(rawValue: Int(field & 0x7)) else { return nil }
        self = speed
    }

    static func < (a: USBSpeed, b: USBSpeed) -> Bool { a.rawValue < b.rawValue }

    /// The fastest a cable rated this way carries, over both of its lane pairs.
    var cableBitsPerSecond: Double {
        switch self {
        case .usb2: 480e6
        case .gen1: 5e9
        case .gen2: 20e9
        case .gen3: 40e9
        case .gen4: 80e9
        }
    }

    var cableTitle: String {
        switch self {
        case .usb2: "USB 2 only"
        case .gen1: "USB 5 Gb/s"
        case .gen2: "USB 10 Gb/s"
        case .gen3: "USB4 40 Gb/s"
        case .gen4: "USB4 80 Gb/s"
        }
    }

    var specName: String {
        switch self {
        case .usb2: "USB 2.0"
        case .gen1: "USB 3.2 Gen 1"
        case .gen2: "USB 3.2 Gen 2"
        case .gen3: "USB4 Gen 3"
        case .gen4: "USB4 Gen 4"
        }
    }
}

/// What a USB-C partner or cable says about itself in its Discover Identity reply.
struct PDIdentity: Equatable, Sendable {
    let vendorID: Int
    let productID: Int
    let bcdDevice: Int
    let vdos: [UInt32]
    let revision: Int?

    var header: UInt32 { vdos.first ?? 0 }
    var usbHost: Bool { header & (1 << 31) != 0 }
    var usbDevice: Bool { header & (1 << 30) != 0 }
    var modal: Bool { header & (1 << 26) != 0 }
    /// The UFP product type for a partner, the cable plug type for SOP'.
    var upperType: Int { Int(header >> 27 & 0x7) }
    var dfpType: Int { Int(header >> 23 & 0x7) }
    var certXID: UInt32? { vdos.count > 1 && vdos[1] != 0 ? vdos[1] : nil }
    var vendor: String? { USBVendors.name(vendorID) }
    var vendorText: String { vendor ?? (vendorID == 0 ? "No vendor given" : Units.hex16(vendorID)) }

    var partnerKind: String {
        switch upperType {
        case 1: return "USB hub"
        case 2: return "USB peripheral"
        case 3: return "Power sink"
        case 5: return "Alternate mode adapter"
        default: break
        }
        switch dfpType {
        case 1: return "USB hub"
        case 2: return "USB host"
        case 3: return "Power brick"
        default: return "USB-C device"
        }
    }

    /// The UFP VDO of a PD 3 hub or peripheral, which says what data the device can do.
    var ufpVDO: UInt32? {
        guard upperType == 1 || upperType == 2, vdos.count > 3, (revision ?? 0) >= 3 else { return nil }
        return vdos[3]
    }

    var deviceSpeed: USBSpeed? { ufpVDO.flatMap { USBSpeed(field: $0) } }
    var revisionText: String? { revision.flatMap { $0 >= 2 ? "USB PD \($0).0" : nil } }
}

/// The e-marker chip in a cable, as read over SOP'.
struct CableMarker: Equatable, Sendable {
    let identity: PDIdentity
    /// Set when the Thunderbolt controller says the cable only made 20 Gb/s, which settles what speed code 3 means.
    var thunderbolt20 = false

    var active: Bool { identity.upperType == 4 }
    /// A VCONN-powered device such as USB-C headphones, whose VDO isn't a cable VDO.
    var poweredDevice: Bool { identity.upperType == 6 }
    var decodable: Bool { !poweredDevice && identity.vdos.count > 3 }
    private var vdo: UInt32 { decodable ? identity.vdos[3] : 0 }
    private var vdo2: UInt32? { active && identity.vdos.count > 4 ? identity.vdos[4] : nil }

    var speed: USBSpeed? {
        guard decodable, let speed = USBSpeed(field: vdo) else { return nil }
        return speed == .gen3 && thunderbolt20 ? .gen2 : speed
    }

    var milliamps: Int { vdo >> 5 & 0x3 == 2 ? 5000 : 3000 }
    var epr: Bool { vdo >> 17 & 0x1 != 0 }
    var fiftyVolts: Bool { vdo >> 9 & 0x3 == 3 }
    /// USB PD contracts top out at 20 V without EPR and at 48 V with it, whatever the insulation is rated for.
    var maxMilliwatts: Int { (epr || fiftyVolts ? 48_000 : 20_000) * milliamps / 1000 }
    var captive: Bool { vdo >> 18 & 0x3 == 3 }
    var latency: Int { Int(vdo >> 13 & 0xF) }
    var hardwareVersion: Int { Int(vdo >> 28 & 0xF) }
    var firmwareVersion: Int { Int(vdo >> 24 & 0xF) }

    var length: String? {
        switch latency {
        case 1: "About 1 m or shorter"
        case 2...7: "About \(latency) m"
        case 8: "Longer than 7 m"
        case 9: "About 200 m"
        case 10: "About 400 m"
        default: nil
        }
    }

    var optical: Bool { (vdo2 ?? 0) >> 10 & 0x1 != 0 || (active && latency >= 9) }
    var retimer: Bool { (vdo2 ?? 0) >> 9 & 0x1 != 0 }
    var usb4: Bool? { vdo2.map { $0 >> 8 & 0x1 == 0 } }

    var kind: String {
        if poweredDevice { return "USB-C accessory" }
        if optical { return "Active optical cable" }
        return active ? "Active cable" : "Passive cable"
    }
}

// MARK: - Ports

enum PortTransport: String, CaseIterable, Sendable {
    case cc = "CC", usb2 = "USB2", usb3 = "USB3", cio = "CIO", displayPort = "DisplayPort", usb4 = "USB4"

    var title: String {
        switch self {
        case .cc: "Power Delivery"
        case .usb2: "USB 2"
        case .usb3: "USB 3"
        case .cio: "Thunderbolt"
        case .displayPort: "DisplayPort"
        case .usb4: "USB4"
        }
    }
}

struct PortLocation: Equatable, Sendable {
    enum Side: String, Sendable { case left, right, rear, front }
    enum Spot: String, Sendable { case rear, middle, front, left, right }

    var side: Side
    var spot: Spot

    /// From the device tree's "left-rear" and the like.
    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "-").map(String.init)
        guard let first = parts.first, let side = Side(rawValue: first) else { return nil }
        self.side = side
        spot = parts.dropFirst().first.flatMap(Spot.init) ?? .middle
    }

    init(side: Side, spot: Spot) {
        self.side = side
        self.spot = spot
    }

    var title: String { spot == .middle ? "\(side.rawValue.capitalized) side" : "\(side.rawValue.capitalized) side, \(spot.rawValue)" }
}

struct PowerOption: Equatable, Sendable, Identifiable {
    let fixed: Bool
    let millivolts: Int
    let milliamps: Int
    let milliwatts: Int

    var id: String { "\(fixed)\(millivolts)\(milliamps)" }
    var title: String { "\(Units.volts(millivolts)) · \(Units.amps(milliamps))" }
}

struct PowerSourceInfo: Equatable, Sendable, Identifiable {
    let name: String
    let options: [PowerOption]
    let winning: PowerOption?
    let selected: Bool

    var id: String { name }
    var maxMilliwatts: Int { options.map(\.milliwatts).max() ?? 0 }
    var negotiated: Bool { (winning?.milliwatts ?? 0) > 0 }
    /// Apple's analog brick reading, a 5 V placeholder rather than a real offer.
    var placeholder: Bool { name == "Brick ID" }
}

struct USBLink: Equatable, Sendable {
    let usb3: Bool
    let generation: String?
    let rate: String?
    let superSpeed: Int?
    let product: String?
    let manufacturer: String?
    let role: String?
    let tunneled: Bool
    let restricted: Bool

    var bitsPerSecond: Double? {
        if usb3, let superSpeed, superSpeed > 0 { return superSpeed >= 2 ? 10e9 : 5e9 }
        guard let rate, let value = Double(rate.split(separator: " ").first ?? "") else { return nil }
        return rate.contains("Gbps") ? value * 1e9 : value * 1e6
    }
}

struct ThunderboltLink: Equatable, Sendable {
    var device: String?
    var vendor: String?
    var generation: Int?
    var routerVersion: Int?
    var laneGbps: Double?
    var lanes = 1
    var asymmetric = false
    var cableSpeed: Int?
    var tunnels: [String] = []
    var firmware: String?
    var restricted = false

    var gbps: Double? { laneGbps.map { $0 * Double(asymmetric ? 3 : lanes) } }

    var versionTitle: String {
        switch generation {
        case 1: return "Thunderbolt 2"
        case 2: return "Thunderbolt 3"
        case 3: return "USB4"
        default: break
        }
        switch routerVersion ?? 0 {
        case 0x10..<0x20: return "Thunderbolt 3"
        case 0x80...: return "Thunderbolt 5"
        case 0x20...: return "USB4"
        default: return "Thunderbolt"
        }
    }
}

struct DisplayLink: Equatable, Sendable, Identifiable {
    let name: String
    let maker: String?
    let rate: String?
    let laneGbps: Double?
    let lanes: Int?
    let maxLanes: Int?
    let tunneled: Bool
    let converter: String?
    let year: Int?
    let branch: String?

    var id: String { "\(name)\(tunneled)\(year ?? 0)\(branch ?? "")" }
    var rawGbps: Double? { laneGbps.map { $0 * Double(lanes ?? 1) } }
    /// What's left for pixels after line coding: 8b/10b up to HBR3, 128b/132b for UHBR.
    var videoGbps: Double? { rawGbps.map { $0 * ((laneGbps ?? 0) >= 10 ? 0.9697 : 0.8) } }
    var rateName: String? { rate.flatMap { $0.split(separator: "(").last.map { String($0.dropLast()) } } }
}

struct USBDeviceInfo: Equatable, Sendable, Identifiable {
    let id: UInt64
    let name: String
    let vendor: String?
    let vendorID: Int
    let productID: Int
    let bcdUSB: Int
    let linkBitsPerSecond: Double?
    let classCode: Int
    let interfaces: [Int]
    let milliamps: Int?
    let depth: Int

    var hub: Bool { classCode == 9 }
    var canDoUSB3: Bool { bcdUSB >= 0x0300 }
    var superSpeed: Bool { (linkBitsPerSecond ?? 0) >= 5e9 }

    var symbol: String {
        let lower = name.lowercased()
        if hub { return "rectangle.connected.to.line.below" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("lan") || lower.contains("ethernet") || interfaces.contains(10) && !interfaces.contains(6) { return "network" }
        if lower.contains("mouse") || lower.contains("naga") || lower.contains("mx master") || lower.contains("trackball") { return "computermouse.fill" }
        if lower.contains("keyboard") { return "keyboard.fill" }
        if lower.contains("camera") || lower.contains("webcam") || interfaces.contains(14) { return "web.camera.fill" }
        if interfaces.contains(8) || lower.contains("ssd") || lower.contains("disk") || lower.contains("drive") { return "externaldrive.fill" }
        if interfaces.contains(1) || lower.contains("audio") { return lower.contains("mic") ? "mic.fill" : "hifispeaker.fill" }
        if interfaces.contains(7) { return "printer.fill" }
        if classCode == 0x11 || interfaces.contains(0x11) { return "rectangle.on.rectangle" }
        if interfaces.contains(3) { return "slider.horizontal.3" }
        return "cable.connector"
    }
}

struct PortCounters: Equatable, Sendable {
    var plugEvents: Int?
    var connections: Int?
    var overcurrent: Int?
}

struct CablePort: Equatable, Sendable, Identifiable {
    let id: String
    let kind: String
    let number: Int
    var location: PortLocation?
    var connected = false
    var supported: [PortTransport] = []
    var active: [PortTransport] = []
    var activeCable = false
    var opticalCable = false
    var orientation: Int?
    var partner: PDIdentity?
    var cable: CableMarker?
    var power: [PowerSourceInfo] = []
    /// What an Apple charger or accessory calls itself, like "96W USB-C Power Adapter".
    var appleName: String?
    var usb: [USBLink] = []
    var thunderbolt: ThunderboltLink?
    var displays: [DisplayLink] = []
    var devices: [USBDeviceInfo] = []
    var counters = PortCounters()
    var liquid: Bool?
    var firmware: String?
    var pins: String?
    /// The fastest Thunderbolt or USB4 link this port can make.
    var maxGbps: Double?

    var magSafe: Bool { kind.lowercased().hasPrefix("magsafe") }
    var title: String { magSafe ? kind : "\(kind) port \(number)" }
    var shortTitle: String { magSafe ? "MagSafe" : "\(kind) \(number)" }
    var restricted: Bool { thunderbolt?.restricted == true || usb.contains(where: \.restricted) }
    var nativeUSB3: USBLink? { usb.first { $0.usb3 && !$0.tunneled && ($0.superSpeed ?? 1) > 0 } }
    var nativeUSB2: USBLink? { usb.first { !$0.usb3 && !$0.tunneled } }

    var contract: PowerSourceInfo? {
        let real = power.filter(\.negotiated)
        return real.first { !$0.placeholder } ?? real.first
    }

    /// The charger's own offer, not Apple's 5 V placeholder.
    var charger: PowerSourceInfo? { power.filter { !$0.placeholder && !$0.options.isEmpty }.max { $0.maxMilliwatts < $1.maxMilliwatts } }
}

/// The Mac's battery and charger, which IOKit keeps in one place rather than per port.
struct Charging: Equatable, Sendable {
    var hasBattery = false
    var external = false
    var charging = false
    var full = false
    var percent: Int?
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var adapterWatts: Int?
    var adapterName: String?
    var adapterMaker: String?
    var adapterDescription: String?
    var adapterMillivolts: Int?
    var adapterMilliamps: Int?
    var inputMilliwatts: Int?
    var inputMillivolts: Int?
    var inputMilliamps: Int?
    var batteryMilliwatts: Int?
    var cycles: Int?
    var health: Int?
    var designMilliampHours: Int?
    var fullMilliampHours: Int?
    var celsius: Double?
    var notChargingReason: Int?

    /// macOS holding the charge at its limit, as with Optimized Battery Charging.
    var limited: Bool { (notChargingReason ?? 0) & (1 << 24) != 0 }
    var onHold: Bool { external && !charging && !full && !limited && (notChargingReason ?? 0) != 0 }
}

struct CablesSnapshot: Equatable, Sendable {
    var ports: [CablePort] = []
    var charging = Charging()
}

// MARK: - Reading

/// One registry entry's properties, read a key at a time: reading them all at once can crash inside IOKit when the
/// entry goes away mid-read, which is exactly what unplugging does.
private struct Node {
    let entry: io_registry_entry_t

    subscript(key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    func int(_ key: String) -> Int? { self[key] as? Int }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func string(_ key: String) -> String? { self[key] as? String }
    func dict(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
}

enum PortReader {
    static func read() -> CablesSnapshot {
        let links = thunderboltLinks()
        var ports: [CablePort] = []
        forEachChild(of: IORegistryGetRootEntry(kIOMainPortDefault), plane: "IOPort") { entry in
            guard var port = port(entry) else { return }
            if port.supported.contains(.cio) {
                port.maxGbps = links.max[port.number]
                if let link = links.current[port.number] {
                    port.thunderbolt?.laneGbps = link.lane
                    port.thunderbolt?.lanes = link.lanes
                    port.thunderbolt?.asymmetric = link.asymmetric
                }
            }
            if port.thunderbolt?.cableSpeed == 2 { port.cable?.thunderbolt20 = true }
            if !port.connected { port.power = [] }
            ports.append(port)
        }
        attachTunneledUSB(&ports)
        ports.sort { ($0.magSafe ? 0 : 1, $0.number) < ($1.magSafe ? 0 : 1, $1.number) }
        return CablesSnapshot(ports: ports, charging: charging())
    }

    // MARK: Ports

    private static func port(_ entry: io_registry_entry_t) -> CablePort? {
        let p = Node(entry: entry)
        guard let kind = p.string("PortTypeDescription"), let number = p.int("PortNumber") else { return nil }
        var port = CablePort(id: p.string("PortDescription") ?? "\(kind)@\(number)", kind: kind, number: number)
        port.connected = p.bool("ConnectionActive") ?? false
        port.supported = transports(p["TransportsSupported"])
        port.active = transports(p["TransportsActive"])
        port.activeCable = p.bool("ActiveCable") ?? false
        port.opticalCable = p.bool("OpticalCable") ?? false
        port.orientation = p.int("PlugOrientation")
        port.counters = PortCounters(plugEvents: p.int("Plug Event Count"), connections: p.int("ConnectionCount"), overcurrent: p.int("Overcurrent Count"))
        port.liquid = p.bool("LDCM_LiquidDetected")
        port.firmware = (p["FW Version"] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() }
        port.pins = pins(p.dict("Pin Configuration"))
        if let text = search(entry, "port-location").flatMap(string) { port.location = PortLocation(text) }
        if port.location == nil, port.magSafe { port.location = PortLocation(side: .left, spot: .rear) }
        walk(entry, into: &port)
        return port
    }

    private static func walk(_ entry: io_registry_entry_t, into port: inout CablePort) {
        forEachChild(of: entry, plane: "IOPort") { child in
            let name = className(child)
            let p = Node(entry: child)
            switch name {
            case "IOPortTransportComponentCCUSBPDSOPp":
                port.cable = identity(p).map { CableMarker(identity: $0) }
            case "IOPortTransportComponentCCUSBPDSOP":
                port.partner = identity(p)
            case "IOPortFeaturePowerSource":
                port.power.append(powerSource(child, p))
            case "IOPortTransportStateUSB2", "IOPortTransportStateUSB3":
                if p.bool("Active") != false { port.usb.append(usbLink(p, usb3: name.hasSuffix("USB3"))) }
            case "IOPortTransportStateCIO":
                if p.bool("Active") == true {
                    var tb = ThunderboltLink()
                    tb.device = p.string("Device Model Name")
                    tb.vendor = p.string("Device Vendor Name")
                    tb.generation = p.int("Generation")
                    tb.cableSpeed = p.int("CableSpeed")
                    tb.tunnels = p["TunneledTransportsProvisioned"] as? [String] ?? []
                    tb.firmware = p.int("ROM Version").map { "\($0).\(p.int("EEPROM Version") ?? 0)" }
                    tb.restricted = p.bool("TRM_TransportRestricted") ?? false
                    port.thunderbolt = tb
                }
            case "IOPortTransportStateDisplayPort":
                if p.bool("Active") == true { port.displays.append(displayLink(p)) }
            case "IOPortTransportProtocolAppleUVDM":
                let name = p.string("User String") ?? p.string("Product")
                if let name, name != "0", name != "EV" { port.appleName = name }
            case _ where name.hasPrefix("IOThunderboltSwitch"):
                port.thunderbolt?.routerVersion = p.int("Thunderbolt Version")
                if port.thunderbolt?.device == nil { port.thunderbolt?.device = p.string("Device Model Name") }
                if port.thunderbolt?.vendor == nil { port.thunderbolt?.vendor = p.string("Device Vendor Name") }
                return
            case "IOUSBHostDevice":
                appendDevices(child, depth: 0, into: &port.devices)
                return
            default:
                break
            }
            walk(child, into: &port)
        }
    }

    private static func transports(_ value: Any?) -> [PortTransport] {
        (value as? [String] ?? []).compactMap(PortTransport.init)
    }

    /// Which signal the four high-speed pin pairs carry: 1–4 are USB 3, 5–8 DisplayPort lanes, 9–12 Thunderbolt.
    private static func pins(_ config: [String: Any]) -> String? {
        let uses = ["tx1", "rx1", "tx2", "rx2"].compactMap { config[$0] as? Int }.map { value -> String in
            switch value {
            case 0: "unused"
            case 1...4: "USB 3"
            case 5...8: "DisplayPort"
            case 9...12: "Thunderbolt"
            default: "other"
            }
        }
        guard !uses.isEmpty else { return nil }
        var counts: [(String, Int)] = []
        for use in uses {
            if let i = counts.firstIndex(where: { $0.0 == use }) { counts[i].1 += 1 } else { counts.append((use, 1)) }
        }
        return counts.map { "\($0.1) × \($0.0)" }.joined(separator: ", ")
    }

    private static func identity(_ p: Node) -> PDIdentity? {
        let meta = p.dict("Metadata")
        let vdos = (meta["VDOs"] as? [Data] ?? []).map(word)
        guard let vendor = p.int("Vendor ID") ?? meta["Vendor ID"] as? Int ?? vdos.first.map({ Int($0 & 0xFFFF) }) else { return nil }
        let product = p.int("Product ID") ?? meta["Product ID"] as? Int ?? (vdos.count > 2 ? Int(vdos[2] >> 16) : 0)
        return PDIdentity(vendorID: vendor, productID: product, bcdDevice: meta["bcdDevice"] as? Int ?? 0, vdos: vdos,
                          revision: p.int("Specification Revision"))
    }

    private static func word(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for (i, byte) in data.prefix(4).enumerated() { value |= UInt32(byte) << (8 * i) }
        return value
    }

    private static func powerSource(_ entry: io_registry_entry_t, _ p: Node) -> PowerSourceInfo {
        let raw = p["PowerSourceOptions"]
        let list = (raw as? NSSet)?.allObjects ?? (raw as? [Any]) ?? []
        let options = list.compactMap { ($0 as? [String: Any]).flatMap(option) }.sorted { $0.milliwatts < $1.milliwatts }
        return PowerSourceInfo(name: p.string("PowerSourceName") ?? registryName(entry), options: options,
                               winning: (p["WinningPowerSourceOption"] as? [String: Any]).flatMap(option),
                               selected: registryName(entry).contains("[*]"))
    }

    private static func option(_ d: [String: Any]) -> PowerOption? {
        guard let mv = d["Voltage (mV)"] as? Int, let ma = d["Max Current (mA)"] as? Int, mv > 0, ma > 0 else { return nil }
        return PowerOption(fixed: (d["Class"] as? String ?? "").hasSuffix("Fixed"), millivolts: mv, milliamps: ma,
                           milliwatts: d["Max Power (mW)"] as? Int ?? mv * ma / 1000)
    }

    private static func usbLink(_ p: Node, usb3: Bool) -> USBLink {
        USBLink(usb3: usb3, generation: p.string("GenerationDescription"), rate: p.string("DataRateDescription") ?? p.string("SuperSpeedSignalingDescription"),
                superSpeed: p.int("SuperSpeedSignaling"), product: p.string("Product"), manufacturer: p.string("Manufacturer"),
                role: p.string("DataRoleDescription"), tunneled: p.bool("Tunneled") ?? false, restricted: p.bool("TRM_TransportRestricted") ?? false)
    }

    private static func displayLink(_ p: Node) -> DisplayLink {
        let meta = p.dict("Metadata")
        let converter = meta["DFP Type Description"] as? String ?? p.string("DFP Type Description")
        let rate = p.string("LinkRateDescription")
        let lane = rate.flatMap { Double($0.split(separator: " ").first ?? "") }
        return DisplayLink(name: p.string("ProductName") ?? "Display", maker: EDID.maker(p.string("ManufacturerName")),
                           rate: rate, laneGbps: lane, lanes: p.int("LaneCount"),
                           maxLanes: p.int("MaxLaneCount"), tunneled: p.bool("Tunneled") ?? false,
                           converter: converter == "DP" ? nil : converter, year: meta["Year of Manufacture"] as? Int,
                           branch: p.string("BranchDeviceID"))
    }

    // MARK: USB devices

    private static func appendDevices(_ entry: io_registry_entry_t, depth: Int, into devices: inout [USBDeviceInfo]) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        guard !devices.contains(where: { $0.id == id }) else { return }
        let p = Node(entry: entry)
        var interfaces: Set<Int> = []
        forEachChild(of: entry, plane: kIOServicePlane) { child in
            if let c = Node(entry: child).int("bInterfaceClass") { interfaces.insert(c) }
        }
        let vendorID = p.int("idVendor") ?? 0
        let speeds: [Double] = [1.5e6, 12e6, 480e6, 5e9, 10e9, 20e9]
        let speed = p.int("UsbLinkSpeed").map(Double.init) ?? p.int("Device Speed").flatMap { speeds.indices.contains($0) ? speeds[$0] : nil }
        devices.append(USBDeviceInfo(
            id: id, name: p.string("kUSBProductString") ?? p.string("USB Product Name") ?? registryName(entry),
            vendor: p.string("kUSBVendorString") ?? p.string("USB Vendor Name") ?? USBVendors.name(vendorID),
            vendorID: vendorID, productID: p.int("idProduct") ?? 0, bcdUSB: p.int("bcdUSB") ?? 0, linkBitsPerSecond: speed,
            classCode: p.int("bDeviceClass") ?? 0, interfaces: interfaces.sorted(), milliamps: p.int("UsbPowerSinkAllocation"), depth: depth))
        forEachChild(of: entry, plane: "IOUSB") { child in
            if IOObjectConformsTo(child, "IOUSBHostDevice") != 0 { appendDevices(child, depth: depth + 1, into: &devices) }
        }
    }

    /// A dock's own USB controller sits behind a PCIe tunnel, under the Mac's PCIe root for that port.
    private static func attachTunneledUSB(_ ports: inout [CablePort]) {
        let tunnelPorts = ports.filter { $0.supported.contains(.cio) }.map(\.number).sorted()
        forEachChild(of: IORegistryGetRootEntry(kIOMainPortDefault), plane: "IOUSB") { controller in
            guard let root = pcieRoot(of: controller), tunnelPorts.indices.contains(root),
                  let index = ports.firstIndex(where: { $0.number == tunnelPorts[root] && $0.supported.contains(.cio) }),
                  ports[index].thunderbolt != nil else { return }
            forEachChild(of: controller, plane: "IOUSB") { device in
                if IOObjectConformsTo(device, "IOUSBHostDevice") != 0 { appendDevices(device, depth: 0, into: &ports[index].devices) }
            }
        }
    }

    private static func pcieRoot(of entry: io_registry_entry_t) -> Int? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        var throughPCI = false
        for _ in 0..<32 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOPCIDevice") != 0 { throughPCI = true }
            let name = registryName(current)
            if name.hasPrefix("apciec") { return throughPCI ? Int(name.dropFirst(6).prefix { $0.isNumber }) : nil }
        }
        return nil
    }

    // MARK: Thunderbolt links

    private struct Links {
        var current: [Int: (lane: Double, lanes: Int, asymmetric: Bool)] = [:]
        var max: [Int: Double] = [:]
    }

    private static func thunderboltLinks() -> Links {
        var links = Links()
        forEachService("IOThunderboltPort") { entry in
            let p = Node(entry: entry)
            guard let socket = p.string("Socket ID").flatMap(Int.init), p.int("Adapter Type") ?? 1 == 1 else { return }
            if let supported = p.int("Supported Link Speed") {
                let dual = (p.int("Supported Link Width") ?? 1) & 0x2 != 0
                links.max[socket] = max(links.max[socket] ?? 0, laneGbps(bestOf: supported) * (dual ? 2 : 1))
            }
            if let width = p.int("Current Link Width"), width > 0, let speed = p.int("Current Link Speed"), speed > 0 {
                links.current[socket] = (laneGbps(bestOf: speed), width & 0x2 != 0 ? 2 : 1, width & 0xC != 0)
            }
        }
        return links
    }

    /// A USB4 lane adapter's speed field: 0x8 is 10 Gb/s, 0x4 20 Gb/s and 0x2 40 Gb/s, per lane.
    private static func laneGbps(bestOf mask: Int) -> Double {
        if mask & 0x2 != 0 { return 40 }
        if mask & 0x4 != 0 { return 20 }
        if mask & 0x8 != 0 { return 10 }
        return 0
    }

    // MARK: Battery

    private static func charging() -> Charging {
        var c = Charging()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return c }
        defer { IOObjectRelease(service) }
        let p = Node(entry: service)
        c.hasBattery = p.bool("BatteryInstalled") ?? true
        c.external = p.bool("ExternalConnected") ?? false
        c.charging = p.bool("IsCharging") ?? false
        c.full = p.bool("FullyCharged") ?? false
        c.percent = p.int("CurrentCapacity")
        c.minutesToFull = p.int("AvgTimeToFull").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        c.minutesToEmpty = p.int("AvgTimeToEmpty").flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        c.cycles = p.int("CycleCount")
        let data = p.dict("BatteryData")
        c.designMilliampHours = p.int("DesignCapacity") ?? data["DesignCapacity"] as? Int
        c.fullMilliampHours = p.int("AppleRawMaxCapacity") ?? data["AppleRawMaxCapacity"] as? Int
        if let full = c.fullMilliampHours, let design = c.designMilliampHours, design > 0 { c.health = min(100, full * 100 / design) }
        if let t = p.int("Temperature") { c.celsius = Double(t) / 100 }
        if let mv = p.int("Voltage"), let ma = p.int("Amperage") ?? p.int("InstantAmperage") {
            c.batteryMilliwatts = mv * Int(Int64(truncatingIfNeeded: ma)) / 1000
        }
        if c.external {
            let adapter = p.dict("AdapterDetails")
            c.adapterWatts = adapter["Watts"] as? Int
            c.adapterName = adapter["Name"] as? String
            c.adapterMaker = adapter["Manufacturer"] as? String
            c.adapterDescription = adapter["Description"] as? String
            c.adapterMillivolts = adapter["AdapterVoltage"] as? Int
            c.adapterMilliamps = adapter["Current"] as? Int
            let telemetry = p.dict("PowerTelemetryData")
            c.inputMilliwatts = telemetry["SystemPowerIn"] as? Int
            c.inputMillivolts = telemetry["SystemVoltageIn"] as? Int
            c.inputMilliamps = telemetry["SystemCurrentIn"] as? Int
        }
        c.notChargingReason = p.dict("ChargerData")["NotChargingReason"] as? Int
        return c
    }

    // MARK: Registry helpers

    private static func forEachChild(of entry: io_registry_entry_t, plane: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            body(child)
            IOObjectRelease(child)
        }
    }

    static func forEachService(_ className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    private static func className(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buffer)
        return String(cString: buffer)
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buffer)
        return String(cString: buffer)
    }

    private static func search(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    private static func string(_ value: Any) -> String? {
        if let s = value as? String { return s }
        guard let data = value as? Data else { return nil }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
}

enum EDID {
    /// The PNP maker codes that turn up on displays most.
    static func maker(_ code: String?) -> String? {
        guard let code else { return nil }
        let names = ["GSM": "LG", "SAM": "Samsung", "DEL": "Dell", "APP": "Apple", "AUS": "ASUS", "ACR": "Acer", "BNQ": "BenQ",
                     "HWP": "HP", "HPN": "HP", "LEN": "Lenovo", "PHL": "Philips", "AOC": "AOC", "VSC": "ViewSonic", "MSI": "MSI",
                     "GBT": "Gigabyte", "SNY": "Sony", "EIZ": "EIZO", "NEC": "NEC", "SHP": "Sharp", "IVM": "iiyama", "XMI": "Xiaomi"]
        return names[code] ?? code
    }
}

// MARK: - Live state

@MainActor
final class Cables: ObservableObject {
    @Published private(set) var snapshot = CablesSnapshot()
    @Published private(set) var connectedAt: [String: Date] = [:]
    @Published var selected: String?
    /// A Cables page is on screen, so the live numbers refresh every couple of seconds.
    var watching = false {
        didSet { if watching, !oldValue { refresh() } }
    }
    var onConnect: ((CablePort) -> Void)?
    var onDisconnect: ((CablePort) -> Void)?

    private let read: @Sendable () -> CablesSnapshot
    private var notify: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var interests: [io_object_t] = []
    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private var reading = false
    private var again = false
    private var lastRead = Date.distantPast
    private var started = false

    init(read: @escaping @Sendable () -> CablesSnapshot = { PortReader.read() }) {
        self.read = read
    }

    var ports: [CablePort] { snapshot.ports }
    var charging: Charging { snapshot.charging }
    var connectedPorts: [CablePort] { ports.filter(\.connected) }

    /// The port powering the Mac. macOS draws from one charger at a time.
    var chargingPort: CablePort? {
        guard snapshot.charging.external else { return nil }
        let candidates = ports.filter { $0.connected && $0.contract != nil }
        return candidates.first { $0.power.contains(where: \.selected) } ?? candidates.first
    }

    func port(_ id: String?) -> CablePort? { ports.first { $0.id == id } }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        watchRegistry()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Notifications cover plugging in; the slow poll is a backstop, the fast one keeps live watts moving.
                // A closed window can leave the page "watching", so the fast one also needs Gremlin in front.
                if self.watching && NSApp.isActive || Date().timeIntervalSince(self.lastRead) > 30 { self.refresh() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        iterators.forEach { IOObjectRelease($0) }
        interests.forEach { IOObjectRelease($0) }
        iterators = []
        interests = []
        notify.map(IONotificationPortDestroy)
        notify = nil
        started = false
    }

    func refresh() {
        guard !reading else {
            again = true
            return
        }
        reading = true
        lastRead = Date()
        let read = read
        Task.detached(priority: .userInitiated) {
            let snapshot = read()
            await MainActor.run {
                self.reading = false
                self.apply(snapshot)
                if self.again {
                    self.again = false
                    self.refresh()
                }
            }
        }
    }

    func apply(_ new: CablesSnapshot) {
        let first = snapshot.ports.isEmpty
        let before = Set(snapshot.ports.filter(\.connected).map(\.id))
        for port in new.ports {
            if port.connected, !before.contains(port.id), !first {
                connectedAt[port.id] = Date()
                onConnect?(port)
            } else if !port.connected {
                connectedAt[port.id] = nil
                if before.contains(port.id) { onDisconnect?(port) }
            }
        }
        if new != snapshot { snapshot = new }
        let arrived = new.ports.first { connectedAt[$0.id].map { Date().timeIntervalSince($0) < 1 } ?? false }
        if let arrived {
            selected = arrived.id
        } else if selected == nil || !new.ports.contains(where: { $0.id == selected }) {
            selected = (chargingPort ?? new.ports.first { $0.connected && !$0.magSafe } ?? new.ports.first(where: \.connected) ?? new.ports.first)?.id
        }
    }

    func justConnected(_ port: CablePort, now: Date = Date()) -> Bool {
        connectedAt[port.id].map { now.timeIntervalSince($0) < 6 } ?? false
    }

    /// Coalesces the burst of registry changes one plug-in makes.
    fileprivate func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func watchRegistry() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notify = port
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let matched: IOServiceMatchingCallback = { info, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let info else { return }
            let cables = Unmanaged<Cables>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { cables.changed() }
        }
        for name in ["IOPortTransportState", "IOPortTransportComponent", "IOPortFeaturePowerSource", "IOUSBHostDevice", "IOThunderboltSwitch"] {
            for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching(name), matched, me, &iterator) == KERN_SUCCESS else { continue }
                while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
                iterators.append(iterator)
            }
        }
        // Plugging a cable in mostly changes properties on the port itself rather than adding services.
        let interest: IOServiceInterestCallback = { info, _, _, _ in
            guard let info else { return }
            let cables = Unmanaged<Cables>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { cables.changed() }
        }
        for name in ["AppleHPMInterface", "AppleTCControllerType10", "AppleTCControllerType11", "AppleSmartBattery"] {
            PortReader.forEachService(name) { service in
                var note: io_object_t = 0
                if IOServiceAddInterestNotification(port, service, kIOGeneralInterest, interest, me, &note) == KERN_SUCCESS { interests.append(note) }
            }
        }
    }
}

// MARK: - Vendors

/// USB-IF vendor IDs for makers whose cables, chargers and chips turn up most. Devices name themselves over USB,
/// but a cable's e-marker or a charger only gives this number.
enum USBVendors {
    static func name(_ id: Int) -> String? { names[id] }

    private static let names: [Int: String] = [
        0x03F0: "HP", 0x0403: "FTDI", 0x0424: "Microchip", 0x043E: "LG", 0x0451: "Texas Instruments", 0x045B: "Renesas",
        0x045E: "Microsoft", 0x046A: "Cherry", 0x046D: "Logitech", 0x047D: "Kensington", 0x047F: "Poly", 0x0483: "STMicroelectronics",
        0x0489: "Foxconn", 0x0499: "Yamaha", 0x04A9: "Canon", 0x04B0: "Nikon", 0x04B4: "Cypress", 0x04D8: "Microchip",
        0x04E8: "Samsung", 0x0502: "Acer", 0x050D: "Belkin", 0x054C: "Sony", 0x056A: "Wacom", 0x057E: "Nintendo", 0x0582: "Roland",
        0x058B: "Infineon", 0x059F: "LaCie", 0x05A7: "Bose", 0x05AC: "Apple", 0x05E3: "Genesys Logic", 0x0634: "Micron",
        0x067B: "Prolific", 0x0781: "SanDisk", 0x0951: "Kingston", 0x0A5C: "Broadcom", 0x0B05: "ASUS", 0x0B0E: "Jabra",
        0x0B95: "ASIX", 0x0BB4: "HTC", 0x0BC2: "Seagate", 0x0BDA: "Realtek", 0x0C45: "Microdia", 0x0D8C: "C-Media",
        0x0E8D: "MediaTek", 0x0FD9: "Elgato", 0x1004: "LG", 0x1038: "SteelSeries", 0x1050: "Yubico", 0x1058: "Western Digital",
        0x10C4: "Silicon Labs", 0x1235: "Focusrite", 0x12D1: "Huawei", 0x1395: "Sennheiser", 0x1397: "Behringer",
        0x14ED: "Shure", 0x152D: "JMicron", 0x1532: "Razer", 0x174C: "ASMedia", 0x17CC: "Native Instruments",
        0x17EF: "Lenovo", 0x18D1: "Google", 0x19F7: "RØDE", 0x1A40: "Terminus", 0x1A86: "WCH", 0x1B1C: "Corsair",
        0x1D5C: "Fresco Logic", 0x1FC9: "NXP", 0x2109: "VIA Labs", 0x2188: "CalDigit", 0x22B8: "Motorola", 0x239A: "Adafruit",
        0x2717: "Xiaomi", 0x28DE: "Valve", 0x291A: "Anker", 0x2A70: "OnePlus", 0x2DC8: "8BitDo", 0x2E8A: "Raspberry Pi",
        0x3297: "ZSA", 0x3434: "Keychron", 0x413C: "Dell", 0x8086: "Intel", 0xB58E: "Blue",
    ]
}

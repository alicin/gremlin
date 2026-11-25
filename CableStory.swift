import Foundation

// What a port's raw readings mean, in plain words: what's plugged in, how fast it runs, how it charges, and which
// part holds it back. The Cables page, the shelf and Home all tell it from here.

struct PortStory {
    enum Tone: Equatable { case good, info, warn }

    struct Insight: Equatable, Identifiable {
        let tone: Tone
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Fact: Equatable, Identifiable {
        let label: String
        let value: String
        var mono = false
        var id: String { label }
    }

    /// One link of the chain from the Mac to the device: the port, the cable, the far end.
    struct Link: Equatable {
        let caption: String
        let title: String
        let subtitle: String?
        let symbol: String
        let facts: [String]
        var limits: String? = nil
    }

    let port: CablePort
    let name: String
    let maker: String?
    let role: String
    let symbol: String
    /// What it's doing, a line each for data, video and power, with a symbol for each.
    let rows: [(symbol: String, text: String)]
    var lines: [String] { rows.map(\.text) }
    let chips: [String]
    let insights: [Insight]
    let chain: [Link]
    let charges: Bool
    let charging: Charging

    var connected: Bool { port.connected }

    init(port: CablePort, charging: Charging, chargingPort: String?) {
        self.port = port
        self.charging = charging
        charges = chargingPort == port.id
        let (name, maker, role, symbol) = Self.identify(port, charging: charging, charges: chargingPort == port.id)
        self.name = name
        self.maker = maker
        self.role = role
        self.symbol = symbol
        rows = Self.rows(port, charges: charges, charging: charging)
        chips = Self.chips(port, charges: charges, charging: charging)
        insights = Self.insights(port, charges: charges, charging: charging, chargingElsewhere: chargingPort != nil && chargingPort != port.id)
        chain = Self.chain(port, name: name, maker: maker, role: role, symbol: symbol, charging: charging, charges: charges)
    }

    // MARK: What's plugged in

    private static func identify(_ port: CablePort, charging: Charging, charges: Bool) -> (String, String?, String, String) {
        guard port.connected else { return ("Nothing plugged in", nil, "Empty", port.magSafe ? "powerplug.portrait" : "cable.connector") }
        if let tb = port.thunderbolt, let device = tb.device {
            let lower = device.lowercased()
            let dock = ["dock", "hub", "station"].contains { lower.contains($0) } || port.displays.contains(where: \.tunneled) || port.devices.count > 1
            return (device, tb.vendor, dock ? "Dock" : tb.versionTitle + " device", dock ? "dock.rectangle" : "bolt.horizontal.fill")
        }
        if let display = port.displays.first(where: { !$0.tunneled }) {
            return (display.name, display.maker, port.partner?.upperType == 5 ? "Display, through an adapter" : "Display", "display")
        }
        if let device = port.devices.first(where: { !$0.hub && $0.classCode != 0x11 }) {
            return (device.name, device.vendor, "USB device", device.symbol)
        }
        if let apple = port.appleName { return (apple, "Apple", port.contract != nil ? "Charger" : "Accessory", port.contract != nil ? "powerplug.fill" : "applelogo") }
        if port.contract != nil {
            if charges, let name = charging.adapterName { return (name, charging.adapterMaker, "Charger", "powerplug.fill") }
            let watts = port.charger.map { Units.watts($0.maxMilliwatts) } ?? charging.adapterWatts.map { "\($0) W" }
            return ([watts, "charger"].compactMap { $0 }.joined(separator: " "), port.partner?.vendor, "Charger", "powerplug.fill")
        }
        if let hub = port.devices.first(where: \.hub) { return (hub.name, hub.vendor, "USB hub", hub.symbol) }
        if let partner = port.partner { return ([partner.vendor, partner.partnerKind].compactMap { $0 }.joined(separator: " "), partner.vendor, partner.partnerKind, "cable.connector") }
        if port.magSafe { return ("MagSafe cable", "Apple", "Charger", "powerplug.portrait.fill") }
        return ("Something's plugged in", nil, "Connected", "cable.connector")
    }

    // MARK: Headline numbers

    static func dataRate(_ port: CablePort) -> (title: String, bitsPerSecond: Double)? {
        if let tb = port.thunderbolt, let gbps = tb.gbps { return ("\(tb.versionTitle) · \(Units.rate(gbps * 1e9))", gbps * 1e9) }
        if let usb3 = port.nativeUSB3, let bps = usb3.bitsPerSecond { return ("USB · \(Units.rate(bps))", bps) }
        if let fastest = port.devices.filter({ $0.depth == 0 }).compactMap(\.linkBitsPerSecond).max(), port.devices.contains(where: { $0.classCode != 0x11 }) {
            return ("USB · \(Units.rate(fastest))", fastest)
        }
        return nil
    }

    private static func rows(_ port: CablePort, charges: Bool, charging: Charging) -> [(symbol: String, text: String)] {
        guard port.connected else { return [("cable.connector", capabilities(port))] }
        var rows: [(symbol: String, text: String)] = []
        if let rate = dataRate(port) { rows.append(("arrow.left.arrow.right", rate.title)) }
        if let display = port.displays.first, port.thunderbolt == nil || display.tunneled {
            let link = [display.rateName, display.lanes.map { "× \($0)" }].compactMap { $0 }.joined(separator: " ")
            rows.append(("display", port.thunderbolt == nil ? "DisplayPort · \(link)" : "\(display.name) through it"))
        }
        if let power = powerLine(port, charges: charges, charging: charging) { rows.append(("bolt.fill", power)) }
        if rows.isEmpty, let partner = port.partner { rows.append(("cable.connector", partner.partnerKind)) }
        return rows
    }

    static func capabilities(_ port: CablePort) -> String {
        if port.magSafe { return "Charging" }
        var parts: [String] = []
        if port.supported.contains(.cio) { parts.append("Thunderbolt" + (port.maxGbps.map { " \(Int($0)) Gb/s" } ?? "")) }
        else if port.supported.contains(.usb3) { parts.append("USB 3") }
        if port.supported.contains(.displayPort) { parts.append("video") }
        parts.append("charging")
        return parts.joined(separator: " · ")
    }

    private static func powerLine(_ port: CablePort, charges: Bool, charging: Charging) -> String? {
        guard let contract = port.contract?.winning else { return nil }
        let max = Units.watts(contract.milliwatts)
        guard charges else { return "Charger on standby · \(max)" }
        if charging.charging { return "Charging · up to \(max)" }
        return "Powering the Mac · up to \(max)"
    }

    private static func chips(_ port: CablePort, charges: Bool, charging: Charging) -> [String] {
        guard port.connected else { return [] }
        var chips: [String] = []
        if let rate = dataRate(port) { chips.append(Units.rate(rate.bitsPerSecond)) }
        if let contract = port.contract?.winning { chips.append(Units.watts(contract.milliwatts)) }
        let displays = port.displays.count
        if displays > 0 { chips.append(displays == 1 ? "1 display" : "\(displays) displays") }
        let devices = port.devices.filter { !$0.hub && $0.classCode != 0x11 }.count
        if devices > 1 { chips.append("\(devices) devices") }
        return chips
    }

    // MARK: The chain

    private static func chain(_ port: CablePort, name: String, maker: String?, role: String, symbol: String, charging: Charging, charges: Bool) -> [Link] {
        var mac: [String] = []
        if port.supported.contains(.cio) { mac.append("Thunderbolt / USB4" + (port.maxGbps.map { " · \(Int($0)) Gb/s" } ?? "")) }
        else if port.supported.contains(.usb3) { mac.append("USB 3") }
        if port.supported.contains(.displayPort) { mac.append("DisplayPort video") }
        mac.append(port.magSafe ? "Charging only" : "Charging and power out")
        let macLink = Link(caption: "This Mac", title: port.title, subtitle: port.location?.title, symbol: "laptopcomputer", facts: mac)

        var cable: [String] = []
        var cableTitle = port.magSafe ? "MagSafe cable" : "USB-C cable"
        var cableSubtitle: String? = nil
        var limits: String? = nil
        if let marker = port.cable {
            cableTitle = marker.kind
            cableSubtitle = marker.identity.vendor.map { "E-marker by \($0)" } ?? "E-marked"
            if let speed = marker.speed {
                if let tb = port.thunderbolt, let gbps = tb.gbps, gbps * 1e9 > speed.cableBitsPerSecond {
                    cable.append("\(tb.versionTitle) · \(Int(gbps)) Gb/s")
                } else {
                    cable.append(speed.cableTitle)
                }
            }
            if !marker.poweredDevice { cable.append("Up to \(Units.watts(marker.maxMilliwatts)) · \(Units.amps(marker.milliamps))") }
            if marker.captive { cable.append("Attached to the device") } else if let length = marker.length { cable.append(length) }
            if let charger = port.charger, marker.maxMilliwatts < charger.maxMilliwatts { limits = "Limits charging" }
        } else if port.connected {
            cableSubtitle = port.magSafe ? nil : "No e-marker read"
            if !port.magSafe { cable.append("Up to 60 W · 3 A") }
            if let tb = port.thunderbolt, let gbps = tb.gbps { cable.append("Carrying \(Int(gbps)) Gb/s") }
            else if let usb3 = port.nativeUSB3?.bitsPerSecond { cable.append("Carrying \(Units.rate(usb3))") }
            else if port.displays.contains(where: { !$0.tunneled }) { cable.append("Carrying video") }
            if usb2Limited(port) != nil { limits = "Limits data" }
        } else {
            cableSubtitle = "Nothing plugged in"
        }
        if port.activeCable, !(port.cable?.active ?? false) { cable.append("Active cable") }
        let cableLink = Link(caption: "Cable", title: cableTitle, subtitle: cableSubtitle, symbol: port.magSafe ? "powerplug.portrait.fill" : "cable.connector",
                             facts: cable, limits: limits)

        var far: [String] = []
        if let tb = port.thunderbolt { far.append(tb.versionTitle) }
        if let converter = port.displays.first(where: { !$0.tunneled })?.converter {
            far.append("Through \(port.partner?.vendor.map { "a \($0)" } ?? "a") \(converter) adapter")
        } else if let partner = port.partner {
            far.append(partner.partnerKind + (partner.revisionText.map { " · \($0)" } ?? ""))
        }
        if let charger = port.charger { far.append("Offers up to \(Units.watts(charger.maxMilliwatts))") }
        let farLink = Link(caption: role, title: name, subtitle: maker, symbol: symbol, facts: Array(far.prefix(3)))
        return [macLink, cableLink, farLink]
    }

    // MARK: Insights

    private static func insights(_ port: CablePort, charges: Bool, charging: Charging, chargingElsewhere: Bool) -> [Insight] {
        guard port.connected else { return [] }
        var list: [Insight] = []

        if port.liquid == true {
            list.append(Insight(tone: .warn, symbol: "drop.triangle.fill", title: "Liquid detected in this port",
                                detail: "macOS found moisture and may hold back power until it dries. Unplug it and let the port dry."))
        }
        if (port.counters.overcurrent ?? 0) > 0 {
            list.append(Insight(tone: .warn, symbol: "bolt.trianglebadge.exclamationmark.fill", title: "This port cut power to protect itself",
                                detail: "Something on it drew too much current \(port.counters.overcurrent == 1 ? "once" : "\(port.counters.overcurrent ?? 0) times"). A damaged cable or device is the usual cause."))
        }
        if port.restricted {
            list.append(Insight(tone: .warn, symbol: "lock.fill", title: "macOS is holding data back",
                                detail: "It's waiting for you to allow this accessory. Unlock the Mac and approve it, or change Allow accessories to connect in Privacy & Security."))
        }

        list += powerInsights(port, charges: charges, charging: charging, chargingElsewhere: chargingElsewhere)
        list += dataInsights(port)
        list += displayInsights(port)

        if port.cable == nil, !port.magSafe, port.contract != nil || port.thunderbolt != nil || !port.devices.isEmpty {
            list.append(Insight(tone: .info, symbol: "questionmark.circle.fill", title: "The cable didn't identify itself",
                                detail: "A Mac usually reads a cable's chip only over Thunderbolt or when charging above 3 A. Cables without a chip carry up to 60 W."))
        }
        if let marker = port.cable, marker.epr {
            list.append(Insight(tone: .good, symbol: "bolt.fill", title: "Rated for 240 W", detail: "This cable can carry Extended Power Range charging, up to 48 V at 5 A."))
        }
        if let marker = port.cable, marker.active || port.activeCable {
            list.append(Insight(tone: .info, symbol: "cpu", title: marker.optical || port.opticalCable ? "Optical cable" : "Active cable",
                                detail: marker.retimer ? "It has a retimer chip, which rebuilds the signal so it stays fast over a longer run."
                                                       : "It has chips that boost the signal, so it stays fast over a longer run."))
        }
        return list
    }

    private static func powerInsights(_ port: CablePort, charges: Bool, charging: Charging, chargingElsewhere: Bool) -> [Insight] {
        guard let contract = port.contract?.winning else { return [] }
        if chargingElsewhere {
            return [Insight(tone: .info, symbol: "powerplug", title: "This charger is on standby",
                            detail: "macOS charges from one port at a time, and it's using another one. This charger offers \(Units.watts(port.charger?.maxMilliwatts ?? contract.milliwatts)).")]
        }
        let offered = port.charger?.maxMilliwatts ?? contract.milliwatts
        if let marker = port.cable, !marker.poweredDevice, marker.maxMilliwatts < offered {
            return [Insight(tone: .warn, symbol: "bolt.trianglebadge.exclamationmark.fill", title: "The cable limits charging to \(Units.watts(marker.maxMilliwatts))",
                            detail: "The charger can give \(Units.watts(offered)), but this cable is rated for \(Units.amps(marker.milliamps)). A 5 A cable, sold as 100 W or 240 W, would let it charge at full speed.")]
        }
        if port.cable == nil, let rated = ratedWatts(port.appleName ?? (charges ? charging.adapterName : nil)), rated >= 65,
           let charger = port.charger, charger.options.allSatisfy({ $0.milliamps <= 3000 }), rated * 1000 - charger.maxMilliwatts > 5000 {
            return [Insight(tone: .warn, symbol: "bolt.trianglebadge.exclamationmark.fill", title: "The cable may be holding charging back",
                            detail: "This \(rated) W charger only offers \(Units.watts(charger.maxMilliwatts)). Chargers do that when they can't confirm the cable is rated for 5 A.")]
        }
        let margin = max(5000, offered / 10)
        if contract.milliwatts < offered - margin {
            return [Insight(tone: .info, symbol: "info.circle.fill", title: "Charging at \(Units.watts(contract.milliwatts)) of the charger's \(Units.watts(offered))",
                            detail: "The Mac asked for less than the charger offers, which is its own choice, not the cable's.")]
        }
        if charges {
            return [Insight(tone: .good, symbol: "checkmark.seal.fill", title: "Getting the charger's full \(Units.watts(contract.milliwatts))",
                            detail: "\(Units.volts(contract.millivolts)) at \(Units.amps(contract.milliamps)), the most it offers. The cable isn't holding it back.")]
        }
        return []
    }

    /// The device that could run at USB 3 but came up at USB 2 speed on this port, if any.
    static func usb2Limited(_ port: CablePort) -> USBDeviceInfo? {
        guard port.thunderbolt == nil else { return nil }
        return port.devices.first { $0.depth == 0 && !$0.hub && $0.canDoUSB3 && ($0.linkBitsPerSecond ?? 0) <= 480e6 }
            ?? port.devices.first { $0.depth == 0 && $0.hub && $0.canDoUSB3 && ($0.linkBitsPerSecond ?? 0) <= 480e6 }
    }

    private static func dataInsights(_ port: CablePort) -> [Insight] {
        var list: [Insight] = []
        if let slow = usb2Limited(port) {
            let cableSaysUSB2 = port.cable?.speed == .usb2
            list.append(Insight(tone: .warn, symbol: "tortoise.fill", title: "\(slow.name) is running at USB 2 speed",
                                detail: cableSaysUSB2 ? "This cable only carries USB 2 data, 480 Mb/s. With a USB 3 or Thunderbolt cable it could go 10 to 20 times faster."
                                                      : "It can do USB 3 but linked at 480 Mb/s, so the cable is probably USB 2 only, as most charging cables are. A USB 3 or Thunderbolt cable would make it 10 to 20 times faster."))
        }
        for device in port.devices where port.thunderbolt != nil && device.depth > 0 && !device.hub && device.canDoUSB3 && (device.linkBitsPerSecond ?? 0) <= 480e6 {
            list.append(Insight(tone: .info, symbol: "tortoise.fill", title: "\(device.name) is running at USB 2 speed",
                                detail: "It can do USB 3. Try one of the dock's faster ports, usually the blue or SS-marked ones."))
            break
        }
        if let tb = port.thunderbolt, let gbps = tb.gbps {
            let lane = tb.laneGbps ?? 0
            if tb.lanes == 1, !tb.asymmetric {
                list.append(Insight(tone: .warn, symbol: "exclamationmark.triangle.fill", title: "Thunderbolt is running on one lane",
                                    detail: "It's linked at \(Int(gbps)) Gb/s instead of \(Int(lane * 2)). A shorter cable, or one certified for Thunderbolt, usually fixes it."))
            } else if let max = port.maxGbps, gbps < max, tb.generation == 2 || tb.versionTitle == "Thunderbolt 3" {
                list.append(Insight(tone: .info, symbol: "info.circle.fill", title: "\(tb.versionTitle) tops out at \(Int(gbps)) Gb/s",
                                    detail: "This port can do \(Int(max)) Gb/s with a newer device."))
            } else {
                list.append(Insight(tone: .good, symbol: "checkmark.seal.fill", title: "Full \(tb.versionTitle) speed",
                                    detail: "Linked at \(Int(gbps)) Gb/s over \(tb.lanes == 2 ? "both lanes" : "\(tb.lanes) lanes")" + (tb.tunnels.isEmpty ? "." : ", carrying \(ListFormatter.localizedString(byJoining: tb.tunnels.map(tunnelName))).")))
            }
            if let marker = port.cable, let speed = marker.speed, speed.cableBitsPerSecond < gbps * 1e9 {
                list.append(Insight(tone: .info, symbol: "info.circle.fill", title: "Faster than its chip says",
                                    detail: "The cable's chip lists \(speed.cableTitle), yet it carries \(Int(gbps)) Gb/s \(tb.versionTitle). Short Thunderbolt 3 cables are labeled that way."))
            }
        } else if let usb3 = port.nativeUSB3?.bitsPerSecond, let marker = port.cable?.speed, marker.cableBitsPerSecond > usb3 * 2.5, port.devices.contains(where: { $0.depth == 0 && $0.superSpeed }) {
            list.append(Insight(tone: .info, symbol: "info.circle.fill", title: "The device sets the speed",
                                detail: "It's linked at \(Units.rate(usb3)). The cable can carry \(marker.cableTitle), so a faster device would go faster."))
        }
        return list
    }

    private static func displayInsights(_ port: CablePort) -> [Insight] {
        var list: [Insight] = []
        for display in port.displays where !display.tunneled {
            if let lanes = display.lanes, let maxLanes = display.maxLanes, lanes < maxLanes {
                list.append(Insight(tone: .info, symbol: "display", title: "Video gets \(lanes) of \(maxLanes) lanes",
                                    detail: "The other lanes carry USB 3 data. A display that needs more bandwidth may run at a lower refresh rate."))
            }
            if let converter = display.converter {
                list.append(Insight(tone: .info, symbol: "display", title: "\(display.name) is on an \(converter) adapter",
                                    detail: "The adapter turns DisplayPort into \(converter). Its \(converter) version sets the top resolution and refresh rate."))
            }
        }
        return list
    }

    static func tunnelName(_ name: String) -> String {
        switch name {
        case "DisplayPort": "video"
        case "PCIe": "PCIe"
        case "USB3": "USB"
        default: name
        }
    }

    /// "96W USB-C Power Adapter" is 96.
    private static func ratedWatts(_ name: String?) -> Int? {
        guard let name, name.hasSuffix("W USB-C Power Adapter") else { return nil }
        return Int(name.prefix { $0.isNumber })
    }

    // MARK: Battery

    static func batteryLine(_ c: Charging) -> String? {
        guard c.hasBattery, let percent = c.percent else { return nil }
        if !c.external { return "On battery · \(percent)%" + (c.minutesToEmpty.map { " · \(duration($0)) left" } ?? "") }
        if c.charging { return "Charging · \(percent)%" + (c.minutesToFull.map { " · full in \(duration($0))" } ?? "") }
        if c.full || percent >= 100 { return "Battery full · running on the charger" }
        if c.limited { return "Holding at \(percent)% to protect the battery" }
        if c.onHold { return "Charging on hold · \(percent)%" }
        return "Plugged in · \(percent)%"
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - Details

extension PortStory {
    var portFacts: [Fact] {
        var facts = [Fact(label: "Port", value: port.id, mono: true)]
        if let location = port.location { facts.append(Fact(label: "Where", value: location.title)) }
        facts.append(Fact(label: "Can carry", value: port.supported.filter { $0 != .cc }.map(\.title).joined(separator: ", ")))
        if port.connected {
            facts.append(Fact(label: "Carrying now", value: port.active.map(\.title).joined(separator: ", ")))
            if let o = port.orientation, o > 0 { facts.append(Fact(label: "Plug", value: o == 1 ? "Normal side up" : "Flipped")) }
            if let pins = port.pins { facts.append(Fact(label: "High-speed pairs", value: pins)) }
        }
        if let max = port.maxGbps { facts.append(Fact(label: "Fastest link", value: "\(Int(max)) Gb/s")) }
        if let n = port.counters.plugEvents { facts.append(Fact(label: "Plug events", value: "\(n) since startup")) }
        if let n = port.counters.overcurrent { facts.append(Fact(label: "Overcurrent trips", value: "\(n)")) }
        if let liquid = port.liquid { facts.append(Fact(label: "Liquid check", value: liquid ? "Liquid detected" : "Dry")) }
        if let fw = port.firmware { facts.append(Fact(label: "Controller firmware", value: fw, mono: true)) }
        return facts
    }

    var cableFacts: [Fact] {
        guard let marker = port.cable else { return [] }
        let id = marker.identity
        var facts = [Fact(label: "Type", value: marker.kind)]
        facts.append(Fact(label: "Maker", value: "\(id.vendorText) (\(Units.hex16(id.vendorID)))"))
        if id.productID != 0 { facts.append(Fact(label: "Product ID", value: Units.hex16(id.productID), mono: true)) }
        if let speed = marker.speed { facts.append(Fact(label: "Data rating", value: speed.specName)) }
        if !marker.poweredDevice {
            facts.append(Fact(label: "Current", value: Units.amps(marker.milliamps)))
            facts.append(Fact(label: "Power", value: "Up to \(Units.watts(marker.maxMilliwatts))" + (marker.epr ? " (EPR)" : "")))
            facts.append(Fact(label: "Plug", value: marker.captive ? "Attached to the device" : "USB-C at both ends"))
            if let length = marker.length { facts.append(Fact(label: "Length", value: length + " (from its signal delay)")) }
        }
        if let xid = id.certXID { facts.append(Fact(label: "USB-IF certification", value: "XID \(xid)", mono: true)) }
        facts.append(Fact(label: "Version", value: "Hardware \(marker.hardwareVersion), firmware \(marker.firmwareVersion)"))
        facts.append(Fact(label: "VDOs", value: id.vdos.map(Units.hex).joined(separator: " "), mono: true))
        return facts
    }

    var partnerFacts: [Fact] {
        guard let id = port.partner else { return [] }
        var facts = [Fact(label: "Maker", value: "\(id.vendorText) (\(Units.hex16(id.vendorID)))"),
                     Fact(label: "Product ID", value: Units.hex16(id.productID), mono: true),
                     Fact(label: "Kind", value: id.partnerKind)]
        var roles: [String] = []
        if id.usbHost { roles.append("USB host") }
        if id.usbDevice { roles.append("USB device") }
        if id.modal { roles.append("alternate modes") }
        if !roles.isEmpty { facts.append(Fact(label: "Speaks", value: roles.joined(separator: ", "))) }
        if let revision = id.revisionText { facts.append(Fact(label: "Power Delivery", value: revision)) }
        if let speed = id.deviceSpeed { facts.append(Fact(label: "Fastest USB", value: speed.specName)) }
        if let xid = id.certXID { facts.append(Fact(label: "USB-IF certification", value: "XID \(xid)", mono: true)) }
        facts.append(Fact(label: "VDOs", value: id.vdos.map(Units.hex).joined(separator: " "), mono: true))
        return facts
    }

    var thunderboltFacts: [Fact] {
        guard let tb = port.thunderbolt else { return [] }
        var facts: [Fact] = []
        if let device = tb.device { facts.append(Fact(label: "Device", value: [tb.vendor, device].compactMap { $0 }.joined(separator: " "))) }
        facts.append(Fact(label: "Kind", value: tb.versionTitle))
        if let lane = tb.laneGbps { facts.append(Fact(label: "Link", value: "\(Int(lane)) Gb/s × \(tb.asymmetric ? "3 out, 1 in" : "\(tb.lanes) \(tb.lanes == 1 ? "lane" : "lanes")")")) }
        if !tb.tunnels.isEmpty { facts.append(Fact(label: "Tunnels", value: tb.tunnels.joined(separator: ", "))) }
        if let firmware = tb.firmware { facts.append(Fact(label: "Firmware", value: firmware, mono: true)) }
        if let version = tb.routerVersion { facts.append(Fact(label: "Router version", value: String(format: "0x%02X", version), mono: true)) }
        return facts
    }

    var usbFacts: [Fact] {
        port.usb.map { link in
            let label = link.tunneled ? "\(link.usb3 ? "USB 3" : "USB 2") (tunneled)" : link.usb3 ? "USB 3" : "USB 2"
            return Fact(label: label, value: [link.rate, link.role.map { "Mac is \($0.lowercased())" }].compactMap { $0 }.joined(separator: " · "))
        }
    }

    func displayFacts(_ display: DisplayLink) -> [Fact] {
        let maker = display.maker.flatMap { display.name.hasPrefix($0) ? nil : $0 }
        var facts = [Fact(label: "Display", value: [maker, display.name].compactMap { $0 }.joined(separator: " "))]
        if let year = display.year { facts.append(Fact(label: "Made", value: "\(year)")) }
        if let rate = display.rate { facts.append(Fact(label: "Link", value: rate + (display.lanes.map { " × \($0) lanes" } ?? ""))) }
        if let maxLanes = display.maxLanes { facts.append(Fact(label: "Lanes", value: "\(display.lanes ?? 0) of \(maxLanes)")) }
        if let video = display.videoGbps { facts.append(Fact(label: "Video bandwidth", value: String(format: "%.1f Gb/s", video))) }
        facts.append(Fact(label: "Route", value: display.tunneled ? "Through Thunderbolt" : display.converter.map { "DisplayPort to \($0) adapter" } ?? "DisplayPort alt mode"))
        if let branch = display.branch { facts.append(Fact(label: "Branch device", value: branch, mono: true)) }
        return facts
    }

    var powerFacts: [Fact] {
        var facts: [Fact] = []
        for source in port.power where !source.options.isEmpty || source.negotiated {
            let offers = source.options.map { "\(Units.volts($0.millivolts)) \(Units.amps($0.milliamps))" + ($0.fixed ? "" : " (PPS)") }
            facts.append(Fact(label: source.name, value: offers.isEmpty ? "—" : offers.joined(separator: ", ")))
            if let winning = source.winning, winning.milliwatts > 0 {
                facts.append(Fact(label: "Contract", value: "\(Units.volts(winning.millivolts)) × \(Units.amps(winning.milliamps)) = \(Units.watts(winning.milliwatts))"))
            }
        }
        guard charges else { return facts }
        let c = charging
        if let w = c.adapterWatts { facts.append(Fact(label: "Charger rating", value: "\(w) W" + (c.adapterDescription.map { " · \($0)" } ?? ""))) }
        if let name = c.adapterName { facts.append(Fact(label: "Charger", value: [c.adapterMaker, name].compactMap { $0 }.joined(separator: " "))) }
        if let mw = c.inputMilliwatts {
            let detail = [c.inputMillivolts.map(Units.volts), c.inputMilliamps.map { String(format: "%.2f A", Double($0) / 1000) }].compactMap { $0 }.joined(separator: " × ")
            facts.append(Fact(label: "Drawing now", value: Units.watts(mw) + (detail.isEmpty ? "" : " (\(detail))")))
        }
        if let battery = c.batteryMilliwatts, battery != 0 { facts.append(Fact(label: battery > 0 ? "Into the battery" : "From the battery", value: Units.watts(abs(battery)))) }
        if let percent = c.percent { facts.append(Fact(label: "Battery", value: "\(percent)%")) }
        if let health = c.health { facts.append(Fact(label: "Battery health", value: "\(health)% of new" + (c.cycles.map { " · \($0) cycles" } ?? ""))) }
        else if let cycles = c.cycles { facts.append(Fact(label: "Battery cycles", value: "\(cycles)")) }
        return facts
    }

    func deviceFacts(_ device: USBDeviceInfo) -> [Fact] {
        var facts = [Fact(label: "ID", value: "\(Units.hex16(device.vendorID)):\(Units.hex16(device.productID).dropFirst(2))", mono: true)]
        if let vendor = device.vendor { facts.append(Fact(label: "Maker", value: vendor)) }
        if let speed = device.linkBitsPerSecond { facts.append(Fact(label: "Link", value: Units.rate(speed))) }
        facts.append(Fact(label: "USB version", value: String(format: "%x.%x", device.bcdUSB >> 8, (device.bcdUSB >> 4) & 0xF)))
        if let ma = device.milliamps { facts.append(Fact(label: "Power", value: "\(ma) mA")) }
        return facts
    }

    /// The whole port as text, for pasting into a message or a bug report.
    var report: String {
        var out = ["\(port.title)" + (port.location.map { " (\($0.title))" } ?? ""), name + (maker.map { " · \($0)" } ?? "")]
        out += lines
        out += insights.map { "• \($0.title). \($0.detail)" }
        func section(_ title: String, _ facts: [Fact]) {
            guard !facts.isEmpty else { return }
            out.append("")
            out.append(title)
            out += facts.map { "  \($0.label): \($0.value)" }
        }
        section("Port", portFacts)
        section("Cable", cableFacts)
        section("Device", partnerFacts)
        section("Thunderbolt", thunderboltFacts)
        section("USB", usbFacts)
        for display in port.displays { section("Display", displayFacts(display)) }
        section("Power", powerFacts)
        let devices = port.devices.filter { !$0.hub }
        if !devices.isEmpty {
            out.append("")
            out.append("USB devices")
            out += devices.map { "  \($0.name)" + ($0.linkBitsPerSecond.map { " · \(Units.rate($0))" } ?? "") }
        }
        return out.joined(separator: "\n")
    }
}

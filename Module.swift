import SwiftUI

// Everything Gremlin does, as the window's sidebar and the shelf list it. A new utility is a new case here,
// plus its screen in the window and its card on the shelf.
enum Module: String, CaseIterable, Identifiable {
    case meetings, tools, keepAwake, displays, restart, fixes, ipad, universalControl, links, drives, settings

    enum Group: String, CaseIterable {
        case capture = "Capture"
        case mac = "This Mac"
        case devices = "Devices"
        case network = "Network"
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: "Meetings"
        case .tools: "Tools"
        case .keepAwake: "Keep Awake"
        case .displays: "Displays"
        case .restart: "Restart"
        case .fixes: "Fixes"
        case .ipad: "iPad"
        case .universalControl: "Universal Control"
        case .links: "Links"
        case .drives: "Drives"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .meetings: "waveform"
        case .tools: "wand.and.stars"
        case .keepAwake: "cup.and.saucer.fill"
        case .displays: "display.2"
        case .restart: "arrow.clockwise"
        case .fixes: "bandage.fill"
        case .ipad: "ipad.landscape"
        case .universalControl: "macbook.and.ipad"
        case .links: "link"
        case .drives: "externaldrive.fill.badge.wifi"
        case .settings: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .meetings: Palette.coral
        case .tools: Palette.sky
        case .keepAwake: Palette.amber
        case .displays: Palette.iris
        case .restart: Palette.slate
        case .fixes: Palette.mint
        case .ipad: Palette.teal
        case .universalControl: Palette.grape
        case .links: Palette.pink
        case .drives: Palette.lime
        case .settings: Palette.slate
        }
    }

    /// The module's color as text, readable on white in Light Mode.
    var ink: Color {
        switch self {
        case .meetings: Ink.coral
        case .tools: Ink.sky
        case .keepAwake: Ink.amber
        case .displays: Ink.iris
        case .fixes: Ink.mint
        case .ipad: Ink.teal
        case .universalControl: Ink.grape
        case .links: Ink.pink
        case .drives: Ink.lime
        case .restart, .settings: .secondary
        }
    }

    /// The vivid fill for the module's widgets and its page header band.
    var fill: [Color] {
        switch self {
        case .keepAwake: [Color(hex: 0xFFC233), Color(hex: 0xFF9F0A), Color(hex: 0xF27A0C)]
        case .settings: [Palette.indigoLift, Palette.indigo, Palette.indigoDeep]
        default: [tint.mixed(with: .white, 0.2), tint, tint.mixed(with: .black, 0.16)]
        }
    }

    var group: Group {
        switch self {
        case .meetings, .tools: .capture
        case .keepAwake, .displays, .restart, .fixes, .settings: .mac
        case .ipad, .universalControl: .devices
        case .links, .drives: .network
        }
    }

    var blurb: String {
        switch self {
        case .meetings: "Record calls with a transcript and summary"
        case .tools: "Grab text, pick colors, paste plain, fix focus"
        case .keepAwake: "Keep the Mac and display awake"
        case .displays: "Save display layouts and put them back"
        case .restart: "Restart a stuck part of macOS"
        case .fixes: "Watch for macOS bugs and fix them"
        case .ipad: "Use the iPad as a display"
        case .universalControl: "Reset it when a device gives up"
        case .links: "Send every link to the right browser"
        case .drives: "Mount SSH servers in Finder"
        case .settings: "Login, transcripts and shortcuts"
        }
    }

    /// Settings sits at the bottom of the sidebar rather than in a group.
    static var grouped: [(group: Group, modules: [Module])] {
        Group.allCases.map { group in (group, allCases.filter { $0.group == group && $0 != .settings }) }
    }
}

import AppKit
import SwiftUI

// The look shared by the Gremlin window and the shelf: Gremlin's holographic paw on deep indigo, a vivid color
// per module, and bento-style tiles. The link picker and the call prompts keep their own glass look in Glass.swift.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }

    func mixed(with other: NSColor, _ amount: CGFloat) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: base.blended(withFraction: amount, of: other) ?? base)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum Palette {
    static let indigo = Color(hex: 0x1E1446)
    static let indigoDeep = Color(hex: 0x140D33)
    static let indigoLift = Color(hex: 0x2E2266)
    static let holoMint = Color(hex: 0x8EF5D0)
    static let holoLemon = Color(hex: 0xF2E58A)
    static let holoPeach = Color(hex: 0xFFB08A)
    static let holoPink = Color(hex: 0xFF8FC8)
    static let holoSky = Color(hex: 0x8CC8FF)
    static let holoLilac = Color(hex: 0xC49BFF)
    static let holo = LinearGradient(colors: [holoMint, holoLemon, holoPeach, holoPink, holoLilac, holoSky],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let holoAngular = AngularGradient(colors: [holoMint, holoLemon, holoPeach, holoPink, holoLilac, holoSky, holoMint],
                                             center: .center)

    static let accent = Color(hex: 0x9B6BFF)
    static let accentTop = Color(hex: 0xB896FF)
    static let accentGradient = LinearGradient(colors: [accentTop, accent], startPoint: .top, endPoint: .bottom)

    static let coral = Color(hex: 0xFF5E57)
    static let amber = Color(hex: 0xFFB020)
    static let lime = Color(hex: 0x7ED321)
    static let mint = Color(hex: 0x22C493)
    static let teal = Color(hex: 0x16BCC8)
    static let sky = Color(hex: 0x3A9BFF)
    static let iris = Color(hex: 0x7F6BFA)
    static let grape = Color(hex: 0xB45CF0)
    static let pink = Color(hex: 0xFF5FA2)
    static let tangerine = Color(hex: 0xFF7A2F)
    static let ocean = Color(hex: 0x2563EB)
    static let emerald = Color(hex: 0x1FAA59)
    static let slate = Color(hex: 0x5E7A8C)

    static let good = Color(hex: 0x34C759)
    static let busy = Color(hex: 0x3A9BFF)
    static let warn = Color(hex: 0xFF9F0A)
    static let bad = Color(hex: 0xFF453A)

    // Solid surfaces rather than `.primary.opacity`, so vibrancy can't gray them out.
    static let window = Color.dynamic(light: NSColor(hex: 0xF7F6FC), dark: NSColor(hex: 0x15112C))
    static let card = Color.dynamic(light: NSColor(white: 1, alpha: 0.86), dark: NSColor(hex: 0x241D4A, alpha: 0.9))
    static let page = Color.dynamic(light: NSColor(white: 1, alpha: 0.95), dark: NSColor(hex: 0x1D173E, alpha: 0.97))
    static let well = Color.dynamic(light: NSColor(hex: 0xF4F2FB), dark: NSColor(hex: 0x29224F))
    static let well2 = Color.dynamic(light: NSColor(hex: 0xE9E5F6), dark: NSColor(hex: 0x352D63))
    static let stroke = Color.dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let shadow = Color.dynamic(light: NSColor(hex: 0x3A2A80, alpha: 0.10), dark: NSColor(white: 0, alpha: 0.32))
}

/// Module colors as text: darker in Light Mode so small labels stay readable on white.
enum Ink {
    static let amber = Color.dynamic(light: NSColor(hex: 0x9A5B00), dark: NSColor(hex: 0xFFC24A))
    static let coral = Color.dynamic(light: NSColor(hex: 0xD3352E), dark: NSColor(hex: 0xFF847D))
    static let mint = Color.dynamic(light: NSColor(hex: 0x0B8A63), dark: NSColor(hex: 0x5BE3B5))
    static let iris = Color.dynamic(light: NSColor(hex: 0x5844D8), dark: NSColor(hex: 0xA899FF))
    static let accent = Color.dynamic(light: NSColor(hex: 0x7243E6), dark: NSColor(hex: 0xBFA2FF))
    static let pink = Color.dynamic(light: NSColor(hex: 0xD2337A), dark: NSColor(hex: 0xFF8DBE))
    static let sky = Color.dynamic(light: NSColor(hex: 0x1D74D8), dark: NSColor(hex: 0x7DBDFF))
    static let lime = Color.dynamic(light: NSColor(hex: 0x4A8A0C), dark: NSColor(hex: 0xA2E35A))
    static let teal = Color.dynamic(light: NSColor(hex: 0x0B8792), dark: NSColor(hex: 0x5ADAE3))
    static let grape = Color.dynamic(light: NSColor(hex: 0x8A2FC4), dark: NSColor(hex: 0xD9A2FF))
    static let tangerine = Color.dynamic(light: NSColor(hex: 0xB4501A), dark: NSColor(hex: 0xFFA36E))
    static let ocean = Color.dynamic(light: NSColor(hex: 0x1D4FC4), dark: NSColor(hex: 0x8AB0FF))
    static let emerald = Color.dynamic(light: NSColor(hex: 0x14803F), dark: NSColor(hex: 0x6BE39C))
}

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var snappy: Animation { reduced ? .easeOut(duration: 0.1) : .spring(response: 0.3, dampingFraction: 0.84) }
    static var bouncy: Animation { reduced ? .easeOut(duration: 0.1) : .spring(response: 0.42, dampingFraction: 0.68) }
    static var zoom: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.5, dampingFraction: 0.84) }
}

/// View state that lives as long as the view. `@State` is a macro in this SDK, which the Command Line Tools can't expand.
@MainActor final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Surfaces

/// A module's own fill, for its widgets, cards and page header band.
struct VividSurface: View {
    let colors: [Color]
    var symbol: String? = nil
    var radius: CGFloat = 24
    var glow = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let m = max(s * 0.66, min(g.size.width * 0.15, 170))
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.26), .clear], center: .topLeading, startRadius: 0, endRadius: s * 1.1)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: m, weight: .bold))
                        .foregroundStyle(.white.opacity(0.08))
                        .rotationEffect(.degrees(-14))
                        .position(x: g.size.width - m * 0.3, y: g.size.height - m * 0.22)
                }
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                               lineWidth: radius > 0 ? 1 : 0)
        }
        .shadow(color: glow ? colors[1].opacity(0.32) : .clear, radius: 14, y: 7)
    }
}

/// A tinted card that sits between the vivid ones.
struct PaperSurface: View {
    var tint: Color = Palette.accent
    var radius: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Palette.card)
            .overlay {
                shape.fill(LinearGradient(colors: [tint.opacity(0.17), tint.opacity(0.04), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { shape.strokeBorder(Palette.stroke, lineWidth: 1) }
            .shadow(color: Palette.shadow, radius: 12, y: 6)
    }
}

/// Gremlin's own surface: indigo with a holographic bloom, like the app icon.
struct BrandSurface: View {
    var radius: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [Palette.indigoLift, Palette.indigoDeep], startPoint: .top, endPoint: .bottom)
                Circle().fill(Palette.holoAngular).frame(width: g.size.width * 0.9, height: g.size.width * 0.9)
                    .blur(radius: 34).opacity(0.38)
                    .position(x: g.size.width * 0.78, y: g.size.height * 0.2)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: Palette.indigo.opacity(0.4), radius: 14, y: 7)
    }
}

/// A quiet inset area inside a page.
struct Well<Content: View>: View {
    var title: String?
    var trailing: String?
    var padding: CGFloat
    var fill: Bool
    let content: Content

    init(_ title: String? = nil, trailing: String? = nil, padding: CGFloat = 16, fill: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.padding = padding
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    Spacer()
                    if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(.tertiary) }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
    }
}

// MARK: - Pieces

/// A rounded square in a module's color with a white symbol.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(tint.gradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                    }
                    .shadow(color: tint.opacity(0.35), radius: 3, y: 1.5)
            }
    }
}

/// The paw on an indigo tile, for Home and anywhere Gremlin itself is meant.
struct PawTile: View {
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [Palette.indigoLift, Palette.indigoDeep], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: "pawprint.fill").font(.system(size: size * 0.52, weight: .bold)).foregroundStyle(Palette.holo)
            }
            .overlay { RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            .frame(width: size, height: size)
            .shadow(color: Palette.indigo.opacity(0.35), radius: 3, y: 1.5)
    }
}

/// Gremlin's paw in its holographic colors. `sticker` adds the white die-cut edge of the app icon.
struct HoloPaw: View {
    var size: CGFloat = 28
    var sticker = false

    var body: some View {
        ZStack {
            if sticker {
                Image(systemName: "pawprint.fill").font(.system(size: size)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .scaleEffect(1.18)
            }
            Image(systemName: "pawprint.fill").font(.system(size: size)).foregroundStyle(Palette.holo)
        }
    }
}

struct AppIconView: View {
    var size: CGFloat = 42

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

struct Keycap: View {
    let text: String
    var small = false
    /// On a vivid fill the caps go translucent white instead of paper.
    var onColor = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 5 : 7, style: .continuous)
        Text(text)
            .font(.system(size: small ? 11 : 13.5, weight: .medium, design: .rounded))
            .foregroundStyle(onColor ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(minWidth: small ? 20 : 28, minHeight: small ? 20 : 28)
            .padding(.horizontal, small ? 4 : 6)
            .background {
                if onColor {
                    shape.fill(.white.opacity(0.22))
                } else {
                    shape.fill(Color.dynamic(light: .white, dark: NSColor(hex: 0x2C2558)))
                        .shadow(color: .black.opacity(0.22), radius: 0, y: small ? 1 : 1.5)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                }
            }
            .overlay { shape.strokeBorder(onColor ? .white.opacity(0.3) : .primary.opacity(0.1), lineWidth: 0.5) }
    }
}

/// A shortcut like "⌃⌥⌘R" as one compact cap, the way menus show it.
struct ShortcutCap: View {
    let keys: String
    var onColor = false

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(onColor ? AnyShapeStyle(.white.opacity(0.92)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(onColor ? .white.opacity(0.2) : Color.primary.opacity(0.07)))
    }
}

struct Chip: View {
    let text: String
    var color: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(color.mixed(with: .black, 0.1))
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// A capsule button: filled in a color, `soft` for a tinted fill, `white` for use on a vivid fill, `neutral` for a quiet one.
struct CapsuleButton: ButtonStyle {
    var tint: Color = Palette.accent
    var soft = false
    var white = false
    var neutral = false
    var big = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: big ? 14 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(neutral ? Color.primary : white ? tint : soft ? tint.mixed(with: .black, 0.08) : .white)
            .padding(.horizontal, big ? 18 : 14)
            .frame(height: big ? 36 : 30)
            .background {
                if neutral { Capsule().fill(Palette.well2) }
                else if white { Capsule().fill(.white) }
                else if soft { Capsule().fill(tint.opacity(0.16)) }
                else { Capsule().fill(LinearGradient(colors: [tint.mixed(with: .white, 0.12), tint.mixed(with: .black, 0.06)], startPoint: .top, endPoint: .bottom)) }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A switch that doesn't go gray when the window isn't key, unlike the system one.
struct ToggleSwitch: View {
    let isOn: Bool
    var tint: Color = Palette.good
    var small = false
    var label = ""
    let action: () -> Void

    var body: some View {
        let w: CGFloat = small ? 32 : 40, h: CGFloat = small ? 19 : 24
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.14)))
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            }
            .frame(width: w, height: h)
            .contentShape(Capsule())
            .animation(Motion.bouncy, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct ProgressRing: View {
    let progress: Double
    var tint: Color
    var size: CGFloat = 16
    var line: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: line)
            Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size - line, height: size - line)
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: progress)
    }
}

/// A thin capsule progress bar.
struct ProgressBar: View {
    let progress: Double
    var tint: Color
    var track: Color = Color.primary.opacity(0.1)
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint.gradient).frame(width: max(height, g.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
        .animation(Motion.snappy, value: progress)
    }
}

/// Bars that move while sound is coming in and lie flat through silence.
struct SoundBars: View {
    var live: Bool
    var color: Color = .white
    var count = 10
    var width: CGFloat = 4
    var height: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: width * 0.6) {
                ForEach(0..<count, id: \.self) { i in
                    let level = live ? 0.25 + 0.75 * abs(sin(t * (2.1 + Double(i % 4) * 0.7) + Double(i) * 1.3)) : 0.12
                    Capsule().fill(color).frame(width: width, height: max(width, height * level))
                }
            }
            .frame(height: height)
        }
    }
}

struct LiveDot: View {
    var color: Color = Palette.coral
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let phase = (sin(context.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
            ZStack {
                Circle().fill(color.opacity(0.35)).frame(width: size * (1.4 + phase), height: size * (1.4 + phase)).opacity(1 - phase * 0.6)
                Circle().fill(color).frame(width: size, height: size)
            }
            .frame(width: size * 2.4, height: size * 2.4)
        }
    }
}

extension View {
    /// A slight lift under the pointer.
    func hoverLift(_ scale: CGFloat = 1.015) -> some View { modifier(HoverLift(scale: scale)) }
}

private struct HoverLift: ViewModifier {
    let scale: CGFloat
    @StateObject private var hovering = Box(false)

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering.value ? scale : 1)
            .animation(Motion.snappy, value: hovering.value)
            .onHover { hovering.value = $0 }
    }
}

/// A person's initial in a color picked from their name, so the same person keeps their color everywhere.
struct Avatar: View {
    let name: String
    var size: CGFloat = 24

    static func color(for name: String) -> Color {
        let colors = [Palette.iris, Palette.teal, Palette.amber, Palette.pink, Palette.mint, Palette.sky, Palette.grape, Palette.coral, Palette.lime]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
    }

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(for: name).gradient))
            .overlay(Circle().strokeBorder(Palette.page, lineWidth: 1.5))
    }
}

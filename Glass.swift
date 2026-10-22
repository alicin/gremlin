import AppKit
import SwiftUI

// Every Gremlin surface takes its look from here: the menu panel, its cards and buttons, the record strip, and the
// call and warning panels. Each knob can also be changed without rebuilding, and the next panel that opens uses it:
//   defaults write com.bunniesinc.gremlin glass.tint -float 0.45
//   defaults write com.bunniesinc.gremlin glass.material frosted
//   defaults delete com.bunniesinc.gremlin glass.tint
struct GlassLook: Sendable {
    enum Material: String, Sendable {
        // Liquid Glass over a dark blur, so whatever is behind it can't be read through it.
        case frosted
        // Liquid Glass with more blur, which adapts to what's behind it.
        case regular
        // Liquid Glass you can see through. Only readable over dark, plain backgrounds.
        case clear
    }

    var material = Material.frosted
    // Laid over the glass so white text stays readable over bright windows. Raise tint when it's hard to read.
    var tintColor = "#1E1446"
    var tint = 0.24
    var radius = 30.0
    var rim = 0.42
    var textShadow = 0.35
    var subtext = 0.84
    var card = 0.10
    var control = 0.15
    var strip = 0.62

    static func current(_ defaults: UserDefaults = .standard) -> GlassLook {
        var look = GlassLook()
        if let name = defaults.string(forKey: "glass.material"), let material = Material(rawValue: name) { look.material = material }
        if let hex = defaults.string(forKey: "glass.tintColor"), Color(hex: hex) != nil { look.tintColor = hex }
        let knobs: [(String, WritableKeyPath<GlassLook, Double>)] = [
            ("tint", \.tint), ("radius", \.radius), ("rim", \.rim), ("textShadow", \.textShadow),
            ("subtext", \.subtext), ("card", \.card), ("control", \.control), ("strip", \.strip),
        ]
        for (key, path) in knobs where defaults.object(forKey: "glass." + key) != nil {
            look[keyPath: path] = defaults.double(forKey: "glass." + key)
        }
        return look
    }

    var sub: Color { .white.opacity(subtext) }
}

private struct GlassLookKey: EnvironmentKey {
    static let defaultValue = GlassLook()
}

extension EnvironmentValues {
    var glass: GlassLook {
        get { self[GlassLookKey.self] }
        set { self[GlassLookKey.self] = newValue }
    }
}

enum Tone: Equatable {
    case good, busy, warning, off, danger

    var color: Color {
        switch self {
        case .good: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .busy: Color(red: 0.04, green: 0.52, blue: 1)
        case .warning: Color(red: 1, green: 0.62, blue: 0.04)
        case .off: .white.opacity(0.55)
        case .danger: Color(red: 1, green: 0.27, blue: 0.23)
        }
    }
}

extension Color {
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

// MARK: Surfaces

enum Surface {
    case panel
    case card
    case control
    case strip
    case warning
    case danger
    case primary
    case record
    case light
}

extension View {
    // Without a radius, panels and cards take their usual corners and everything else is a capsule.
    func surface(_ kind: Surface, radius: CGFloat? = nil) -> some View {
        modifier(SurfaceStyle(kind: kind, radius: radius))
    }

    // Puts a view tree on the glass: the look for every surface in it, and light text and controls.
    func onGlass(_ look: GlassLook) -> some View {
        environment(\.glass, look).environment(\.colorScheme, .dark)
    }

    // White text with a faint shadow, so it stays readable over bright windows behind the glass.
    func legible() -> some View {
        modifier(Legible())
    }
}

private struct Legible: ViewModifier {
    @Environment(\.glass) private var look

    func body(content: Content) -> some View {
        content.foregroundStyle(.white)
            .shadow(color: Color(red: 20 / 255, green: 10 / 255, blue: 60 / 255).opacity(look.textShadow), radius: 3, y: 1)
    }
}

private struct SurfaceStyle: ViewModifier {
    @Environment(\.glass) private var look
    let kind: Surface
    let radius: CGFloat?

    private var corner: CGFloat? {
        if let radius { return radius }
        switch kind {
        case .panel: return look.radius
        case .card, .warning: return 18
        default: return nil
        }
    }

    private var shape: GlassShape {
        GlassShape(radius: corner)
    }

    func body(content: Content) -> some View {
        switch kind {
        case .panel:
            glass(content.background(Color(hex: look.tintColor)?.opacity(look.tint) ?? .clear, in: shape))
                .overlay(shape.strokeBorder(rim(look.rim), lineWidth: 1))
        case .card:
            content.background(.white.opacity(look.card), in: shape).overlay(shape.strokeBorder(rim(0.3), lineWidth: 1))
        case .control:
            content.background(.white.opacity(look.control), in: shape).overlay(shape.strokeBorder(rim(0.38), lineWidth: 1))
        case .strip:
            content.background(Color(red: 8 / 255, green: 6 / 255, blue: 20 / 255).opacity(look.strip), in: shape)
                .overlay(shape.strokeBorder(rim(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        case .warning:
            content.background(Tone.warning.color.opacity(0.22), in: shape)
                .overlay(shape.strokeBorder(Color(red: 1, green: 0.78, blue: 0.47).opacity(0.55), lineWidth: 1))
        case .danger:
            content.background(Tone.danger.color.opacity(0.4), in: shape).overlay(shape.strokeBorder(rim(0.4), lineWidth: 1))
        case .primary:
            content.background(Tone.busy.color, in: shape)
        case .record:
            content.background(Tone.danger.color, in: shape)
        case .light:
            content.background(.white, in: shape)
        }
    }

    @ViewBuilder
    private func glass(_ content: some View) -> some View {
        switch look.material {
        case .clear: content.glassEffect(.clear, in: shape)
        case .regular: content.glassEffect(.regular, in: shape)
        case .frosted: content.background(Frost(radius: corner ?? 30)).glassEffect(.clear, in: shape)
        }
    }

    // Brighter along the top edge, like light catching the rim.
    private func rim(_ opacity: Double) -> LinearGradient {
        LinearGradient(colors: [.white.opacity(min(1, opacity * 1.5)), .white.opacity(opacity * 0.5)], startPoint: .top, endPoint: .bottom)
    }
}

// A rounded rectangle, or a capsule without a radius.
private struct GlassShape: InsettableShape {
    var radius: CGFloat?
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let corner = radius.map { max(0, $0 - inset) } ?? min(rect.width, rect.height) / 2
        return RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: rect)
    }

    func inset(by amount: CGFloat) -> GlassShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

private struct Frost: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        // A layer's corner radius doesn't clip a behind-window blur, a mask image does.
        view.maskImage = .roundedMask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension NSImage {
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: Windows

// A borderless panel for glass content. It doesn't activate Gremlin, so the app in front keeps its menu bar.
final class GlassWindow: NSPanel {
    var onCancel: (() -> Void)?
    private let keyable: Bool

    // A window that can't become key never takes keystrokes from the app in front, even when AppKit picks a new key
    // window after another one closes. Its buttons still work.
    init(level: NSWindow.Level, keyable: Bool) {
        self.keyable = keyable
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        self.level = level
        // Gremlin is never the active app, and tooltips are off for inactive apps unless asked for.
        allowsToolTipsWhenApplicationIsInactive = true
        // The text on the glass is white, so the glass and the blur under it stay dark in Light Mode too.
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The system draws the shadow from the glass's outline, like it does for menus.
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
    }

    override var canBecomeKey: Bool { keyable }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Room around the glass for it to stretch when a page morphs.
    static let margin = NSEdgeInsets(top: 0, left: 8, bottom: 32, right: 8)

    // The shadow follows what's drawn, so it's redrawn once the glass has settled into a new size.
    func reshadow() {
        invalidateShadow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.invalidateShadow() }
    }
}

// MARK: Controls

struct PillStyle: ButtonStyle {
    var kind = Surface.control
    var height: CGFloat = 30
    var font: CGFloat = 12
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, style: self)
    }

    private struct Pill: View {
        let configuration: Configuration
        let style: PillStyle

        var body: some View {
            configuration.label
                .font(.system(size: style.font, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: !style.wide, vertical: false)
                .foregroundStyle(style.kind == .light ? Color(white: 0.07) : .white)
                .padding(.horizontal, style.height > 36 ? 16 : 12)
                .frame(maxWidth: style.wide ? .infinity : nil)
                .frame(height: style.height)
                .surface(style.kind)
                .contentShape(Capsule())
                .modifier(Pressable(pressed: configuration.isPressed, scale: 0.97, light: style.kind == .light))
        }
    }
}

// A round glass button for an icon, e.g. back or more.
struct RoundStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .bold))
            .frame(width: size, height: size)
            .surface(.control)
            .contentShape(Circle())
            .modifier(Pressable(pressed: configuration.isPressed, scale: 0.94))
    }
}

// For buttons that draw their own surfaces, like the tool circles and restart tiles.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .modifier(Pressable(pressed: configuration.isPressed, scale: 0.96))
    }
}

// Hover and press feedback for every button on the glass.
private struct Pressable: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    // @State is a macro in this SDK, and the Command Line Tools can't expand it.
    private let hovered = State(initialValue: false)
    let pressed: Bool
    let scale: CGFloat
    var light = false

    func body(content: Content) -> some View {
        content
            .brightness(isEnabled && hovered.wrappedValue ? (light ? -0.06 : 0.08) : 0)
            .opacity(isEnabled ? (pressed ? 0.75 : 1) : 0.45)
            .scaleEffect(pressed ? scale : 1)
            .onHover { hovered.wrappedValue = $0 }
            .animation(.snappy(duration: 0.15), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered.wrappedValue)
    }
}

struct GlassSwitch: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? Tone.good.color : .white.opacity(0.25))
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
                .animation(.snappy(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct Dot: View {
    let tone: Tone

    var body: some View {
        Circle().fill(tone.color).frame(width: 8, height: 8)
            .background(Circle().fill(tone.color.opacity(0.2)).frame(width: 14, height: 14))
    }
}

struct Spinner: View {
    var size: CGFloat = 16
    var line: CGFloat = 2

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle().stroke(.white.opacity(0.25), lineWidth: line)
                .overlay(Circle().trim(from: 0, to: 0.25).stroke(.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360)))
                .frame(width: size - line, height: size - line)
                .frame(width: size, height: size)
        }
    }
}

// A rounded square holding an icon, at the start of a card.
struct TileIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 34, height: 34)
            .surface(.control, radius: 12)
            .accessibilityHidden(true)
    }
}

// A filled circle with a white glyph, for banner states.
struct Badge: View {
    let symbol: String
    let tone: Tone

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .heavy))
            .frame(width: 28, height: 28)
            .background(tone.color, in: Circle())
    }
}

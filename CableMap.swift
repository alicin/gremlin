import SwiftUI

// The Cables page's hero: the Mac seen from above with its ports where they really are, and a cable from each port
// to a card saying what's on the end of it. Power runs along the charging cable as moving dots.
struct CableMap: View {
    let stories: [PortStory]
    let selected: String?
    let laptop: Bool
    let liveMilliwatts: Int?
    let fresh: (CablePort) -> Bool
    let select: (String) -> Void

    static let cardHeight: CGFloat = 66
    static let cardGap: CGFloat = 12
    static let pad: CGFloat = 16

    static func height(for stories: [PortStory]) -> CGFloat {
        let sides = Dictionary(grouping: stories) { MapLayout.side(of: $0.port) }
        let most = CGFloat(sides.values.map(\.count).max() ?? 1)
        return max(246, most * cardHeight + (most - 1) * cardGap + pad * 2)
    }

    var body: some View {
        GeometryReader { geo in
            let layout = MapLayout(stories: stories, size: geo.size, laptop: laptop)
            ZStack(alignment: .topLeading) {
                CableLines(layout: layout, selected: selected, liveMilliwatts: liveMilliwatts)
                MacTop(laptop: laptop)
                    .frame(width: layout.mac.width, height: layout.mac.height)
                    .position(x: layout.mac.midX, y: layout.mac.midY)
                ForEach(layout.items, id: \.story.port.id) { item in
                    Socket(port: item.story.port, selected: item.story.port.id == selected, plugged: item.story.connected,
                           vertical: item.side != .rear)
                        .position(item.socket)
                        .onTapGesture { select(item.story.port.id) }
                        .help(item.story.port.title)
                    MapCard(story: item.story, selected: item.story.port.id == selected, fresh: fresh(item.story.port))
                        .frame(width: item.card.width, height: item.card.height)
                        .position(x: item.card.midX, y: item.card.midY)
                        .onTapGesture { select(item.story.port.id) }
                        .accessibilityAction { select(item.story.port.id) }
                }
            }
            .animation(Motion.snappy, value: selected)
        }
        .frame(height: Self.height(for: stories))
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.well)
                .overlay { DotGrid().clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)) }
        }
    }
}

// MARK: - Layout

struct MapLayout {
    enum Side { case left, right, rear }

    struct Item {
        let story: PortStory
        let side: Side
        let card: CGRect
        let socket: CGPoint
        /// Where the cable leaves the card and where it meets the plug.
        let start: CGPoint
        let end: CGPoint
    }

    let mac: CGRect
    let items: [Item]

    static func side(of port: CablePort) -> Side {
        switch port.location?.side {
        case .right: .right
        case .rear: .rear
        default: .left
        }
    }

    private static func order(_ a: PortStory, _ b: PortStory) -> Bool {
        func rank(_ p: CablePort) -> Int {
            if p.magSafe { return 0 }
            switch p.location?.spot {
            case .rear, .left: return 1
            case .middle, nil: return 2
            case .front, .right: return 3
            }
        }
        return (rank(a.port), a.port.number) < (rank(b.port), b.port.number)
    }

    init(stories: [PortStory], size: CGSize, laptop: Bool) {
        let pad = CableMap.pad
        let left = stories.filter { Self.side(of: $0.port) != .right }.sorted(by: Self.order)
        let right = stories.filter { Self.side(of: $0.port) == .right }.sorted(by: Self.order)
        let both = !left.isEmpty && !right.isEmpty
        let reach: CGFloat = both ? 64 : 110
        let macWidth = min(both ? 250 : 300, size.width * (both ? 0.3 : 0.36))
        let macHeight = min(size.height - pad * 2, macWidth * (laptop ? 0.68 : 0.62))
        let sides: CGFloat = both ? 2 : 1
        let cardWidth = max(170, min(340, (size.width - macWidth - reach * sides - pad * 2) / sides))
        let x0 = max(pad, (size.width - (cardWidth * sides + reach * sides + macWidth)) / 2)
        let macX = right.isEmpty || both ? x0 + cardWidth + reach : x0
        let mac = CGRect(x: macX, y: (size.height - macHeight) / 2, width: macWidth, height: macHeight)

        var items: [Item] = []
        func place(_ list: [PortStory], side: Side) {
            guard !list.isEmpty else { return }
            let n = CGFloat(list.count)
            let h = CableMap.cardHeight
            let spare = size.height - pad * 2 - n * h
            let gap = n > 1 ? min(34, max(CableMap.cardGap, spare / (n - 1))) : 0
            let top = (size.height - (n * h + (n - 1) * gap)) / 2
            // Ports on a laptop sit in the half nearest the hinge, the top of the drawing.
            let first: CGFloat = laptop ? 0.2 : 0.3
            let step = n > 1 ? min(0.2, (laptop ? 0.42 : 0.4) / (n - 1)) : 0
            for (i, story) in list.enumerated() {
                let y = top + CGFloat(i) * (h + gap)
                let socketY = mac.minY + mac.height * (first + step * CGFloat(i))
                let onLeft = side != .right
                let card = CGRect(x: onLeft ? mac.minX - reach - cardWidth : mac.maxX + reach, y: y, width: cardWidth, height: h)
                let socket = CGPoint(x: onLeft ? mac.minX : mac.maxX, y: socketY)
                let plug = Socket.plugLength
                items.append(Item(story: story, side: side, card: card, socket: socket,
                                  start: CGPoint(x: onLeft ? card.maxX : card.minX, y: card.midY),
                                  end: CGPoint(x: onLeft ? socket.x - plug : socket.x + plug, y: socketY)))
            }
        }
        place(left, side: .left)
        place(right, side: .right)
        self.mac = mac
        self.items = items
    }
}

// MARK: - Cables

private struct CableLines: View {
    let layout: MapLayout
    let selected: String?
    let liveMilliwatts: Int?

    var body: some View {
        let flowing = layout.items.contains { $0.story.charges }
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !flowing || Motion.reduced)) { context in
            Canvas { canvas, _ in
                let t = context.date.timeIntervalSinceReferenceDate
                for item in layout.items { draw(item, in: &canvas, time: t) }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ item: MapLayout.Item, in canvas: inout GraphicsContext, time: Double) {
        let curve = Bezier(item.start, item.end)
        let path = curve.path
        let isSelected = item.story.port.id == selected
        guard item.story.connected else {
            canvas.stroke(path, with: .color(.secondary.opacity(isSelected ? 0.5 : 0.28)),
                          style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
            return
        }
        let tint = Palette.emerald
        let body = isSelected ? tint : Color.dynamic(light: NSColor(hex: 0x9AA3AE), dark: NSColor(hex: 0x5B6170))
        if isSelected {
            var glow = canvas
            glow.addFilter(.blur(radius: 6))
            glow.stroke(path, with: .color(tint.opacity(0.45)), style: StrokeStyle(lineWidth: 10, lineCap: .round))
        }
        canvas.stroke(path, with: .color(body.mixed(with: .black, 0.18)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        canvas.stroke(path, with: .color(body), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        var shine = canvas
        shine.translateBy(x: 0, y: -1.2)
        shine.stroke(path, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

        guard item.story.charges else { return }
        let watts = Double(liveMilliwatts ?? item.story.port.contract?.winning?.milliwatts ?? 0) / 1000
        let period = max(0.9, 2.6 - watts / 45)
        let count = 4
        for i in 0..<count {
            let phase = Motion.reduced ? Double(i) / Double(count) + 0.12 : (time / period + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let p = curve.point(CGFloat(phase))
            let fade = min(1, min(phase, 1 - phase) * 6)
            let dot = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
            var halo = canvas
            halo.addFilter(.blur(radius: 3))
            halo.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Palette.holoLemon.opacity(0.8 * fade)))
            canvas.fill(Path(ellipseIn: dot), with: .color(Color(hex: 0xFFF6C2).opacity(fade)))
        }
    }
}

/// A cable's curve: it leaves the card and meets the plug level, like a cable lying on a desk.
struct Bezier {
    let p0, c1, c2, p3: CGPoint

    init(_ start: CGPoint, _ end: CGPoint) {
        p0 = start
        p3 = end
        let dx = (end.x - start.x) * 0.55
        c1 = CGPoint(x: start.x + dx, y: start.y)
        c2 = CGPoint(x: end.x - dx, y: end.y)
    }

    var path: Path {
        var path = Path()
        path.move(to: p0)
        path.addCurve(to: p3, control1: c1, control2: c2)
        return path
    }

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }
}

// MARK: - The Mac

private struct MacTop: View {
    let laptop: Bool

    private static let shell = [Color.dynamic(light: NSColor(hex: 0xEEEFF3), dark: NSColor(hex: 0x434A58)),
                                Color.dynamic(light: NSColor(hex: 0xD3D6DE), dark: NSColor(hex: 0x2E333E))]
    private static let deck = Color.dynamic(light: NSColor(hex: 0xC9CDD6), dark: NSColor(hex: 0x262A33))
    private static let key = Color.dynamic(light: NSColor(hex: 0x23252B), dark: NSColor(hex: 0x14161B))

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let shape = RoundedRectangle(cornerRadius: min(w, h) * 0.08, style: .continuous)
            ZStack {
                shape.fill(LinearGradient(colors: Self.shell, startPoint: .top, endPoint: .bottom))
                    .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
                    .shadow(color: Palette.shadow, radius: 14, y: 8)
                if laptop {
                    Capsule().fill(Color.black.opacity(0.78))
                        .frame(width: w * 0.94, height: max(4, h * 0.035))
                        .position(x: w / 2, y: h * 0.035)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Self.deck)
                        .frame(width: w * 0.86, height: h * 0.45)
                        .position(x: w / 2, y: h * 0.335)
                    Keys(color: Self.key)
                        .frame(width: w * 0.82, height: h * 0.4)
                        .position(x: w / 2, y: h * 0.335)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Self.deck.opacity(0.55))
                        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
                        .frame(width: w * 0.42, height: h * 0.3)
                        .position(x: w / 2, y: h * 0.76)
                    Capsule().fill(Color.black.opacity(0.12))
                        .frame(width: w * 0.14, height: 3)
                        .position(x: w / 2, y: h - 2.5)
                } else {
                    Image(systemName: "applelogo")
                        .font(.system(size: min(w, h) * 0.24))
                        .foregroundStyle(.black.opacity(0.18))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct Keys: View {
    let color: Color

    var body: some View {
        Canvas { canvas, size in
            let rows = 5
            let gap: CGFloat = 2
            let rowHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for row in 0..<rows {
                let y = CGFloat(row) * (rowHeight + gap)
                let widths: [CGFloat] = switch row {
                case 0: Array(repeating: 1, count: 14)
                case 1: [1] + Array(repeating: 1, count: 12) + [1.4]
                case 2: [1.5] + Array(repeating: 1, count: 11) + [1.9]
                case 3: [2.1] + Array(repeating: 1, count: 10) + [2.3]
                default: [1, 1, 1, 1.3, 5.1, 1.3, 1, 1, 1]
                }
                let total = widths.reduce(0, +)
                let unit = (size.width - gap * CGFloat(widths.count - 1)) / total
                var x: CGFloat = 0
                for w in widths {
                    let rect = CGRect(x: x, y: y, width: unit * w, height: rowHeight)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 1.6), with: .color(color))
                    x += unit * w + gap
                }
            }
        }
    }
}

private struct Socket: View {
    let port: CablePort
    let selected: Bool
    let plugged: Bool
    let vertical: Bool

    static let plugLength: CGFloat = 16

    var body: some View {
        let length: CGFloat = port.magSafe ? 22 : 15
        ZStack {
            Capsule().fill(Color.black.opacity(0.82)).frame(width: 4, height: length)
            if plugged {
                let onLeft = (port.location?.side ?? .left) != .right
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(LinearGradient(colors: [selected ? Palette.emerald.mixed(with: .white, 0.15) : Color(hex: 0xA7AFBA),
                                                  selected ? Palette.emerald.mixed(with: .black, 0.2) : Color(hex: 0x7A828E)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay { RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                    .frame(width: Self.plugLength, height: length - 3)
                    .offset(x: onLeft ? -Self.plugLength / 2 - 1 : Self.plugLength / 2 + 1)
            }
            if selected, !plugged {
                Capsule().strokeBorder(Palette.emerald, lineWidth: 1.5).frame(width: 10, height: length + 6)
            }
        }
        .frame(width: 36, height: length + 12)
        .contentShape(Rectangle())
        .animation(Motion.snappy, value: plugged)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { canvas, size in
            let step: CGFloat = 16
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    canvas.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(.primary.opacity(0.07)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Cards

private struct MapCard: View {
    let story: PortStory
    let selected: Bool
    let fresh: Bool

    private var caption: String {
        let port = story.port
        return ([port.shortTitle] + (port.location.map { [$0.spot == .middle ? $0.side.rawValue : "\($0.side.rawValue) \($0.spot.rawValue)"] } ?? [])).joined(separator: " · ").uppercased()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 11) {
            if story.connected {
                IconTile(symbol: story.symbol, tint: selected ? Palette.emerald : Palette.slate, size: 36)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .frame(width: 36, height: 36)
                    .overlay { Image(systemName: story.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(selected ? AnyShapeStyle(Ink.emerald) : AnyShapeStyle(.tertiary))
                Text(story.connected ? story.name : "Empty")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(story.lines.prefix(2).joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let warning = story.insights.first(where: { $0.tone == .warn }), !fresh {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.warn)
                    .help(warning.title)
            }
            if fresh {
                Text("NEW")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(Palette.emerald.gradient))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if story.connected {
                shape.fill(Palette.card).shadow(color: Palette.shadow, radius: selected ? 10 : 5, y: selected ? 5 : 2)
            } else {
                shape.fill(Palette.card.opacity(0.5))
            }
        }
        .overlay {
            if story.connected {
                shape.strokeBorder(selected ? Palette.emerald : Palette.stroke, lineWidth: selected ? 2 : 1)
            } else {
                shape.strokeBorder(selected ? Palette.emerald : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: [4, 4]))
            }
        }
        .overlay { if fresh { FreshRing(shape: shape) } }
        .contentShape(shape)
        .hoverLift(1.02)
        .animation(Motion.bouncy, value: fresh)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A ring that ripples out from a card whose cable just went in.
private struct FreshRing: View {
    let shape: RoundedRectangle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Motion.reduced)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            shape.strokeBorder(Palette.emerald.opacity(0.6 * (1 - phase)), lineWidth: 2)
                .padding(-CGFloat(phase) * 8)
        }
        .allowsHitTesting(false)
    }
}

import SwiftUI

private extension View {
    func layoutField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .surface(.control, radius: 9)
    }
}

private extension SavedDisplay {
    var shortName: String { display.builtIn ? "Built-in" : display.name }
}

// The displays as they sit, drawn to scale, with the menu bar on the main one.
private struct LayoutDiagram: View {
    let displays: [SavedDisplay]
    var missing: Set<Int> = []
    @Environment(\.glass) private var look

    var body: some View {
        GeometryReader { geometry in
            let shown = displays.indices.filter { displays[$0].mirrors == nil }
            let bounds = shown.map { displays[$0].frame }.reduce(CGRect.null) { $0.union($1) }
            let scale = bounds.isNull ? 0 : min(geometry.size.width / bounds.width, geometry.size.height / bounds.height)
            let inset = CGPoint(x: (geometry.size.width - bounds.width * scale) / 2, y: (geometry.size.height - bounds.height * scale) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(shown, id: \.self) { index in
                    let display = displays[index]
                    let frame = CGRect(x: inset.x + (display.frame.minX - bounds.minX) * scale, y: inset.y + (display.frame.minY - bounds.minY) * scale,
                                       width: display.frame.width * scale, height: display.frame.height * scale).insetBy(dx: 1.5, dy: 1.5)
                    let mirrors = displays.indices.filter { displays[$0].mirrors == index }.map { displays[$0].shortName }
                    screen(display, mirrors: mirrors, missing: missing.contains(index))
                        .frame(width: max(frame.width, 0), height: max(frame.height, 0))
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .combine)
    }

    private func screen(_ display: SavedDisplay, mirrors: [String], missing: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return shape.fill(look.fill(missing ? 0.04 : 0.14))
            .overlay(shape.strokeBorder(look.fill(0.28), style: StrokeStyle(lineWidth: 1, dash: missing ? [3, 3] : [])))
            .overlay(alignment: .top) {
                if display.main {
                    UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                        .fill(look.fill(0.5)).frame(height: 4)
                }
            }
            .overlay {
                VStack(spacing: 1) {
                    Text(([display.shortName] + mirrors).joined(separator: " + ")).font(.system(size: 10, weight: .semibold))
                    Text(verbatim: "\(display.mode.width)×\(display.mode.height)").font(.system(size: 9)).foregroundStyle(look.sub)
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(4)
                .opacity(missing ? 0.5 : 1)
            }
    }
}

// MARK: Main page

struct DisplaysCard: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var displays: Displays
    @Environment(\.glass) private var look

    private var fitting: [DisplayLayout] { displays.config.layouts.filter(displays.fits) }

    private var summary: (tone: Tone, text: String) {
        if let layout = displays.layout(displays.applying) { return (.busy, "Applying \(layout.title)…") }
        if let layout = fitting.first(where: { displays.notes[$0.id] != nil }) { return (.warning, "\(layout.title) didn't fully apply") }
        if let current = displays.current { return (.good, "Arranged as \(current.title)") }
        if displays.config.layouts.isEmpty { return (.off, "Save how your displays are arranged") }
        return (.off, fitting.isEmpty ? "No layout for these displays" : "Not a saved layout")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.go(.displays) } label: {
                HStack(spacing: 12) {
                    TileIcon(symbol: "display.2")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Displays").font(.system(size: 13, weight: .bold))
                        HStack(spacing: 6) {
                            if displays.applying != nil { Spinner(size: 12, line: 1.5) } else { Dot(tone: summary.tone) }
                            Text(summary.text).lineLimit(1)
                        }
                        .font(.system(size: 11)).foregroundStyle(look.sub)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(look.sub)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            if !fitting.isEmpty, displays.current == nil || fitting.count > 1 {
                HStack(spacing: 6) {
                    ForEach(fitting.prefix(3)) { LayoutChip(layout: $0, displays: displays) }
                    if fitting.count > 3 {
                        Button("+\(fitting.count - 3)") { model.go(.displays) }.buttonStyle(PillStyle())
                    }
                }
            }
        }
        .padding(12)
        .surface(.card)
    }
}

private struct LayoutChip: View {
    let layout: DisplayLayout
    @ObservedObject var displays: Displays

    var body: some View {
        let current = displays.current?.id == layout.id
        Button { displays.apply(layout) } label: {
            HStack(spacing: 6) {
                if displays.applying == layout.id {
                    Spinner(size: 12, line: 1.5)
                } else {
                    Dot(tone: current ? .good : .off)
                }
                Text(layout.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 30)
            .surface(.control, radius: 15)
        }
        .buttonStyle(PressStyle())
        .disabled(displays.applying != nil || current)
        .help(current ? "Your displays are arranged this way" : "Arrange your displays this way")
    }
}

// MARK: Displays

struct DisplaysPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var displays: Displays
    @Environment(\.glass) private var look

    var body: some View {
        let now = DisplayHardware.snapshot(displays.live)
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Displays", back: { model.go(.main) }) {
                Button { edit(displays.saveCurrent()) } label: { Image(systemName: "plus") }
                    .buttonStyle(RoundStyle())
                    .accessibilityLabel("Save Current Layout")
            }
            VStack(alignment: .leading, spacing: 10) {
                LayoutDiagram(displays: now)
                Text(displays.current.map { "Arranged as \($0.title)." }
                    ?? "Save this arrangement to put it back later. Gremlin knows displays by name, and tells ones with the same name apart by serial number, so it doesn't matter which port they're on.")
                    .font(.system(size: 11)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
                if displays.current == nil {
                    Button("Save Current Layout") { edit(displays.saveCurrent()) }
                        .buttonStyle(PillStyle(kind: .primary, wide: true))
                }
            }
            .padding(12)
            .surface(.card)
            if !displays.config.layouts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Layouts")
                    ForEach(displays.config.layouts) { layout in
                        LayoutRow(layout: layout, displays: displays) { edit(layout) }
                    }
                }
            }
        }
    }

    private func edit(_ layout: DisplayLayout) {
        displays.editing = layout.id
        model.go(.displayLayout)
    }
}

private struct LayoutRow: View {
    let layout: DisplayLayout
    @ObservedObject var displays: Displays
    let edit: () -> Void
    @Environment(\.glass) private var look

    private var detail: String {
        let missing = displays.missing(layout)
        if !missing.isEmpty {
            return missing.count == layout.displays.count ? "Its displays aren't connected" : "\(ListFormatter.localizedString(byJoining: missing.map(\.display.name))) not connected"
        }
        let count = layout.displays.count == 1 ? "1 display" : "\(layout.displays.count) displays"
        return layout.automatic ? "\(count) · applies when they connect" : count
    }

    var body: some View {
        let current = displays.current?.id == layout.id
        let note = displays.notes[layout.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: edit) {
                    HStack(spacing: 10) {
                        TileIcon(symbol: layout.displays.count > 1 ? "display.2" : "display")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layout.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            HStack(spacing: 6) {
                                if current { Dot(tone: .good) }
                                Text(detail).lineLimit(1)
                            }
                            .font(.system(size: 11)).foregroundStyle(look.sub)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Edit \(layout.title)")
                if displays.applying == layout.id {
                    Spinner()
                } else if !current {
                    Button("Apply") { displays.apply(layout) }
                        .buttonStyle(PillStyle(kind: displays.fits(layout) ? .primary : .control))
                        .disabled(displays.applying != nil || displays.missing(layout).count == layout.displays.count)
                }
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(look.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .surface(note != nil ? .warning : .card)
    }
}

// MARK: Layout

struct DisplayLayoutPage: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var displays: Displays
    @Environment(\.glass) private var look

    private var index: Int? { displays.config.layouts.firstIndex { $0.id == displays.editing } }

    var body: some View {
        if let index {
            let layout = $displays.config.layouts[index]
            let value = layout.wrappedValue
            let missing = Set(DisplayHardware.match(value.displays.map(\.display), to: displays.live).keys).symmetricDifference(value.displays.indices)
            let current = displays.current?.id == value.id
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: value.title, back: { model.go(.displays) }) { EmptyView() }
                HStack(spacing: 8) {
                    Text("Name").font(.system(size: 12, weight: .semibold))
                    TextField("Desk, Couch, Presenting…", text: layout.name).layoutField()
                }
                LayoutDiagram(displays: value.displays, missing: missing)
                    .padding(12)
                    .surface(.card)
                PageGroup(title: "Displays") {
                    ForEach(value.displays.indices, id: \.self) { item in
                        let display = value.displays[item]
                        PageRow(title: display.display.name, detail: displayDetail(display, in: value)) {
                            if missing.contains(item) {
                                Text("Not connected")
                            } else if display.main {
                                Text("Menu bar")
                            }
                        }
                    }
                }
                PageGroup(title: "Options") {
                    PageRow(title: "Apply when these displays connect", detail: "And after sleep, if they've moved") {
                        GlassSwitch(label: "Apply when these displays connect", isOn: value.automatic) { displays.setAutomatic(value, !value.automatic) }
                    }
                }
                HStack(spacing: 8) {
                    if displays.applying == value.id {
                        Button("Applying…") {}.buttonStyle(PillStyle(kind: .primary, wide: true)).disabled(true)
                    } else {
                        Button(current ? "Applied" : "Apply") { displays.apply(value) }
                            .buttonStyle(PillStyle(kind: .primary, wide: true))
                            .disabled(current || displays.applying != nil || missing.count == value.displays.count)
                    }
                    Button("Use Current Layout") { displays.replace(value) }
                        .buttonStyle(PillStyle(wide: true))
                        .disabled(current)
                        .help("Save how the displays are arranged now in this layout")
                }
                Button("Remove Layout") {
                    let removed = value
                    model.go(.displays)
                    displays.editing = nil
                    displays.remove(removed)
                }
                .buttonStyle(PillStyle(kind: .danger, wide: true))
                if let note = displays.notes[value.id] {
                    Text(note).font(.system(size: 11)).foregroundStyle(look.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func displayDetail(_ display: SavedDisplay, in layout: DisplayLayout) -> String {
        guard let master = display.mirrors, layout.displays.indices.contains(master) else { return display.detail }
        return "Mirrors \(layout.displays[master].shortName) · \(display.mode.text)"
    }
}

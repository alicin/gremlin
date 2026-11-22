import AppKit
import SwiftUI

// Displays in the window: the live arrangement drawn to scale, the saved layouts beside it, and an editor that
// takes the layouts' place. The editor keeps its own selection rather than `Displays.editing`, which the menu bar
// panel's layout page uses.

struct DisplaysScreen: View {
    @EnvironmentObject private var displays: Displays
    @StateObject private var editing = Box<UUID?>(nil)
    @StateObject private var created = Box<UUID?>(nil)

    private var editor: UUID? {
        guard let id = editing.value, displays.layout(id) != nil else { return nil }
        return id
    }

    var body: some View {
        ScreenCard(module: .displays, scrolls: false) {
            Button(action: saveCurrent) { Label("Save current layout", systemImage: "plus") }
                .buttonStyle(CapsuleButton(tint: Palette.iris.mixed(with: .black, 0.12), white: true))
                .help("Save how your displays are arranged now")
        } content: {
            HStack(alignment: .top, spacing: 0) {
                NowPanel().padding(18)
                Group {
                    if let id = editor {
                        LayoutEditor(id: id, isNew: created.value == id, close: close)
                            .id(id)
                            .padding([.top, .bottom, .trailing], 18)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        ScrollView(.vertical) {
                            LayoutList(edit: open, save: saveCurrent).padding([.top, .bottom, .trailing], 18)
                        }
                        .scrollIndicators(.automatic)
                        .transition(.opacity)
                    }
                }
                .frame(width: 358)
            }
            .padding(-18)
        }
        .onAppear { displays.refresh() }
    }

    private func saveCurrent() {
        let layout = displays.saveCurrent()
        created.value = layout.id
        open(layout.id)
    }

    private func open(_ id: UUID) {
        withAnimation(Motion.snappy) { editing.value = id }
    }

    private func close() {
        withAnimation(Motion.snappy) { editing.value = nil }
    }
}

private extension SavedDisplay {
    var shortName: String { display.builtIn ? "Built-in" : display.name }

    var symbol: String {
        if display.builtIn { return "laptopcomputer" }
        if mirrors != nil { return "rectangle.on.rectangle" }
        return mode.height > mode.width ? "rectangle.portrait" : "display"
    }
}

private func missing(_ layout: DisplayLayout, _ live: [LiveDisplay]) -> Set<Int> {
    Set(layout.displays.indices).subtracting(DisplayHardware.match(layout.displays.map(\.display), to: live).keys)
}

// MARK: - Now

private struct NowPanel: View {
    @EnvironmentObject private var displays: Displays

    var body: some View {
        let now = DisplayHardware.snapshot(displays.live)
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if displays.applying != nil {
                        Spin(tint: Ink.iris, size: 15).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    } else if displays.current != nil {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.good)
                            .help("Your displays are arranged as a saved layout")
                    }
                    Text(headline(now)).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(2)
                    Spacer(minLength: 8)
                    if displays.applying == nil, displays.current == nil, !displays.config.layouts.isEmpty {
                        Chip(text: "Not a saved layout", color: Palette.slate)
                    }
                }
                Text("Drawn to scale, with the menu bar on the main display")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                ScreenMap(displays: now, gap: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 14)
                    .animation(Motion.bouncy, value: now)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.well))
            TileGrid(minWidth: 168, spacing: 10) {
                ForEach(now.indices, id: \.self) { index in
                    DisplayFacts(display: now[index], master: now[index].mirrors.flatMap { now.indices.contains($0) ? now[$0] : nil })
                }
            }
        }
    }

    private func headline(_ now: [SavedDisplay]) -> String {
        if let layout = displays.layout(displays.applying) { return "Applying \(layout.title)…" }
        if let current = displays.current { return "Arranged as \(current.title)" }
        return now.count == 1 ? "1 display connected" : "\(now.count) displays connected"
    }
}

private struct DisplayFacts: View {
    let display: SavedDisplay
    let master: SavedDisplay?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: display.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.iris)
                    .frame(width: 18)
                Text(display.shortName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            Text(display.mode.text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            if let extra {
                Text(extra).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.iris).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.well))
        .help(display.display.name)
    }

    private var extra: String? {
        var parts: [String] = []
        if display.main { parts.append("Menu bar") }
        if let master { parts.append("Mirrors \(master.shortName)") }
        if display.rotation != 0 { parts.append("Rotated \(display.rotation)°") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Map

// The displays as they sit, to scale. Mirrors are folded into the display they show.
private struct ScreenMap: View {
    let displays: [SavedDisplay]
    var missing: Set<Int> = []
    var gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let shown = displays.indices.filter { displays[$0].mirrors == nil }
            let bounds = shown.map { displays[$0].frame }.reduce(CGRect.null) { $0.union($1) }
            if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
                let scale = min(geometry.size.width / bounds.width, geometry.size.height / bounds.height)
                let inset = CGPoint(x: (geometry.size.width - bounds.width * scale) / 2, y: (geometry.size.height - bounds.height * scale) / 2)
                ZStack(alignment: .topLeading) {
                    ForEach(shown, id: \.self) { index in
                        let display = displays[index]
                        let frame = CGRect(x: inset.x + (display.frame.minX - bounds.minX) * scale, y: inset.y + (display.frame.minY - bounds.minY) * scale,
                                           width: display.frame.width * scale, height: display.frame.height * scale).insetBy(dx: gap, dy: gap)
                        ScreenTile(display: display, mirrors: displays.indices.filter { displays[$0].mirrors == index }.map { displays[$0].shortName },
                                   missing: missing.contains(index), size: frame.size)
                            .frame(width: max(frame.width, 0), height: max(frame.height, 0))
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ScreenTile: View {
    let display: SavedDisplay
    let mirrors: [String]
    let missing: Bool
    let size: CGSize

    var body: some View {
        let main = display.main && !missing
        let radius = max(3, min(size.width, size.height) * 0.06)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let bar = max(2.5, min(size.height * 0.05, 8))
        ZStack(alignment: .top) {
            if missing {
                shape.fill(Palette.iris.opacity(0.06))
            } else {
                shape.fill(LinearGradient(colors: main ? [Palette.iris.mixed(with: .white, 0.25), Palette.iris] : [Palette.iris.opacity(0.42), Palette.iris.opacity(0.26)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            if main {
                Rectangle().fill(.white.opacity(0.6)).frame(height: bar)
            }
            if display.display.builtIn {
                Capsule().fill(.black.opacity(missing ? 0.2 : 0.5))
                    .frame(width: size.width * 0.14, height: max(2, min(size.height * 0.045, 6)))
                    .padding(.top, main ? bar : 0)
            }
            label.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(missing ? Palette.iris.opacity(0.55) : .white.opacity(main ? 0.45 : 0.22),
                               style: StrokeStyle(lineWidth: 1, dash: missing ? [4, 3] : []))
        }
        .shadow(color: Palette.iris.opacity(main ? 0.35 : 0), radius: 6, y: 3)
    }

    @ViewBuilder private var label: some View {
        let big = size.width > 150 && size.height > 90
        let roomy = size.height > 46
        if size.width > 44, size.height > 22 {
            VStack(spacing: big ? 3 : 1) {
                Text(([display.shortName] + mirrors).joined(separator: " + "))
                    .font(.system(size: big ? 13.5 : 10.5, weight: .semibold, design: .rounded))
                if roomy {
                    Text(verbatim: big ? display.mode.text : "\(display.mode.width)×\(display.mode.height)")
                        .font(.system(size: big ? 11.5 : 9.5, weight: .medium))
                        .opacity(0.85)
                }
                if big, display.rotation != 0 {
                    Label("\(display.rotation)°", systemImage: "rotate.right")
                        .font(.system(size: 11, weight: .medium)).opacity(0.85)
                }
                if missing, roomy {
                    Text("Not connected").font(.system(size: big ? 11 : 9, weight: .semibold)).foregroundStyle(Ink.iris)
                } else if big, display.main {
                    Text("Menu bar")
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(.white.opacity(0.25)))
                        .padding(.top, 3)
                }
            }
            .foregroundStyle(display.main && !missing ? Color.white : Color.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .padding(6)
            .opacity(missing ? 0.6 : 1)
        }
    }
}

// MARK: - Layouts

private struct LayoutList: View {
    let edit: (UUID) -> Void
    let save: () -> Void
    @EnvironmentObject private var displays: Displays

    var body: some View {
        let layouts = displays.config.layouts
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved layouts").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                if !layouts.isEmpty {
                    Text("\(layouts.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            if layouts.isEmpty {
                EmptyLayouts(save: save)
            }
            ForEach(layouts) { layout in
                LayoutCard(layout: layout) { edit(layout.id) }
            }
            Well(padding: 14) {
                InfoRow(symbol: "tag.fill", tint: Palette.sky, title: "Known by name",
                        detail: "Two with the same name are told apart by serial number, so a hub can't mix them up.")
                InfoRow(symbol: "hand.raised.fill", tint: Palette.amber, title: "Your own changes stay",
                        detail: "Gremlin steps in only when displays come or go, so arranging them by hand isn't undone.")
            }
            .padding(.top, 4)
        }
    }
}

private struct EmptyLayouts: View {
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            IconTile(symbol: "display.2", tint: Palette.iris, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("No layouts yet").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Save how your displays are arranged now, with their resolutions and rotation, and put it back in one click.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: save) { Label("Save current layout", systemImage: "plus") }
                .buttonStyle(CapsuleButton(tint: Palette.iris))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperSurface(tint: Palette.iris, radius: 20))
    }
}

private struct LayoutCard: View {
    let layout: DisplayLayout
    let edit: () -> Void
    @EnvironmentObject private var displays: Displays

    var body: some View {
        let current = displays.current?.id == layout.id
        let gone = missing(layout, displays.live)
        let applying = displays.applying == layout.id
        let note = displays.notes[layout.id]
        VStack(alignment: .leading, spacing: 12) {
            ScreenMap(displays: layout.displays, missing: gone, gap: 2.5)
                .frame(height: 104)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.well))
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(layout.title).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(detail(gone)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                if current { Chip(text: "Now", color: Palette.good, symbol: "checkmark") }
            }
            HStack(spacing: 9) {
                ToggleSwitch(isOn: layout.automatic, tint: Palette.iris, small: true, label: "Apply when these displays connect") {
                    displays.setAutomatic(layout, !layout.automatic)
                }
                Text("Apply when these displays connect").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if applying {
                    Spin(tint: Ink.iris)
                    Text("Applying…").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Ink.iris)
                } else if !current {
                    let none = gone.count == layout.displays.count
                    Button("Apply") { displays.apply(layout) }
                        .buttonStyle(CapsuleButton(tint: Palette.iris, soft: !gone.isEmpty))
                        .disabled(displays.applying != nil || none)
                        .opacity(displays.applying != nil || none ? 0.45 : 1)
                        .help(none ? "None of its displays are connected" : gone.isEmpty ? "Arrange your displays this way" : "Apply it to the displays that are connected")
                }
                Spacer(minLength: 0)
                Button("Edit", action: edit).buttonStyle(CapsuleButton(neutral: true))
            }
            .frame(height: 30)
        }
        .padding(14)
        .background(PaperSurface(tint: note != nil ? Palette.warn : Palette.iris, radius: 20))
        .animation(Motion.snappy, value: applying)
    }

    private func detail(_ gone: Set<Int>) -> String {
        if !gone.isEmpty {
            if gone.count == layout.displays.count { return "Its displays aren't connected" }
            let names = gone.sorted().map { layout.displays[$0].shortName }
            return "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "isn't" : "aren't") connected"
        }
        return layout.displays.map(\.shortName).joined(separator: ", ")
    }
}

// MARK: - Editor

private struct LayoutEditor: View {
    let id: UUID
    let isNew: Bool
    let close: () -> Void
    @EnvironmentObject private var displays: Displays
    @FocusState private var naming: Bool

    var body: some View {
        if let layout = displays.layout(id) {
            let gone = missing(layout, displays.live)
            let current = displays.current?.id == layout.id
            EditorPanel(module: .displays, symbol: "display.2", caption: isNew ? "New layout" : "Edit layout", title: layout.title, done: close) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("", text: name, prompt: Text("Desk, Couch, Presenting…"))
                        .modifier(FieldBox(focused: naming, tint: Palette.iris))
                        .focused($naming)
                }
                ScreenMap(displays: layout.displays, missing: gone, gap: 3)
                    .frame(height: 140)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.well))
                Well("Displays", padding: 14) {
                    ForEach(layout.displays.indices, id: \.self) { index in
                        displayRow(layout, index, missing: gone.contains(index))
                    }
                }
                Well(padding: 14) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Apply when these displays connect").font(.system(size: 13, weight: .semibold))
                            Text("And after sleep, if they've moved. One layout for each set of displays can.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        ToggleSwitch(isOn: layout.automatic, tint: Palette.iris, label: "Apply when these displays connect") {
                            displays.setAutomatic(layout, !layout.automatic)
                        }
                    }
                }
                if let note = displays.notes[layout.id] {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                actions(layout, gone: gone, current: current)
            }
            .onAppear {
                if isNew { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { naming = true } }
            }
        }
    }

    private var name: Binding<String> {
        Binding(get: { displays.layout(id)?.name ?? "" },
                set: { value in
                    guard let index = displays.config.layouts.firstIndex(where: { $0.id == id }) else { return }
                    displays.config.layouts[index].name = value
                })
    }

    private func displayRow(_ layout: DisplayLayout, _ index: Int, missing: Bool) -> some View {
        let display = layout.displays[index]
        let master = display.mirrors.flatMap { layout.displays.indices.contains($0) ? layout.displays[$0] : nil }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: display.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(missing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Ink.iris))
                .frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.display.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(master.map { "Mirrors \($0.shortName) · \(display.mode.text)" } ?? display.detail)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if missing {
                Chip(text: "Not connected", color: Palette.warn)
            } else if display.main {
                Chip(text: "Menu bar", color: Palette.iris)
            }
        }
        .opacity(missing ? 0.75 : 1)
    }

    private func actions(_ layout: DisplayLayout, gone: Set<Int>, current: Bool) -> some View {
        let none = gone.count == layout.displays.count
        let busy = displays.applying != nil
        return HStack(spacing: 8) {
                Button { displays.apply(layout) } label: {
                    HStack(spacing: 6) {
                        if displays.applying == layout.id { Spin(tint: .white, size: 13) }
                        Text(displays.applying == layout.id ? "Applying…" : current ? "Applied" : "Apply")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButton(tint: Palette.iris))
                .disabled(current || busy || none)
                .opacity(current || none || (busy && displays.applying != layout.id) ? 0.45 : 1)
                Button("Use current layout") { displays.replace(layout) }
                    .buttonStyle(CapsuleButton(neutral: true))
                    .fixedSize()
                    .disabled(current)
                    .opacity(current ? 0.45 : 1)
                    .help("Save how the displays are arranged now in this layout")
                RemoveButton(title: "Remove layout") {
                    close()
                    displays.remove(layout)
                }
        }
    }
}

// MARK: - Pieces

private struct EditorPanel<Content: View, Footer: View>: View {
    let module: Module
    let symbol: String
    let caption: String
    let title: String
    let done: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption).font(.system(size: 11.5, weight: .semibold)).opacity(0.85)
                    Text(title).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Done", action: done)
                    .buttonStyle(CapsuleButton(tint: module.tint.mixed(with: .black, 0.15), white: true))
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 66)
            .background(VividSurface(colors: module.fill, symbol: symbol, radius: 0, glow: false))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(14)
            }
            .scrollIndicators(.automatic)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Rectangle().fill(Palette.stroke).frame(height: 1) }
        }
        .clipShape(shape)
        .background(PaperSurface(tint: module.tint, radius: 22))
    }
}

private struct InfoRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FieldBox: ViewModifier {
    let focused: Bool
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(Palette.page))
            .overlay(shape.strokeBorder(focused ? tint : Palette.stroke, lineWidth: focused ? 1.5 : 1))
            .animation(Motion.snappy, value: focused)
    }
}

// Removing asks for a second click, since there's no undo.
private struct RemoveButton: View {
    let title: String
    let action: () -> Void
    @StateObject private var armed = Box(false)

    var body: some View {
        Button {
            if armed.value { return action() }
            withAnimation(Motion.snappy) { armed.value = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation(Motion.snappy) { armed.value = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash").font(.system(size: 12.5, weight: .semibold))
                if armed.value { Text("Remove?").font(.system(size: 13, weight: .semibold, design: .rounded)).fixedSize() }
            }
            .foregroundStyle(armed.value ? Color.white : Ink.coral)
            .padding(.horizontal, armed.value ? 12 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(Capsule().fill(armed.value ? AnyShapeStyle(Palette.coral.gradient) : AnyShapeStyle(Palette.coral.opacity(0.14))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct Spin: View {
    var tint: Color
    var size: CGFloat = 14
    var line: CGFloat = 2

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: line)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size - line, height: size - line)
            .frame(width: size, height: size)
        }
    }
}

/// Columns at least `minWidth` wide, as many as fit and no more than there are tiles, with each row as tall as its tallest tile.
private struct TileGrid: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat = 14

    private func measure(_ width: CGFloat, _ subviews: Subviews) -> (columns: Int, width: CGFloat, heights: [CGFloat]) {
        let columns = max(1, min(subviews.count, Int((width + spacing) / (minWidth + spacing))))
        let column = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
        return (columns, column, heights)
    }

    private func width(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return minWidth * 2 + spacing }
        return width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = measure(width(proposal), subviews)
        return CGSize(width: width(proposal), height: size.heights.reduce(0, +) + spacing * CGFloat(max(0, size.heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = measure(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in size.heights.enumerated() {
            for column in 0..<size.columns {
                let index = row * size.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (size.width + spacing), y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: size.width, height: height))
            }
            y += height + spacing
        }
    }
}

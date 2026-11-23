import AppKit
import SwiftUI

// The Links screen in Gremlin's window, as tabs inside one page.

struct LinksScreen: View {
    @EnvironmentObject private var links: Links
    @StateObject private var tab = Box(LinkTab.overview)

    var body: some View {
        ScreenCard(module: .links, scrolls: false) {
            LinkHeaderActions()
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                LinkTabStrip(selection: $tab.value)
                Group {
                    switch tab.value {
                    case .overview: LinkOverview { tab.value = $0 }
                    case .rules: LinkRulesTab()
                    case .browsers: LinkBrowsersTab()
                    case .apps: LinkAppsTab()
                    case .history: LinkHistoryTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { links.refresh() }
        // Back from the macOS prompt or System Settings, the default browser may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in links.refresh() }
    }
}

// MARK: - Shared pieces

/// Gremlin can't be a destination for its own links, though an older config may still list it.
private func isSelf(_ target: LinkTarget) -> Bool { target.app == Bundle.main.bundleIdentifier }

private enum LinkTab: String, CaseIterable, Identifiable {
    case overview, rules, browsers, apps, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .rules: "Rules"
        case .browsers: "Browsers"
        case .apps: "Apps"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .rules: "arrow.triangle.branch"
        case .browsers: "safari.fill"
        case .apps: "arrow.up.forward.app.fill"
        case .history: "clock.fill"
        }
    }
}

private extension Links {
    var visibleShown: [LinkTarget] { shownTargets.filter { !isSelf($0) } }

    func appName(_ target: LinkTarget) -> String {
        target.isPrompt ? "Ask Every Time" : appURL(target.app).map(Browsers.name) ?? target.app
    }

    /// The browser's icon sits beside this, so a profile or private window can go by its own name.
    func shortTitle(_ target: LinkTarget) -> String {
        if target.isPrivate { return "Private" }
        return target.profileName ?? appName(target)
    }

    func detail(_ target: LinkTarget) -> String? {
        if target.isPrompt { return "You choose each time" }
        if target.isPrivate { return "Private window" }
        return target.profileName
    }

    /// History keeps titles rather than targets, so this finds the target a title came from to show its icon.
    func targetsByTitle() -> [String: LinkTarget] {
        var all = allTargets + shownTargets + config.rules.map(\.target) + [primary, config.alternative, .prompt]
        all += installedLinkApps.compactMap { app in app.apps.first { appURL($0) != nil }.map { LinkTarget(app: $0) } }
        var map: [String: LinkTarget] = [:]
        for target in all where map[title(of: target)] == nil { map[title(of: target)] = target }
        return map
    }

    func moveShown(_ target: LinkTarget, by offset: Int) {
        let visible = visibleShown
        guard let i = visible.firstIndex(of: target), visible.indices.contains(i + offset),
              let a = config.shown.firstIndex(of: target), let b = config.shown.firstIndex(of: visible[i + offset]) else { return }
        config.shown.swapAt(a, b)
    }

    func moveRule(_ id: UUID, by offset: Int) {
        guard let i = config.rules.firstIndex(where: { $0.id == id }), config.rules.indices.contains(i + offset) else { return }
        config.rules.swapAt(i, i + offset)
    }
}

private func shortURL(_ text: String) -> String {
    var text = text
    for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
    if text.hasPrefix("www.") { text.removeFirst(4) }
    if text.hasSuffix("/") { text.removeLast() }
    return text
}

private func ago(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    if seconds < 6 * 3600 { return "\(Int(seconds / 3600)) h ago" }
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private func menuIcon(_ image: NSImage?) -> NSImage? {
    guard let copy = image?.copy() as? NSImage else { return nil }
    copy.size = NSSize(width: 16, height: 16)
    return copy
}

private let sectionFont = Font.system(size: 12, weight: .semibold, design: .rounded)
private let monoFont = Font.system(size: 12, weight: .medium, design: .monospaced)

/// The page's quiet inset panel, like `Well`, with room for controls beside the title.
private struct LinkPane<Trailing: View, Content: View>: View {
    var title: String?
    var fill: Bool
    var padding: CGFloat
    let trailing: Trailing
    let content: Content

    init(_ title: String? = nil, fill: Bool = false, padding: CGFloat = 16, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.fill = fill
        self.padding = padding
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    trailing
                }
                .frame(minHeight: 20)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
    }
}

extension LinkPane where Trailing == EmptyView {
    init(_ title: String? = nil, fill: Bool = false, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.init(title, fill: fill, padding: padding, trailing: { EmptyView() }, content: content)
    }
}

/// Content that fits stays put so its panels can reach the bottom; taller content scrolls.
private struct LinkFitOrScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ScrollView(.vertical) { content.padding(.bottom, 2) }.scrollIndicators(.automatic)
        }
    }
}

private struct LinkField: ViewModifier {
    var height: CGFloat = 32

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(shape.fill(Palette.page))
            .overlay(shape.strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

private extension View {
    func linkField(height: CGFloat = 32) -> some View { modifier(LinkField(height: height)) }
}

private struct LinkPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A small round button for a row, like moving it or taking it out.
private struct LinkRoundButton: View {
    let symbol: String
    let help: String
    var disabled = false
    var size: CGFloat = 24
    let action: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hovering.value ? 0.13 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(LinkPressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .onHover { hovering.value = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A browser's or app's own icon, the picker's glyph for Ask Every Time, or a globe for anything since uninstalled.
private struct LinkTargetIcon: View {
    @EnvironmentObject private var links: Links
    let target: LinkTarget?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let target, target.isPrompt {
                IconTile(symbol: "hand.point.up.left.fill", tint: Palette.iris, size: size * 0.86)
            } else if let target, let icon = links.icon(of: target) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                IconTile(symbol: "globe", tint: Palette.slate, size: size * 0.86)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if target?.isPrivate == true {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(Palette.indigo))
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

/// Every place a link can go: Ask Every Time, each browser with its profiles and private window, or any other app.
private struct LinkTargetMenu<Label: View>: View {
    @EnvironmentObject private var links: Links
    var allowsPrompt = true
    let choose: (LinkTarget) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if allowsPrompt {
                Button("Ask Every Time") { choose(.prompt) }
                Divider()
            }
            ForEach(links.allTargets.filter { !isSelf($0) }) { target in
                Button { choose(target) } label: {
                    if let icon = menuIcon(links.icon(of: target)) {
                        SwiftUI.Label { Text(links.title(of: target)) } icon: { Image(nsImage: icon) }
                    } else {
                        Text(links.title(of: target))
                    }
                }
            }
            Divider()
            Menu("Other App") {
                ForEach(links.allApps(), id: \.id) { app in
                    Button(app.name) { choose(LinkTarget(app: app.id)) }
                }
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// A tinted capsule that opens a menu, for choices inside a sentence.
private struct LinkMenuCapsule: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).opacity(0.7)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Ink.pink)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Palette.pink.opacity(0.14)))
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// A field-like row that opens a menu, for a choice that deserves its own line.
private struct LinkMenuField<Icon: View>: View {
    let text: String
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.page))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Wraps its children onto as many lines as they need.
private struct LinkFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

private struct LinkCodeEditor: View {
    @Binding var text: String
    var placeholder: String
    var height: CGFloat = 84
    var grows = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .writingToolsBehavior(.disabled)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(minHeight: height, maxHeight: grows ? .infinity : height)
            .background(shape.fill(Palette.page))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(shape.strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

// MARK: - Header and tabs

private struct LinkHeaderActions: View {
    @EnvironmentObject private var links: Links
    @StateObject private var showing = Box(false)

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actions(compact: false)
            actions(compact: true)
        }
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button { links.openCopiedLink() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill").font(.system(size: 12, weight: .semibold))
                    if !compact { Text("Open copied link") }
                    ShortcutCap(keys: "⌃⌥⌘L", onColor: true)
                }
                .fixedSize()
            }
            .buttonStyle(LinkBandButton())
            .help("Opens the link on the clipboard. ⌃⌥⌘L does it from anywhere.")
            .accessibilityLabel("Open copied link")
            if links.isDefault {
                Button { showing.value.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
                        Text(compact ? "Default" : "Default browser")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8)
                    }
                    .fixedSize()
                }
                .buttonStyle(LinkBandButton())
                .popover(isPresented: $showing.value, arrowEdge: .bottom) {
                    LinkDefaultPopover { showing.value = false }.environmentObject(links)
                }
            } else {
                Button("Make default") { links.makeDefault() }
                    .buttonStyle(CapsuleButton(tint: Color(hex: 0xD2337A), white: true))
                    .fixedSize()
                    .help("Sends every link through Gremlin. macOS asks you to confirm.")
            }
        }
    }
}

/// A translucent white capsule for the colored header band.
private struct LinkBandButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.3 : 0.2)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

private struct LinkDefaultPopover: View {
    @EnvironmentObject private var links: Links
    let close: () -> Void

    var body: some View {
        let back = links.primary.isPrompt ? "Safari" : links.appName(links.primary)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "checkmark", tint: Palette.good, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gremlin is handling your links").font(.system(size: 13, weight: .semibold))
                    Text("Each one goes where you've set it to.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Button("Stop handling links") {
                close()
                links.stopBeingDefault()
            }
            .buttonStyle(CapsuleButton(tint: Palette.slate, neutral: true))
            Text("\(back) becomes the default browser again, and rules and cleanup stop. macOS asks you to confirm.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 290, alignment: .leading)
        // The header band sets white text, and a popover inherits it.
        .foregroundStyle(Color.primary)
    }
}

private struct LinkTabStrip: View {
    @Binding var selection: LinkTab
    @EnvironmentObject private var links: Links
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LinkTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.well))
        .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
    }

    private func count(_ tab: LinkTab) -> Int? {
        let n: Int
        switch tab {
        case .rules: n = links.config.rules.count
        case .browsers: n = links.visibleShown.count
        case .history: n = links.recent.count
        default: return nil
        }
        return n > 0 ? n : nil
    }

    private func tabButton(_ tab: LinkTab) -> some View {
        let on = selection == tab
        return Button {
            withAnimation(Motion.snappy) { selection = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol).font(.system(size: 11.5, weight: .semibold))
                Text(tab.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                if let n = count(tab) {
                    Text("\(n)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(on ? Color.white.opacity(0.25) : Color.primary.opacity(0.08)))
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background {
                if on {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.pink.mixed(with: .white, 0.1), Palette.pink.mixed(with: .black, 0.08)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: Palette.pink.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "tab", in: space)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Overview

private struct LinkOverview: View {
    let open: (LinkTab) -> Void
    @StateObject private var width = Box<CGFloat>(900)

    var body: some View {
        let wide = width.value >= 820
        LinkFitOrScroll {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    LinkTodayPanel()
                    LinkCleanupPanel()
                }
                .frame(width: wide ? 320 : 280)
                VStack(spacing: 14) {
                    LinkDestinationsPanel()
                    if wide {
                        HStack(alignment: .top, spacing: 14) {
                            LinkTesterPanel()
                            LinkRecentPanel(open: open)
                        }
                    } else {
                        LinkTesterPanel()
                        LinkRecentPanel(open: open)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width.value = $0 }
    }
}

private struct LinkTodayPanel: View {
    @EnvironmentObject private var links: Links
    private static let colors = [Palette.pink, Palette.sky, Palette.amber, Palette.teal, Palette.iris]

    var body: some View {
        let events = links.recent
        let today = events.filter { Calendar.current.isDateInToday($0.date) }
        // Without kept history Gremlin only remembers the last 50, so a full list means there may have been more.
        let capped = !links.config.keepHistory && events.count >= 50 && today.count == events.count
        let cleaned = today.filter { $0.received != $0.opened && $0.opened.hasPrefix("http") }.count
        let groups = Dictionary(grouping: today, by: \.target).map { (title: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
        let shown = Array(groups.prefix(4))
        let rest = groups.dropFirst(4).reduce(0) { $0 + $1.count }

        VStack(alignment: .leading, spacing: 12) {
            Text("Today").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(today.count)\(capped ? "+" : "")")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [Palette.pink.mixed(with: .white, 0.08), Palette.grape], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 1) {
                    Text(today.count == 1 ? "link opened" : "links opened").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(subtitle(today: today.count, cleaned: cleaned)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    if today.isEmpty {
                        Capsule().fill(Color.primary.opacity(0.08))
                    } else {
                        let total = Double(today.count)
                        let gaps = CGFloat(shown.count + (rest > 0 ? 1 : 0) - 1) * 3
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, group in
                            Capsule().fill(Self.colors[i].gradient).frame(width: max(6, (geo.size.width - gaps) * Double(group.count) / total))
                        }
                        if rest > 0 {
                            Capsule().fill(Palette.slate.gradient).frame(width: max(6, (geo.size.width - gaps) * Double(rest) / total))
                        }
                    }
                }
            }
            .frame(height: 10)
            if today.isEmpty {
                Text(links.isDefault ? "Click a link in any app and it shows up here, with where it went." : "Links come through here once Gremlin is your default browser.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, group in
                        row(group.title, group.count, Self.colors[i])
                    }
                    if rest > 0 { row("Everywhere else", rest, Palette.slate) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperSurface(tint: Palette.pink, radius: 18))
        .animation(Motion.snappy, value: today.count)
    }

    private func subtitle(today: Int, cleaned: Int) -> String {
        if today == 0 { return "None yet" }
        if cleaned == 0 { return "None needed cleaning" }
        return "\(cleaned) cleaned up on the way"
    }

    private func row(_ title: String, _ count: Int, _ color: Color) -> some View {
        let parts = title.components(separatedBy: " · ")
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(parts[0]).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if parts.count > 1 {
                Text(parts.dropFirst().joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(count)").font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
        }
    }
}

private struct LinkCleanupPanel: View {
    @EnvironmentObject private var links: Links

    var body: some View {
        LinkPane("Clean up every link", fill: true) {
            VStack(alignment: .leading, spacing: 14) {
                row("arrow.uturn.backward", Palette.pink, "Unwrap redirect links", "Google, Outlook, Slack and more", \.unwrapRedirects)
                row("arrow.up.left.and.arrow.down.right", Palette.iris, "Expand short links", "bit.ly, t.co and about 40 others", \.expandShort)
                if links.config.expandShort {
                    LinkShortHosts().padding(.leading, 42).transition(.opacity)
                }
                row("eye.slash.fill", Palette.teal, "Remove tracking", "utm_*, fbclid and 160 more", \.removeTracking)
            }
            .animation(Motion.snappy, value: links.config.expandShort)
        }
    }

    private func row(_ symbol: String, _ tint: Color, _ title: String, _ detail: String, _ key: WritableKeyPath<LinkConfig, Bool>) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ToggleSwitch(isOn: links.config[keyPath: key], tint: Palette.pink, small: true, label: title) {
                links.config[keyPath: key].toggle()
            }
        }
    }
}

/// Short link sites Gremlin doesn't know about, like a company's own.
private struct LinkShortHosts: View {
    @EnvironmentObject private var links: Links
    @StateObject private var draft = Box("")

    var body: some View {
        LinkFlow(spacing: 6) {
            ForEach(links.config.shortHosts, id: \.self) { host in
                HStack(spacing: 4) {
                    Text(host).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    Button { links.config.shortHosts.removeAll { $0 == host } } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(host)")
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(height: 24)
                .background(Capsule().fill(Palette.page))
                .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
            }
            TextField(links.config.shortHosts.isEmpty ? "Add your own, like go.example.com" : "Add another", text: $draft.value)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .frame(width: links.config.shortHosts.isEmpty ? 210 : 110, height: 24)
                .background(Capsule().strokeBorder(Palette.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .onSubmit(add)
        }
    }

    private func add() {
        var host = draft.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.split(separator: "/").first ?? "")
        draft.value = ""
        guard host.contains("."), !links.config.shortHosts.contains(host) else { return }
        links.config.shortHosts.append(host)
    }
}

private struct LinkDestinationsPanel: View {
    @EnvironmentObject private var links: Links
    @StateObject private var width = Box<CGFloat>(540)

    private var targets: [LinkTarget] {
        var targets = links.visibleShown
        if !links.primary.isPrompt, !targets.contains(links.primary) { targets.append(links.primary) }
        return targets + [.prompt]
    }

    var body: some View {
        let counts = Dictionary(grouping: links.recent.filter { Calendar.current.isDateInToday($0.date) }, by: \.target).mapValues(\.count)
        LinkPane("Links open in") {
            LinkTargetMenu(allowsPrompt: false, choose: { links.config.primary = $0 }) {
                HStack(spacing: 4) {
                    Text("Something else")
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .fixedSize()
        } content: {
            if !links.isDefault {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.warn)
                    Text("Gremlin isn't your default browser yet, so none of this applies until it is.")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.warn.opacity(0.13)))
            }
            // As many equal columns as there are tiles, so a short list never leaves an empty slot or a lone tile below.
            let perRow = max(1, Int((width.value + 10) / 86))
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: min(targets.count, perRow))
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(targets) { target in
                    LinkTargetTile(target: target, selected: target == links.primary, count: counts[links.title(of: target)] ?? 0) {
                        withAnimation(Motion.bouncy) { links.config.primary = target }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width.value = $0 }
            LinkHoldSentence()
        }
    }
}

private struct LinkTargetTile: View {
    @EnvironmentObject private var links: Links
    let target: LinkTarget
    let selected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(spacing: 3) {
                LinkTargetIcon(target: target, size: 34)
                    .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 3, y: 1)
                    .padding(.bottom, 4)
                Text(links.appName(target))
                    .font(.system(size: 12.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
                Text(caption)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .opacity(selected ? 0.9 : 1)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 112)
            .background {
                if selected {
                    VividSurface(colors: Module.links.fill, symbol: "checkmark", radius: 16)
                } else {
                    shape.fill(Palette.page).overlay(shape.strokeBorder(Palette.stroke, lineWidth: 1))
                }
            }
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.pink))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Palette.pink.opacity(0.16)))
                        .padding(7)
                        .help("\(count) today")
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(LinkPressStyle())
        .hoverLift(1.03)
        .help(selected ? "Links open here unless a rule says otherwise" : "Open links in \(links.title(of: target))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var caption: String {
        if target.isPrompt { return selected ? "The default" : "The picker" }
        return links.detail(target) ?? (selected ? "The default" : " ")
    }
}

/// The key that sends a link somewhere else for once, as one sentence with its two choices in it.
private struct LinkHoldSentence: View {
    @EnvironmentObject private var links: Links

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { lead; menus; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 6) { lead; HStack(spacing: 6) { menus } }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
    }

    private var lead: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 12, weight: .medium))
            Text("Holding")
            Menu {
                ForEach(LinkConfig.Modifier.allCases, id: \.self) { modifier in
                    Button(modifier.title) { links.config.modifier = modifier }
                }
            } label: {
                LinkMenuCapsule(text: links.config.modifier.title)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Some keyboards don't send Fn")
        }
        .fixedSize()
    }

    private var menus: some View {
        HStack(spacing: 6) {
            Text("while you click opens it in")
            LinkTargetMenu(choose: { links.config.alternative = $0 }) {
                LinkMenuCapsule(text: links.title(of: links.config.alternative))
            }
            .fixedSize()
        }
        .fixedSize()
    }
}

private enum LinkTestState {
    case invalid
    case checking
    case done(LinkDecision, cleaned: Bool)
}

private struct LinkTesterPanel: View {
    @EnvironmentObject private var links: Links
    @StateObject private var state = Box<LinkTestState?>(nil)

    var body: some View {
        LinkPane("Where would this link go?", fill: true) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Paste or type a link", text: $links.testText)
                    .font(.system(size: 12.5))
                    .onSubmit(run)
                if links.testText.isEmpty {
                    Button("Paste") {
                        links.testText = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        run()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.pink)
                } else {
                    Button {
                        links.testText = ""
                        state.value = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .linkField(height: 36)
            result
            Spacer(minLength: 0)
            LinkRouteSteps(decided: decidedStep)
        }
    }

    private var decidedStep: Int? {
        guard case .done(let decision, _) = state.value else { return nil }
        if decision.why.hasPrefix("Holding") { return 0 }
        if decision.why.hasPrefix("Rule") { return 1 }
        return decision.why == "Default" ? 3 : 2
    }

    @ViewBuilder private var result: some View {
        switch state.value {
        case nil:
            EmptyView()
        case .invalid:
            Label("That isn't a web link", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.warn)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        case .done(let decision, let cleaned):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.pink)
                    LinkTargetIcon(target: decision.target, size: 22)
                    Text(links.title(of: decision.target)).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    let rule = decision.why.hasPrefix("Rule: ")
                    Chip(text: rule ? String(decision.why.dropFirst(6)) : decision.why, color: Palette.pink, symbol: rule ? "arrow.triangle.branch" : nil)
                        .help(decision.why)
                    if cleaned { Chip(text: "Cleaned up", color: Palette.mint, symbol: "sparkles") }
                }
                Text(shortURL(decision.url.absoluteString))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func run() {
        let text = links.testText
        guard let url = LinkCleaner.httpURL(text) else {
            state.value = text.isEmpty ? nil : .invalid
            return
        }
        state.value = .checking
        Task {
            let decision = await links.decide(url, source: nil, modifiers: [])
            guard links.testText == text else { return }
            withAnimation(Motion.snappy) { state.value = .done(decision, cleaned: decision.url != url) }
        }
    }
}

/// The order every link is checked in, with the step that decided a tested link lit up.
private struct LinkRouteSteps: View {
    @EnvironmentObject private var links: Links
    let decided: Int?

    var body: some View {
        let rules = links.config.rules.filter(\.isOn).count
        let steps = [links.config.modifier.title, rules > 0 ? "Rules \(rules)" : "Rules", "Apps", "Default"]
        VStack(alignment: .leading, spacing: 8) {
            Text(decided == nil ? "Each link takes the first of these that fits, without anything opening." : "Nothing opened. This is only where it would go.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { i in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                    Text(steps[i])
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(decided == i ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(decided == i ? AnyShapeStyle(Palette.pink.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
                        .fixedSize()
                }
            }
            .animation(Motion.bouncy, value: decided)
        }
    }
}

private struct LinkRecentPanel: View {
    @EnvironmentObject private var links: Links
    let open: (LinkTab) -> Void

    var body: some View {
        let events = links.recent
        LinkPane("Recent", fill: true) {
            if !events.isEmpty {
                Button { open(.history) } label: {
                    HStack(spacing: 3) {
                        Text("All \(events.count)")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.pink)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } content: {
            if events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 22, weight: .medium)).foregroundStyle(.tertiary)
                    Text("Links show up here with where they went and why.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(events.prefix(4)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortURL(event.opened)).font(.system(size: 11.5, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .bold))
                                Text(event.target).fontWeight(.semibold).lineLimit(1)
                                Text("· \(ago(event.date))").foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.pink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(event.received == event.opened ? event.opened : "\(event.received)\n→ \(event.opened)")
                    }
                }
            }
        }
    }
}

// MARK: - Rules

private struct LinkRulesTab: View {
    @EnvironmentObject private var links: Links
    @StateObject private var everyLink = Box(false)
    @StateObject private var note = Box<String?>(nil)
    @StateObject private var width = Box<CGFloat>(900)

    var body: some View {
        let wide = width.value >= 820
        HStack(alignment: .top, spacing: 14) {
            list(compact: !wide)
            side.frame(width: wide ? 370 : 330)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width.value = $0 }
        .onAppear {
            if !everyLink.value, !links.config.rules.contains(where: { $0.id == links.editing }) {
                links.editing = links.config.rules.first?.id
            }
        }
    }

    private func select(_ id: UUID?) {
        withAnimation(Motion.snappy) {
            everyLink.value = false
            links.editing = id
        }
    }

    private func list(compact: Bool) -> some View {
        let rules = links.config.rules
        return LinkPane("Rules", fill: true) {
            Text("First match wins").font(.system(size: 12)).foregroundStyle(.tertiary)
        } content: {
            ScrollView(.vertical) {
                VStack(spacing: 3) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        LinkRuleRow(rule: rule, number: index + 1, isFirst: index == 0, isLast: index == rules.count - 1, compact: compact,
                                    selected: !everyLink.value && links.editing == rule.id, select: { select(rule.id) }, delete: { delete(rule.id) })
                    }
                    if rules.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No rules yet").font(.system(size: 13.5, weight: .semibold))
                            Text("Every link goes to \(links.title(of: links.primary)) for now.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Rectangle().fill(Palette.stroke).frame(height: 1).padding(.vertical, 6)
                    LinkEveryLinkRow(selected: everyLink.value) {
                        withAnimation(Motion.snappy) {
                            everyLink.value = true
                            links.editing = nil
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            HStack(spacing: 8) {
                Button(action: add) { Label("Add a rule", systemImage: "plus") }
                    .buttonStyle(CapsuleButton(tint: Palette.pink))
                Spacer(minLength: 6)
                if let text = note.value {
                    Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        .transition(.opacity)
                }
                Menu {
                    Button("Copy Rules") { copy() }.disabled(rules.isEmpty)
                    Button("Paste Rules") { paste() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        Text("Copy or paste")
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Palette.well2))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rules move between Macs as JSON on the clipboard")
            }
        }
    }

    @ViewBuilder private var side: some View {
        if everyLink.value {
            LinkEveryLinkEditor()
        } else if let id = links.editing, links.config.rules.contains(where: { $0.id == id }) {
            LinkRuleEditor(id: id, delete: { delete(id) }).id(id)
        } else {
            LinkRulesExplainer()
        }
    }

    private func add() {
        let rule = LinkRule(matchers: [LinkMatcher()])
        withAnimation(Motion.snappy) {
            links.config.rules.insert(rule, at: 0)
            everyLink.value = false
            links.editing = rule.id
        }
    }

    private func delete(_ id: UUID) {
        let rules = links.config.rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let next = index + 1 < rules.count ? rules[index + 1].id : index > 0 ? rules[index - 1].id : nil
        withAnimation(Motion.snappy) {
            if links.editing == id { links.editing = next }
            links.config.rules.removeAll { $0.id == id }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.rulesText(), forType: .string)
        let n = links.config.rules.count
        flash("Copied \(n) \(n == 1 ? "rule" : "rules")")
    }

    private func paste() {
        let before = links.config.rules.count
        if links.addRules(fromText: NSPasteboard.general.string(forType: .string) ?? "") {
            let n = links.config.rules.count - before
            flash("Added \(n) \(n == 1 ? "rule" : "rules")")
            if let first = links.config.rules.dropFirst(before).first { select(first.id) }
        } else {
            flash("No rules on the clipboard")
        }
    }

    private func flash(_ text: String) {
        withAnimation(Motion.snappy) { note.value = text }
        let box = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if box.value == text { withAnimation(Motion.snappy) { box.value = nil } }
        }
    }
}

@MainActor private func ruleSummary(_ rule: LinkRule, links: Links) -> String {
    let matchers = rule.matchers.map(\.value).filter { !$0.isEmpty }
    let apps = rule.sources.map { id in links.appURL(id).map(Browsers.name) ?? id }
    var parts: [String] = []
    if !matchers.isEmpty { parts.append(matchers.joined(separator: ", ")) }
    if !apps.isEmpty { parts.append("from " + apps.joined(separator: ", ")) }
    return parts.isEmpty ? "Matches nothing yet" : parts.joined(separator: " · ")
}

private struct LinkRuleRow: View {
    @EnvironmentObject private var links: Links
    let rule: LinkRule
    let number: Int
    let isFirst: Bool
    let isLast: Bool
    let compact: Bool
    let selected: Bool
    let select: () -> Void
    let delete: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(rule.isOn ? AnyShapeStyle(Palette.pink.gradient) : AnyShapeStyle(Palette.slate.opacity(0.6))))
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled" : rule.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(rule.name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(ruleSummary(rule, links: links))
                    .font(.system(size: 11.5, design: rule.matchers.contains { !$0.value.isEmpty } ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(rule.isOn ? 1 : 0.55)
            .layoutPriority(1)
            Spacer(minLength: 6)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            Group {
                if compact {
                    LinkTargetIcon(target: rule.target, size: 24)
                } else {
                    HStack(spacing: 6) {
                        LinkTargetIcon(target: rule.target, size: 18)
                        Text(links.shortTitle(rule.target)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: 120)
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Palette.page))
                    .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
                }
            }
            .fixedSize()
            .opacity(rule.isOn ? 1 : 0.55)
            .help("Opens in \(links.title(of: rule.target))")
            VStack(spacing: 2) {
                LinkRoundButton(symbol: "chevron.up", help: "Check this rule sooner", disabled: isFirst, size: 20) { move(-1) }
                LinkRoundButton(symbol: "chevron.down", help: "Check this rule later", disabled: isLast, size: 20) { move(1) }
            }
            .opacity(hovering.value || selected ? 1 : 0)
            ToggleSwitch(isOn: rule.isOn, tint: Palette.pink, small: true, label: rule.name) {
                if let i = links.config.rules.firstIndex(where: { $0.id == rule.id }) { links.config.rules[i].isOn.toggle() }
            }
            .help(rule.isOn ? "Turn this rule off" : "Turn this rule on")
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background {
            if selected {
                shape.fill(Palette.pink.opacity(0.13)).overlay(shape.strokeBorder(Palette.pink.opacity(0.45), lineWidth: 1))
            } else if hovering.value {
                shape.fill(Color.primary.opacity(0.04))
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: select)
        .onHover { hovering.value = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit") { select() }
        .contextMenu {
            Button("Move Up") { move(-1) }.disabled(isFirst)
            Button("Move Down") { move(1) }.disabled(isLast)
            Divider()
            Button("Delete Rule", role: .destructive, action: delete)
        }
    }

    private func move(_ offset: Int) {
        withAnimation(Motion.snappy) { links.moveRule(rule.id, by: offset) }
    }
}

private struct LinkEveryLinkRow: View {
    @EnvironmentObject private var links: Links
    let selected: Bool
    let select: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let script = links.config.script.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 10) {
            IconTile(symbol: "curlybraces", tint: Palette.slate, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Before any rule").font(.system(size: 13.5, weight: .semibold))
                Text(script.isEmpty ? "A script for every link, if you need one" : script.components(separatedBy: .newlines).first ?? "")
                    .font(.system(size: 11.5, design: script.isEmpty ? .default : .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !script.isEmpty { Chip(text: "On", color: Palette.mint) }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background {
            if selected {
                shape.fill(Palette.pink.opacity(0.13)).overlay(shape.strokeBorder(Palette.pink.opacity(0.45), lineWidth: 1))
            } else if hovering.value {
                shape.fill(Color.primary.opacity(0.04))
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: select)
        .onHover { hovering.value = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
    }
}

private struct LinkRulesExplainer: View {
    @EnvironmentObject private var links: Links

    private static let examples = [("github.com/your-company", "Chrome · Work"), ("Clicked in Slack", "Firefox"), ("docs.google.com", "Safari")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            Text(links.config.rules.isEmpty ? "Send some links somewhere else" : "Pick a rule to change it")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("A rule sends links from a site or an app to a browser, a profile, a private window or another app. Rules are checked top to bottom, and the first one that fits wins.")
                .font(.system(size: 13, weight: .medium))
                .opacity(0.92)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(Self.examples, id: \.0) { example in
                    HStack(spacing: 8) {
                        Text(example.0).font(.system(size: 12, weight: .medium, design: example.0.contains(".") ? .monospaced : .default)).lineLimit(1)
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).opacity(0.7)
                        Text(example.1).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Text("Tip: ⌘-click a browser in the picker to make a rule for that site.")
                .font(.system(size: 12.5, weight: .medium))
                .opacity(0.9)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VividSurface(colors: Module.links.fill, symbol: "arrow.triangle.branch", radius: 18))
    }
}

private struct LinkRuleEditor: View {
    @EnvironmentObject private var links: Links
    let id: UUID
    let delete: () -> Void
    @StateObject private var sample = Box("")
    @FocusState private var nameFocused: Bool

    // Bound by id rather than index, so deleting the rule can't leave a field writing to the wrong one.
    private var rule: Binding<LinkRule> {
        Binding {
            links.config.rules.first { $0.id == id } ?? LinkRule(id: id)
        } set: { new in
            if let i = links.config.rules.firstIndex(where: { $0.id == id }) { links.config.rules[i] = new }
        }
    }

    private func matcher(_ mid: UUID) -> Binding<LinkMatcher> {
        Binding {
            rule.wrappedValue.matchers.first { $0.id == mid } ?? LinkMatcher(id: mid)
        } set: { new in
            if let i = rule.wrappedValue.matchers.firstIndex(where: { $0.id == mid }) { rule.wrappedValue.matchers[i] = new }
        }
    }

    var body: some View {
        let current = rule.wrappedValue
        let number = (links.config.rules.firstIndex { $0.id == id } ?? 0) + 1
        LinkPane(fill: true, padding: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Text("\(number)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Palette.pink.gradient))
                        TextField("Name this rule", text: rule.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .focused($nameFocused)
                        ToggleSwitch(isOn: current.isOn, tint: Palette.pink, label: "Rule on") { rule.wrappedValue.isOn.toggle() }
                            .help(current.isOn ? "Turn this rule off" : "Turn this rule on")
                    }
                    section("Open in") {
                        LinkTargetMenu(choose: { rule.wrappedValue.target = $0 }) {
                            LinkMenuField(text: links.title(of: current.target)) { LinkTargetIcon(target: current.target, size: 22) }
                        }
                    }
                    section("Links that match any of these") {
                        ForEach(current.matchers) { item in
                            matcherRow(item)
                        }
                        Button { rule.wrappedValue.matchers.append(LinkMatcher()) } label: { Label("Add a link condition", systemImage: "plus") }
                            .buttonStyle(CapsuleButton(tint: Palette.pink, soft: true))
                    }
                    section("Clicked in any of these apps") {
                        ForEach(current.sources, id: \.self) { app in
                            sourceRow(app)
                        }
                        addAppMenu(empty: current.sources.isEmpty)
                        if current.matchers.contains(where: { !$0.value.isEmpty }), !current.sources.isEmpty {
                            note("Both must fit: the link and the app.")
                        }
                    }
                    section("Change the link (optional)") {
                        LinkCodeEditor(text: rule.script, placeholder: "return url.replace(\"http:\", \"https:\")", height: 76)
                        note("JavaScript with url and sourceApp. Runs once this rule has matched, so it can't change which rule matches.")
                    }
                    section("Try a link") {
                        TextField("https://…", text: $sample.value).font(.system(size: 12.5, design: .monospaced)).linkField()
                        tryResult(current)
                    }
                    Button(role: .destructive, action: delete) { Label("Delete rule", systemImage: "trash") }
                        .buttonStyle(CapsuleButton(tint: Palette.bad, soft: true))
                }
                .padding(18)
            }
            .scrollIndicators(.automatic)
        }
        .onAppear {
            if current.name.isEmpty { nameFocused = true }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(sectionFont).foregroundStyle(.secondary)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func matcherRow(_ item: LinkMatcher) -> some View {
        let binding = matcher(item.id)
        return HStack(spacing: 6) {
            Menu {
                ForEach(LinkMatcher.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) { binding.wrappedValue.kind = kind }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(item.kind.title).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(width: 98, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.well2))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            TextField(placeholder(item.kind), text: binding.value)
                .font(.system(size: 12.5, design: .monospaced))
                .linkField()
                .overlay(alignment: .trailing) {
                    if !item.isValid {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn).padding(.trailing, 9)
                            .help("This regex doesn't compile, so the rule skips it")
                    }
                }
            LinkRoundButton(symbol: "xmark", help: "Remove this condition") {
                rule.wrappedValue.matchers.removeAll { $0.id == item.id }
            }
        }
    }

    private func sourceRow(_ app: String) -> some View {
        HStack(spacing: 8) {
            if let url = links.appURL(app) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
            } else {
                IconTile(symbol: "app.dashed", tint: Palette.slate, size: 20)
            }
            Text(links.appURL(app).map(Browsers.name) ?? app).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            LinkRoundButton(symbol: "xmark", help: "Remove this app") { rule.wrappedValue.sources.removeAll { $0 == app } }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.page))
    }

    private func addAppMenu(empty: Bool) -> some View {
        Menu {
            Section("Open Now") {
                ForEach(links.runningApps(), id: \.id) { app in
                    Button(app.name) { addSource(app.id) }
                }
            }
            Menu("All Apps") {
                ForEach(links.allApps(), id: \.id) { app in
                    Button(app.name) { addSource(app.id) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text(empty ? "Any app. Add one to narrow it down" : "Add an app")
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(empty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ink.pink))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(empty ? Color.primary.opacity(0.06) : Palette.pink.opacity(0.16)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func addSource(_ id: String) {
        if !rule.wrappedValue.sources.contains(id) { rule.wrappedValue.sources.append(id) }
    }

    @ViewBuilder private func tryResult(_ current: LinkRule) -> some View {
        if let url = LinkCleaner.httpURL(sample.value) {
            let matched = current.matchers.isEmpty ? nil : current.matchers.contains { $0.matches(url) }
            HStack(spacing: 6) {
                Image(systemName: matched == false ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(matched == false ? Palette.slate : Palette.good)
                Text(matched == false ? "Doesn't match" : matched == true ? "Matches" : "Any link matches")
                    .font(.system(size: 12.5, weight: .medium))
                if matched != false, !current.sources.isEmpty {
                    Text("when clicked in one of the apps").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        } else if !sample.value.isEmpty {
            Text("That isn't a web link").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ kind: LinkMatcher.Kind) -> String {
        switch kind {
        case .domain: "github.com"
        case .prefix: "github.com/bunniesinc"
        case .regex: "^https://.*\\.example\\.com/"
        }
    }
}

private struct LinkEveryLinkEditor: View {
    @EnvironmentObject private var links: Links

    var body: some View {
        LinkPane(fill: true, padding: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: "curlybraces", tint: Palette.slate, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Before any rule").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("Runs on every link first, so it can change which rule matches.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LinkCodeEditor(text: $links.config.script, placeholder: "// For example:\nreturn url.replace(\"old.example.com\", \"new.example.com\")", height: 140, grows: true)
            Text("JavaScript with url and sourceApp. Return a new link, or nothing to leave it. If it fails or takes over a second, the link carries on as it was.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Browsers

private struct LinkBrowsersTab: View {
    @EnvironmentObject private var links: Links
    @StateObject private var width = Box<CGFloat>(900)

    var body: some View {
        let shown = links.visibleShown
        let hidden = links.allTargets.filter { !links.config.shown.contains($0) && !isSelf($0) }
        let keys = links.pickerKeys(for: shown)
        HStack(alignment: .top, spacing: 14) {
            LinkPane("In the picker, in this order", fill: true) {
                Text("\(shown.count) shown").font(.system(size: 12)).foregroundStyle(.tertiary)
            } content: {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, target in
                            LinkBrowserRow(target: target, shown: true, autoKey: keys[target.id], isFirst: i == 0, isLast: i == shown.count - 1)
                        }
                        if shown.isEmpty {
                            Text("With nothing here, links skip the picker and go to the default.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                        }
                        if !hidden.isEmpty {
                            Text("Not shown").font(sectionFont).foregroundStyle(.secondary)
                                .padding(.top, 14).padding(.bottom, 4).padding(.leading, 10)
                            ForEach(hidden) { target in
                                LinkBrowserRow(target: target, shown: false, autoKey: nil, isFirst: true, isLast: true)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            VStack(spacing: 14) {
                LinkPickerPreview(targets: shown, keys: keys)
                LinkProfilesPanel()
            }
            .frame(width: width.value >= 820 ? 320 : 290)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width.value = $0 }
    }
}

private struct LinkBrowserRow: View {
    @EnvironmentObject private var links: Links
    let target: LinkTarget
    let shown: Bool
    let autoKey: String?
    let isFirst: Bool
    let isLast: Bool
    @StateObject private var hovering = Box(false)

    var body: some View {
        HStack(spacing: 10) {
            LinkTargetIcon(target: target, size: 28)
                .opacity(shown ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(links.appName(target)).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                if let detail = links.detail(target) {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if shown {
                HStack(spacing: 4) {
                    LinkRoundButton(symbol: "arrow.up", help: "Move up in the picker", disabled: isFirst) { move(-1) }
                    LinkRoundButton(symbol: "arrow.down", help: "Move down in the picker", disabled: isLast) { move(1) }
                }
                .opacity(hovering.value ? 1 : 0)
                keyField
            }
            ToggleSwitch(isOn: shown, tint: Palette.pink, small: true, label: links.title(of: target)) {
                withAnimation(Motion.snappy) { links.toggleShown(target) }
            }
            .help(shown ? "Take it out of the picker" : "Show it in the picker")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering.value ? 0.04 : 0)))
        .onHover { hovering.value = $0 }
    }

    private var keyField: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return TextField(autoKey?.uppercased() ?? "", text: key)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .frame(width: 28, height: 28)
            .background {
                shape.fill(Color.dynamic(light: .white, dark: NSColor(hex: 0x2C2558)))
                    .shadow(color: .black.opacity(0.22), radius: 0, y: 1.5)
            }
            .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .help("The key that picks it. Type a letter to choose your own.")
    }

    private var key: Binding<String> {
        Binding {
            links.config.keys[target.id]?.uppercased() ?? ""
        } set: { text in
            links.config.keys[target.id] = text.last(where: \.isLetter).map { String($0).lowercased() }
        }
    }

    private func move(_ offset: Int) {
        withAnimation(Motion.snappy) { links.moveShown(target, by: offset) }
    }
}

/// The picker as it will look, so the order and keys can be checked at a glance.
private struct LinkPickerPreview: View {
    @EnvironmentObject private var links: Links
    let targets: [LinkTarget]
    let keys: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The picker").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("For Ask Every Time. Press a key or click.").font(.system(size: 12, weight: .medium)).opacity(0.88)
            }
            HStack(spacing: 6) {
                ForEach(targets.prefix(5)) { target in
                    VStack(spacing: 5) {
                        LinkTargetIcon(target: target, size: 30)
                        Keycap(text: keys[target.id]?.uppercased() ?? "·", small: true, onColor: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(target == links.primary ? 0.26 : 0.13)))
                }
                if targets.count > 5 {
                    Text("+\(targets.count - 5)").font(.system(size: 13, weight: .bold, design: .rounded)).frame(width: 30)
                }
            }
            if targets.isEmpty {
                Text("Nothing to choose from, so links go straight to the default.").font(.system(size: 12, weight: .medium)).opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VividSurface(colors: Module.links.fill, symbol: "cursorarrow.click.2", radius: 18))
    }
}

private struct LinkProfilesPanel: View {
    @EnvironmentObject private var links: Links

    var body: some View {
        let supported = links.browsers.filter { browser in
            if case .other = browser.family { return false }
            return true
        }
        LinkPane("Profiles and private windows", fill: true) {
            Text("Chrome, Edge, Brave, Vivaldi and Firefox keep their profiles in their own folders. Gremlin only looks when you ask, and macOS may check with you first.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !supported.isEmpty {
                VStack(spacing: 8) {
                    ForEach(supported) { browser in
                        HStack(spacing: 8) {
                            Image(nsImage: browser.icon).resizable().frame(width: 20, height: 20)
                            Text(browser.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 6)
                            status(browser)
                        }
                    }
                }
            }
            Button("Find profiles") { withAnimation(Motion.snappy) { links.findProfiles() } }
                .buttonStyle(CapsuleButton(tint: Palette.pink, soft: true))
            if !links.profilesDenied.isEmpty {
                Text("Allow Gremlin in System Settings › Privacy & Security › App Management or Full Disk Access, then try again.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("Private windows work in Chrome, Edge, Brave, Vivaldi, Opera, Firefox, Zen and LibreWolf. Turn one on to put it in the picker.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func status(_ browser: Browser) -> some View {
        if links.profilesDenied.contains(browser.id) {
            Chip(text: "Not allowed", color: Palette.warn)
        } else if let profiles = links.config.profiles[browser.id] {
            Text(profiles.isEmpty ? "Just one" : "\(profiles.count) \(profiles.count == 1 ? "profile" : "profiles")")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        } else {
            Text("Not looked yet").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Apps

private struct LinkAppsTab: View {
    @EnvironmentObject private var links: Links

    private var apps: [LinkApp] {
        let installed = Set(links.installedLinkApps.map(\.id))
        return LinkApp.all.filter { installed.contains($0.id) } + LinkApp.all.filter { !installed.contains($0.id) }
    }

    var body: some View {
        LinkFitOrScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(symbol: "arrow.up.forward.app.fill", tint: Palette.pink, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("These links skip the browser").font(.system(size: 14, weight: .semibold))
                        Text("When the app is installed, its links open there. Your rules come first, and any other app can be a rule's destination.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(apps) { app in
                        LinkAppCard(app: app)
                    }
                }
            }
        }
    }
}

private struct LinkAppCard: View {
    @EnvironmentObject private var links: Links
    let app: LinkApp

    private var look: (symbol: String, tint: Color, example: String) {
        switch app.id {
        case "meet": ("video.fill", Palette.mint, "meet.google.com/…")
        case "zoom": ("video.circle.fill", Palette.sky, "zoom.us/j/…")
        case "teams": ("person.3.fill", Palette.iris, "teams.microsoft.com/l/…")
        case "figma": ("paintbrush.pointed.fill", Palette.coral, "figma.com/design/…")
        case "linear": ("checklist", Palette.iris, "linear.app/…/issue/…")
        case "notion": ("doc.text.fill", Palette.slate, "notion.so/…")
        case "spotify": ("music.note", Palette.mint, "open.spotify.com/…")
        case "discord": ("bubble.left.and.bubble.right.fill", Palette.grape, "discord.com/channels/…")
        default: ("app.fill", Palette.slate, "")
        }
    }

    var body: some View {
        let installed = app.apps.first { links.appURL($0) != nil }
        let on = installed != nil && !links.config.appsOff.contains(app.id)
        let look = look
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if let installed, let url = links.appURL(installed) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).frame(width: 40, height: 40)
                } else {
                    IconTile(symbol: look.symbol, tint: look.tint, size: 38).saturation(0.2).opacity(0.7)
                }
                Spacer()
                if installed != nil {
                    ToggleSwitch(isOn: on, tint: Palette.pink, small: true, label: app.title) {
                        if links.config.appsOff.contains(app.id) { links.config.appsOff.remove(app.id) } else { links.config.appsOff.insert(app.id) }
                    }
                } else {
                    Chip(text: "Not installed", color: Palette.slate)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(app.title).font(.system(size: 15, weight: .bold, design: .rounded))
                Text(look.example).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(caption(installed: installed, on: on))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(Ink.pink) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if on {
                PaperSurface(tint: look.tint, radius: 18)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well)
            }
        }
        .opacity(installed == nil ? 0.75 : 1)
        .animation(Motion.snappy, value: on)
    }

    private func caption(installed: String?, on: Bool) -> String {
        guard let installed else { return "Opens in the browser" }
        let name = links.appURL(installed).map(Browsers.name) ?? app.title
        return on ? "Opens in \(name)" : "Off, so they open in the browser"
    }
}

// MARK: - History

private struct LinkHistoryTab: View {
    @EnvironmentObject private var links: Links
    @StateObject private var query = Box("")

    var body: some View {
        let all = links.recent
        let q = query.value.trimmingCharacters(in: .whitespaces)
        let events = q.isEmpty ? all : all.filter { event in
            [event.opened, event.received, event.target, event.why, event.source ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        let icons = links.targetsByTitle()
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "externaldrive.fill", tint: Palette.slate, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep history after quitting").font(.system(size: 13.5, weight: .semibold))
                    Text(links.config.keepHistory ? "Up to 500 links, on this Mac only" : "The last 50, until Gremlin quits")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ToggleSwitch(isOn: links.config.keepHistory, tint: Palette.pink, small: true, label: "Keep history after quitting") {
                    links.setKeepHistory(!links.config.keepHistory)
                }
                .padding(.leading, 6)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("Search history", text: $query.value)
                }
                .linkField()
                .frame(maxWidth: 220)
                Button("Clear") { withAnimation(Motion.snappy) { links.clearHistory() } }
                    .buttonStyle(CapsuleButton(tint: Palette.bad, soft: true))
                    .disabled(all.isEmpty)
                    .opacity(all.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
            LinkPane(fill: true, padding: 0) {
                if events.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: q.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                            .font(.system(size: 30, weight: .medium)).foregroundStyle(.tertiary)
                        Text(q.isEmpty ? "No links yet" : "Nothing matches “\(q)”").font(.system(size: 15, weight: .semibold, design: .rounded))
                        if q.isEmpty {
                            Text("Each link shows up here with the app it came from, where it went and why.")
                                .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(days, id: \.key) { day in
                                Text(dayTitle(day.key)).font(sectionFont).foregroundStyle(.secondary)
                                    .padding(.leading, 10).padding(.top, 10).padding(.bottom, 4)
                                ForEach(day.value) { event in
                                    LinkHistoryRow(event: event, target: icons[event.target])
                                }
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct LinkHistoryRow: View {
    let event: LinkEvent
    let target: LinkTarget?
    @StateObject private var hovering = Box(false)

    var body: some View {
        let cleaned = event.received != event.opened && event.opened.hasPrefix("http")
        HStack(spacing: 12) {
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            LinkTargetIcon(target: target, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(shortURL(event.opened)).font(monoFont).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(event.target).fontWeight(.semibold).foregroundStyle(Ink.pink)
                    Text("· \(event.why)")
                    if let source = event.source { Text("· from \(source)") }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if cleaned {
                Chip(text: "Cleaned", color: Palette.mint, symbol: "sparkles")
                    .help("Arrived as \(event.received)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering.value ? 0.04 : 0)))
        .onHover { hovering.value = $0 }
        .help(cleaned ? "\(event.received)\n→ \(event.opened)" : event.opened)
        .contextMenu {
            Button("Copy Link") { copy(event.opened) }
            if cleaned { Button("Copy Link as It Arrived") { copy(event.received) } }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

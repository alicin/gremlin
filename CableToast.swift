import AppKit
import SwiftUI

// A card under the menu bar when something gets plugged in: what it is, how fast it links and charges, and the one
// thing holding it back, if anything. It fills in as the link settles and goes away on its own.
@MainActor
final class CableToast {
    nonisolated static let enabledKey = "cablesToast"

    var open: ((String) -> Void)?
    private let cables: Cables
    private var window: GlassWindow?
    private var host: NSHostingView<AnyView>?
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    private(set) var port: String?

    init(cables: Cables) {
        self.cables = cables
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func show(_ id: String) {
        hide()
        port = id
        let view = CableToastView(cables: cables, id: id, open: { [weak self] in
            self?.hide()
            self?.open?(id)
        }, close: { [weak self] in
            self?.hide()
        }, hover: { [weak self] inside in
            self?.hovering = inside
            if !inside { self?.scheduleHide() }
        }, resized: { [weak self] in
            self?.place(animated: true)
        })
        let host = NSHostingView(rootView: AnyView(view.onGlass()))
        let window = GlassWindow(level: .statusBar, keyable: false)
        window.contentView = host
        self.host = host
        self.window = window
        place(animated: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; window.animator().alphaValue = 1 }
        window.reshadow()
        scheduleHide()
    }

    func hide(_ id: String? = nil) {
        guard id == nil || id == port else { return }
        hideWork?.cancel()
        guard let window else { return }
        self.window = nil
        host = nil
        port = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; window.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { window.orderOut(nil) }
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: work)
    }

    /// Keeps the card's top right corner put while its content grows or shrinks.
    private func place(animated: Bool) {
        guard let window, let host else { return }
        let size = host.fittingSize
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let frame = NSRect(x: visible.maxX - 16 - size.width, y: visible.maxY - 10 - size.height, width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: animated && window.frame.size != frame.size)
        window.reshadow()
    }
}

private struct CableToastView: View {
    @ObservedObject var cables: Cables
    let id: String
    let open: () -> Void
    let close: () -> Void
    let hover: (Bool) -> Void
    let resized: () -> Void
    @Environment(\.glass) private var look

    var body: some View {
        let story = cables.port(id).map { PortStory(port: $0, charging: cables.charging, chargingPort: cables.chargingPort?.id) }
        let insight = story.flatMap { s in s.insights.first { $0.tone == .warn } ?? s.insights.first { $0.tone == .good } }
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: story?.symbol ?? "cable.connector")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Palette.emerald.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(story?.name ?? "Something's plugged in").font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                    Text(place(story)).font(.system(size: 11.5)).foregroundStyle(look.sub).lineLimit(1)
                    if let rows = story?.rows, !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(rows, id: \.text) { row in
                                Label(row.text, systemImage: row.symbol)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 5)
                    }
                }
                Spacer(minLength: 4)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(RoundStyle(size: 24))
                    .help("Close")
            }
            if let insight {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: insight.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(insight.tone == .warn ? Tone.warning.color : Tone.good.color)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(insight.title).font(.system(size: 12, weight: .semibold))
                        if insight.tone == .warn {
                            Text(insight.detail).font(.system(size: 11.5)).foregroundStyle(look.sub).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(insight.tone == .warn ? .warning : .card, radius: 14)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Everything about it", action: open).buttonStyle(PillStyle(kind: .prominent, height: 28))
            }
        }
        .padding(14)
        .frame(width: 380)
        .legible()
        .surface(.panel, radius: 24)
        .onHover(perform: hover)
        .onChange(of: signature(story, insight)) { resized() }
        .animation(Motion.snappy, value: signature(story, insight))
    }

    private func place(_ story: PortStory?) -> String {
        guard let story else { return "Reading the cable…" }
        let port = story.port
        let place = [port.title, port.location.map { $0.title.lowercased() }].compactMap { $0 }.joined(separator: ", ")
        return [story.maker, place].compactMap { $0 }.joined(separator: " · ")
    }

    private func signature(_ story: PortStory?, _ insight: PortStory.Insight?) -> String {
        [story?.name ?? "", story?.lines.joined() ?? "", insight?.id ?? ""].joined(separator: "|")
    }
}

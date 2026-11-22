import AppKit
import SwiftUI

// Each module's cards on the shelf: its card on the strip, what Space shows beside it, and the page of cards it opens
// into. A new module adds a case to each switch here.

// MARK: - Home strip

struct ShelfHomeStrip: View {
    @ObservedObject var s: ShelfState

    var body: some View {
        let modules = s.modules
        if modules.isEmpty {
            ShelfEmpty(title: "Nothing matches \u{201C}\(s.query)\u{201D}", detail: "Try another word, or pick All.")
        } else {
            ShelfStrip(target: s.selected.rawValue) {
                ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                    ShelfModuleCard(s: s, module: module, index: index)
                        .shelfScrollID(module.rawValue)
                        .zIndex(s.selected == module ? 1 : 0)
                        .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                removal: .scale(scale: 0.6).combined(with: .opacity)))
                }
            }
            .animation(Motion.bouncy, value: s.query)
        }
    }
}

private struct ShelfModuleCard: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @ObservedObject var drives: Drives
    @ObservedObject var displays: Displays
    @ObservedObject var recordings: Recordings
    let module: Module
    let index: Int

    init(s: ShelfState, module: Module, index: Int) {
        self.s = s
        model = s.model
        links = s.model.links
        drives = s.model.drives
        displays = s.model.displays
        recordings = s.recordings
        self.module = module
        self.index = index
    }

    var body: some View {
        let selected = s.selected == module
        let peeking = s.peek == module
        ShelfCard(module.title, status: s.status(module), symbol: module.symbol, tint: module.tint,
                  width: ShelfMetrics.cardWidth + (peeking ? ShelfMetrics.peekWidth : 0), footer: footer,
                  footerAccessory: selected && !peeking ? AnyView(Keycap(text: "↩", small: true).transition(.scale.combined(with: .opacity))) : nil,
                  selected: selected, live: s.isLive(module), index: index,
                  onTap: { s.select(module) }, onOpen: { s.open(module) }) {
            HStack(alignment: .top, spacing: 0) {
                ShelfModuleBody(s: s, module: module)
                    .frame(width: ShelfMetrics.cardWidth)
                if peeking {
                    ShelfPeek(s: s, module: module)
                        .transition(.opacity)
                }
            }
        }
    }

    private var footer: String {
        switch module {
        case .meetings:
            let items = recordings.items
            guard !items.isEmpty else { return "Saved in Movies › Meetings" }
            let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
            return "\(items.count) recordings · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        case .tools: return "Shortcuts work anywhere"
        case .keepAwake: return "Survives a Gremlin restart"
        case .displays: return "Puts them back when they connect"
        case .restart: return "Runs as you, no admin password"
        case .fixes: return "Runs in the background"
        case .ipad: return "Sidecar, like Control Center"
        case .universalControl:
            if case .paired(let name, _) = model.pairing { return "Paired with \(name)" }
            return "Not paired with another Mac"
        case .links:
            let rules = links.config.rules.count
            return "\(rules) \(rules == 1 ? "rule" : "rules")" + (links.config.removeTracking ? " · tracking removed" : "")
        case .drives: return "In ~/Drives, over SSH"
        case .settings: return "Gremlin \(ShelfState.version)"
        }
    }
}

private struct ShelfModuleBody: View {
    @ObservedObject var s: ShelfState
    let module: Module

    var body: some View {
        switch module {
        case .meetings: ShelfMeetingsBody(s: s, model: s.model, recordings: s.recordings)
        case .tools: ShelfToolsBody(s: s)
        case .keepAwake: ShelfAwakeBody(s: s, model: s.model)
        case .displays: ShelfDisplaysBody(s: s, displays: s.model.displays)
        case .restart: ShelfRestartBody(s: s, model: s.model)
        case .fixes: ShelfFixesBody(s: s, model: s.model)
        case .ipad: ShelfIPadBody(s: s, model: s.model)
        case .universalControl: ShelfUCBody(s: s, model: s.model)
        case .links: ShelfLinksBody(links: s.model.links)
        case .drives: ShelfDrivesBody(s: s, drives: s.model.drives)
        case .settings: ShelfSettingsBody(s: s, model: s.model)
        }
    }
}

private struct ShelfPeek: View {
    @ObservedObject var s: ShelfState
    let module: Module

    private var facts: [String] {
        switch module {
        case .meetings: ["Screen and audio, or just audio", "Transcript, summary and action items", "Offers to record when a call starts"]
        case .tools: ["Grab text and QR codes off the screen", "Pick any color as hex", "Paste plain, give focus back"]
        case .keepAwake: ["30 minutes to 4 hours, or until you stop", "Shows who else keeps the Mac up", "Survives a Gremlin restart"]
        case .displays: ["Saves where each display sits", "Puts them back when they connect", "Knows displays by name and serial"]
        case .restart: ["Dock, Finder, Menu Bar and 6 more", "Runs as you, never asks for a password", "Back in a couple of seconds"]
        case .fixes: ["Restarts a stuck Notification Center", "Watches Universal Control", "Gives focus back to the front window"]
        case .ipad: ["Connect with ⌃⌥⌘S from anywhere", "Takes the iPad from another Mac", "Same calls as Control Center"]
        case .universalControl: ["Spots the moment it gives up", "Resets it, then tries again later", "Paired Macs can reset each other"]
        case .links: ["Rules by site and by app", "Strips tracking on the way", "Zoom and Figma links open in their apps"]
        case .drives: ["Any server you can ssh into", "Shows up in Finder like a disk", "Nothing to install on either end"]
        case .settings: ["Open at login", "Transcript language", "Every shortcut in one place"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(module.blurb)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(facts, id: \.self) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(ShelfMetrics.deep(module.tint))
                    Text(fact).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("Open \(module.title)") { s.open(module) }
                    .buttonStyle(ShelfPill(kind: .tint(module.tint)))
                Spacer(minLength: 0)
                Button { s.openInGremlin(module) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(ShelfPill(kind: .soft))
                .help("Open in Gremlin")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: ShelfMetrics.peekWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(ShelfMetrics.paperTint)
    }
}

// MARK: - Meetings card

private struct ShelfMeetingsBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    @ObservedObject var recordings: Recordings

    var body: some View {
        let job = s.job
        let ready = recordings.items.filter { $0.folder != job?.folder }.prefix(job == nil ? 3 : 2)
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let recording = model.recording {
                    ShelfLiveTile(recording: recording) { s.run(.stopRecording, closing: true) }
                } else if model.starting {
                    ShelfStartingTile()
                } else {
                    HStack(spacing: 8) {
                        ShelfRecordTile(title: "Screen", keys: "⌃⌥⌘R", filled: true) { s.run(.record(audioOnly: false), closing: true) }
                        ShelfRecordTile(title: "Audio", keys: "⌃⌥⌘A", filled: false) { s.run(.record(audioOnly: true), closing: true) }
                    }
                }
            }
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            VStack(alignment: .leading, spacing: 9) {
                if let job {
                    ShelfJobRow(title: MeetingNotes.title(of: job.folder), job: job)
                        .contentShape(Rectangle())
                        .onTapGesture { show(job.folder) }
                }
                ForEach(Array(ready)) { item in
                    ShelfReadyRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { show(item.folder) }
                }
                if recordings.items.isEmpty, job == nil {
                    Text("Your recordings and their transcripts show up here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 13)
        .animation(Motion.bouncy, value: model.recording != nil)
    }

    private func show(_ folder: URL) {
        s.open(.meetings)
        s.selectMeeting(folder)
    }
}

private struct ShelfRecordTile: View {
    let title: String
    let keys: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if filled {
                        Circle().fill(.white).frame(width: 9, height: 9)
                    } else {
                        Image(systemName: "waveform").font(.system(size: 11, weight: .bold))
                    }
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Keycap(text: keys, small: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 60)
            .background {
                shape.fill(filled ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFF7A6E), Palette.coral], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(ShelfMetrics.paperTint))
                    .shadow(color: filled ? Palette.coral.opacity(0.35) : .clear, radius: 5, y: 2)
            }
            .contentShape(shape)
        }
        .buttonStyle(ShelfPress())
        .help(filled ? "Record the screen and audio" : "Record audio only")
    }
}

private struct ShelfLiveTile: View {
    let recording: MenuModel.Recording
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: recording.started, by: 1)) { _ in
                    Text(Meetings.elapsed(since: recording.started))
                        .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(recording.audioOnly ? "Audio only" : "Screen and audio")
                    .font(.system(size: 10.5, weight: .medium)).opacity(0.85).lineLimit(1).fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            SoundBars(live: recording.hearing, color: .white.opacity(0.9), count: 6, width: 2.5, height: 20)
            Button(action: stop) {
                RoundedRectangle(cornerRadius: 3).fill(Palette.coral).frame(width: 11, height: 11)
                    .frame(width: 30, height: 30)
                    .background(.white, in: Circle())
            }
            .buttonStyle(ShelfPress())
            .help("Stop recording  ⌃⌥⌘R")
            .accessibilityLabel("Stop recording")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .frame(height: 60)
        .background(Palette.coral.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct ShelfStartingTile: View {
    var body: some View {
        HStack(spacing: 10) {
            ShelfSpinner(tint: .white, size: 20, line: 3)
            Text("Starting…").font(.system(size: 15, weight: .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(Palette.coral.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct ShelfJobRow: View {
    let title: String
    let job: ShelfJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(job.percent.map { "\($0)%" } ?? job.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            if let percent = job.percent {
                ProgressBar(progress: Double(percent) / 100, tint: job.tint)
            } else {
                ShelfSweep(tint: job.tint)
            }
        }
        .help(job.doing)
    }
}

private struct ShelfReadyRow: View {
    let item: Recordings.Item

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.transcribed ? "checkmark.circle.fill" : item.uncompressed ? "hourglass.circle.fill" : "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(item.transcribed ? Palette.good : item.uncompressed ? Palette.amber : .secondary)
            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 2)
            Text(item.shelfShortState)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A bar for work with no percentage: a short stretch of color that keeps sliding across.
private struct ShelfSweep: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint.gradient)
                        .frame(width: g.size.width * 0.3)
                        .offset(x: (g.size.width * 1.3) * phase - g.size.width * 0.3)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Tools card

private struct ShelfTool: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let keys: String
    let hint: String
    let tint: Color
    let action: MenuModel.Action

    static let all = [
        ShelfTool(id: "grab", title: "Grab Text", symbol: "text.viewfinder", keys: "⇧⌘1", hint: "Copy the text in any part of the screen, or what a QR code says",
                  tint: Palette.sky, action: .grabText),
        ShelfTool(id: "color", title: "Pick Color", symbol: "eyedropper", keys: "⇧⌘2", hint: "Copy any color on the screen as hex",
                  tint: Palette.pink, action: .pickColor),
        ShelfTool(id: "paste", title: "Plain Paste", symbol: "doc.on.clipboard", keys: "⌃⌥⌘V", hint: "Paste the clipboard without its formatting",
                  tint: Palette.teal, action: .plainPaste),
        ShelfTool(id: "focus", title: "Fix Focus", symbol: "scope", keys: "⌃⌥⌘F", hint: "Give your typing back to the window on top",
                  tint: Palette.iris, action: .fixFocus),
    ]
}

private struct ShelfToolsBody: View {
    @ObservedObject var s: ShelfState

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
            ForEach(ShelfTool.all) { tool in
                Button { s.run(tool.action, closing: true) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        IconTile(symbol: tool.symbol, tint: tool.tint, size: 26)
                        Spacer(minLength: 4)
                        Text(tool.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(tool.keys)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .frame(height: 78)
                    .background(ShelfMetrics.paperTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ShelfPress())
                .help(tool.hint)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 13)
    }
}

// MARK: - Keep Awake card

private struct ShelfAwakeBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ShelfAwakeReadout(model: model, big: false)
                Spacer(minLength: 0)
                ShelfCup(on: model.awakeStop != 0, size: 46)
            }
            Spacer(minLength: 0)
            ShelfStopSlider(stops: MenuModel.awakeStops, index: model.awakeStop, tint: Palette.amber) { s.run(.keepAwake($0)) }
            if let other = model.awakeOthers.first {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.sky)
                    Text(model.awakeOthers.count > 1 ? "\(ShelfState.short(other)) and \(model.awakeOthers.count - 1) more keep it awake too"
                                                     : "\(ShelfState.short(other)) is keeping it awake too")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(ShelfMetrics.paperTint, in: Capsule())
                .padding(.top, 12)
                .help("Also kept awake by " + ListFormatter.localizedString(byJoining: model.awakeOthers))
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 14)
        .padding(.bottom, model.awakeOthers.isEmpty ? 14 : 4)
    }
}

/// How long is left, read from the "Until 10:41 AM" the panel shows, so it counts down without a model change.
private struct ShelfAwakeReadout: View {
    @ObservedObject var model: MenuModel
    let big: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let value = Self.value(model, now: context.date)
            VStack(alignment: .leading, spacing: big ? 2 : 0) {
                Text(value.0)
                    .font(.system(size: big ? 46 : 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(value.1)
                    .font(.system(size: big ? 13.5 : 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .animation(Motion.snappy, value: model.awakeStop)
        }
    }

    static func value(_ model: MenuModel, now: Date) -> (String, String) {
        let stop = model.awakeStop
        guard stop > 0 else { return ("Off", "Sleeps as usual") }
        guard stop <= KeepAwake.choices.count, let most = KeepAwake.choices[stop - 1].duration else { return ("∞", "Until you turn it off") }
        if let until = until(model.awakeText, now: now), case let left = until.timeIntervalSince(now), left > 0, left <= most + 90 {
            let minutes = Int((left / 60).rounded(.up))
            let text = minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
            return (text, "left · \(model.awakeText.lowercased())")
        }
        return (MenuModel.awakeStops[stop].replacingOccurrences(of: "m", with: " min").replacingOccurrences(of: "h", with: " h"), model.awakeText)
    }

    private static func until(_ text: String, now: Date) -> Date? {
        guard text.hasPrefix("Until ") else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        guard let time = formatter.date(from: String(text.dropFirst(6))) else { return nil }
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        guard let today = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) else { return nil }
        return today < now.addingTimeInterval(-60) ? calendar.date(byAdding: .day, value: 1, to: today) : today
    }
}

private struct ShelfCup: View {
    let on: Bool
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(on ? AnyShapeStyle(ShelfMetrics.deep(Palette.amber).gradient) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(Palette.amber.opacity(on ? 0.18 : 0.06), in: Circle())
            .overlay(alignment: .top) {
                if on {
                    HStack(spacing: size * 0.06) {
                        ForEach(0..<3) { i in
                            Capsule().fill(ShelfMetrics.deep(Palette.amber).opacity(0.45))
                                .frame(width: 2, height: size * (i == 1 ? 0.16 : 0.11))
                        }
                    }
                    .offset(y: size * 0.1)
                    .transition(.opacity)
                }
            }
            .animation(Motion.snappy, value: on)
    }
}

private struct ShelfStopSlider: View {
    let stops: [String]
    let index: Int
    let tint: Color
    let pick: (Int) -> Void
    @StateObject private var dragging = Box<Int?>(nil)

    var body: some View {
        let shown = dragging.value ?? index
        VStack(spacing: 6) {
            GeometryReader { g in
                let seg = g.size.width / CGFloat(stops.count)
                let x0 = seg / 2
                let xi = x0 + seg * CGFloat(shown)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                        .frame(width: g.size.width - seg + 6, height: 6)
                        .offset(x: x0 - 3)
                    Capsule().fill(tint.gradient)
                        .frame(width: xi - x0 + 6, height: 6)
                        .offset(x: x0 - 3)
                    Circle().fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .overlay { Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5) }
                        .offset(x: xi - 10)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let i = min(max(Int(((drag.location.x - x0) / seg).rounded()), 0), stops.count - 1)
                        if i != dragging.value { withAnimation(Motion.bouncy) { dragging.value = i } }
                    }
                    .onEnded { _ in
                        if let i = dragging.value, i != index { pick(i) }
                        dragging.value = nil
                    })
            }
            .frame(height: 22)
            HStack(spacing: 0) {
                ForEach(stops.indices, id: \.self) { i in
                    Text(stops[i])
                        .font(.system(size: 10.5, weight: i == shown ? .bold : .medium, design: .rounded))
                        .foregroundStyle(i == shown ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Motion.bouncy) { pick(i) } }
                }
            }
        }
        .animation(Motion.bouncy, value: index)
        .accessibilityElement()
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(stops[index])
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: pick(min(index + 1, stops.count - 1))
            case .decrement: pick(max(index - 1, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Displays card

private struct ShelfDisplaysBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var displays: Displays

    var body: some View {
        let fitting = displays.config.layouts.filter(displays.fits)
        VStack(spacing: 14) {
            ShelfScreenMap(screens: ShelfScreen.from(DisplayHardware.snapshot(displays.live)))
                .frame(height: 96)
            HStack(spacing: 5) {
                if fitting.isEmpty {
                    Button { displays.saveCurrent() } label: { Label("Save this layout", systemImage: "square.and.arrow.down") }
                        .buttonStyle(ShelfPill(kind: .tint(Palette.iris), height: 26))
                } else {
                    ForEach(fitting.prefix(3)) { layout in
                        ShelfLayoutChip(layout: layout, displays: displays)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 14)
    }
}

private struct ShelfLayoutChip: View {
    let layout: DisplayLayout
    @ObservedObject var displays: Displays

    var body: some View {
        let on = displays.current?.id == layout.id
        Button { withAnimation(Motion.bouncy) { displays.apply(layout) } } label: {
            HStack(spacing: 5) {
                if displays.applying == layout.id { ShelfSpinner(tint: .white, size: 11, line: 2) }
                Text(layout.title)
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(on ? AnyShapeStyle(Palette.iris.gradient) : AnyShapeStyle(ShelfMetrics.paperTint), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(ShelfPress())
        .disabled(on || displays.applying != nil)
        .help(on ? "Your displays are arranged this way" : "Arrange your displays this way")
    }
}

// MARK: - Restart card

private struct ShelfRestartBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    // The ones that get stuck most, by their index in Restart.items.
    private static let picks = [0, 1, 2, 4, 6]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
            ForEach(Self.picks, id: \.self) { index in
                let item = Restart.items[index]
                ShelfPartCell(title: ShelfPart.name(item), symbol: item.symbol, done: model.restarted.contains(index)) { s.run(.restart(index)) }
                    .help("Restart \(item.title): \(item.hint)")
            }
            ShelfPartCell(title: "\(Restart.items.count - Self.picks.count) more", symbol: "ellipsis", done: false) { s.open(.restart) }
        }
        .padding(.horizontal, 13)
        .padding(.top, 13)
    }
}

private enum ShelfPart {
    static func name(_ item: Restart.Item) -> String { item.title == "Notification Center" ? "Notifications" : item.title }
}

private struct ShelfPartCell: View {
    let title: String
    let symbol: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.good)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 34, height: 34)
                .background(ShelfMetrics.paper, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .background(ShelfMetrics.paperTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(Motion.bouncy, value: done)
        }
        .buttonStyle(ShelfPress())
    }
}

// MARK: - Fixes card

private struct ShelfFix: Identifiable {
    let key: String
    let title: String
    let detail: String
    let note: String
    let symbol: String
    let tint: Color

    var id: String { key }

    static let all = [
        ShelfFix(key: AppSwitch.autoFixFocus, title: "Auto-Fix Lost Focus", detail: "Gives your typing back to the front window",
                 note: "Does Fix Focus for you when the front app has windows on screen but none of them has focus for 3 seconds.",
                 symbol: "scope", tint: Palette.sky),
        ShelfFix(key: AppSwitch.notificationCenterWatchdog, title: "Fix Stuck Notification Center", detail: "Restarts it after 30 s at full CPU",
                 note: "Restarts Notification Center when it sits at full CPU for 30 seconds, so banners come back.",
                 symbol: "bell.badge", tint: Palette.coral),
        ShelfFix(key: AppSwitch.universalControlWatcher, title: "Universal Control Watcher", detail: "Resets it when a device gives up",
                 note: "Reads Universal Control's logs and resets it the moment a device gives up after sleep.",
                 symbol: "macbook.and.ipad", tint: Palette.grape),
    ]

    @MainActor func warns(_ model: MenuModel) -> Bool { key == AppSwitch.autoFixFocus && !model.accessibility }
    @MainActor func detail(_ model: MenuModel) -> String { warns(model) ? "Needs Accessibility" : detail }
}

private struct ShelfFixesBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ShelfFix.all.enumerated()), id: \.element.id) { index, fix in
                let on = model.switches[fix.key] ?? false
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fix.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        ShelfFixDetail(text: fix.detail(model), warn: fix.warns(model))
                    }
                    Spacer(minLength: 4)
                    ToggleSwitch(isOn: on, tint: Palette.mint, small: true, label: fix.title) { s.run(.setSwitch(fix.key, !on)) }
                }
                .padding(.vertical, 8)
                if index < ShelfFix.all.count - 1 { Rectangle().fill(ShelfMetrics.hairline).frame(height: 1) }
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 5)
    }
}

private struct ShelfFixDetail: View {
    let text: String
    let warn: Bool

    var body: some View {
        HStack(spacing: 3) {
            if warn { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(warn ? AnyShapeStyle(Ink.amber) : AnyShapeStyle(.secondary))
    }
}

// MARK: - iPad card

private extension MenuModel.IPad {
    var connected: Bool { state == .connected }
    var busy: Bool { state == .connecting || state == .disconnecting }

    var line: (color: Color, text: String) {
        switch state {
        case .nearby: (Palette.good, "Nearby · ready to connect")
        case .connecting: (Palette.busy, "Connecting…")
        case .disconnecting: (Palette.busy, "Disconnecting…")
        case .connected: (Palette.busy, "Connected as a display")
        case .away: (.gray, seen.map { "Not nearby · seen \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" } ?? "Not nearby")
        }
    }
}

private struct ShelfIPadBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(spacing: 11) {
            ShelfIPadArt(connected: model.ipad?.connected == true)
                .frame(width: 128, height: 86)
                .padding(.top, 2)
            if let ipad = model.ipad {
                HStack(spacing: 6) {
                    Circle().fill(ipad.line.color).frame(width: 6, height: 6)
                    Text(ipad.line.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                ShelfSidecarButton(s: s, ipad: ipad, wide: true)
            } else {
                Text("Sidecar isn't available on this Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
    }
}

private struct ShelfSidecarButton: View {
    @ObservedObject var s: ShelfState
    let ipad: MenuModel.IPad
    var wide = false

    var body: some View {
        Button { s.run(.toggleSidecar) } label: {
            HStack(spacing: 6) {
                if ipad.busy { ShelfSpinner(tint: ipad.connected ? Color.primary : .white, size: 12, line: 2) }
                Text(ipad.connected || ipad.state == .disconnecting ? "Disconnect" : "Connect")
                Text("⌃⌥⌘S").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.7)
            }
            .frame(maxWidth: wide ? .infinity : nil)
        }
        .buttonStyle(ShelfPill(kind: ipad.connected ? .soft : .tint(Palette.teal), height: 30))
        .disabled(ipad.state == .away || ipad.busy)
    }
}

private struct ShelfIPadArt: View {
    let connected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color(hex: 0x1A1530))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(connected ? AnyShapeStyle(Palette.holo)
                                    : AnyShapeStyle(LinearGradient(colors: [Palette.indigoLift, Palette.indigoDeep], startPoint: .top, endPoint: .bottom)))
                    .overlay {
                        if connected {
                            VStack(spacing: 0) {
                                Rectangle().fill(.white.opacity(0.85)).frame(height: 4)
                                Spacer()
                            }
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(.white.opacity(0.92))
                                .frame(width: 46, height: 30)
                                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                                .offset(x: -8, y: 4)
                        } else {
                            HoloPaw(size: 17, sticker: true)
                        }
                    }
                    .padding(5)
            }
            .overlay(alignment: .leading) {
                Circle().fill(.white.opacity(0.3)).frame(width: 2.5, height: 2.5).padding(.leading, 1.5)
            }
            .shadow(color: Palette.teal.opacity(connected ? 0.5 : 0.18), radius: connected ? 12 : 6, y: 3)
            .animation(Motion.bouncy, value: connected)
    }
}

// MARK: - Universal Control card

private struct ShelfDevice: Identifiable {
    let id: String
    let symbol: String
    let label: String
    let detail: String
    let ok: Bool

    @MainActor static func all(_ model: MenuModel) -> [ShelfDevice] {
        var devices = [ShelfDevice(id: model.thisMac, symbol: "laptopcomputer", label: "This Mac",
                                   detail: model.watcher.isOn ? "Watching" : "Watcher off", ok: model.watcher.isOn)]
        if let ipad = model.ipad {
            let detail = switch ipad.state {
            case .connected: "A display for this Mac"
            case .away: "Not nearby"
            default: "Nearby"
            }
            devices.append(ShelfDevice(id: ipad.name, symbol: "ipad", label: ipad.name, detail: detail, ok: ipad.state != .away))
        }
        if case .paired(let name, let status) = model.pairing {
            devices.append(ShelfDevice(id: name, symbol: "macmini", label: name, detail: "Paired · \(status)", ok: status == MenuModel.reachable))
        }
        return devices
    }
}

private struct ShelfUCBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        let watcher = model.watcher
        VStack(alignment: .leading, spacing: 10) {
            ShelfDeviceChain(devices: ShelfDevice.all(model), active: watcher.isOn)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(watcher.tone.color).frame(width: 6, height: 6)
                    Text(watcher.isOn ? watcher.status : "The watcher is off").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Text(watcher.lastReset.isEmpty ? watcher.detail : watcher.lastReset)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            HStack {
                Button(isPaired ? "Reset here" : "Reset now") { s.run(.resetUniversalControl(.local)) }
                    .buttonStyle(ShelfPill(kind: .tint(Palette.grape), height: 28))
                    .help("Turns Universal Control off and on again on this Mac")
                Spacer()
                ToggleSwitch(isOn: watcher.isOn, tint: Palette.grape, small: true, label: "Universal Control Watcher") {
                    s.run(.setSwitch(AppSwitch.universalControlWatcher, !watcher.isOn))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 13)
    }

    private var isPaired: Bool {
        if case .paired = model.pairing { return true }
        return false
    }
}

private struct ShelfDeviceChain: View {
    let devices: [ShelfDevice]
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 {
                    Dash()
                        .stroke(Palette.grape.opacity(active ? 0.55 : 0.2), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
                        .frame(height: 1.5)
                        .padding(.top, 19)
                }
                VStack(spacing: 4) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 40)
                        .background(ShelfMetrics.paperTint, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(device.ok && active ? Palette.good : Color.gray)
                                .frame(width: 9, height: 9)
                                .overlay { Circle().strokeBorder(ShelfMetrics.paper, lineWidth: 1.5) }
                        }
                    Text(device.label.count > 11 ? device.label.prefix(10) + "…" : device.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if devices.count == 1 { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: devices.count == 1 ? .leading : .center)
    }

    private struct Dash: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX + 3, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
            }
        }
    }
}

// MARK: - Links card

@MainActor
private enum ShelfLinks {
    static let tints = [Palette.sky, Palette.amber, Palette.teal, Palette.iris, Palette.pink, Palette.mint]

    static func today(_ links: Links) -> [LinkEvent] { links.recent.filter { Calendar.current.isDateInToday($0.date) } }

    static func counts(_ events: [LinkEvent]) -> [String: Int] { Dictionary(grouping: events, by: \.target).mapValues(\.count) }
}

private struct ShelfLinksBody: View {
    @ObservedObject var links: Links
    /// The Links page has Make Default in its bar instead.
    var offerDefault = true

    var body: some View {
        let today = ShelfLinks.today(links)
        let counts = ShelfLinks.counts(today)
        let targets = Array(links.shownTargets.prefix(links.isDefault || !offerDefault ? 4 : 3))
        VStack(alignment: .leading, spacing: 10) {
            if today.isEmpty {
                ShelfLinksDefault(links: links)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(today.count)").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("today").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    let cleaned = today.filter { $0.received != $0.opened }.count
                    if cleaned > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles").font(.system(size: 9.5, weight: .bold))
                            Text("\(cleaned) cleaned").font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Ink.pink)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Palette.pink.opacity(0.14), in: Capsule())
                    }
                }
                ShelfBrowserBar(parts: targets.enumerated().map { (ShelfLinks.tints[$0.offset % 6], counts[links.title(of: $0.element)] ?? 0) })
                    .frame(height: 8)
            }
            VStack(spacing: 5) {
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    Button { links.config.primary = target } label: {
                        HStack(spacing: 7) {
                            if today.isEmpty, let icon = links.icon(of: target) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            } else {
                                Circle().fill(ShelfLinks.tints[index % 6]).frame(width: 7, height: 7).frame(width: 16)
                            }
                            Text(ShelfState.short(links.title(of: target))).font(.system(size: 11.5)).lineLimit(1)
                            Spacer(minLength: 2)
                            if !today.isEmpty {
                                Text("\(counts[links.title(of: target)] ?? 0)")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else if target == links.primary {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.pink)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ShelfPress())
                    .help("Open links in \(links.title(of: target))")
                }
            }
            if !links.isDefault, offerDefault {
                Button { links.makeDefault() } label: { Label("Make Default", systemImage: "checkmark.seal.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(ShelfPill(kind: .tint(Palette.pink), height: 28))
                    .help("Make Gremlin the default browser, so links go through it. macOS asks you first.")
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
    }
}

private struct ShelfLinksDefault: View {
    @ObservedObject var links: Links

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = links.icon(of: links.primary) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "questionmark.app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(ShelfState.short(links.title(of: links.primary))).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(links.isDefault ? "Where links open" : "Once Gremlin is the default")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
    }
}

private struct ShelfBrowserBar: View {
    let parts: [(Color, Int)]

    var body: some View {
        GeometryReader { g in
            let total = CGFloat(max(1, parts.reduce(0) { $0 + $1.1 }))
            let shown = parts.filter { $0.1 > 0 }
            let gap: CGFloat = 2
            let usable = g.size.width - gap * CGFloat(max(0, shown.count - 1))
            HStack(spacing: gap) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                    Capsule().fill(part.0.gradient).frame(width: usable * CGFloat(part.1) / total)
                }
                if shown.isEmpty { Capsule().fill(Color.primary.opacity(0.1)) }
            }
        }
    }
}

// MARK: - Drives card

private extension Drives.Status {
    var mounted: Bool { phase == .mounted }

    var text: String {
        switch phase {
        case .off: problem.map(ShelfDrive.firstLine) ?? "Not mounted"
        case .connecting: "Connecting…"
        case .mounted: offline ? "Offline · reconnecting" : inUse ? "Mounted · in use" : "Mounted"
        case .ejecting: "Ejecting…"
        }
    }
}

private enum ShelfDrive {
    static func firstLine(_ text: String) -> String { text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text }
}

private struct ShelfDrivesBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var drives: Drives

    var body: some View {
        VStack(spacing: 10) {
            if drives.config.drives.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mount a folder on any server you can ssh into, right in Finder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { s.openInGremlin(.drives) } label: { Label("Add a drive", systemImage: "plus") }
                        .buttonStyle(ShelfPill(kind: .tint(Palette.lime)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(drives.config.drives.prefix(3)) { drive in
                ShelfDriveRow(s: s, drive: drive, drives: drives)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 13)
    }
}

private struct ShelfDriveRow: View {
    @ObservedObject var s: ShelfState
    let drive: Drive
    @ObservedObject var drives: Drives

    var body: some View {
        let status = drives.status(of: drive)
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(status.mounted ? AnyShapeStyle(ShelfMetrics.deep(Palette.lime)) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background(ShelfMetrics.paperTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(status.mounted ? (status.offline ? Palette.warn : Palette.good) : status.problem != nil ? Palette.warn : Color.gray)
                        .frame(width: 9, height: 9)
                        .overlay { Circle().strokeBorder(ShelfMetrics.paper, lineWidth: 1.5) }
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(drive.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(status.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(status.problem != nil && !status.mounted ? AnyShapeStyle(Ink.amber) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { if status.mounted { s.close(); drives.reveal(drive) } }
            Spacer(minLength: 2)
            Button {
                switch status.phase {
                case .mounted: drives.eject(drive)
                case .connecting: drives.cancel(drive)
                case .off: drives.mount(drive, reveal: false)
                case .ejecting: break
                }
            } label: {
                Group {
                    if status.phase == .connecting || status.phase == .ejecting {
                        ShelfSpinner(tint: ShelfMetrics.deep(Palette.lime), size: 12, line: 2)
                    } else {
                        Image(systemName: status.mounted ? "eject.fill" : "play.fill").font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(status.phase == .off ? AnyShapeStyle(ShelfMetrics.ink(Palette.lime)) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(status.phase == .off ? AnyShapeStyle(Palette.lime.gradient) : AnyShapeStyle(ShelfMetrics.paperTint), in: Circle())
            }
            .buttonStyle(ShelfPress())
            .disabled(status.phase == .ejecting)
            .help(status.mounted ? "Eject" : status.phase == .connecting ? "Stop connecting" : "Mount")
        }
        .help(drive.place)
    }
}

// MARK: - Settings card

private struct ShelfSettingsBody: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(spacing: 0) {
            ShelfSettingRow(title: "Open at login") {
                ToggleSwitch(isOn: model.login, tint: Palette.accent, small: true, label: "Open at login") { s.run(.setLogin(!model.login)) }
            }
            ShelfSettingRow(title: "Offer to record calls") { ShelfSwitchFor(s: s, model: model, key: AppSwitch.offerToRecordCalls) }
            ShelfSettingRow(title: "Transcript language") { ShelfLanguageMenu(s: s, model: model) }
            ShelfSettingRow(title: "Recordings", divider: false) {
                Button { s.run(.showRecordings, closing: true) } label: {
                    Text("Movies › Meetings").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(ShelfPress())
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 6)
    }
}

private struct ShelfSwitchFor: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    let key: String
    var tint = Palette.accent

    var body: some View {
        let on = model.switches[key] ?? false
        ToggleSwitch(isOn: on, tint: tint, small: true, label: key) { s.run(.setSwitch(key, !on)) }
    }
}

private struct ShelfLanguageMenu: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        Menu {
            ForEach(MenuModel.languages, id: \.name) { language in
                Button(language.name) { s.run(.setLanguage(language.code)) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(MenuModel.languages.first { $0.code == model.language }?.name ?? model.language ?? "Automatic")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ShelfSettingRow<Trailing: View>: View {
    let title: String
    var divider = true
    var height: CGFloat = 38
    let trailing: Trailing

    init(title: String, divider: Bool = true, height: CGFloat = 38, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.divider = divider
        self.height = height
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                trailing
            }
            .frame(height: height)
            if divider { Rectangle().fill(ShelfMetrics.hairline).frame(height: 1) }
        }
    }
}

// MARK: - Meetings page

private extension Recordings.Item {
    var shelfKind: String { audioOnly ? "Audio" : "Screen and audio" }
    var shelfSymbol: String { audioOnly ? "waveform" : "display" }
    var shelfSeed: Int { folder.lastPathComponent.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } }
    var shelfSize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var shelfLength: String? {
        guard let minutes else { return nil }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    var shelfWhen: String {
        guard let date else { return title }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
        if Date().timeIntervalSince(date) < 6 * 86400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))), \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    var shelfShortState: String {
        if actionItems > 0 { return "\(actionItems) action \(actionItems == 1 ? "item" : "items")" }
        if uncompressed { return "Waiting" }
        if summarized { return "No action items" }
        return transcribed ? "Transcript ready" : "No transcript"
    }

    func shelfTint(_ job: ShelfJob?) -> Color {
        if let job, job.folder == folder { return job.tint }
        return uncompressed ? Palette.amber : Palette.coral
    }
}

struct ShelfMeetingsStrip: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var recordings: Recordings
    @ObservedObject var model: MenuModel

    var body: some View {
        let list = s.meetings
        if list.isEmpty {
            if recordings.items.isEmpty {
                ShelfEmpty(title: "No meetings yet", detail: "Record a call with ⌃⌥⌘R, or just its audio with ⌃⌥⌘A.")
            } else {
                ShelfEmpty(title: "No meetings here", detail: "Try another day, or clear the search.")
            }
        } else {
            ShelfStrip(target: s.meeting?.path) {
                ForEach(Array(list.enumerated()), id: \.element.id) { position, item in
                    ShelfRecordingCard(s: s, recordings: recordings, item: item, job: s.job, position: position)
                        .shelfScrollID(item.folder.path)
                        .zIndex(s.meeting == item.folder ? 1 : 0)
                        .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                removal: .scale(scale: 0.6).combined(with: .opacity)))
                }
            }
            .animation(Motion.bouncy, value: s.meetingQuery)
        }
    }
}

private struct ShelfRecordingCard: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var recordings: Recordings
    let item: Recordings.Item
    let job: ShelfJob?
    let position: Int

    var body: some View {
        let open = s.preview == item.folder
        let mine = job?.folder == item.folder ? job : nil
        let progress = mine.map { job in job.percent.map { Double($0) / 100 } ?? 0 }
        ShelfCard(item.title, status: open ? [item.shelfWhen, item.shelfLength, item.shelfKind].compactMap { $0 }.joined(separator: " · ") : status(mine),
                  symbol: item.shelfSymbol, tint: item.shelfTint(job), width: open ? ShelfMetrics.previewWidth : ShelfMetrics.recordingWidth,
                  footer: open ? nil : (mine != nil || item.uncompressed ? item.shelfWhen : item.shelfKind),
                  headerAccessory: open && mine == nil ? AnyView(ShelfPreviewActions(s: s, item: item, notes: recordings.notes(for: item))) : nil,
                  selected: s.meeting == item.folder || (s.meeting == nil && position == 0), progress: mine?.percent == nil ? nil : progress,
                  live: mine != nil, index: position,
                  onTap: { s.selectMeeting(item.folder) }, onOpen: { s.togglePreview(item.folder) }) {
            if open {
                ShelfPreview(s: s, recordings: recordings, item: item, job: mine)
                    .transition(.opacity)
            } else {
                ShelfRecordingBody(item: item, job: mine)
                    .transition(.opacity)
            }
        }
    }

    private func status(_ job: ShelfJob?) -> String {
        if let job { return job.percent.map { "\(job.title) · \($0)%" } ?? "\(job.title)…" }
        return item.uncompressed ? "Waiting its turn" : item.shelfWhen
    }
}

private struct ShelfRecordingBody: View {
    let item: Recordings.Item
    let job: ShelfJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ShelfWave(seed: item.shelfSeed, progress: job?.percent.map { Double($0) / 100 } ?? 1, tint: item.shelfTint(job))
                .frame(height: 64)
                .padding(.bottom, 2)
            HStack(spacing: 5) {
                Image(systemName: item.audioOnly ? "mic.fill" : "rectangle.inset.filled.on.rectangle").font(.system(size: 10))
                Text(item.shelfLength ?? item.shelfKind)
                Spacer(minLength: 2)
                Text(item.shelfSize)
            }
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(.secondary)
            ShelfPeople(names: item.people)
            Spacer(minLength: 0)
            stateLine
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var stateLine: some View {
        if let job {
            switch job.kind {
            case .compressing: ShelfStateLine(symbol: "arrow.down.right.and.arrow.up.left", text: job.doing, tint: ShelfMetrics.deep(Palette.amber))
            case .summarizing: ShelfStateLine(symbol: "sparkles", text: job.doing, tint: Palette.grape)
            default: ShelfStateLine(symbol: "text.bubble.fill", text: job.doing, tint: Palette.iris)
            }
        } else if item.uncompressed {
            ShelfStateLine(symbol: "hourglass", text: "Waiting its turn", tint: ShelfMetrics.deep(Palette.amber))
        } else if item.actionItems > 0 {
            ShelfStateLine(symbol: "checklist", text: item.shelfShortState, tint: Palette.coral)
        } else if item.transcribed {
            ShelfStateLine(symbol: "checkmark.circle.fill", text: item.shelfShortState, tint: Palette.good)
        } else {
            ShelfStateLine(symbol: "exclamationmark.circle", text: item.shelfShortState, tint: .secondary)
        }
    }
}

private struct ShelfStateLine: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
    }
}

private struct ShelfPreviewActions: View {
    @ObservedObject var s: ShelfState
    let item: Recordings.Item
    let notes: Recordings.Notes?

    var body: some View {
        HStack(spacing: 6) {
            if let summary = notes?.summary, !summary.isEmpty {
                action(s.copied == item.folder ? "checkmark" : "doc.on.doc", s.copied == item.folder ? "Copied" : "Copy summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    withAnimation(Motion.snappy) { s.copied = item.folder }
                }
            }
            action("folder", "Show in Finder") {
                let file = FileManager.default.fileExists(atPath: item.transcript.path) ? item.transcript : item.folder
                s.close()
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
        .padding(.trailing, 4)
    }

    private func action(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white.opacity(0.22), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(ShelfPress())
    }
}

private struct ShelfPreview: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var recordings: Recordings
    let item: Recordings.Item
    let job: ShelfJob?

    var body: some View {
        if let job {
            ShelfPendingPreview(item: item, job: job)
        } else if let notes = recordings.notes(for: item), !notes.summary.isEmpty || !notes.actionItems.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                ShelfSummaryColumn(s: s, item: item, notes: notes)
                    .frame(width: 302, alignment: .topLeading)
                    .padding(.horizontal, 16)
                Rectangle().fill(ShelfMetrics.hairline).frame(width: 1).padding(.bottom, 14)
                ShelfActionsColumn(notes: notes)
                    .padding(.horizontal, 16)
            }
            .padding(.top, 14)
        } else {
            ShelfReadyPreview(s: s, item: item, notes: recordings.notes(for: item))
        }
    }
}

private enum ShelfText {
    /// transcript.md is Markdown, and bold markers read as noise in a card.
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "**", with: "") }

    /// "**Ali:** Do the thing" as who and what.
    static func owner(_ item: String) -> (who: String?, what: String) {
        guard let match = item.firstMatch(of: #/^\*\*(.+?):?\*\*:?\s*(.*)$/#) else { return (nil, plain(item)) }
        return (String(match.1), plain(String(match.2)))
    }
}

private struct ShelfSummaryColumn: View {
    @ObservedObject var s: ShelfState
    let item: Recordings.Item
    let notes: Recordings.Notes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShelfSectionLabel(text: "Summary")
            Text(ShelfText.plain(notes.summary.isEmpty ? "No summary for this one." : notes.summary))
                .font(.system(size: 12))
                .lineSpacing(1.5)
                .lineLimit(notes.decisions.isEmpty ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
            if !notes.decisions.isEmpty {
                ShelfSectionLabel(text: "Decisions").padding(.top, 6)
                ForEach(notes.decisions.prefix(2), id: \.self) { decision in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 10.5)).foregroundStyle(Palette.coral)
                        Text(ShelfText.plain(decision)).font(.system(size: 11.5)).lineLimit(1)
                    }
                    .help(ShelfText.plain(decision))
                }
            }
            Spacer(minLength: 0)
            ShelfFileChips(s: s, item: item)
                .padding(.bottom, 12)
        }
    }
}

private struct ShelfFileChips: View {
    @ObservedObject var s: ShelfState
    let item: Recordings.Item

    var body: some View {
        let files = [item.transcript, item.media, item.folder.appendingPathComponent(MeetingNotes.event)]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        HStack(spacing: 4) {
            ForEach(files, id: \.self) { file in
                Button { s.open(url: file) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: Self.symbol(file)).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.coral)
                        Text(file.lastPathComponent).font(.system(size: 10.5, weight: .medium)).fixedSize()
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(ShelfMetrics.paperTint, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(ShelfPress())
                .help("Open \(file.lastPathComponent)")
            }
        }
    }

    private static func symbol(_ file: URL) -> String {
        switch file.pathExtension {
        case "md": "doc.text"
        case "json": "curlybraces"
        case "m4a": "waveform"
        default: "film"
        }
    }
}

private struct ShelfActionsColumn: View {
    let notes: Recordings.Notes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ShelfSectionLabel(text: "Action items")
                Spacer()
                if !notes.actionItems.isEmpty {
                    Text("\(notes.actionItems.count) \(notes.actionItems.count == 1 ? "item" : "items")")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if notes.actionItems.isEmpty {
                Text("None this time.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(Array(notes.actionItems.prefix(notes.lines.isEmpty ? 7 : 4).enumerated()), id: \.offset) { _, entry in
                let parts = ShelfText.owner(entry)
                HStack(spacing: 7) {
                    Circle().fill(Palette.coral.gradient).frame(width: 6, height: 6).frame(width: 11)
                    Text(parts.what).font(.system(size: 11.5)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let who = parts.who {
                        Avatar(name: who, size: 16)
                        Text(who).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
                .frame(height: 18)
                .help(ShelfText.plain(entry))
            }
            if !notes.lines.isEmpty {
                Spacer(minLength: 0)
                ShelfTranscriptBlock(lines: Array(notes.lines.prefix(2)))
                    .padding(.bottom, 12)
            }
        }
    }
}

private struct ShelfSectionLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// Always dark, like Clipboard's code cards, so the transcript reads as a transcript at a glance.
private struct ShelfTranscriptBlock: View {
    let lines: [Recordings.Notes.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.speaker)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(line.speaker == "Me" ? Palette.holoMint : Palette.holoPink)
                        .lineLimit(1)
                        .frame(width: 34, alignment: .leading)
                    Text(line.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(line.time)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShelfMetrics.transcriptInk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ShelfPendingPreview: View {
    let item: Recordings.Item
    let job: ShelfJob

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                if let percent = job.percent {
                    ShelfRing(value: Double(percent) / 100, tint: job.tint, size: 112, line: 10)
                } else {
                    ShelfSpinner(tint: job.tint, size: 112, line: 10)
                }
                VStack(spacing: 0) {
                    Text(job.percent.map { "\($0)%" } ?? "…").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(job.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(headline).font(.system(size: 16, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShelfPeople(names: item.people)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 380, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
    }

    private var headline: String {
        switch job.kind {
        case .compressing: "Making a smaller copy"
        case .transcribing: "The transcript is on its way"
        case .summarizing: "The summary is on its way"
        case .other: job.title
        }
    }

    private var detail: String {
        switch job.kind {
        case .compressing:
            "ffmpeg is shrinking the \(item.audioOnly ? "audio" : "video"). It runs at background priority while a call is using the mic."
        case .transcribing: "Written on this Mac by whisper. A summary, decisions and action items follow when it's done."
        case .summarizing: "Claude is writing the summary, decisions and action items from the transcript."
        case .other: "This only happens the first time."
        }
    }
}

private struct ShelfReadyPreview: View {
    @ObservedObject var s: ShelfState
    let item: Recordings.Item
    let notes: Recordings.Notes?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                ShelfWave(seed: item.shelfSeed, tint: item.shelfTint(nil), count: 46).frame(height: 54)
                ShelfPeople(names: item.people)
                ShelfFileChips(s: s, item: item)
            }
            .frame(width: 320, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                if item.transcribed {
                    ShelfStateLine(symbol: "checkmark.circle.fill", text: "Transcript ready", tint: Palette.good)
                } else if item.uncompressed {
                    ShelfStateLine(symbol: "hourglass", text: "Waiting its turn", tint: ShelfMetrics.deep(Palette.amber))
                } else {
                    ShelfStateLine(symbol: "exclamationmark.circle", text: "No transcript", tint: .secondary)
                }
                if let lines = notes?.lines, !lines.isEmpty {
                    ShelfStateLine(symbol: "text.bubble", text: "\(lines.count) passages", tint: .secondary)
                }
                if let length = item.shelfLength { ShelfStateLine(symbol: "clock", text: length, tint: .secondary) }
                ShelfStateLine(symbol: "internaldrive", text: item.shelfSize, tint: .secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }
}

/// Bars drawn from the recording's name, so every card has its own waveform. Past `progress` they're gray.
private struct ShelfWave: View {
    let seed: Int
    var progress: Double = 1
    let tint: Color
    var count = 24

    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = 2.5
            let w = max(2, (g.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(count) < progress ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: w, height: max(w, g.size.height * Self.level(i, seed)))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    static func level(_ i: Int, _ seed: Int) -> CGFloat {
        let x = Double(i), s = Double(seed % 97)
        let v = abs(sin(x * 0.9 + s) * 0.6 + sin(x * 0.37 + s * 0.5) * 0.45)
        return CGFloat(0.2 + 0.8 * min(1, v))
    }
}

private struct ShelfPeople: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 7) {
            if names.isEmpty {
                Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("No calendar event").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: -6) {
                    ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { _, name in Avatar(name: name, size: 20) }
                }
                Text(names.count > 3 ? "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)" : names.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The record buttons in the Meetings bar, or the running recording with Stop.
struct ShelfRecordControls: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        Group {
            if let recording = model.recording {
                Button { s.run(.stopRecording, closing: true) } label: {
                    HStack(spacing: 8) {
                        LiveDot(color: .white, size: 6).frame(width: 10, height: 10)
                        TimelineView(.periodic(from: recording.started, by: 1)) { _ in
                            Text(Meetings.elapsed(since: recording.started))
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        }
                        SoundBars(live: recording.hearing, color: .white.opacity(0.9), count: 6, width: 2.5, height: 14)
                        Text("Stop").font(.system(size: 12.5, weight: .semibold))
                    }
                }
                .buttonStyle(ShelfPill(kind: .tint(Palette.coral), height: 30))
                .help("Stop recording  ⌃⌥⌘R")
            } else {
                HStack(spacing: 6) {
                    Button { s.run(.record(audioOnly: true), closing: true) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").font(.system(size: 11.5, weight: .semibold))
                            Text("Audio")
                            Text("⌃⌥⌘A").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.55)
                        }
                    }
                    .buttonStyle(ShelfPill(kind: .soft, height: 30))
                    .help("Record audio only")
                    Button { s.run(.record(audioOnly: false), closing: true) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(.white).frame(width: 8, height: 8)
                            Text("Screen")
                            Text("⌃⌥⌘R").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.8)
                        }
                    }
                    .buttonStyle(ShelfPill(kind: .tint(Palette.coral), height: 30))
                    .help("Record the screen and audio")
                }
                .disabled(model.starting)
            }
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .animation(Motion.bouncy, value: model.recording != nil)
    }
}

// MARK: - Module pages

struct ShelfModulePage: View {
    @ObservedObject var s: ShelfState
    let module: Module

    var body: some View {
        ShelfStrip(target: s.sub) {
            switch module {
            case .tools: ShelfToolsPage(s: s, model: s.model)
            case .keepAwake: ShelfAwakePage(s: s, model: s.model)
            case .displays: ShelfDisplaysPage(s: s, displays: s.model.displays)
            case .restart: ShelfRestartPage(s: s, model: s.model)
            case .fixes: ShelfFixesPage(s: s, model: s.model)
            case .ipad: ShelfIPadPage(s: s, model: s.model)
            case .universalControl: ShelfUCPage(s: s, model: s.model)
            case .links: ShelfLinksPage(s: s, links: s.model.links)
            case .drives: ShelfDrivesPage(s: s, drives: s.model.drives)
            case .settings, .meetings: ShelfSettingsPage(s: s, model: s.model)
            }
        }
    }
}

/// The one thing each module's page offers from the bar, where Meetings has its record buttons.
struct ShelfPageAction: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    @ObservedObject var links: Links
    @ObservedObject var displays: Displays
    let module: Module

    init(s: ShelfState, module: Module) {
        self.s = s
        model = s.model
        links = s.model.links
        displays = s.model.displays
        self.module = module
    }

    var body: some View {
        switch module {
        case .keepAwake:
            Button(model.awakeStop == 0 ? "Turn on for 1 hour" : "Turn off") { s.run(.keepAwake(model.awakeStop == 0 ? 2 : 0)) }
                .buttonStyle(ShelfPill(kind: model.awakeStop == 0 ? .tint(Palette.amber) : .soft, height: 30))
        case .ipad:
            if let ipad = model.ipad { ShelfSidecarButton(s: s, ipad: ipad) }
        case .displays:
            if displays.current == nil {
                Button { displays.saveCurrent() } label: { Label("Save this layout", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ShelfPill(kind: .tint(Palette.iris), height: 30))
                    .help("Save how your displays are arranged now, to put them back later")
            }
        case .links:
            if !links.isDefault {
                Button { links.makeDefault() } label: { Label("Make Default", systemImage: "checkmark.seal.fill") }
                    .buttonStyle(ShelfPill(kind: .tint(Palette.pink), height: 30))
                    .help("Make Gremlin the default browser. macOS asks you first.")
            }
        case .drives:
            Button { s.openInGremlin(.drives) } label: { Label("Add drive", systemImage: "plus") }
                .buttonStyle(ShelfPill(kind: .tint(Palette.lime), height: 30))
        case .universalControl:
            switch model.pairing {
            case .unpaired:
                Button { s.run(.startPairing) } label: { Label("Pair another Mac", systemImage: "link") }
                    .buttonStyle(ShelfPill(kind: .soft, height: 30))
            case .pairing:
                Button("Stop pairing") { s.run(.stopPairing) }.buttonStyle(ShelfPill(kind: .soft, height: 30))
            case .paired:
                EmptyView()
            }
        case .restart:
            let everything = model.restarted.count == Restart.items.count
            Button(model.confirmRestartAll ? "Click again to restart all" : everything ? "Everything restarted" : "Restart All") {
                s.run(.restartAll)
            }
            .buttonStyle(ShelfPill(kind: model.confirmRestartAll ? .tint(Palette.coral) : .soft, height: 30))
            .help("Restarts every part. It also empties the clipboard, so it takes a second click.")
        default:
            EmptyView()
        }
    }
}

/// A card on a module page. With nothing picked yet, the first one wears the ring.
private struct ShelfSub<Content: View>: View {
    @ObservedObject var s: ShelfState
    let key: String
    let title: String
    let status: String
    let symbol: String
    let tint: Color
    var width: CGFloat
    var index: Int
    var footer: String?
    var progress: Double?
    let content: Content

    init(_ s: ShelfState, _ key: String, _ title: String, status: String, symbol: String, tint: Color, width: CGFloat = ShelfMetrics.cardWidth,
         index: Int = 0, footer: String? = nil, progress: Double? = nil, @ViewBuilder content: () -> Content) {
        self.s = s
        self.key = key
        self.title = title
        self.status = status
        self.symbol = symbol
        self.tint = tint
        self.width = width
        self.index = index
        self.footer = footer
        self.progress = progress
        self.content = content()
    }

    var body: some View {
        ShelfCard(title, status: status, symbol: symbol, tint: tint, width: width, footer: footer,
                  selected: s.sub == key || (s.sub == nil && index == 0), progress: progress, index: index,
                  onTap: { withAnimation(Motion.bouncy) { s.sub = key } }) {
            content
        }
        .shelfScrollID(key)
        .zIndex(s.sub == key ? 1 : 0)
    }
}

private struct ShelfNote: View {
    let text: String
    var size: CGFloat = 12.5

    var body: some View {
        Text(text).font(.system(size: size)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShelfToolsPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        ForEach(Array(ShelfTool.all.enumerated()), id: \.element.id) { index, tool in
            ShelfSub(s, tool.id, tool.title, status: "Works anywhere", symbol: tool.symbol, tint: tool.tint, index: index) {
                VStack(alignment: .leading, spacing: 11) {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(tool.tint.gradient)
                        .frame(maxWidth: .infinity)
                        .frame(height: 74)
                        .background(ShelfMetrics.paperTint, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    Text(tool.hint).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack {
                        Button("Try it") { s.run(tool.action, closing: true) }.buttonStyle(ShelfPill(kind: .tint(tool.tint)))
                        Spacer()
                        Keycap(text: tool.keys, small: true)
                    }
                }
                .padding(13)
            }
        }
        let fix = ShelfFix.all[0]
        let on = model.switches[fix.key] ?? false
        ShelfSub(s, "autofix", fix.title, status: on ? "On" : model.accessibility ? "Off" : "Off · needs Accessibility", symbol: fix.symbol,
                 tint: Palette.mint, index: 4) {
            VStack(alignment: .leading, spacing: 12) {
                ShelfNote(text: fix.note)
                HStack {
                    Text("Fix it for me").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    ToggleSwitch(isOn: on, tint: Palette.mint, small: true, label: fix.title) { s.run(.setSwitch(fix.key, !on)) }
                }
                Spacer(minLength: 0)
                if !model.accessibility {
                    Button { ShelfSystem.openAccessibility(s) } label: { Label("Allow Accessibility", systemImage: "lock.open.fill") }
                        .buttonStyle(ShelfPill(kind: .soft))
                }
            }
            .padding(13)
        }
    }
}

@MainActor
private enum ShelfSystem {
    static func openAccessibility(_ s: ShelfState) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        s.open(url: url)
    }
}

private struct ShelfAwakePage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        ShelfSub(s, "awake", "Keep Awake", status: model.awakeText, symbol: "cup.and.saucer.fill", tint: Palette.amber,
                 width: 470, footer: "Keeps the display awake too, and survives a Gremlin restart") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ShelfAwakeReadout(model: model, big: true)
                    Spacer()
                    ShelfCup(on: model.awakeStop != 0, size: 70)
                }
                Spacer(minLength: 0)
                ShelfStopSlider(stops: MenuModel.awakeStops, index: model.awakeStop, tint: Palette.amber) { s.run(.keepAwake($0)) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        if model.awakeOthers.isEmpty {
            ShelfSub(s, "others", "Nothing else", status: "Only Gremlin, if it's on", symbol: "moon.zzz.fill", tint: Palette.sky, index: 1) {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfNote(text: "No other app is keeping the Mac awake right now. When one does, it's listed here.")
                    Spacer(minLength: 0)
                }
                .padding(13)
            }
        }
        ForEach(Array(model.awakeOthers.prefix(3).enumerated()), id: \.element) { index, name in
            ShelfSub(s, "other-\(name)", ShelfState.short(name), status: "Also keeping the Mac awake", symbol: "globe", tint: Palette.sky, index: index + 1) {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfNote(text: "It asked macOS to stay awake on its own. The Mac stays up while it does, even after Keep Awake ends.")
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        LiveDot(color: Palette.sky, size: 5).frame(width: 9, height: 9)
                        Text("Listed for as long as it holds on").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(13)
            }
        }
        ShelfSub(s, "restart", "After a restart", status: "Picks up where it left off", symbol: "arrow.clockwise", tint: Palette.iris,
                 index: 1 + max(1, min(3, model.awakeOthers.count))) {
            VStack(alignment: .leading, spacing: 12) {
                ShelfNote(text: "If Gremlin quits or restarts, Keep Awake comes back on until its time is up.")
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle().fill(Palette.iris).frame(width: 6, height: 6)
                    Text(model.awakeText).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .padding(13)
        }
    }
}

private struct ShelfDisplaysPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var displays: Displays
    private let tints = [Palette.iris, Palette.sky, Palette.grape, Palette.teal, Palette.pink]

    var body: some View {
        let now = DisplayHardware.snapshot(displays.live)
        let current = displays.current
        ShelfSub(s, "map", current?.title ?? "Now", status: "Now · \(now.count == 1 ? "1 display" : "\(now.count) displays")",
                 symbol: "display.2", tint: Palette.iris, width: 470,
                 footer: current.map { "Arranged as \($0.title)" } ?? "Not a saved layout. Save it to put it back later.") {
            ShelfScreenMap(screens: ShelfScreen.from(now), labels: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        ForEach(Array(displays.config.layouts.enumerated()), id: \.element.id) { index, layout in
            let tint = tints[index % tints.count]
            let on = current?.id == layout.id
            let fits = displays.fits(layout)
            ShelfSub(s, layout.id.uuidString, layout.title, status: on ? "In use" : fits ? "Saved" : "Not all connected",
                     symbol: on ? "checkmark" : "rectangle.3.group", tint: fits ? tint : Palette.slate, width: 210, index: index + 1) {
                VStack(alignment: .leading, spacing: 10) {
                    ShelfScreenMap(screens: ShelfScreen.from(layout.displays))
                        .frame(height: 70)
                        .opacity(fits ? 1 : 0.5)
                    if let note = displays.notes[layout.id] {
                        ShelfFixDetail(text: note, warn: true)
                    } else {
                        ShelfNote(text: detail(layout), size: 11.5)
                    }
                    Spacer(minLength: 0)
                    Button(on ? "Arranged" : displays.applying == layout.id ? "Arranging…" : "Arrange") { displays.apply(layout) }
                        .buttonStyle(ShelfPill(kind: on || !fits ? .soft : .tint(tint)))
                        .disabled(on || !fits || displays.applying != nil)
                }
                .padding(13)
            }
        }
        if displays.config.layouts.isEmpty {
            ShelfGhostCard(title: "Save a layout", detail: "Gremlin puts your displays back this way whenever they connect.",
                           symbol: "square.and.arrow.down", index: 1) { displays.saveCurrent() }
        }
    }

    private func detail(_ layout: DisplayLayout) -> String {
        let missing = displays.missing(layout)
        if !missing.isEmpty {
            return missing.count == layout.displays.count ? "Its displays aren't connected"
                : "\(ListFormatter.localizedString(byJoining: missing.map(\.display.name))) not connected"
        }
        let count = layout.displays.count
        return "\(count) \(count == 1 ? "display" : "displays")" + (layout.automatic ? " · applies when they connect" : "")
    }
}

private struct ShelfRestartPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    private let tints = [Palette.sky, Palette.teal, Palette.iris, Palette.grape, Palette.coral, Palette.amber, Palette.mint, Palette.pink, Palette.sky]

    var body: some View {
        ForEach(Array(Restart.items.enumerated()), id: \.offset) { index, item in
            let tint = tints[index % tints.count]
            let done = model.restarted.contains(index)
            ShelfSub(s, item.title, item.title, status: done ? "Restarted just now" : item.hint, symbol: item.symbol, tint: tint, width: 196, index: index) {
                VStack(spacing: 14) {
                    Image(systemName: done ? "checkmark" : item.symbol)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(done ? AnyShapeStyle(Palette.good) : AnyShapeStyle(ShelfMetrics.deep(tint).gradient))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 76, height: 76)
                        .background(ShelfMetrics.paperTint, in: Circle())
                        .padding(.top, 20)
                    Spacer(minLength: 0)
                    Button { s.run(.restart(index)) } label: {
                        Label("Restart", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShelfPill(kind: .tint(tint), height: 30))
                }
                .padding(13)
            }
        }
    }
}

private struct ShelfFixesPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        ForEach(Array(ShelfFix.all.enumerated()), id: \.element.id) { index, fix in
            let on = model.switches[fix.key] ?? false
            ShelfSub(s, fix.key, fix.title, status: on ? "On" : "Off", symbol: fix.symbol, tint: fix.tint, width: 290, index: index) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(fix.note).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    ShelfFixDetail(text: fix.detail(model), warn: fix.warns(model))
                    Spacer(minLength: 0)
                    HStack {
                        Text(on ? "Watching" : "Turned off").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        if fix.warns(model) {
                            Button("Allow") { ShelfSystem.openAccessibility(s) }.buttonStyle(ShelfPill(kind: .soft, height: 24))
                        }
                        ToggleSwitch(isOn: on, tint: fix.tint, small: true, label: fix.title) { s.run(.setSwitch(fix.key, !on)) }
                    }
                }
                .padding(14)
            }
        }
        ShelfGhostCard(title: "More fixes land here", detail: "Each new one gets a card and a switch.", symbol: "sparkles", index: 3)
    }
}

private struct ShelfIPadPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        let ipad = model.ipad
        let connected = ipad?.connected == true
        let name = ipad?.name ?? "iPad"
        ShelfSub(s, "ipad", name, status: ipad?.line.text ?? "Sidecar isn't available on this Mac", symbol: "ipad.landscape",
                 tint: Palette.teal, width: 470, footer: "With several iPads nearby, it picks the first one") {
            HStack(spacing: 20) {
                ShelfIPadArt(connected: connected).frame(width: 186, height: 126)
                VStack(alignment: .leading, spacing: 9) {
                    Text(connected ? "\(name) is a display" : "Use \(name) as a display")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                    ShelfNote(text: connected ? "Move windows onto it like any screen. Disconnect gives it back."
                                              : "Sidecar, one click away. It always takes the iPad.")
                    Spacer(minLength: 0)
                    if let ipad {
                        ShelfSidecarButton(s: s, ipad: ipad)
                    }
                }
            }
            .padding(18)
        }
        ShelfSub(s, "takes", "Takes it over", status: "From another Mac", symbol: "arrow.left.arrow.right", tint: Palette.sky, index: 1) {
            ShelfNote(text: "An iPad that's a display for another Mac switches over. A session this Mac is still holding is dropped and started fresh.")
                .padding(13)
        }
        ShelfSub(s, "calls", "Built on Sidecar", status: "Same as Control Center", symbol: "display", tint: Palette.grape, index: 2) {
            ShelfNote(text: "It uses the calls behind the Displays menu. If a macOS update changes them, the card hides instead of misbehaving.")
                .padding(13)
        }
    }
}

private struct ShelfUCPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    private let tints = [Palette.iris, Palette.teal, Palette.slate]

    private var targets: [(String, UniversalControlWatcher.Target)] {
        guard case .paired(let name, _) = model.pairing else { return [("This Mac", .local)] }
        return [("This Mac", .local), (name, .remote), ("Both", .both)]
    }

    var body: some View {
        let watcher = model.watcher
        ShelfSub(s, "status", watcher.isOn ? watcher.status : "The watcher is off", status: watcher.lastReset.isEmpty ? "No resets yet" : watcher.lastReset,
                 symbol: "macbook.and.ipad", tint: Palette.grape, width: 300) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Reset it when a device gives up").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    ToggleSwitch(isOn: watcher.isOn, tint: Palette.grape, small: true, label: "Universal Control Watcher") {
                        s.run(.setSwitch(AppSwitch.universalControlWatcher, !watcher.isOn))
                    }
                }
                ShelfNote(text: watcher.detail.isEmpty ? "If a reset doesn't bring it back, Gremlin tries again a little later." : watcher.detail, size: 12)
                    .lineLimit(3)
                Spacer(minLength: 0)
                ShelfSectionLabel(text: "Reset now")
                HStack(spacing: 6) {
                    ForEach(targets, id: \.0) { target in
                        Button(target.0) { s.run(.resetUniversalControl(target.1)) }
                            .buttonStyle(ShelfPill(kind: target.1 == .local ? .tint(Palette.grape) : .soft))
                    }
                }
            }
            .padding(14)
        }
        ForEach(Array(ShelfDevice.all(model).enumerated()), id: \.element.id) { index, device in
            ShelfSub(s, "device-\(device.id)", device.label == "This Mac" ? device.id : device.label, status: device.label == "This Mac" ? "This Mac" : device.detail,
                     symbol: device.symbol, tint: tints[index % tints.count], width: 214, index: index + 1) {
                VStack(spacing: 12) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 34, weight: .light))
                        .frame(width: 84, height: 84)
                        .background(ShelfMetrics.paperTint, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(device.ok && watcher.isOn ? Palette.good : Color.gray)
                                .frame(width: 16, height: 16)
                                .overlay { Circle().strokeBorder(ShelfMetrics.paper, lineWidth: 3) }
                                .offset(x: -4, y: 4)
                        }
                    HStack(spacing: 6) {
                        Circle().fill(device.ok ? Palette.good : Palette.bad).frame(width: 6, height: 6)
                        Text(device.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        ShelfPairingCard(s: s, model: model, index: ShelfDevice.all(model).count + 1)
    }
}

private struct ShelfPairingCard: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel
    let index: Int

    var body: some View {
        switch model.pairing {
        case .paired(let name, _):
            ShelfSub(s, "pair", "Paired with \(name)", status: "Either Mac can reset the other", symbol: "link", tint: Palette.mint, width: 240, index: index) {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfNote(text: "Paired Gremlins talk over the local network, so whichever Mac notices can get the other one to reset.")
                    Spacer(minLength: 0)
                    Button("Unpair") { s.run(.unpair) }.buttonStyle(ShelfPill(kind: .soft))
                }
                .padding(13)
            }
        case .pairing:
            ShelfSub(s, "pair", "Waiting for the other Mac", status: "Pairing", symbol: "link", tint: Palette.mint, width: 240, index: index) {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfNote(text: "Choose Pair Another Mac… there too, then compare the codes both Macs show.")
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        ShelfSpinner(tint: Palette.mint, size: 16, line: 2.5)
                        Button("Cancel") { s.run(.stopPairing) }.buttonStyle(ShelfPill(kind: .soft))
                    }
                }
                .padding(13)
            }
        case .unpaired:
            ShelfSub(s, "pair", "Not paired", status: "Pair to reset each other", symbol: "link", tint: Palette.mint, width: 240, index: index) {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfNote(text: "With Gremlin on both Macs, whichever one notices Universal Control giving up can reset the other.")
                    Spacer(minLength: 0)
                    Button("Pair Another Mac…") { s.run(.startPairing) }.buttonStyle(ShelfPill(kind: .tint(Palette.mint)))
                }
                .padding(13)
            }
        }
    }
}

private struct ShelfLinksPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var links: Links

    var body: some View {
        let today = ShelfLinks.today(links)
        let counts = ShelfLinks.counts(today)
        ShelfSub(s, "today", today.isEmpty ? "Default" : "Today", status: today.isEmpty ? "Where links open" : "By browser", symbol: "link",
                 tint: Palette.pink, footer: links.config.removeTracking ? "Tracking stripped on the way" : nil) {
            ShelfLinksBody(links: links, offerDefault: false)
        }
        ShelfSub(s, "rules", "Rules", status: "First match wins", symbol: "list.bullet", tint: Palette.iris, width: 320, index: 1,
                 footer: "Then apps like Zoom and Figma, then the default") {
            ShelfRulesList(links: links, s: s)
        }
        ShelfSub(s, "recent", "Recent", status: "Where links went", symbol: "clock.arrow.circlepath", tint: Palette.sky, width: 300, index: 2) {
            ShelfRecentLinks(links: links)
        }
        ForEach(Array(links.shownTargets.enumerated()), id: \.element.id) { index, target in
            let title = links.title(of: target)
            let count = counts[title] ?? 0
            let tint = ShelfLinks.tints[index % ShelfLinks.tints.count]
            let keys = links.pickerKeys(for: links.shownTargets)
            ShelfSub(s, "target-\(target.id)", ShelfState.short(title), status: target == links.primary ? "Default" : target.profileName.map { "\($0) profile" } ?? "In the picker",
                     symbol: target.isPrivate ? "eyeglasses" : "globe", tint: tint, width: 180, index: index + 3) {
                VStack(alignment: .leading, spacing: 4) {
                    if today.isEmpty {
                        Group {
                            if let icon = links.icon(of: target) { Image(nsImage: icon).resizable() } else { Image(systemName: "globe").resizable() }
                        }
                        .frame(width: 46, height: 46)
                        Spacer(minLength: 0)
                    } else {
                        Text("\(count)").font(.system(size: 38, weight: .bold, design: .rounded))
                        Text(count == 1 ? "link today" : "links today").font(.system(size: 12)).foregroundStyle(.secondary)
                        ProgressBar(progress: Double(count) / Double(max(1, today.count)), tint: tint)
                            .padding(.top, 12)
                        Spacer(minLength: 0)
                    }
                    if target != links.primary {
                        Button("Make default") { links.config.primary = target }.buttonStyle(ShelfPill(kind: .soft, height: 24))
                            .padding(.bottom, 6)
                    }
                    if let key = keys[target.id] {
                        HStack(spacing: 6) {
                            Keycap(text: key.uppercased(), small: true)
                            Text("in the picker").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct ShelfRulesList: View {
    @ObservedObject var links: Links
    @ObservedObject var s: ShelfState

    var body: some View {
        let rules = links.config.rules
        VStack(spacing: 0) {
            if rules.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ShelfNote(text: "No rules yet. A rule sends a site, or links from an app, to a browser of your choosing.")
                    Button("Add one in Gremlin") { s.openInGremlin(.links) }.buttonStyle(ShelfPill(kind: .soft))
                }
                .padding(.top, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(rules.prefix(5).enumerated()), id: \.element.id) { index, rule in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(ShelfMetrics.paperTint, in: Circle())
                    Text(Self.label(rule))
                        .font(.system(size: 11.5, design: rule.name.isEmpty ? .monospaced : .default))
                        .lineLimit(1)
                        .opacity(rule.isOn ? 1 : 0.5)
                    Spacer(minLength: 4)
                    Text(ShelfState.short(links.title(of: rule.target))).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.iris).lineLimit(1)
                }
                .frame(height: 30)
                if index < min(rules.count, 5) - 1 { Rectangle().fill(ShelfMetrics.hairline).frame(height: 1) }
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 4)
    }

    private static func label(_ rule: LinkRule) -> String {
        if !rule.name.isEmpty { return rule.name }
        if let matcher = rule.matchers.first { return matcher.value }
        return rule.sources.isEmpty ? "Rule" : "From \(rule.sources.joined(separator: ", "))"
    }
}

private struct ShelfRecentLinks: View {
    @ObservedObject var links: Links

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if links.recent.isEmpty {
                ShelfNote(text: links.config.keepHistory ? "Links you open show up here, with where they went and why."
                                                          : "Gremlin forgets links unless you ask it to keep them.")
                Spacer(minLength: 0)
                HStack {
                    Text("Keep history").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    ToggleSwitch(isOn: links.config.keepHistory, tint: Palette.sky, small: true, label: "Keep history") {
                        links.setKeepHistory(!links.config.keepHistory)
                    }
                }
            } else {
                ForEach(links.recent.prefix(3)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.trimmed(event.opened)).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .bold))
                            Text(ShelfState.short(event.target)).lineLimit(1)
                            Text("· \(event.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))").foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.sky)
                    }
                    .help(event.why)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(13)
    }

    private static func trimmed(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "www.", with: "")
    }
}

private struct ShelfDrivesPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var drives: Drives

    var body: some View {
        ForEach(Array(drives.config.drives.enumerated()), id: \.element.id) { index, drive in
            let status = drives.status(of: drive)
            ShelfSub(s, drive.id.uuidString, drive.title, status: status.text, symbol: "externaldrive.fill",
                     tint: status.mounted ? Palette.lime : Palette.slate, index: index,
                     footer: drives.mountPoint(of: drive).map { "~/" + $0.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "") } ?? "~/Drives/\(drive.title)") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: status.mounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill.badge.minus")
                            .font(.system(size: 24))
                            .foregroundStyle(status.mounted ? AnyShapeStyle(ShelfMetrics.deep(Palette.lime).gradient) : AnyShapeStyle(.secondary))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 46, height: 46)
                            .background(ShelfMetrics.paperTint, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drive.place).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(status.problem.map(ShelfDrive.firstLine) ?? "SFTP over ssh")
                                .font(.system(size: 11))
                                .foregroundStyle(status.problem != nil ? AnyShapeStyle(Ink.amber) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, 4)
                    ShelfSettingRow(title: "Mount when Gremlin starts", height: 32) {
                        ToggleSwitch(isOn: drive.mountAtLaunch, tint: Palette.lime, small: true, label: "Mount when Gremlin starts") {
                            drives.update(drive.id) { $0.mountAtLaunch.toggle() }
                        }
                    }
                    ShelfSettingRow(title: "Read only", divider: false, height: 32) {
                        ToggleSwitch(isOn: drive.readOnly, tint: Palette.lime, small: true, label: "Read only") {
                            drives.update(drive.id) { $0.readOnly.toggle() }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        switch status.phase {
                        case .mounted:
                            Button("Open") { s.close(); drives.reveal(drive) }.buttonStyle(ShelfPill(kind: .tint(Palette.lime)))
                            Button("Eject") { drives.eject(drive) }.buttonStyle(ShelfPill(kind: .soft))
                        case .connecting:
                            ShelfSpinner(tint: ShelfMetrics.deep(Palette.lime), size: 16, line: 2.5)
                            Button("Cancel") { drives.cancel(drive) }.buttonStyle(ShelfPill(kind: .soft))
                        case .ejecting:
                            ShelfSpinner(tint: .secondary, size: 16, line: 2.5)
                            Text("Ejecting…").font(.system(size: 12)).foregroundStyle(.secondary)
                        case .off:
                            Button("Mount") { drives.mount(drive, reveal: false) }.buttonStyle(ShelfPill(kind: .tint(Palette.lime)))
                        }
                    }
                }
                .padding(13)
            }
        }
        ShelfGhostCard(title: "Add a drive", detail: "Any host in ~/.ssh/config, or a new one.", symbol: "plus",
                       index: drives.config.drives.count) { s.openInGremlin(.drives) }
    }
}

private struct ShelfSettingsPage: View {
    @ObservedObject var s: ShelfState
    @ObservedObject var model: MenuModel

    var body: some View {
        ShelfSub(s, "general", "General", status: "Starts with your Mac", symbol: "gearshape.fill", tint: Palette.slate, footer: "Saved as you change them") {
            VStack(spacing: 0) {
                ShelfSettingRow(title: "Open at login") {
                    ToggleSwitch(isOn: model.login, tint: Palette.accent, small: true, label: "Open at login") { s.run(.setLogin(!model.login)) }
                }
                ShelfSettingRow(title: "Offer to record calls") { ShelfSwitchFor(s: s, model: model, key: AppSwitch.offerToRecordCalls) }
                ShelfSettingRow(title: "Auto-fix lost focus", divider: false) { ShelfSwitchFor(s: s, model: model, key: AppSwitch.autoFixFocus) }
            }
            .padding(.horizontal, 13)
            .padding(.top, 6)
        }
        ShelfSub(s, "transcripts", "Transcripts", status: "Written on this Mac", symbol: "text.bubble.fill", tint: Palette.coral, index: 1) {
            VStack(spacing: 0) {
                ShelfSettingRow(title: "Language") { ShelfLanguageMenu(s: s, model: model) }
                ShelfSettingRow(title: "Saved in", divider: false) {
                    Button { s.run(.showRecordings, closing: true) } label: {
                        Text("Movies › Meetings").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(ShelfPress())
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 6)
        }
        ShelfSub(s, "keys", "Shortcuts", status: "Work in any app", symbol: "keyboard", tint: Palette.sky, width: 290, index: 2) {
            VStack(spacing: 0) {
                ShelfKeyRow(title: "Record the screen", keys: "⌃⌥⌘R")
                ShelfKeyRow(title: "Record audio", keys: "⌃⌥⌘A")
                ShelfKeyRow(title: "Grab text", keys: "⇧⌘1")
                ShelfKeyRow(title: "Connect the iPad", keys: "⌃⌥⌘S")
                ShelfKeyRow(title: "Show the shelf", keys: "⌃⌥⌘G", divider: false)
            }
            .padding(.horizontal, 13)
            .padding(.top, 4)
        }
        ShelfSub(s, "about", "Gremlin", status: "Version \(ShelfState.version)", symbol: "pawprint.fill", tint: Palette.indigoLift, index: 3) {
            VStack(spacing: 10) {
                AppIconView(size: 72).padding(.top, 10)
                Text("Runs as you and never asks for an admin password.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
                Button("Quit Gremlin") { s.run(.quit) }
                    .buttonStyle(ShelfPill(kind: .soft))
                    .padding(.bottom, 13)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ShelfKeyRow: View {
    let title: String
    let keys: String
    var divider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Keycap(text: keys, small: true)
            }
            .frame(height: 33)
            if divider { Rectangle().fill(ShelfMetrics.hairline).frame(height: 1) }
        }
    }
}

// MARK: - Display map

private struct ShelfScreen: Identifiable {
    let id: String
    let name: String
    let frame: CGRect
    let mode: String
    let main: Bool
    let mirrored: Bool

    /// Mirrors share their source's spot, so they show as a badge on it instead of a tile of their own.
    static func from(_ displays: [SavedDisplay]) -> [ShelfScreen] {
        displays.enumerated().filter { $0.element.mirrors == nil }.map { index, display in
            ShelfScreen(id: "\(index)-\(display.display.key)", name: display.display.builtIn ? "Built-in" : display.display.name,
                        frame: display.frame, mode: display.mode.text, main: display.main,
                        mirrored: displays.contains { $0.mirrors == index })
        }
    }
}

private struct ShelfScreenMap: View {
    let screens: [ShelfScreen]
    var labels = false

    var body: some View {
        GeometryReader { g in
            let box = screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let pad: CGFloat = 4
            let scale = box.isNull ? 1 : min((g.size.width - pad * 2) / box.width, (g.size.height - pad * 2) / box.height)
            let ox = box.isNull ? 0 : (g.size.width - box.width * scale) / 2
            let oy = box.isNull ? 0 : (g.size.height - box.height * scale) / 2
            ZStack {
                ForEach(screens) { screen in
                    let r = CGRect(x: ox + (screen.frame.minX - box.minX) * scale, y: oy + (screen.frame.minY - box.minY) * scale,
                                   width: screen.frame.width * scale, height: screen.frame.height * scale)
                    ShelfScreenTile(screen: screen, labels: labels)
                        .frame(width: max(4, r.width - 4), height: max(4, r.height - 4))
                        .position(x: r.midX, y: r.midY)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
    }
}

private struct ShelfScreenTile: View {
    let screen: ShelfScreen
    let labels: Bool

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: labels ? 7 : 4, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: labels ? 4.5 : 2.5, style: .continuous)
        outer.fill(Color(hex: 0x1A1530))
            .overlay {
                inner
                    .fill(LinearGradient(colors: screen.main ? [Palette.holoMint, Palette.holoSky, Palette.holoLilac]
                                                             : [Palette.holoLilac, Palette.holoPink, Palette.holoPeach],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(alignment: .top) {
                        if screen.main { Rectangle().fill(.white.opacity(0.85)).frame(height: labels ? 5 : 2.5) }
                    }
                    .clipShape(inner)
                    .padding(labels ? 3 : 2)
            }
            .overlay {
                if labels {
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            if screen.mirrored { Image(systemName: "rectangle.on.rectangle").font(.system(size: 9, weight: .bold)) }
                            Text(screen.name).font(.system(size: 11, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        Text(screen.mode).font(.system(size: 9, weight: .medium)).opacity(0.75).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color(hex: 0x1E1446))
                    .minimumScaleFactor(0.6)
                    .padding(4)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
    }
}

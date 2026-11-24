import AppKit
import SwiftUI

// Meetings in the window: recording from the header band, the recordings in ~/Movies/Meetings grouped by day, and
// the picked one's summary, decisions, action items and transcript.

struct MeetingsScreen: View {
    @EnvironmentObject private var model: MenuModel
    @EnvironmentObject private var recordings: Recordings
    @StateObject private var picked = Box<MeetingPick?>(nil)
    @StateObject private var checked = Box<[URL: Set<Int>]>([:])

    var body: some View {
        let items = visibleItems
        let pick = resolved(picked.value, in: items)
        ScreenCard(module: .meetings, scrolls: false) {
            MeetingRecordControls()
        } content: {
            VStack(spacing: 14) {
                ForEach(model.banners.filter { $0.kind == .problem }) { banner in
                    MeetingProblemBanner(banner: banner, perform: model.perform)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                HStack(alignment: .top, spacing: 16) {
                    MeetingList(items: items, live: model.recording, progress: model.notesProgress, picked: pick) { new in
                        withAnimation(Motion.snappy) { picked.value = new }
                    }
                    .frame(width: 266)
                    detail(pick, items: items)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .animation(Motion.snappy, value: model.banners)
        }
        .onAppear { recordings.refresh() }
        .onChange(of: model.recording != nil) { _, _ in
            picked.value = nil
            recordings.refresh()
        }
        // Each step of the pipeline changes what's in the folder: a transcript, then a summary, then a smaller copy.
        .onChange(of: model.notesProgress?.title) { _, _ in recordings.refresh() }
    }

    /// The folder being recorded into shows as the live row instead.
    private var visibleItems: [Recordings.Item] {
        guard let live = model.recording else { return recordings.items }
        return recordings.items.filter { item in
            guard let date = item.date, item.uncompressed, !item.transcribed else { return true }
            return abs(date.timeIntervalSince(live.started)) > 90
        }
    }

    private func resolved(_ pick: MeetingPick?, in items: [Recordings.Item]) -> MeetingPick? {
        switch pick {
        case .live where model.recording != nil: return .live
        case .folder(let url) where items.contains { $0.folder == url }: return pick
        default: break
        }
        if model.recording != nil { return .live }
        return items.first.map { .folder($0.folder) }
    }

    @ViewBuilder private func detail(_ pick: MeetingPick?, items: [Recordings.Item]) -> some View {
        switch pick {
        case .live:
            if let recording = model.recording {
                MeetingLiveDetail(recording: recording) { model.perform(.stopRecording) }
                    .transition(.opacity)
            }
        case .folder(let url):
            if let item = items.first(where: { $0.folder == url }) {
                MeetingDetail(item: item, state: MeetingState(item, model.notesProgress), notes: recordings.notes(for: item),
                              checked: checked.value[url] ?? []) { index in
                    var done = checked.value[url] ?? []
                    if done.contains(index) { done.remove(index) } else { done.insert(index) }
                    checked.value[url] = done
                }
                .id(url)
                .transition(.opacity)
            }
        case nil:
            if recordings.loaded { MeetingEmpty() }
        }
    }
}

// MARK: - State

private enum MeetingPick: Hashable {
    case live
    case folder(URL)
}

private enum MeetingState: Equatable {
    enum Work { case compressing, transcribing, summarizing, preparing }

    case working(Work, percent: Int?, title: String, note: String)
    case waiting
    case ready
    case noTranscript

    init(_ item: Recordings.Item, _ progress: MeetingNotes.Progress?) {
        if let progress, progress.folder == item.folder {
            let title = progress.title
            let work: Work = title.hasPrefix("Compressing") ? .compressing
                : title.hasPrefix("Transcribing") ? .transcribing
                : title.hasPrefix("Summarizing") ? .summarizing : .preparing
            self = .working(work, percent: Recordings.percent(in: progress.detail), title: title,
                            note: progress.detail.replacing(#/^\d+%( · )?/#, with: ""))
        } else if item.transcribed {
            self = .ready
        } else if item.uncompressed {
            self = .waiting
        } else {
            self = .noTranscript
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var percent: Int? {
        if case .working(_, let percent, _, _) = self { return percent }
        return nil
    }

    var tint: Color {
        switch self {
        case .working(.compressing, _, _, _): Palette.amber
        case .working(.summarizing, _, _, _): Palette.grape
        case .working: Palette.iris
        case .waiting, .noTranscript: Palette.slate
        case .ready: Palette.good
        }
    }

    var ink: Color {
        switch self {
        case .working(.compressing, _, _, _): Ink.amber
        case .working(.summarizing, _, _, _): Ink.grape
        case .working: Ink.iris
        case .waiting, .noTranscript: .secondary
        case .ready: Ink.mint
        }
    }

    var fill: [Color] {
        switch self {
        case .working(.compressing, _, _, _): Module.keepAwake.fill
        default: [tint.mixed(with: .white, 0.2), tint, tint.mixed(with: .black, 0.16)]
        }
    }

    var symbol: String {
        switch self {
        case .working(.compressing, _, _, _): "arrow.down.right.and.arrow.up.left"
        case .working(.transcribing, _, _, _): "text.bubble.fill"
        case .working(.summarizing, _, _, _): "sparkles"
        case .working: "arrow.down.circle.fill"
        case .waiting: "hourglass"
        case .noTranscript: "text.bubble"
        case .ready: "checkmark"
        }
    }

    var verb: String {
        switch self {
        case .working(.compressing, _, _, _): "Compressing"
        case .working(.transcribing, _, _, _): "Transcribing"
        case .working(.summarizing, _, _, _): "Summarizing"
        case .working: "Getting ready"
        case .waiting: "Waiting"
        case .ready: "Transcript ready"
        case .noTranscript: "No transcript"
        }
    }

    var label: String {
        percent.map { "\(verb) \($0)%" } ?? verb
    }
}

private enum MeetingDay: Int, CaseIterable {
    case today, week, earlier

    init(_ date: Date?, now: Date) {
        let calendar = Calendar.current
        guard let date else { self = .earlier; return }
        if calendar.isDateInToday(date) || date > now { self = .today; return }
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        self = date >= weekAgo ? .week : .earlier
    }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "This week"
        case .earlier: "Earlier"
        }
    }

    func text(for date: Date) -> String {
        switch self {
        case .today: return date.formatted(date: .omitted, time: .shortened)
        case .week: return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .earlier:
            let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            return thisYear ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                : date.formatted(.dateTime.year().month(.abbreviated).day())
        }
    }
}

private enum MeetingFormat {
    static func length(_ minutes: Int?) -> String? {
        guard let minutes else { return nil }
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func kind(_ item: Recordings.Item) -> String {
        item.audioOnly ? "Audio only" : "Screen and audio"
    }

    static func people(_ names: [String]) -> String {
        names.count <= 3 ? ListFormatter.localizedString(byJoining: names)
            : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
    }

    /// "0:01:30" reads better as "1:30" when the meeting is under an hour.
    static func time(_ stamp: String) -> String {
        stamp.hasPrefix("0:") ? String(stamp.dropFirst(2)).replacing(#/^0(\d)/#) { $0.1 } : stamp
    }

    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    static var folderPath: String {
        (Meetings.folder.path as NSString).abbreviatingWithTildeInPath
    }
}

private enum MeetingFiles {
    static func show(_ item: Recordings.Item) { NSWorkspace.shared.open(item.folder) }

    static func transcript(_ item: Recordings.Item) -> URL? {
        FileManager.default.fileExists(atPath: item.transcript.path) ? item.transcript : nil
    }

    static func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// An action item, with its owner split off when claude named one, as in "**Ali:** Send the doc" or "Send the doc (Ali)".
private struct MeetingTask {
    let text: String
    let owner: String?

    init(_ raw: String) {
        if let match = raw.firstMatch(of: #/^\*\*([^*]+?):\*\*\s*(.+)$/#) ?? raw.firstMatch(of: #/^\*\*([^*]+?)\*\*:\s*(.+)$/#)
            ?? raw.firstMatch(of: #/^([A-Z][\w'’.-]*(?: [A-Z][\w'’.-]*){0,2}):\s+(.+)$/#) {
            owner = String(match.1)
            text = String(match.2)
        } else if let match = raw.firstMatch(of: #/^(.+?)\s+\(([A-Z][\w'’.-]*(?: [A-Z][\w'’.-]*){0,2})\)\.?$/#) {
            owner = String(match.2)
            text = String(match.1)
        } else {
            owner = nil
            text = raw
        }
    }
}

// MARK: - Header

private struct MeetingRecordControls: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        Group {
            if let recording = model.recording {
                MeetingLiveCapsule(recording: recording) { model.perform(.stopRecording) }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if model.starting {
                HStack(spacing: 9) {
                    MeetingSpinner(color: .white, size: 18, line: 2.5)
                    Text("Starting…").font(.system(size: 14.5, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(.white.opacity(0.2)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .transition(.opacity)
            } else {
                ViewThatFits(in: .horizontal) {
                    buttons(screen: "Record screen", audio: "Audio only", keys: true)
                    buttons(screen: "Screen", audio: "Audio", keys: true)
                    buttons(screen: "Screen", audio: "Audio", keys: false)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.snappy, value: model.recording != nil)
        .animation(Motion.snappy, value: model.starting)
    }

    private func buttons(screen: String, audio: String, keys: Bool) -> some View {
        HStack(spacing: 10) {
            MeetingRecordButton(title: screen, symbol: "record.circle.fill", keys: keys ? "⌃⌥⌘R" : nil, solid: true) {
                model.perform(.record(audioOnly: false))
            }
            .help("Record the screen the pointer is on, with all sound and your mic  ⌃⌥⌘R")
            MeetingRecordButton(title: audio, symbol: "waveform", keys: keys ? "⌃⌥⌘A" : nil, solid: false) {
                model.perform(.record(audioOnly: true))
            }
            .help("Record just the two sides of the call  ⌃⌥⌘A")
        }
        .fixedSize()
    }
}

private struct MeetingRecordButton: View {
    let title: String
    let symbol: String
    let keys: String?
    let solid: Bool
    let action: () -> Void

    private static let ink = Palette.coral.mixed(with: .black, 0.1)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                Text(title).font(.system(size: 14.5, weight: .semibold, design: .rounded))
                if let keys {
                    Text(keys)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .frame(height: 19)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(solid ? Palette.coral.opacity(0.13) : .white.opacity(0.2)))
                        .padding(.leading, 4)
                }
            }
            .foregroundStyle(solid ? Self.ink : .white)
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(shape.fill(solid ? Color.white : Color.white.opacity(0.2)))
            .overlay(shape.strokeBorder(.white.opacity(solid ? 0 : 0.3), lineWidth: 0.5))
            .shadow(color: .black.opacity(solid ? 0.12 : 0), radius: 4, y: 2)
            .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .hoverLift(1.03)
    }
}

private struct MeetingLiveCapsule: View {
    let recording: MenuModel.Recording
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            LiveDot(color: .white, size: 8)
            VStack(alignment: .leading, spacing: 0) {
                MeetingElapsed(started: recording.started)
                    .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                Text(recording.audioOnly ? "Audio only" : "Screen and audio")
                    .font(.system(size: 11.5, weight: .medium))
                    .opacity(0.85)
            }
            SoundBars(live: recording.hearing, color: .white, count: 9, width: 3.5, height: 26)
                .padding(.horizontal, 2)
            Button(action: stop) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Palette.coral).frame(width: 14, height: 14)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
            .buttonStyle(PressStyle())
            .help("Stop recording  ⌃⌥⌘R")
            .accessibilityLabel("Stop recording")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 50)
        .background(Capsule().fill(.black.opacity(0.18)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

private struct MeetingElapsed: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { _ in
            Text(Meetings.elapsed(since: started))
        }
    }
}

private struct MeetingProblemBanner: View {
    let banner: MenuModel.Banner
    let perform: (MenuModel.Action) -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: banner.symbol, tint: Palette.warn, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.system(size: 13.5, weight: .semibold))
                Text(banner.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let title = banner.button, let action = banner.action {
                Button(title) { perform(action) }.buttonStyle(CapsuleButton(tint: Palette.warn))
            }
            if let dismiss = banner.dismiss {
                Button { perform(dismiss) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.well2))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PaperSurface(tint: Palette.warn, radius: 18))
    }
}

// MARK: - List

private struct MeetingList: View {
    let items: [Recordings.Item]
    let live: MenuModel.Recording?
    let progress: MeetingNotes.Progress?
    let picked: MeetingPick?
    let pick: (MeetingPick) -> Void

    private var sections: [(day: MeetingDay, items: [Recordings.Item])] {
        let now = Date()
        let byDay = Dictionary(grouping: items) { MeetingDay($0.date, now: now) }
        return MeetingDay.allCases.compactMap { day in
            let items = byDay[day] ?? []
            return items.isEmpty && !(day == .today && live != nil) ? nil : (day, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("Recordings").font(.system(size: 15, weight: .bold, design: .rounded))
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Palette.well2))
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty && live == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing here yet").font(.system(size: 13, weight: .semibold))
                            Text("Each recording gets its own folder, with the transcript next to it.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                    }
                    ForEach(sections, id: \.day) { section in
                        Text(section.day.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        if section.day == .today, let live {
                            MeetingLiveRow(recording: live, selected: picked == .live) { pick(.live) }
                        }
                        ForEach(section.items) { item in
                            MeetingRow(item: item, state: MeetingState(item, progress), day: section.day,
                                       selected: picked == .folder(item.folder)) { pick(.folder(item.folder)) }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            .modifier(MeetingFade())
            MeetingSettings().padding(.top, 4)
            MeetingFooter(bytes: items.reduce(0) { $0 + $1.bytes }).padding(.top, 10)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
    }
}

private struct MeetingRowIcon: View {
    let symbol: String
    let selected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Palette.coral)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Palette.coral.gradient) : AnyShapeStyle(Palette.coral.opacity(0.14))))
            .shadow(color: selected ? Palette.coral.opacity(0.35) : .clear, radius: 3, y: 1.5)
    }
}

private struct MeetingRowBackground: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if selected {
            shape.fill(Palette.page).shadow(color: Palette.shadow, radius: 6, y: 2)
        } else if hovering {
            shape.fill(Palette.well2.opacity(0.6))
        }
    }
}

private struct MeetingRow: View {
    let item: Recordings.Item
    let state: MeetingState
    let day: MeetingDay
    let selected: Bool
    let action: () -> Void
    @StateObject private var hovering = Box(false)

    private var subtitle: String {
        [item.date.map(day.text(for:)), MeetingFormat.length(item.minutes)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MeetingRowIcon(symbol: item.audioOnly ? "waveform" : "play.rectangle.fill", selected: selected)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        trailing
                    }
                    if state.isWorking {
                        HStack(spacing: 8) {
                            Text(state.verb).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(state.ink).fixedSize()
                            MeetingBar(progress: state.percent.map { Double($0) / 100 }, tint: state.tint)
                        }
                    } else {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(8)
            .background(MeetingRowBackground(selected: selected, hovering: hovering.value))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .animation(Motion.snappy, value: hovering.value)
        .contextMenu {
            Button("Show in Finder") { MeetingFiles.show(item) }
            if let transcript = MeetingFiles.transcript(item) { Button("Open transcript.md") { MeetingFiles.open(transcript) } }
            if let media = item.media { Button("Play Recording") { MeetingFiles.open(media) } }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .working:
            if let percent = state.percent {
                Text("\(percent)%").font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(state.ink)
            } else {
                MeetingSpinner(color: state.tint, size: 13, line: 2)
            }
        case .ready:
            if item.actionItems > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "checklist").font(.system(size: 10, weight: .bold))
                    Text("\(item.actionItems)").font(.system(size: 11.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.secondary)
                .help("\(item.actionItems) action item\(item.actionItems == 1 ? "" : "s")")
            }
        case .waiting, .noTranscript:
            Text(state.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

private struct MeetingLiveRow: View {
    let recording: MenuModel.Recording
    let selected: Bool
    let action: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.coral.gradient)
                    LiveDot(color: .white, size: 7)
                }
                .frame(width: 32, height: 32)
                .shadow(color: Palette.coral.opacity(0.35), radius: 3, y: 1.5)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Recording now").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        SoundBars(live: recording.hearing, color: Palette.coral, count: 5, width: 2.5, height: 13)
                    }
                    HStack(spacing: 0) {
                        MeetingElapsed(started: recording.started).monospacedDigit()
                        Text(" · " + (recording.audioOnly ? "Audio only" : "Screen and audio"))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .padding(8)
            .background(MeetingRowBackground(selected: selected, hovering: hovering.value))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

/// A progress bar, or a sweep while there's no percentage to show.
private struct MeetingBar: View {
    let progress: Double?
    let tint: Color

    var body: some View {
        if let progress {
            ProgressBar(progress: progress, tint: tint, track: tint.opacity(0.18), height: 5)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.18))
                        Capsule().fill(tint.gradient)
                            .frame(width: geo.size.width * 0.32)
                            .offset(x: geo.size.width * 1.32 * t - geo.size.width * 0.32)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 5)
        }
    }
}

private struct MeetingSettings: View {
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        let offer = model.switches[AppSwitch.offerToRecordCalls] ?? false
        let language = MenuModel.languages.first { $0.code == model.language }?.name ?? model.language ?? "Automatic"
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                IconTile(symbol: "phone.fill", tint: Palette.mint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Offer to record calls").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text("Asks when a call starts").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                ToggleSwitch(isOn: offer, small: true, label: "Offer to record calls") {
                    model.perform(.setSwitch(AppSwitch.offerToRecordCalls, !offer))
                }
            }
            HStack(spacing: 10) {
                IconTile(symbol: "character.bubble.fill", tint: Palette.iris, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcript language").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Menu {
                        ForEach(MenuModel.languages, id: \.name) { option in
                            Button { model.perform(.setLanguage(option.code)) } label: {
                                if option.code == model.language { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(language)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.iris)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(model.language == nil ? "whisper detects the language" : "whisper assumes this language")
                }
                Spacer(minLength: 0)
            }
            MeetingSyncRow()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.page))
    }
}

private struct MeetingSyncRow: View {
    @EnvironmentObject private var model: MenuModel
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        let sync = model.sync
        HStack(spacing: 10) {
            IconTile(symbol: "arrow.triangle.2.circlepath", tint: sync.connected ? Palette.sky : Palette.slate, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Google Drive").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(sync.connected && sync.problem != nil && !sync.syncing ? "Couldn't sync" : sync.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(sync.problem != nil && !sync.syncing ? AnyShapeStyle(Ink.coral) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(sync.problem ?? sync.summary)
            Spacer(minLength: 6)
            if sync.syncing {
                DevicesParts.Spinner(tint: Palette.sky, size: 14)
            } else if sync.connected {
                Button { model.perform(.syncMeetings) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.sky)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sync now")
            } else {
                Button { navigator.go(.settings) } label: {
                    HStack(spacing: 3) {
                        Text("Set up")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Ink.sky)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sync meetings with Google Drive")
            }
        }
    }
}

private struct MeetingFooter: View {
    let bytes: Int64
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.perform(.showRecordings) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Palette.sky)
                    Text(MeetingFormat.folderPath)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(PressStyle())
            .help("Show in Finder")
            Spacer(minLength: 6)
            if bytes > 0 {
                Text(MeetingFormat.size(bytes)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Detail

private struct MeetingDetail: View {
    let item: Recordings.Item
    let state: MeetingState
    let notes: Recordings.Notes?
    let checked: Set<Int>
    let toggle: (Int) -> Void
    @EnvironmentObject private var model: MenuModel
    /// Once the transcript has come into view, the jump button stays out of the way.
    @StateObject private var reachedTranscript = Box(false)

    private var lines: [Recordings.Notes.Line] { notes?.lines ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MeetingDetailHeader(item: item, state: state)
            if state != .ready {
                MeetingStatusTile(state: state, failure: notes?.failure)
            }
            GeometryReader { geo in
                if geo.size.width >= 700 {
                    HStack(alignment: .top, spacing: 14) {
                        ScrollView {
                            VStack(spacing: 14) { panels }.padding(.bottom, 18)
                        }
                        .scrollIndicators(.never)
                        .modifier(MeetingFade())
                        if hasTranscript { transcriptColumn.frame(width: min(400, geo.size.width * 0.42)) }
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                VStack(spacing: 14) { panels }.padding(.bottom, hasTranscript ? 14 : 0)
                                if hasTranscript { transcriptRows }
                            }
                            .padding(.bottom, 18)
                        }
                        .scrollIndicators(.never)
                        .modifier(MeetingFade())
                        .overlay(alignment: .bottomTrailing) {
                            if !lines.isEmpty && !reachedTranscript.value {
                                Button {
                                    withAnimation(Motion.zoom) { proxy.scrollTo(MeetingDetail.transcriptID, anchor: .top) }
                                } label: {
                                    Label("Transcript", systemImage: "arrow.down")
                                }
                                .buttonStyle(CapsuleButton(tint: Palette.coral))
                                .shadow(color: Palette.coral.opacity(0.3), radius: 8, y: 3)
                                .padding(.trailing, 14)
                                .padding(.bottom, 16)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                            }
                        }
                        .animation(Motion.snappy, value: reachedTranscript.value)
                    }
                }
            }
        }
    }

    private var transcribing: Bool {
        if case .working(let work, _, _, _) = state { return work == .transcribing || work == .preparing }
        return state == .waiting
    }

    /// Whether there's a transcript to show, or one on its way.
    private var hasTranscript: Bool {
        item.transcribed || transcribing
    }

    @ViewBuilder private var panels: some View {
        if let notes, !notes.summary.isEmpty {
            Well("Summary", trailing: "by Claude") {
                Text(MeetingFormat.inline(notes.summary))
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if case .working(.summarizing, _, _, _) = state {
            Well("Summary") { MeetingSkeleton(lines: [1, 0.94, 0.6]) }
        } else if item.transcribed {
            Well("Summary") {
                Text(model.claudeLoggedOut ? "No summary yet, because Claude Code is logged out. Log in, and Gremlin writes it with the decisions and action items."
                     : MeetingNotes.claude == nil ? "No summary yet. With the Claude Code CLI installed, Gremlin writes one, with decisions and action items."
                     : "No summary yet. Claude Code didn't write one; try again.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.claudeLoggedOut {
                    Button("Log In to Claude Code") { model.perform(.logInToClaude) }
                        .buttonStyle(CapsuleButton(tint: Palette.coral))
                        .help("Opens Terminal on claude auth login")
                } else if MeetingNotes.claude != nil {
                    Button("Summarize") { model.perform(.summarize(item.folder)) }
                        .buttonStyle(CapsuleButton(tint: Palette.coral))
                }
            }
        } else if transcribing {
            Well("Summary") { MeetingSkeleton(lines: [1, 0.94, 0.6]) }
            Well("Action items") { MeetingSkeleton(lines: [0.7, 0.55, 0.8], dots: true) }
        }
        if let notes, !notes.decisions.isEmpty {
            Well("Decisions", trailing: "\(notes.decisions.count)") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(notes.decisions.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundStyle(Palette.mint)
                            Text(MeetingFormat.inline(notes.decisions[index]))
                                .font(.system(size: 13))
                                .lineSpacing(1.5)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        if let notes, !notes.actionItems.isEmpty {
            let done = checked.intersection(notes.actionItems.indices).count
            Well("Action items", trailing: done == 0 ? "\(notes.actionItems.count)" : "\(done) of \(notes.actionItems.count) done") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(notes.actionItems.indices, id: \.self) { index in
                        MeetingTaskRow(task: MeetingTask(notes.actionItems[index]), done: checked.contains(index)) { toggle(index) }
                    }
                }
            }
        }
    }

    private var transcriptHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Transcript").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !lines.isEmpty {
                Text("Me is your mic, Them is the call").font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var transcriptPlaceholder: some View {
        if item.transcribed {
            Text("Nobody said anything the transcriber could pick up.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if transcribing {
            VStack(spacing: 12) {
                ForEach([0.75, 0.6, 0.8, 0.5].indices, id: \.self) { index in
                    MeetingSkeleton(lines: [[0.75, 0.6, 0.8, 0.5][index]], height: 30)
                        .environment(\.layoutDirection, index.isMultiple(of: 2) ? .leftToRight : .rightToLeft)
                }
            }
        }
    }

    private static let transcriptID = "transcript"

    // Each row draws its own slice of the panel, so a long transcript stays lazy inside the one scroll view.
    @ViewBuilder private var transcriptRows: some View {
        transcriptHeader
            .id(Self.transcriptID)
            .onAppear { reachedTranscript.value = true }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, lines.isEmpty ? 12 : 8)
            .background(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous).fill(Palette.well))
        if lines.isEmpty {
            transcriptPlaceholder
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.well)
        }
        ForEach(lines) { line in
            MeetingBubble(line: line, inset: 64)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Palette.well)
        }
        Color.clear.frame(height: 14)
            .frame(maxWidth: .infinity)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous).fill(Palette.well))
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            transcriptHeader.padding(.horizontal, 16).padding(.top, 16)
            if lines.isEmpty {
                transcriptPlaceholder.padding(.horizontal, 16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(lines) { MeetingBubble(line: $0, inset: 26) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .modifier(MeetingFade())
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.well))
    }
}

private struct MeetingDetailHeader: View {
    let item: Recordings.Item
    let state: MeetingState

    private var meta: String {
        [item.date.map { $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()) },
         MeetingFormat.length(item.minutes), MeetingFormat.kind(item), item.bytes > 0 ? MeetingFormat.size(item.bytes) : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .textSelection(.enabled)
                chip.fixedSize()
            }
            Text(meta).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    people(MeetingFormat.people(item.people))
                    Spacer(minLength: 0)
                    buttons
                }
                HStack(spacing: 10) {
                    people(item.people.count == 1 ? item.people[0] : "\(item.people.count) people")
                    Spacer(minLength: 0)
                    buttons
                }
                VStack(alignment: .leading, spacing: 10) {
                    people(MeetingFormat.people(item.people))
                    buttons
                }
            }
            .padding(.top, 2)
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            if state == .ready { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            Text(state.label).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(state.ink)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(state.tint.opacity(0.16)))
    }

    @ViewBuilder private func people(_ names: String) -> some View {
        if !item.people.isEmpty {
            HStack(spacing: 8) {
                MeetingFaces(names: item.people)
                Text(names)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(ListFormatter.localizedString(byJoining: item.people))
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { MeetingFiles.show(item) } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(CapsuleButton(tint: Palette.slate, neutral: true))
            if let transcript = MeetingFiles.transcript(item) {
                Button { MeetingFiles.open(transcript) } label: { Label("transcript.md", systemImage: "doc.text") }
                    .buttonStyle(CapsuleButton(tint: Palette.coral, soft: true))
                    .help("Open transcript.md")
            }
            if let media = item.media {
                Button { MeetingFiles.open(media) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(CapsuleButton(tint: Palette.coral))
                    .help("Play the recording")
            }
        }
        .fixedSize()
    }
}

private struct MeetingFaces: View {
    let names: [String]
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(Array(names.prefix(5).enumerated()), id: \.offset) { _, name in
                Avatar(name: name, size: size)
            }
            if names.count > 5 {
                Text("+\(names.count - 5)")
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Palette.well2))
                    .overlay(Circle().strokeBorder(Palette.page, lineWidth: 1.5))
            }
        }
    }
}

private struct MeetingTaskRow: View {
    let task: MeetingTask
    let done: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(done ? AnyShapeStyle(Palette.coral) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                    .contentTransition(.symbolEffect(.replace))
                Text(MeetingFormat.inline(task.text))
                    .font(.system(size: 13))
                    .lineSpacing(1.5)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let owner = task.owner {
                    HStack(spacing: 5) {
                        Avatar(name: owner, size: 18)
                        Text(owner).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: 130, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(owner)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.bouncy, value: done)
    }
}

private struct MeetingBubble: View {
    let line: Recordings.Notes.Line
    let inset: CGFloat

    var body: some View {
        let me = line.speaker == "Me"
        VStack(alignment: me ? .trailing : .leading, spacing: 3) {
            Text("\(line.speaker) · \(MeetingFormat.time(line.time))")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(line.text)
                .font(.system(size: 12.5))
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(me ? AnyShapeStyle(Palette.coral.opacity(0.16)) : AnyShapeStyle(Palette.page)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: me ? .trailing : .leading)
        .padding(me ? .leading : .trailing, inset)
    }
}

/// Where a recording is in the pipeline, as a vivid tile above its notes.
private struct MeetingStatusTile: View {
    let state: MeetingState
    let failure: String?

    private var text: (title: String, detail: String) {
        switch state {
        case .working(let work, _, let title, let note):
            switch work {
            case .compressing:
                let left = note.isEmpty || note.hasPrefix("Making") ? "" : note.prefix(1).uppercased() + note.dropFirst() + ". "
                return ("Making a smaller copy", left + "It slows down while a call is using the mic.")
            case .transcribing:
                return ("Transcribing on this Mac", "The summary, decisions and action items show up here when it's done.")
            case .summarizing:
                return ("Writing the summary", "Claude is reading the transcript for decisions and action items.")
            case .preparing:
                return (title, note.isEmpty ? "The transcript starts right after." : note + ". The transcript starts right after.")
            }
        case .waiting:
            return ("Waiting its turn", "It's transcribed after the meeting before it, or when Gremlin next starts.")
        case .noTranscript:
            return ("No transcript", failure ?? "Gremlin didn't write a transcript for this recording.")
        case .ready:
            return ("Transcript ready", "")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if let percent = state.percent {
                    ProgressRing(progress: Double(percent) / 100, tint: .white, size: 52, line: 5)
                    Text("\(percent)%").font(.system(size: 13.5, weight: .bold, design: .rounded).monospacedDigit())
                } else if state.isWorking {
                    MeetingSpinner(color: .white, size: 52, line: 5)
                    Image(systemName: state.symbol).font(.system(size: 17, weight: .bold))
                } else {
                    Circle().fill(.white.opacity(0.2))
                    Image(systemName: state.symbol).font(.system(size: 19, weight: .bold))
                }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(text.title).font(.system(size: 16, weight: .bold, design: .rounded))
                Text(text.detail)
                    .font(.system(size: 12.5, weight: .medium))
                    .opacity(0.9)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(VividSurface(colors: state.fill, symbol: state.symbol, radius: 18))
    }
}

private struct MeetingLiveDetail: View {
    let recording: MenuModel.Recording
    let stop: () -> Void
    @EnvironmentObject private var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    LiveDot(color: .white, size: 8)
                    Text("Recording").font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                    RecordingScreenMenu(model: model, fallback: recording.audioOnly ? "Audio only" : "Screen and audio")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
                Spacer(minLength: 14)
                MeetingElapsed(started: recording.started)
                    .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                Text(recording.hearing ? "Sound is coming in" : "No sound for the last few seconds")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.88)
                MeetingLiveWave(live: recording.hearing)
                    .frame(height: 44)
                    .padding(.top, 14)
                Spacer(minLength: 18)
                Button(action: stop) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.coral).frame(width: 12, height: 12)
                        Text("Stop and transcribe").font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Palette.coral.mixed(with: .black, 0.1))
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .hoverLift(1.03)
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 360, alignment: .topLeading)
            .background(VividSurface(colors: Module.meetings.fill, symbol: "waveform", radius: 22))
            Well {
                VStack(alignment: .leading, spacing: 10) {
                    tip("folder.fill", Palette.sky) {
                        Text("Stopping opens the folder in Finder and starts the transcript.")
                    }
                    tip("keyboard.fill", Palette.iris) {
                        HStack(spacing: 6) {
                            ShortcutCap(keys: "⌃⌥⌘R")
                            Text("or")
                            ShortcutCap(keys: "⌃⌥⌘A")
                            Text("stops it from anywhere.")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tip(_ symbol: String, _ tint: Color, @ViewBuilder _ text: () -> some View) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 26)
            text().font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MeetingEmpty: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No recordings yet").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Record a call, and its transcript, summary and action items show up here.")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 18)
                MeetingWaveform().frame(maxHeight: 96)
                Spacer(minLength: 18)
                shortcut("R", "Screen, all sound and your mic")
                shortcut("A", "Just the two sides of the call")
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .background(VividSurface(colors: Module.meetings.fill, symbol: "waveform", radius: 22))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                feature("text.bubble.fill", Palette.iris, "Transcribed here", "whisper.cpp writes it on this Mac, labelled Me and Them.")
                feature("sparkles", Palette.grape, "Summarized", "Claude Code adds a summary, decisions and action items.")
                feature("arrow.down.right.and.arrow.up.left", Palette.amber, "Made smaller", "ffmpeg compresses the video after the call.")
            }
            Spacer(minLength: 0)
        }
    }

    private func shortcut(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(["⌃", "⌥", "⌘", key], id: \.self) { Keycap(text: $0, small: true, onColor: true) }
            }
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .padding(.top, 6)
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconTile(symbol: symbol, tint: tint, size: 30)
            Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(PaperSurface(tint: tint, radius: 18))
    }
}

// MARK: - Pieces

/// Fades the bottom edge of a scroll view, so rows read as continuing below.
private struct MeetingFade: ViewModifier {
    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            }
        }
    }
}

/// A wave across the live tile that rolls while sound comes in and lies low through silence.
private struct MeetingLiveWave: View {
    let live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let count = max(8, Int((geo.size.width + 3) / 7))
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<count, id: \.self) { index in
                        let d = Double(index)
                        let wave = abs(sin(t * 3.1 + d * 0.52) * cos(t * 1.7 + d * 0.23))
                        Capsule().fill(.white.opacity(0.9))
                            .frame(width: 4, height: max(4, geo.size.height * (live ? 0.16 + 0.84 * wave : 0.1)))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.3), value: live)
    }
}

/// A still waveform, for decoration.
private struct MeetingWaveform: View {
    var body: some View {
        GeometryReader { geo in
            let count = max(12, Int((geo.size.width + 4) / 10))
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    let d = Double(index)
                    let level = 0.14 + 0.86 * abs(sin(d * 0.55) * cos(d * 0.21 + 0.6))
                    Capsule().fill(.white.opacity(0.32)).frame(width: 6, height: max(6, geo.size.height * level))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }
}

private struct MeetingSpinner: View {
    var color: Color = .white
    var size: CGFloat = 16
    var line: CGFloat = 2

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: line)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size - line, height: size - line)
            .frame(width: size, height: size)
        }
    }
}

/// Pulsing placeholder lines for notes that aren't written yet.
private struct MeetingSkeleton: View {
    let lines: [Double]
    var height: CGFloat = 10
    var dots = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let pulse = 0.06 + 0.04 * (sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2
            VStack(alignment: .leading, spacing: height > 12 ? 12 : 10) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        if dots { Circle().strokeBorder(Color.primary.opacity(pulse * 2), lineWidth: 1.5).frame(width: 15, height: 15) }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                                .fill(Color.primary.opacity(pulse))
                                .frame(width: geo.size.width * lines[index])
                        }
                        .frame(height: height)
                    }
                }
            }
        }
    }
}

/// Which display a screen recording takes, and a menu to move it to another one. With one display, or audio only, it's
/// just the fallback text.
struct RecordingScreenMenu: View {
    @ObservedObject var model: MenuModel
    let fallback: String

    var body: some View {
        if let current = model.recording?.screen, model.screens.count > 1 {
            Menu {
                Picker("Record", selection: Binding(get: { current }, set: { model.perform(.recordScreen($0)) })) {
                    ForEach(model.screens) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "display")
                    Text(model.screens.first { $0.id == current }?.name ?? "Screen").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Record another display")
        } else {
            Text(fallback).lineLimit(1)
        }
    }
}

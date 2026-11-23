import Foundation

// The meetings in ~/Movies/Meetings, read from their folders: the name and time from the folder, the people from
// event.json, and the summary, decisions, action items and transcript from transcript.md.
@MainActor
final class Recordings: ObservableObject {
    struct Item: Identifiable, Equatable {
        let folder: URL
        let title: String
        let date: Date?
        let minutes: Int?
        let audioOnly: Bool
        /// recording.mov is still there, so the smaller copy isn't made yet.
        let uncompressed: Bool
        let transcribed: Bool
        let summarized: Bool
        let actionItems: Int
        let people: [String]
        let bytes: Int64

        var id: URL { folder }
        var transcript: URL { folder.appendingPathComponent(MeetingNotes.transcript) }
        var media: URL? {
            [MeetingNotes.compressed, MeetingNotes.compressedAudio, MeetingNotes.recording]
                .map { folder.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    struct Notes: Equatable {
        struct Line: Equatable, Identifiable {
            let id: Int
            let speaker: String
            let time: String
            let text: String
        }

        var summary = ""
        var decisions: [String] = []
        var actionItems: [String] = []
        var lines: [Line] = []
        /// Why there's no transcript, when transcribing failed.
        var failure: String?
    }

    @Published private(set) var items: [Item] = []
    /// False until the first scan is in, so an empty list isn't mistaken for no recordings.
    @Published private(set) var loaded = false
    private var notesCache: [URL: (date: Date, notes: Notes)] = [:]
    private var scanning = false
    private let folder: URL

    init(folder: URL = Meetings.folder) {
        self.folder = folder
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let folder = folder
        Task.detached(priority: .utility) {
            let items = Self.scan(folder)
            await MainActor.run {
                self.scanning = false
                if items != self.items { self.items = items }
                if !self.loaded { self.loaded = true }
            }
        }
    }

    /// The parsed transcript.md, cached until the file changes.
    func notes(for item: Item) -> Notes? {
        let url = item.transcript
        guard let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        if let cached = notesCache[url], cached.date == changed { return cached.notes }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let notes = Self.parse(text)
        notesCache[url] = (changed, notes)
        return notes
    }

    /// The percentage at the start of a progress detail like "64% · about 6 min left".
    nonisolated static func percent(in detail: String) -> Int? {
        detail.firstMatch(of: #/^(\d+)%/#).flatMap { Int($0.1) }
    }

    // MARK: Reading folders

    nonisolated private static func scan(_ root: URL) -> [Item] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return folders.compactMap { folder -> Item? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let names = Set(files.map(\.lastPathComponent))
            guard !names.isDisjoint(with: [MeetingNotes.recording, MeetingNotes.compressed, MeetingNotes.compressedAudio, MeetingNotes.transcript])
            else { return nil }
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            let head = (try? String(contentsOf: folder.appendingPathComponent(MeetingNotes.transcript), encoding: .utf8)) ?? ""
            return Item(folder: folder, title: MeetingNotes.title(of: folder), date: date(of: folder), minutes: minutes(in: head),
                        audioOnly: names.contains(MeetingNotes.compressedAudio) && !names.contains(MeetingNotes.compressed),
                        uncompressed: names.contains(MeetingNotes.recording), transcribed: head.contains("\n## Transcript"),
                        summarized: head.contains("\n## Summary"), actionItems: actionItems(in: head),
                        people: people(in: folder.appendingPathComponent(MeetingNotes.event)), bytes: bytes)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    nonisolated private static func date(of folder: URL) -> Date? {
        let name = folder.lastPathComponent
        guard name.count >= 16 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.date(from: String(name.prefix(16)))
    }

    nonisolated private static func minutes(in text: String) -> Int? {
        guard let match = text.firstMatch(of: #/\n(\d+) minutes? ·/#) else { return nil }
        return Int(match.1)
    }

    nonisolated private static func actionItems(in text: String) -> Int {
        section("### Action items", in: text).filter { bullet($0) != nil }.count
    }

    // Calendar attendees are names or email addresses. For an address, the part before the @ stands in for a name.
    nonisolated private static func people(in event: URL) -> [String] {
        struct Event: Decodable { let attendees: [String]? }
        guard let data = try? Data(contentsOf: event), let decoded = try? JSONDecoder().decode(Event.self, from: data) else { return [] }
        return (decoded.attendees ?? []).map { address in
            guard address.contains("@") else { return address }
            let local = address.split(separator: "@").first.map(String.init) ?? address
            return local.split(whereSeparator: { ".-_+".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    // MARK: Reading transcript.md

    nonisolated private static func section(_ heading: String, in text: String) -> [String] {
        guard let start = text.range(of: heading + "\n") else { return [] }
        return text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("#") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // claude usually writes "- " bullets, and now and then "* " or a numbered list.
    nonisolated private static func bullet(_ line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        guard let match = line.firstMatch(of: #/^\d+[.)] (.+)/#) else { return nil }
        return String(match.1)
    }

    nonisolated static func parse(_ text: String) -> Notes {
        var notes = Notes()
        notes.summary = section("## Summary", in: text).joined(separator: "\n\n")
        notes.decisions = section("### Decisions", in: text).compactMap(bullet)
        notes.actionItems = section("### Action items", in: text).compactMap(bullet)
        if !text.contains("\n## Transcript"), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Couldn't transcribe") }) {
            notes.failure = String(line)
        }
        if let start = text.range(of: "## Transcript\n") {
            var speaker: (name: String, time: String)?
            var said: [String] = []
            func flush() {
                if let speaker, !said.isEmpty {
                    notes.lines.append(.init(id: notes.lines.count, speaker: speaker.name, time: speaker.time, text: said.joined(separator: " ")))
                }
                said = []
            }
            for line in text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
                if let match = line.firstMatch(of: #/^\*\*(.+?)\*\* · ([\d:]+)/#) {
                    flush()
                    speaker = (String(match.1), String(match.2))
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    said.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
            flush()
        }
        return notes
    }
}

import AVFoundation
import Speech
@preconcurrency import UserNotifications

// Turns a finished recording into transcript.md, with a summary from the local claude CLI when it is installed,
// and a smaller copy of the video made with ffmpeg that replaces the original. Folders a quit left half done are
// picked up at launch.
@MainActor
final class MeetingNotes {
    static let recording = "recording.mov"
    static let compressed = "recording.mp4"
    static let transcript = "transcript.md"

    private struct Segment {
        let speaker: String
        let start: Double
        var end: Double
        var text: String
    }

    var onChange: (() -> Void)?
    private(set) var status: String?
    private var queue: [URL] = []
    private var running = false

    func process(_ folder: URL) {
        guard !queue.contains(folder) else { return }
        queue.append(folder)
        next()
    }

    func resume(in root: URL) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.path < $1.path })
        where fileManager.fileExists(atPath: folder.appendingPathComponent(Self.recording).path)
            && (Self.ffmpeg != nil || !fileManager.fileExists(atPath: folder.appendingPathComponent(Self.transcript).path)) {
            process(folder)
        }
    }

    private func next() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let folder = queue.removeFirst()
        Task {
            await run(folder)
            running = false
            setStatus(nil)
            next()
        }
    }

    private func setStatus(_ text: String?) {
        status = text
        onChange?()
    }

    private func run(_ folder: URL) async {
        let name = folder.lastPathComponent
        let video = folder.appendingPathComponent(Self.recording)
        let transcript = folder.appendingPathComponent(Self.transcript)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: transcript.path) {
            setStatus("Transcribing \(name)…")
            let started = Date()
            do {
                let segments = try await transcribe(video)
                let body = try await Self.markdown(name: name, video: video, segments: segments)
                try body.write(to: transcript, atomically: true, encoding: .utf8)
                Log.write("Meeting \(name): transcribed \(segments.count) passages in \(Int(Date().timeIntervalSince(started)))s")
                if !segments.isEmpty, let claude = Self.claude {
                    setStatus("Summarizing \(name)…")
                    if let summary = await summarize(transcript, claude: claude) {
                        let marker = "## Transcript"
                        try body.replacingOccurrences(of: marker, with: "## Summary\n\n\(summary)\n\n\(marker)")
                            .write(to: transcript, atomically: true, encoding: .utf8)
                    }
                }
                notify("Transcript ready", name)
            } catch {
                Log.write("Meeting \(name): transcription failed: \(error.localizedDescription)")
                try? "# \(name)\n\nCouldn't transcribe the recording: \(error.localizedDescription)\n"
                    .write(to: transcript, atomically: true, encoding: .utf8)
            }
        }

        let compressed = folder.appendingPathComponent(Self.compressed)
        guard let ffmpeg = Self.ffmpeg else { return }
        if !fileManager.fileExists(atPath: compressed.path) {
            setStatus("Compressing \(name)…")
            let started = Date()
            guard await compress(video, to: compressed, ffmpeg: ffmpeg) else { return }
            let before = (try? fileManager.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0
            let after = (try? fileManager.attributesOfItem(atPath: compressed.path)[.size] as? Int) ?? 0
            Log.write("Meeting \(name): compressed \(before / 1_000_000) MB to \(after / 1_000_000) MB in \(Int(Date().timeIntervalSince(started)))s")
        }
        let original = try? await AVURLAsset(url: video).load(.duration).seconds
        let copy = try? await AVURLAsset(url: compressed).load(.duration).seconds
        guard let original, let copy, abs(original - copy) < 2 else {
            return Log.write("Meeting \(name): kept \(Self.recording), the compressed copy is \(copy ?? 0)s long instead of \(original ?? 0)s")
        }
        if let text = try? String(contentsOf: transcript, encoding: .utf8) {
            try? text.replacingOccurrences(of: "](\(Self.recording))", with: "](\(Self.compressed))")
                .write(to: transcript, atomically: true, encoding: .utf8)
        }
        do {
            try fileManager.trashItem(at: video, resultingItemURL: nil)
        } catch {
            Log.write("Meeting \(name): couldn't move \(Self.recording) to the Trash: \(error.localizedDescription)")
        }
    }

    // MARK: Transcript

    private func transcribe(_ video: URL) async throws -> [Segment] {
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        // Meetings records the call's audio as the first track and the microphone as the second.
        let speakers = tracks.count > 1 ? ["Them", "Me"] : ["Speaker"]
        var segments: [Segment] = []
        for (track, speaker) in zip(tracks, speakers) {
            let audio = FileManager.default.temporaryDirectory.appendingPathComponent("gremlin-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await Self.extract(track, of: asset, to: audio)
            for (range, text) in try await Self.recognize(audio) where !text.isEmpty {
                segments.append(Segment(speaker: speaker, start: range.start.seconds, end: range.end.seconds, text: text))
            }
        }
        return Self.merge(segments)
    }

    private static func extract(_ track: AVAssetTrack, of asset: AVAsset, to url: URL) async throws {
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        try await export.export(to: url, as: .m4a)
    }

    private static func recognize(_ url: URL) async throws -> [(CMTimeRange, String)] {
        let preferred = UserDefaults.standard.string(forKey: "meetingLocale").map(Locale.init(identifier:)) ?? .current
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) ?? Locale(identifier: "en_US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
            var results: [(CMTimeRange, String)] = []
            for try await result in transcriber.results {
                results.append((result.range, String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return results
        }
        if let last = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: url)) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await results.value
    }

    private static func merge(_ segments: [Segment]) -> [Segment] {
        let them = segments.filter { $0.speaker == "Them" }
        // Without headphones the mic also hears the call, so drop what it picked up from the speakers.
        let kept = segments.filter { segment in
            guard segment.speaker == "Me" else { return true }
            let mine = words(segment.text)
            let theirs = Set(them.filter { $0.start < segment.end + 2 && segment.start < $0.end + 2 }.flatMap { words($0.text) })
            return mine.isEmpty || Double(mine.filter(theirs.contains).count) / Double(mine.count) < 0.5
        }
        var merged: [Segment] = []
        for segment in kept.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end < 2 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func markdown(name: String, video: URL, segments: [Segment]) async throws -> String {
        let minutes = max(1, Int((try await AVURLAsset(url: video).load(.duration).seconds / 60).rounded()))
        var lines = ["# \(name)", "", "\(minutes) minute\(minutes == 1 ? "" : "s") · [recording](\(Self.recording))", "", "## Transcript", ""]
        if segments.isEmpty { lines.append("Nobody said anything the transcriber could pick up.") }
        for segment in segments {
            lines += ["**\(segment.speaker)** · \(timestamp(segment.start))  ", segment.text, ""]
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    // MARK: Summary

    private static let summaryPrompt = """
        The input is the transcript of a meeting. "Me" is the person who recorded it; "Them" is everyone else on \
        the call, possibly several people. Write a two to four sentence summary, then "### Decisions" and \
        "### Action items" as bullet lists, naming who owns each item when the transcript makes it clear. Leave out \
        a section that would be empty. Reply with the markdown only, no preamble.
        """

    private func summarize(_ transcript: URL, claude: URL) async -> String? {
        let result = await Self.run(claude, ["-p", Self.summaryPrompt, "--tools", "", "--no-session-persistence"],
                                    input: transcript, directory: transcript.deletingLastPathComponent(), timeout: 600)
        let summary = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !summary.isEmpty else {
            Log.write("Meeting \(transcript.deletingLastPathComponent().lastPathComponent): claude exited \(result.status)")
            return nil
        }
        return summary
    }

    // MARK: Compression

    private func compress(_ video: URL, to output: URL, ffmpeg: URL) async -> Bool {
        let audioTracks = (try? await AVURLAsset(url: video).loadTracks(withMediaType: .audio).count) ?? 0
        // Shrinks only what is bigger than 2560 px, since screen shares rarely arrive sharper than that. Halving the
        // frame rate leaves text as sharp, makes the file a quarter smaller and the encode almost twice as fast.
        var graph = "[0:v:0]fps=15,scale=w='min(2560,iw)':h='min(2560,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2[v]"
        var maps = ["-map", "[v]"]
        if audioTracks > 1 {
            graph += ";[0:a:0][0:a:1]amix=inputs=2:duration=longest:normalize=0[a]"
            maps += ["-map", "[a]"]
        } else if audioTracks == 1 {
            maps += ["-map", "0:a:0"]
        }
        let partial = output.appendingPathExtension("part")
        let arguments = ["-nostdin", "-loglevel", "error", "-y", "-i", video.path, "-filter_complex", graph] + maps + [
            "-c:v", "libx265", "-preset", "medium", "-crf", "26", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
            "-x265-params", "log-level=error", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
            "-f", "mp4", partial.path,
        ]
        let result = await Self.run(ffmpeg, arguments, quality: .utility)
        guard result.status == 0 else {
            Log.write("Meeting \(video.deletingLastPathComponent().lastPathComponent): ffmpeg exited \(result.status): "
                      + String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        return (try? FileManager.default.moveItem(at: partial, to: output)) != nil
    }

    // MARK: Tools

    // Gremlin starts from launchd, so the PATH a shell would have isn't there.
    private static func find(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var claude: URL? { find("claude") }
    static var ffmpeg: URL? { find("ffmpeg") }

    private static func run(_ executable: URL, _ arguments: [String], input: URL? = nil, directory: URL? = nil,
                            timeout: TimeInterval? = nil, quality: QualityOfService = .default) async -> (status: Int32, output: Data, errors: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.qualityOfService = quality
                if let directory { process.currentDirectoryURL = directory }
                process.standardInput = input.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    return continuation.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8)))
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                }
                var errorData = Data()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, outputData, errorData))
            }
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

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

    private struct Whisper {
        let cli: URL
        let ffmpeg: URL
        let model: URL
        let vad: URL
    }

    private struct WhisperOutput: Decodable {
        struct Result: Decodable {
            let language: String
        }

        struct Passage: Decodable {
            struct Offsets: Decodable {
                let from: Int
                let to: Int
            }

            let offsets: Offsets
            let text: String
        }

        let result: Result
        let transcription: [Passage]
    }

    private static let models = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Gremlin/Models")

    var onChange: (() -> Void)?
    private(set) var status: String?
    private var queue: [URL] = []
    private var running = false
    private var current: Process?

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
                let segments = try await transcribe(video, name: name)
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

    private func transcribe(_ video: URL, name: String) async throws -> [Segment] {
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        // Meetings records the call's audio as the first track and the microphone as the second.
        let speakers = tracks.count > 1 ? ["Them", "Me"] : ["Speaker"]
        var whisper: Whisper?
        do {
            whisper = try await setUpWhisper()
        } catch {
            Log.write("Meeting \(name): using Apple's transcriber, whisper isn't ready: \(error.localizedDescription)")
        }
        setStatus("Transcribing \(name)…")
        var segments: [Segment] = []
        for (index, (track, speaker)) in zip(tracks, speakers).enumerated() {
            let passages: [(start: Double, end: Double, text: String)]
            if let whisper {
                let heard = try await recognize(track: index, of: video, with: whisper)
                Log.write("Meeting \(name): whisper heard \(speaker) speaking \(heard.language)")
                passages = heard.passages
            } else {
                let audio = FileManager.default.temporaryDirectory.appendingPathComponent("gremlin-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: audio) }
                try await Self.extract(track, of: asset, to: audio)
                passages = try await Self.recognize(audio).map { ($0.0.start.seconds, $0.0.end.seconds, $0.1) }
            }
            for passage in passages where !passage.text.isEmpty {
                segments.append(Segment(speaker: speaker, start: passage.start, end: passage.end, text: passage.text))
            }
        }
        return Self.merge(segments)
    }

    // whisper.cpp, when it's installed, knows Turkish and detects which language is spoken. Apple's transcriber is
    // the fallback; it only knows a few languages and has to be told which one.
    private func setUpWhisper() async throws -> Whisper? {
        guard let cli = Self.find("whisper-cli"), let ffmpeg = Self.ffmpeg else { return nil }
        let model = try await download("ggml-large-v3-turbo-q8_0.bin",
                                       from: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")
        let vad = try await download("ggml-silero-v6.2.0.bin",
                                     from: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")
        return Whisper(cli: cli, ffmpeg: ffmpeg, model: model, vad: vad)
    }

    private func download(_ name: String, from address: String) async throws -> URL {
        let file = Self.models.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        setStatus("Downloading the transcription model…")
        let (temporary, response) = try await URLSession.shared.download(from: URL(string: address)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.createDirectory(at: Self.models, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: file)
        Log.write("Meetings: downloaded \(name)")
        return file
    }

    private func recognize(track index: Int, of video: URL,
                           with whisper: Whisper) async throws -> (language: String, passages: [(start: Double, end: Double, text: String)]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gremlin-\(UUID().uuidString)")
        let audio = base.appendingPathExtension("wav")
        let json = base.appendingPathExtension("json")
        defer { [audio, json].forEach { try? FileManager.default.removeItem(at: $0) } }
        let extract = await run(whisper.ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-i", video.path, "-map", "0:a:\(index)",
                                                 "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio.path])
        guard extract.status == 0 else { throw Self.failure("ffmpeg", extract) }
        let language = UserDefaults.standard.string(forKey: "meetingLanguage") ?? "auto"
        // Voice activity detection skips the long silences on each side's track, where whisper tends to make up words.
        let result = await run(whisper.cli, ["-m", whisper.model.path, "-f", audio.path, "-l", language,
                                             "--vad", "-vm", whisper.vad.path, "-oj", "-of", base.path, "-np"],
                               quality: .utility, yieldsDuringCalls: true)
        guard result.status == 0 else { throw Self.failure("whisper-cli", result) }
        // A token can end partway through a multibyte character, which JSONDecoder rejects.
        let data = Data(String(decoding: try Data(contentsOf: json), as: UTF8.self).utf8)
        let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
        return (output.result.language, output.transcription.map {
            (Double($0.offsets.from) / 1000, Double($0.offsets.to) / 1000, $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private static func failure(_ tool: String, _ result: (status: Int32, output: Data, errors: Data)) -> Error {
        let message = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(domain: "Gremlin", code: Int(result.status),
                       userInfo: [NSLocalizedDescriptionKey: "\(tool) exited \(result.status): \(message)"])
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
        let preferred = UserDefaults.standard.string(forKey: "meetingLanguage").map(Locale.init(identifier:)) ?? .current
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
        a section that would be empty. Write in English whatever language the meeting was in, and reply with the \
        markdown only, no preamble.
        """

    private func summarize(_ transcript: URL, claude: URL) async -> String? {
        let result = await run(claude, ["-p", Self.summaryPrompt, "--tools", "", "--no-session-persistence"],
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
        // Meetings records at most 2560 px and 15 fps; older recordings were bigger.
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
        let result = await run(ffmpeg, arguments, quality: .utility, yieldsDuringCalls: true)
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

    // ffmpeg would outlive Gremlin and race the copy the next launch starts.
    func stop() {
        current?.terminate()
    }

    private func run(_ executable: URL, _ arguments: [String], input: URL? = nil, directory: URL? = nil,
                     timeout: TimeInterval? = nil, quality: QualityOfService = .default,
                     yieldsDuringCalls: Bool = false) async -> (status: Int32, output: Data, errors: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = quality
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = input.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        current = process
        defer { current = nil }
        return await Self.wait(for: process, timeout: timeout, yieldsDuringCalls: yieldsDuringCalls)
    }

    private nonisolated static func wait(for process: Process, timeout: TimeInterval?,
                                         yieldsDuringCalls: Bool) async -> (status: Int32, output: Data, errors: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
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
                // Encoding at full speed next to a call makes the call drop frames. Pausing instead could wait forever,
                // since a browser tab can hold the mic long after the call ends.
                var calls: DispatchSourceTimer?
                if yieldsDuringCalls {
                    var throttled = false
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now(), repeating: 2)
                    timer.setEventHandler {
                        let busy = !Meetings.micUsers().isEmpty
                        guard busy != throttled, process.isRunning else { return }
                        throttled = busy
                        setpriority(PRIO_DARWIN_PROCESS, id_t(process.processIdentifier), busy ? PRIO_DARWIN_BG : 0)
                        let tool = process.executableURL?.lastPathComponent ?? "process"
                        Log.write(busy ? "Meetings: running \(tool) at background priority while the mic is in use"
                                       : "Meetings: running \(tool) at full speed")
                    }
                    timer.resume()
                    calls = timer
                }
                var errorData = Data()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                calls?.cancel()
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

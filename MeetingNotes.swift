import AVFoundation
import Speech
@preconcurrency import UserNotifications

// Turns a finished recording into transcript.md, with a summary from the local claude CLI when it is installed,
// and a smaller copy of the video, or of the audio, made with ffmpeg that replaces the original. Folders a quit left half done are
// picked up at launch.
@MainActor
final class MeetingNotes {
    static let recording = "recording.mov"
    static let compressed = "recording.mp4"
    static let compressedAudio = "recording.m4a"
    static let transcript = "transcript.md"
    static let event = "event.json"

    struct Progress: Equatable {
        let title: String
        let detail: String
        let folder: URL
    }

    struct Outcome: Equatable {
        let folder: URL
        let ok: Bool
        let detail: String
        let date: Date
    }

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
    private(set) var progress: Progress?
    // The last transcript written since launch.
    private(set) var outcome: Outcome?
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
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            let recorded = fileManager.fileExists(atPath: folder.appendingPathComponent(Self.recording).path)
            let transcribed = fileManager.fileExists(atPath: folder.appendingPathComponent(Self.transcript).path)
            if recorded && (Self.ffmpeg != nil || !transcribed) || Self.claude != nil && Self.needsSummary(folder) { process(folder) }
        }
    }

    private func next() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let folder = queue.removeFirst()
        Task {
            await run(folder)
            running = false
            setProgress(nil)
            next()
        }
    }

    private func setProgress(_ progress: Progress?) {
        self.progress = progress
        onChange?()
    }

    // The folder's name without the date and time it starts with.
    static func title(of folder: URL) -> String {
        let name = folder.lastPathComponent
        guard let range = name.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2} "#, options: .regularExpression) else { return name }
        return String(name[range.upperBound...])
    }

    private func run(_ folder: URL) async {
        let name = folder.lastPathComponent
        let video = folder.appendingPathComponent(Self.recording)
        let transcript = folder.appendingPathComponent(Self.transcript)
        let fileManager = FileManager.default
        let title = Self.title(of: folder)
        let recorded = fileManager.fileExists(atPath: video.path)
        // Once the original is in the Trash, only the compressed copy is left to measure.
        let media = recorded ? video : [Self.compressed, Self.compressedAudio].map { folder.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) } ?? video
        let asset = AVURLAsset(url: media)
        let length = (try? await asset.load(.duration).seconds).map { "\(max(1, Int(($0 / 60).rounded()))) min" } ?? "Saved"
        let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        let event = (try? Data(contentsOf: folder.appendingPathComponent(Self.event)))
            .flatMap { try? JSONDecoder().decode(MeetingCalendar.Event.self, from: $0) }

        if !fileManager.fileExists(atPath: transcript.path) {
            guard recorded else { return }
            setProgress(Progress(title: "Transcribing \(title)", detail: Self.claude == nil ? length : "\(length) · summary next",
                                 folder: folder))
            let started = Date()
            do {
                let segments = try await transcribe(video, name: name)
                let body = try await Self.markdown(name: name, video: video, segments: segments, event: event)
                try body.write(to: transcript, atomically: true, encoding: .utf8)
                Log.write("Meeting \(name): transcribed \(segments.count) passages in \(Int(Date().timeIntervalSince(started)))s")
                var details = [title, length]
                if !segments.isEmpty, Self.claude != nil {
                    details.append(await addSummary(to: folder, title: title, length: length, event: event))
                }
                outcome = Outcome(folder: folder, ok: true, detail: details.joined(separator: " · "), date: Date())
                notify("Transcript ready", name)
            } catch {
                Log.write("Meeting \(name): transcription failed: \(error.localizedDescription)")
                try? "# \(name)\n\nCouldn't transcribe the recording: \(error.localizedDescription)\n"
                    .write(to: transcript, atomically: true, encoding: .utf8)
                outcome = Outcome(folder: folder, ok: false, detail: error.localizedDescription, date: Date())
            }
        } else if Self.claude != nil, Self.needsSummary(folder) {
            let summary = await addSummary(to: folder, title: title, length: length, event: event)
            outcome = Outcome(folder: folder, ok: true, detail: [title, length, summary].joined(separator: " · "), date: Date())
        }

        guard recorded else { return }
        let compressed = folder.appendingPathComponent(hasVideo ? Self.compressed : Self.compressedAudio)
        guard let ffmpeg = Self.ffmpeg else { return }
        if !fileManager.fileExists(atPath: compressed.path) {
            let heading = "Compressing \(title)"
            let detail = "Making a smaller copy of the " + (hasVideo ? "video" : "audio")
            setProgress(Progress(title: heading, detail: detail, folder: folder))
            let started = Date()
            let done = await compress(video, to: compressed, video: hasVideo, ffmpeg: ffmpeg) { [weak self] percent in
                let update = Progress(title: heading, detail: "\(percent)% · \(detail)", folder: folder)
                guard let self, self.progress?.title == heading, self.progress != update else { return }
                self.setProgress(update)
            }
            guard done else { return }
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
            try? text.replacingOccurrences(of: "](\(Self.recording))", with: "](\(compressed.lastPathComponent))")
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
        let previous = progress
        setProgress(Progress(title: "Downloading the transcription model", detail: "Only the first time",
                             folder: previous?.folder ?? Self.models))
        defer { setProgress(previous) }
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
                                                 "-af", Self.fromStart, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio.path])
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

    // A track that starts after the recording does keeps its offset in the movie, but ffmpeg drops it unless the
    // start is padded with silence, which would put Me and Them out of step.
    private static let fromStart = "aresample=async=1:first_pts=0"

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

    private static func markdown(name: String, video: URL, segments: [Segment], event: MeetingCalendar.Event?) async throws -> String {
        let minutes = max(1, Int((try await AVURLAsset(url: video).load(.duration).seconds / 60).rounded()))
        var lines = ["# \(name)", "", "\(minutes) minute\(minutes == 1 ? "" : "s") · [recording](\(Self.recording))", ""]
        if let event, !event.attendees.isEmpty { lines += ["With " + ListFormatter.localizedString(byJoining: event.attendees), ""] }
        lines += ["## Transcript", ""]
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

    private static func actionItems(in summary: String) -> Int {
        guard let heading = summary.range(of: "### Action items") else { return 0 }
        return summary[heading.upperBound...].split(separator: "\n").prefix { !$0.hasPrefix("#") }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.count
    }

    // A transcript with something said in it and no summary yet, e.g. because claude failed the first time.
    private static func needsSummary(_ folder: URL) -> Bool {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(transcript), encoding: .utf8) else { return false }
        return !text.contains("\n## Summary\n") && text.contains("\n## Transcript\n")
            && ["**Me**", "**Them**", "**Speaker**"].contains { text.contains("\n\($0) · ") }
    }

    // Puts claude's summary above the transcript, and says how it went for the panel: how many action items, or
    // that there's no summary.
    private func addSummary(to folder: URL, title: String, length: String, event: MeetingCalendar.Event?) async -> String {
        let transcript = folder.appendingPathComponent(Self.transcript)
        setProgress(Progress(title: "Summarizing \(title)", detail: "\(length) · claude is writing it", folder: folder))
        guard let claude = Self.claude, let summary = await summarize(transcript, claude: claude, event: event),
              let body = try? String(contentsOf: transcript, encoding: .utf8), let marker = body.range(of: "## Transcript")
        else { return "no summary" }
        do {
            try body.replacingCharacters(in: marker, with: "## Summary\n\n\(summary)\n\n## Transcript")
                .write(to: transcript, atomically: true, encoding: .utf8)
        } catch {
            Log.write("Meeting \(folder.lastPathComponent): couldn't save the summary: \(error.localizedDescription)")
            return "no summary"
        }
        Log.write("Meeting \(folder.lastPathComponent): summarized")
        let items = Self.actionItems(in: summary)
        return items == 0 ? "summarized" : "\(items) action item\(items == 1 ? "" : "s")"
    }

    private func summarize(_ transcript: URL, claude: URL, event: MeetingCalendar.Event?) async -> String? {
        var prompt = Self.summaryPrompt
        if let event {
            prompt += " The calendar event was \"\(event.title)\""
            prompt += event.attendees.isEmpty ? "." : ", with " + ListFormatter.localizedString(byJoining: event.attendees)
                + ". Them is one or more of these people; name them where the transcript makes it clear who is speaking."
        }
        // claude can fail for a moment, e.g. while another claude process is refreshing the login, so it gets three
        // tries. If all of them fail, the next launch tries again.
        let name = transcript.deletingLastPathComponent().lastPathComponent
        for (attempt, wait) in [0, 20, 90].enumerated() {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let result = await run(claude, ["-p", prompt, "--tools", "", "--no-session-persistence"],
                                   input: transcript, directory: transcript.deletingLastPathComponent(), timeout: 600)
            let summary = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !summary.isEmpty { return summary }
            let reason = String(decoding: result.errors + result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("Meeting \(name): claude exited \(result.status), try \(attempt + 1) of 3: \(reason.suffix(300))")
        }
        return nil
    }

    // MARK: Compression

    private func compress(_ recording: URL, to output: URL, video: Bool, ffmpeg: URL,
                          onPercent: @escaping @MainActor (Int) -> Void) async -> Bool {
        let asset = AVURLAsset(url: recording)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        var graph: [String] = []
        var maps: [String] = []
        if video {
            // Meetings records at most 2560 px and 15 fps; older recordings were bigger.
            graph.append("[0:v:0]fps=15,scale=w='min(2560,iw)':h='min(2560,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2[v]")
            maps += ["-map", "[v]"]
        }
        if audioTracks > 1 {
            graph.append("[0:a:0]\(Self.fromStart)[s];[0:a:1]\(Self.fromStart)[m];[s][m]amix=inputs=2:duration=longest:normalize=0[a]")
            maps += ["-map", "[a]"]
        } else if audioTracks == 1 {
            graph.append("[0:a:0]\(Self.fromStart)[a]")
            maps += ["-map", "[a]"]
        }
        let partial = output.appendingPathExtension("part")
        var arguments = ["-nostdin", "-nostats", "-loglevel", "error", "-progress", "pipe:1", "-y", "-i", recording.path]
        if !graph.isEmpty { arguments += ["-filter_complex", graph.joined(separator: ";")] }
        arguments += maps
        if video {
            arguments += ["-c:v", "libx265", "-preset", "medium", "-crf", "26", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
                          "-x265-params", "log-level=error"]
        }
        arguments += ["-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", "-f", "mp4", partial.path]
        let result = await run(ffmpeg, arguments, quality: .utility, yieldsDuringCalls: true) { chunk in
            guard seconds > 0, let written = Self.secondsWritten(in: chunk) else { return }
            // 100% waits for ffmpeg to finish, since it still has to rewrite the file for +faststart.
            let percent = min(99, Int(written / seconds * 100))
            Task { @MainActor in onPercent(percent) }
        }
        guard result.status == 0 else {
            Log.write("Meeting \(recording.deletingLastPathComponent().lastPathComponent): ffmpeg exited \(result.status): "
                      + String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        return (try? FileManager.default.moveItem(at: partial, to: output)) != nil
    }

    // ffmpeg's -progress output is blocks of key=value lines. out_time_us is N/A until the first packet is written.
    private nonisolated static func secondsWritten(in chunk: Data) -> Double? {
        String(decoding: chunk, as: UTF8.self).split(separator: "\n").reversed().lazy
            .compactMap { $0.hasPrefix("out_time_us=") ? Double($0.dropFirst("out_time_us=".count)) : nil }
            .first.map { $0 / 1_000_000 }
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
                     timeout: TimeInterval? = nil, quality: QualityOfService = .default, yieldsDuringCalls: Bool = false,
                     onOutput: (@Sendable (Data) -> Void)? = nil) async -> (status: Int32, output: Data, errors: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = quality
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = input.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        current = process
        defer { current = nil }
        return await Self.wait(for: process, timeout: timeout, yieldsDuringCalls: yieldsDuringCalls, onOutput: onOutput)
    }

    // With onOutput, standard output goes to it as it arrives and isn't kept.
    private nonisolated static func wait(for process: Process, timeout: TimeInterval?, yieldsDuringCalls: Bool,
                                         onOutput: (@Sendable (Data) -> Void)?) async -> (status: Int32, output: Data, errors: Data) {
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
                var outputData = Data()
                if let onOutput {
                    while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty { onOutput(chunk) }
                } else {
                    outputData = output.fileHandleForReading.readDataToEndOfFile()
                }
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

import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit
@preconcurrency import UserNotifications

// Records a meeting's window to ~/Movies/Meetings: its video, the call's audio and the microphone, the last two on
// separate tracks so the transcript can tell Me from Them. With auto-detect on, a meeting is a meeting app (or a
// browser on a Meet, Teams or Zoom page) using the mic, and it ends when that app lets go of the mic.
@MainActor
final class Meetings: NSObject, @preconcurrency Feature, SCStreamDelegate, SCRecordingOutputDelegate {
    struct Recording {
        let name: String
        let folder: URL
        let started: Date
        let windowID: CGWindowID
        let micPIDs: Set<pid_t>
    }

    private struct Candidate {
        let windowID: CGWindowID
        let name: String
        let micPIDs: Set<pid_t>
    }

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Meetings")

    var onChange: (() -> Void)?
    let notes = MeetingNotes()
    private(set) var recording: Recording?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var starting = false
    private var autoDetect = false
    private var timer: Timer?
    private var quietSince: Date?
    // Muting doesn't always keep the mic open, so the call has to stay quiet this long before it counts as over.
    private let quietTimeout: TimeInterval = 20
    // A meeting stopped by hand isn't picked up again until its app lets go of the mic.
    private var ignoredPIDs: Set<pid_t> = []
    private var onFinish: [() -> Void] = []

    override init() {
        super.init()
        notes.onChange = { [weak self] in self?.onChange?() }
        notes.resume(in: Self.folder)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func start() {
        autoDetect = true
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func stop() {
        autoDetect = false
    }

    var statusText: String? {
        if let recording {
            let elapsed = Int(Date().timeIntervalSince(recording.started))
            return "Recording \(recording.name) · " + String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        }
        return notes.status
    }

    func toggle() {
        if let recording {
            ignoredPIDs = recording.micPIDs
            return finishCapture("stopped by hand")
        }
        guard !starting else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                guard let candidate = Self.findMeeting(Self.micUsers()) ?? Self.frontWindow() else {
                    return self.notify("Nothing to record", "Gremlin records the meeting window, or the front window when there's no meeting.")
                }
                self.begin(candidate)
            }
        }
    }

    // Lets a quit wait until the recording is written out.
    func finish(then done: @escaping () -> Void) {
        guard recording != nil else { return done() }
        onFinish.append(done)
        finishCapture("Gremlin is quitting")
    }

    private func poll() {
        let users = Self.micUsers()
        ignoredPIDs.formIntersection(users.keys)
        if let recording {
            if !Self.windowExists(recording.windowID) { return finishCapture("its window closed") }
            guard !recording.micPIDs.isEmpty else { return }
            if !recording.micPIDs.isDisjoint(with: users.keys) {
                quietSince = nil
            } else if let quietSince, Date().timeIntervalSince(quietSince) > quietTimeout {
                finishCapture("the call let go of the mic")
            } else if quietSince == nil {
                quietSince = Date()
            }
            return
        }
        guard autoDetect, !starting else { return }
        let candidates = users.filter { !ignoredPIDs.contains($0.key) }
        guard !candidates.isEmpty, let meeting = Self.findMeeting(candidates) else { return }
        notify("Recording \(meeting.name)", "Stop it from the Gremlin menu or with ⌃⌥⌘R.")
        begin(meeting)
    }

    // MARK: Recording

    private func begin(_ candidate: Candidate) {
        starting = true
        onChange?()
        Task {
            var folder: URL?
            defer {
                starting = false
                onChange?()
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == candidate.windowID }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                // Retina pixels at 30 fps took enough GPU and encoder time to make the call drop frames. One pixel per
                // point is still sharper than the screen shares a call sends.
                let shrink = min(1, 1920 / max(filter.contentRect.width, filter.contentRect.height, 1))
                config.captureResolution = .nominal
                config.width = Int(filter.contentRect.width * shrink) & ~1
                config.height = Int(filter.contentRect.height * shrink) & ~1
                config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
                config.scalesToFit = true
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.captureMicrophone = true

                let target = Self.newFolder(candidate.name)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                folder = target
                let recordingConfig = SCRecordingOutputConfiguration()
                recordingConfig.outputURL = target.appendingPathComponent(MeetingNotes.recording)
                recordingConfig.outputFileType = .mov
                recordingConfig.videoCodecType = .hevc
                recordingConfig.mixesAudioWithMicrophone = false
                let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addRecordingOutput(output)
                try await stream.startCapture()

                self.stream = stream
                self.output = output
                quietSince = nil
                recording = Recording(name: candidate.name, folder: target, started: Date(),
                                      windowID: candidate.windowID, micPIDs: candidate.micPIDs)
                Log.write("Meeting recording: \(candidate.name), window \(candidate.windowID) at \(config.width)x\(config.height), "
                          + "mic held by \(candidate.micPIDs.sorted())")
            } catch {
                if let folder { try? FileManager.default.removeItem(at: folder) }
                ignoredPIDs.formUnion(candidate.micPIDs)
                Log.write("Meeting recording: couldn't start \(candidate.name): \(error.localizedDescription)")
                notify("Couldn't record \(candidate.name)", error.localizedDescription)
            }
        }
    }

    private func finishCapture(_ reason: String) {
        guard let stream else { return }
        self.stream = nil
        Log.write("Meeting recording: stopping, \(reason)")
        onChange?()
        let folder = recording?.folder
        Task {
            try? await stream.stopCapture()
            try? await Task.sleep(for: .seconds(15))
            guard recording?.folder == folder else { return }
            Log.write("Meeting recording: the recording never reported finishing")
            finished()
        }
    }

    private func finished() {
        stream = nil
        output = nil
        guard let recording else { return }
        self.recording = nil
        Log.write("Meeting recording: saved \(recording.folder.lastPathComponent)")
        notes.process(recording.folder)
        onChange?()
        onFinish.forEach { $0() }
        onFinish = []
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            Log.write("Meeting recording: capture stopped: \(error.localizedDescription)")
            self.finishCapture("capture stopped")
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            Log.write("Meeting recording: writing failed: \(error.localizedDescription)")
            self.notify("Meeting recording failed", error.localizedDescription)
            self.finished()
        }
    }

    private static func newFolder(_ name: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let base = "\(formatter.string(from: Date())) \(name)"
        var folder = Self.folder.appendingPathComponent(base)
        var index = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = Self.folder.appendingPathComponent("\(base) \(index)")
            index += 1
        }
        return folder
    }

    // MARK: Finding the meeting

    private static let browsers = ["com.apple.safari", "com.google.chrome", "company.thebrowser.browser",
                                   "com.microsoft.edgemac", "com.brave.browser", "org.mozilla.firefox"]

    // A browser window's title is its current tab's.
    private static func meetingName(bundle: String, title: String) -> String? {
        let bundle = bundle.lowercased()
        if browsers.contains(where: bundle.hasPrefix) {
            if title == "Meet" || ["Meet -", "Meet –", "Meet:"].contains(where: title.hasPrefix) || title.contains("Google Meet") {
                return "Google Meet"
            }
            if title.contains("Microsoft Teams") { return "Teams" }
            if title.hasPrefix("Zoom Meeting") || title.hasPrefix("Zoom Webinar") { return "Zoom" }
            return nil
        }
        switch bundle {
        case "us.zoom.xos": return title.hasPrefix("Zoom Meeting") || title.hasPrefix("Zoom Webinar") ? "Zoom" : nil
        case "com.microsoft.teams2", "com.microsoft.teams": return title.isEmpty ? nil : "Teams"
        case "com.apple.facetime": return "FaceTime"
        case "com.tinyspeck.slackmacgap": return "Slack"
        case "cisco-systems.spark", "com.webex.meetingmanager": return "Webex"
        default: return nil
        }
    }

    // Browsers take the mic in a helper process, e.g. com.apple.WebKit.GPU for Safari or com.google.Chrome.helper.
    private static func owns(_ app: String, _ micUser: String) -> Bool {
        let app = app.lowercased()
        let mic = micUser.lowercased()
        guard !mic.isEmpty else { return false }
        if mic.hasPrefix("com.apple.webkit") { return app.hasPrefix("com.apple.safari") }
        if mic == "com.apple.avconferenced" { return app == "com.apple.facetime" }
        return app.hasPrefix(mic.components(separatedBy: ".helper")[0])
    }

    private static func findMeeting(_ micUsers: [pid_t: String]) -> Candidate? {
        guard !micUsers.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var bundles: [pid_t: String] = [:]
        var best: (candidate: Candidate, area: CGFloat)?
        for info in windows {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let title = info[kCGWindowName as String] as? String,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { continue }
            if bundles[pid] == nil { bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            guard let bundle = bundles[pid], let name = meetingName(bundle: bundle, title: title) else { continue }
            let pids = Set(micUsers.filter { $0.key == pid || owns(bundle, $0.value) }.keys)
            let area = bounds.width * bounds.height
            guard !pids.isEmpty, area > (best?.area ?? 0) else { continue }
            best = (Candidate(windowID: id, name: name, micPIDs: pids), area)
        }
        return best?.candidate
    }

    private static func frontWindow() -> Candidate? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: {
                  $0[kCGWindowLayer as String] as? Int == 0 && $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
              }),
              let id = window[kCGWindowNumber as String] as? CGWindowID
        else { return nil }
        return Candidate(windowID: id, name: app.localizedName ?? "Recording", micPIDs: [])
    }

    private static func windowExists(_ id: CGWindowID) -> Bool {
        (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.isEmpty == false
    }

    // Processes other than Gremlin that are taking audio from an input device, with their bundle IDs.
    nonisolated static func micUsers() -> [pid_t: String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [:] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [:] }
        var users: [pid_t: String] = [:]
        for process in processes where property(process, kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1 {
            guard let pid = property(process, kAudioProcessPropertyPID, as: pid_t.self), pid != getpid() else { continue }
            users[pid] = property(process, kAudioProcessPropertyBundleID, as: CFString.self).map { $0 as String } ?? ""
        }
        return users
    }

    private nonisolated static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.move()
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

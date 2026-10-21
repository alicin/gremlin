import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit

// Records a screen to ~/Movies/Meetings: its video, all system audio and the microphone, the last two on separate
// tracks so the transcript can tell Me from Them. When a browser or meeting app starts using the mic, a prompt offers
// to record it, and when that call goes quiet, it offers to stop.
@MainActor
final class Meetings: NSObject, SCStreamDelegate {
    struct Recording {
        let folder: URL
        let started: Date
    }

    struct AudioUse {
        let bundle: String
        let input: Bool
        let output: Bool
    }

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Meetings")
    // About -66 dBFS: any working mic's background noise is above it, and only a dead or muted input stays below.
    private static let signal: Float = 0.0005

    var onChange: (() -> Void)?
    let notes = MeetingNotes()
    private(set) var recording: Recording?
    private var stream: SCStream?
    private var recorder: Recorder?
    private var starting = false
    private var lastError: String?
    private var onFinish: [() -> Void] = []

    private let prompt = Prompt()
    private var timer: Timer?
    private var talkingSince: [pid_t: Date] = [:]
    // Calls the user chose not to record, until they let go of the mic.
    private var declined: Set<pid_t> = []
    private var offered: Set<pid_t> = []
    private var callPIDs: Set<pid_t> = []
    private var quietSince: Date?
    private var countdown: Timer?
    private var levels: (mic: Float, sound: Float) = (0, 0)
    private var heardMic = false
    private var size: Int64 = 0
    private var grewAt = Date()
    private var warned: Set<String> = []

    override init() {
        super.init()
        notes.onChange = { [weak self] in self?.onChange?() }
        notes.resume(in: Self.folder)
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Keeps running while a dialog is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var statusText: String? {
        if let recording {
            return "Recording · \(Self.elapsed(since: recording.started))   mic \(levels.mic > Self.signal ? "●" : "○")"
                + "   sound \(levels.sound > Self.signal ? "●" : "○")"
        }
        return notes.status ?? lastError
    }

    static func elapsed(since date: Date) -> String {
        let total = Int(Date().timeIntervalSince(date))
        return total < 3600 ? String(format: "%d:%02d", total / 60, total % 60)
            : String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    func toggle() {
        if recording != nil { return finishCapture("stopped by hand") }
        begin(call: Set(Self.callers(Self.audioUse()).filter { $0.value.input }.keys), window: nil)
    }

    // Lets a quit wait until the recording is written out.
    func finish(then done: @escaping () -> Void) {
        guard recording != nil else { return done() }
        onFinish.append(done)
        finishCapture("Gremlin is quitting")
    }

    // MARK: Watching for calls

    private func poll() {
        let callers = Self.callers(Self.audioUse())
        let talking = Set(callers.filter { $0.value.input }.keys)
        talkingSince = talkingSince.filter { talking.contains($0.key) }
        for pid in talking where talkingSince[pid] == nil { talkingSince[pid] = Date() }
        declined.formIntersection(talking)
        if recording != nil {
            checkHealth()
            return watchForEnd(callers, talking)
        }
        if prompt.topic == "offer", offered.isDisjoint(with: talking) {
            prompt.hide("offer")
            offered = []
        }
        guard !starting, prompt.topic == nil,
              let pid = talking.first(where: { !declined.contains($0) && Date().timeIntervalSince(talkingSince[$0]!) >= 5 }),
              let bundle = callers[pid]?.bundle
        else { return }
        offer(bundle, talking: talking, callers: callers)
    }

    private func offer(_ bundle: String, talking: Set<pid_t>, callers: [pid_t: AudioUse]) {
        let app = Self.app(owning: bundle)
        let call = app.map { app in talking.filter { callers[$0].map { Self.owns(app.bundleIdentifier ?? "", $0.bundle) } ?? false } }
            ?? talking.filter { callers[$0]?.bundle == bundle }
        let name = app?.localizedName ?? "An app"
        offered = call
        let window = app.flatMap { Self.window(of: $0.processIdentifier) }
        prompt.show("offer", icon: app?.icon, title: "\(name) is on a call", message: "Record the screen and both sides of the call?",
                    actions: [
                        .init(title: "Record") { [weak self] in
                            self?.offered = []
                            self?.begin(call: call, window: app.flatMap { Self.window(of: $0.processIdentifier) })
                        },
                        .init(title: "Not now") { [weak self] in
                            self?.declined.formUnion(call)
                            self?.offered = []
                        },
                    ], on: Self.screen(containing: window))
        NSSound(named: "Tink")?.play()
        Log.write("Meetings: \(name) is on a call, offered to record it")
    }

    private func watchForEnd(_ callers: [pid_t: AudioUse], _ talking: Set<pid_t>) {
        callPIDs.formUnion(talking)
        guard !callPIDs.isEmpty else { return }
        // Muting can let go of the mic, so the call only counts as over once its app stops playing sound too.
        if callPIDs.contains(where: { callers[$0].map { $0.input || $0.output } ?? false }) {
            quietSince = nil
            if prompt.topic == "ended" {
                countdown?.invalidate()
                prompt.hide("ended")
                Log.write("Meetings: the call came back")
            }
            return
        }
        guard prompt.topic != "ended" else { return }
        guard let since = quietSince else { return quietSince = Date() }
        guard Date().timeIntervalSince(since) >= 8 else { return }
        offerToStop()
    }

    private func offerToStop() {
        var left = 15
        func message() -> String { "Stopping the recording in \(left) s." }
        prompt.show("ended", icon: nil, title: "The call seems to be over", message: message(), actions: [
            .init(title: "Stop now") { [weak self] in self?.finishCapture("the call ended") },
            .init(title: "Keep recording") { [weak self] in
                self?.countdown?.invalidate()
                self?.callPIDs = []
                self?.quietSince = nil
            },
        ], on: nil)
        Log.write("Meetings: the call went quiet, stopping in \(left) s")
        let countdown = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                left -= 1
                guard let self, self.prompt.topic == "ended" else { return timer.invalidate() }
                if left > 0 { return self.prompt.update(message()) }
                timer.invalidate()
                self.prompt.hide("ended")
                self.finishCapture("the call ended")
            }
        }
        RunLoop.main.add(countdown, forMode: .common)
        self.countdown = countdown
    }

    private func checkHealth() {
        guard let recorder, let recording else { return }
        let health = recorder.takeHealth()
        levels = (health.micPeak, health.soundPeak)
        if health.micPeak > Self.signal { heardMic = true }
        if let error = health.error {
            warn("failed", "The recording stopped", error.localizedDescription)
            return finishCapture("writing failed")
        }
        let path = recording.folder.appendingPathComponent(MeetingNotes.recording).path
        let current = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        if current > size {
            size = current
            grewAt = Date()
        } else if Date().timeIntervalSince(grewAt) > 40 {
            warn("stuck", "The recording isn't growing", "Nothing has been saved for 40 seconds. Stop it and start it again.")
        }
        let elapsed = Date().timeIntervalSince(recording.started)
        if elapsed > 20, health.micBuffers == 0 {
            warn("no mic", "Gremlin isn't getting your mic",
                 "Allow Gremlin in System Settings → Privacy & Security → Microphone, then start the recording again.")
        }
        // AirPods send silence rather than background noise until you talk, so quiet is only suspicious for a while.
        if elapsed > 90, health.micBuffers > 0, !heardMic {
            warn("silent mic", "Your mic is silent", "Nothing from your mic has reached the recording. Check the input in Control Center.")
        }
    }

    private func warn(_ key: String, _ title: String, _ message: String) {
        guard !warned.contains(key) else { return }
        warned.insert(key)
        lastError = title
        Log.write("Meeting recording: \(title). \(message)")
        onChange?()
        guard prompt.topic != "ended" else { return }
        prompt.show("warning", icon: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil),
                    title: title, message: message, actions: [.init(title: "OK") {}], on: nil)
    }

    // MARK: Recording

    private func begin(call: Set<pid_t>, window: CGRect?) {
        guard recording == nil, !starting else { return }
        starting = true
        prompt.hide("offer")
        MeetingCalendar.requestAccess()
        onChange?()
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in await self.start(call: call, window: window) }
        }
    }

    private func start(call: Set<pid_t>, window: CGRect?) async {
        var folder: URL?
        defer {
            starting = false
            onChange?()
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = Self.display(for: window, in: content) else { throw CocoaError(.fileNoSuchFile) }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            // Retina pixels at 30 fps took enough GPU and encoder time to make the call drop frames. One pixel per
            // point keeps text readable.
            let shrink = min(1, 2560 / CGFloat(max(display.width, display.height, 1)))
            config.captureResolution = .nominal
            config.width = Int(CGFloat(display.width) * shrink) & ~1
            config.height = Int(CGFloat(display.height) * shrink) & ~1
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.scalesToFit = true
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = true

            let target = Self.newFolder(at: Date(), "Meeting")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            folder = target
            let recorder = try Recorder(url: target.appendingPathComponent(MeetingNotes.recording), width: config.width,
                                        height: config.height)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            for type in [SCStreamOutputType.screen, .audio, .microphone] {
                try stream.addStreamOutput(recorder, type: type, sampleHandlerQueue: recorder.queue)
            }
            try await stream.startCapture()

            self.stream = stream
            self.recorder = recorder
            callPIDs = call
            quietSince = nil
            heardMic = false
            levels = (0, 0)
            size = 0
            grewAt = Date()
            warned = []
            lastError = nil
            recording = Recording(folder: target, started: Date())
            Log.write("Meeting recording: display \(display.displayID) at \(config.width)x\(config.height), call \(call.sorted())")
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            Log.write("Meeting recording: couldn't start: \(error.localizedDescription)")
            alert("Couldn't start recording", error.localizedDescription)
        }
    }

    private func finishCapture(_ reason: String) {
        guard let stream, let recorder else { return }
        self.stream = nil
        countdown?.invalidate()
        prompt.hide("ended")
        // Stopping during a call shouldn't bring the offer to record it straight back.
        declined.formUnion(Self.callers(Self.audioUse()).filter { $0.value.input }.keys)
        Log.write("Meeting recording: stopping, \(reason)")
        onChange?()
        let folder = recording?.folder
        Task {
            try? await stream.stopCapture()
            recorder.finish { recorded, error in
                Task { @MainActor in self.finished(recorded: recorded, error: error) }
            }
            try? await Task.sleep(for: .seconds(30))
            guard recording?.folder == folder else { return }
            Log.write("Meeting recording: the file never finished writing; it's kept up to its last fragment")
            finished(recorded: true, error: nil)
        }
    }

    private func finished(recorded: Bool, error: Error?) {
        recorder = nil
        guard let recording else { return }
        self.recording = nil
        callPIDs = []
        quietSince = nil
        defer {
            onChange?()
            onFinish.forEach { $0() }
            onFinish = []
        }
        if let error { Log.write("Meeting recording: finishing the file failed, it's kept up to its last fragment: \(error.localizedDescription)") }
        guard recorded else {
            try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
            return warn("empty", "Nothing was recorded", "The screen never sent a frame. Try recording again.")
        }
        var folder = recording.folder
        if let event = MeetingCalendar.event(at: recording.started) {
            try? JSONEncoder().encode(event).write(to: folder.appendingPathComponent(MeetingNotes.event))
            let named = Self.newFolder(at: recording.started, event.title)
            if (try? FileManager.default.moveItem(at: folder, to: named)) != nil { folder = named }
        }
        Log.write("Meeting recording: saved \(folder.lastPathComponent)")
        notes.process(folder)
        if onFinish.isEmpty { NSWorkspace.shared.open(folder) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            Log.write("Meeting recording: capture stopped: \(error.localizedDescription)")
            self.finishCapture("capture stopped")
        }
    }

    private static func newFolder(at date: Date, _ name: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        let base = "\(formatter.string(from: date)) \(clean)"
        var folder = Self.folder.appendingPathComponent(base)
        var index = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = Self.folder.appendingPathComponent("\(base) \(index)")
            index += 1
        }
        return folder
    }

    // MARK: Screens and apps

    // The call's display, or else the one the pointer is on.
    private static func display(for window: CGRect?, in content: SCShareableContent) -> SCDisplay? {
        if let window {
            func overlap(_ display: SCDisplay) -> CGFloat {
                let shared = display.frame.intersection(window)
                return shared.isNull ? 0 : shared.width * shared.height
            }
            if let display = content.displays.max(by: { overlap($0) < overlap($1) }), overlap(display) > 0 { return display }
        }
        let mouse = NSEvent.mouseLocation
        let id = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }.flatMap(displayID) ?? CGMainDisplayID()
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }

    private nonisolated static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func screen(containing window: CGRect?) -> NSScreen? {
        guard let window else { return nil }
        return NSScreen.screens.max { a, b in
            func overlap(_ screen: NSScreen) -> CGFloat {
                guard let id = displayID(screen) else { return 0 }
                let shared = CGDisplayBounds(id).intersection(window)
                return shared.isNull ? 0 : shared.width * shared.height
            }
            return overlap(a) < overlap(b)
        }
    }

    // The app's biggest window on screen, in global display coordinates.
    private static func window(of pid: pid_t) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info -> CGRect? in
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowOwnerPID as String] as? pid_t == pid else { return nil }
            return (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    // Processes that take the mic for calls: browsers (Safari's is com.apple.WebKit.GPU) and meeting apps.
    private static let callerBundles = ["com.apple.webkit", "com.google.chrome", "company.thebrowser", "com.microsoft.edgemac",
                                        "com.brave.browser", "org.mozilla.firefox", "us.zoom", "com.microsoft.teams",
                                        "cisco-systems.spark", "com.webex", "com.tinyspeck.slackmacgap", "com.apple.avconferenced",
                                        "com.apple.facetime"]

    private static func callers(_ processes: [pid_t: AudioUse]) -> [pid_t: AudioUse] {
        processes.filter { process in callerBundles.contains(where: process.value.bundle.lowercased().hasPrefix) }
    }

    // Browsers take the mic in a helper process, e.g. com.apple.WebKit.GPU for Safari or com.google.Chrome.helper.
    private static func owns(_ app: String, _ process: String) -> Bool {
        let app = app.lowercased()
        let process = process.lowercased()
        guard !app.isEmpty, !process.isEmpty else { return false }
        if process.hasPrefix("com.apple.webkit") { return app.hasPrefix("com.apple.safari") }
        if process == "com.apple.avconferenced" { return app == "com.apple.facetime" }
        return app.hasPrefix(process.components(separatedBy: ".helper")[0])
    }

    private static func app(owning process: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && owns($0.bundleIdentifier ?? "", process) }
    }

    // MARK: Audio processes

    // Processes other than Gremlin that are taking audio from an input device, with their bundle IDs.
    nonisolated static func micUsers() -> [pid_t: String] {
        audioUse().filter { $0.value.input }.mapValues(\.bundle)
    }

    nonisolated static func audioUse() -> [pid_t: AudioUse] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [:] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [:] }
        var uses: [pid_t: AudioUse] = [:]
        for process in processes {
            let input = property(process, kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1
            let output = property(process, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1
            guard input || output, let pid = property(process, kAudioProcessPropertyPID, as: pid_t.self), pid != getpid() else { continue }
            let bundle = property(process, kAudioProcessPropertyBundleID, as: CFString.self).map { $0 as String } ?? ""
            uses[pid] = AudioUse(bundle: bundle, input: input, output: output)
        }
        return uses
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

    // Notifications can be turned off for Gremlin, and a recording that didn't happen mustn't go unnoticed.
    private func alert(_ title: String, _ body: String) {
        lastError = title
        onChange?()
        DispatchQueue.main.async {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = body
            alert.runModal()
        }
    }
}

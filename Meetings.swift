import AppKit
import AVFoundation
import CoreAudio
import ScreenCaptureKit

// Records the screen the pointer is on to ~/Movies/Meetings, from the moment it's asked to until it's asked to stop: its
// video, all system audio and the microphone, the last two on separate tracks so the transcript can tell Me from Them.
@MainActor
final class Meetings: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    struct Recording {
        let folder: URL
        let started: Date
    }

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Meetings")

    var onChange: (() -> Void)?
    let notes = MeetingNotes()
    private(set) var recording: Recording?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var starting = false
    private var lastError: String?
    private var onFinish: [() -> Void] = []

    override init() {
        super.init()
        notes.onChange = { [weak self] in self?.onChange?() }
        notes.resume(in: Self.folder)
    }

    var statusText: String? {
        if let recording {
            let elapsed = Int(Date().timeIntervalSince(recording.started))
            return "Recording · " + String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        }
        return notes.status ?? lastError
    }

    func toggle() {
        if recording != nil { return finishCapture("stopped by hand") }
        guard !starting else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.begin() }
        }
    }

    // Lets a quit wait until the recording is written out.
    func finish(then done: @escaping () -> Void) {
        guard recording != nil else { return done() }
        onFinish.append(done)
        finishCapture("Gremlin is quitting")
    }

    private func begin() {
        starting = true
        onChange?()
        Task {
            var folder: URL?
            defer {
                starting = false
                onChange?()
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = Self.display(in: content) else { throw CocoaError(.fileNoSuchFile) }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                // Retina pixels at 30 fps took enough GPU and encoder time to make the call drop frames. One pixel per
                // point keeps text readable.
                let shrink = min(1, 2560 / CGFloat(max(display.width, display.height, 1)))
                config.captureResolution = .nominal
                config.width = Int(CGFloat(display.width) * shrink) & ~1
                config.height = Int(CGFloat(display.height) * shrink) & ~1
                config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
                config.scalesToFit = true
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.captureMicrophone = true

                let target = Self.newFolder("Meeting")
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
                lastError = nil
                recording = Recording(folder: target, started: Date())
                Log.write("Meeting recording: display \(display.displayID) at \(config.width)x\(config.height)")
            } catch {
                if let folder { try? FileManager.default.removeItem(at: folder) }
                Log.write("Meeting recording: couldn't start: \(error.localizedDescription)")
                alert("Couldn't start recording", error.localizedDescription)
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
            self.alert("The meeting recording failed", error.localizedDescription)
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

    private static func display(in content: SCShareableContent) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        return content.displays.first { $0.displayID == id } ?? content.displays.first
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

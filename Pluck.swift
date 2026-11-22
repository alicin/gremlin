import AppKit
import Carbon.HIToolbox
import Vision

final class Pluck {
    private var busy = false
    private var sampler: NSColorSampler?
    private var samplingSince = Date.distantPast

    func start() {
        // Left over from a Gremlin killed mid-pick, it would block every click.
        Self.endSamplerOverlay()
        HotKeys.shared.register(kVK_ANSI_1, cmdKey | shiftKey, name: "cmd+shift+1") { [weak self] in self?.grabText() }
        HotKeys.shared.register(kVK_ANSI_2, cmdKey | shiftKey, name: "cmd+shift+2") { [weak self] in self?.pickColor() }
        HotKeys.shared.register(kVK_ANSI_V, controlKey | optionKey | cmdKey, name: "ctrl+opt+cmd+V") { [weak self] in
            self?.pasteAsPlainText()
        }
        CGRequestScreenCaptureAccess()
    }

    func grabText() {
        guard !busy else { return }
        busy = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gremlin-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            let text = Self.read(file)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                self.busy = false
                if let text, !text.isEmpty { self.copy(text) }
            }
        }
        do {
            try process.run()
        } catch {
            busy = false
        }
    }

    // A QR code or barcode in the selection wins over the text around it.
    private static func read(_ file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let barcodes = VNDetectBarcodesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([barcodes, text])
        var codes: [String] = []
        for payload in barcodes.results?.compactMap(\.payloadStringValue) ?? [] where !codes.contains(payload) {
            codes.append(payload)
        }
        if !codes.isEmpty { return codes.joined(separator: "\n") }
        return text.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // The sampler's overlay belongs to a system process that keeps it over every screen, swallowing clicks, when
    // the session ends badly: if the sampler is dropped, if Gremlin quits mid-pick, or sometimes after it answers.
    func pickColor() {
        if sampler != nil {
            // A session that never answered and shows nothing is dead, and shouldn't block picking again.
            guard Date().timeIntervalSince(samplingSince) > 2, Self.samplerOverlay().isEmpty else { return }
        }
        let sampler = NSColorSampler()
        self.sampler = sampler
        samplingSince = Date()
        sampler.show { color in
            DispatchQueue.main.async {
                guard self.sampler === sampler else { return }
                self.sampler = nil
                if let rgb = color?.usingColorSpace(.sRGB) {
                    let hex = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                        .map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }
                        .joined()
                    self.copy("#" + hex)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if self.sampler == nil { Self.endSamplerOverlay() }
                }
            }
        }
    }

    func stop() {
        if sampler != nil { Self.endSamplerOverlay() }
    }

    private static func samplerOverlay() -> Set<pid_t> {
        let samplers = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.appkit.xpc.ColorSampler")
            .map(\.processIdentifier))
        guard !samplers.isEmpty else { return [] }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }).intersection(samplers)
    }

    // Only a kill takes the overlay down: NSRunningApplication can't terminate an XPC service.
    private static func endSamplerOverlay() {
        let samplers = samplerOverlay()
        guard !samplers.isEmpty else { return }
        Log.write("Pick Color: the color sampler stayed on screen, ending it")
        samplers.forEach { kill($0, SIGKILL) }
    }

    func pasteAsPlainText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        copy(text)
        // Posting the paste keystroke needs Accessibility; without it the clipboard is still left as plain text.
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

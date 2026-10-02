import AppKit
import Carbon.HIToolbox
import Vision

final class Pluck {
    private var busy = false

    func start() {
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

    func pickColor() {
        guard !busy else { return }
        busy = true
        NSColorSampler().show { color in
            self.busy = false
            guard let rgb = color?.usingColorSpace(.sRGB) else { return }
            let hex = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                .map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }
                .joined()
            self.copy("#" + hex)
        }
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

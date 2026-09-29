import AppKit
import Carbon.HIToolbox
import Vision

final class Pluck {
    private var hotKeys: [EventHotKeyRef?] = []
    private var busy = false

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            Unmanaged<Pluck>.fromOpaque(context!).takeUnretainedValue().pressed(hotKey.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        register(keyCode: kVK_ANSI_1, id: 1)
        register(keyCode: kVK_ANSI_2, id: 2)
        CGRequestScreenCaptureAccess()
    }

    private func register(keyCode: Int, id: UInt32) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x706C636B, id: id), GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("gremlin: cmd+shift+%u is taken (%d)", id, status)
        }
        hotKeys.append(ref)
    }

    private func pressed(_ id: UInt32) {
        switch id {
        case 1: grabText()
        case 2: pickColor()
        default: break
        }
    }

    func grabText() {
        guard !busy else { return }
        busy = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gremlin-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            let text = Self.recognizeText(in: file)
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

    private static func recognizeText(in file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
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

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

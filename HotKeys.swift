import Carbon.HIToolbox

// Carbon hotkeys need no Accessibility permission, unlike event taps.
final class HotKeys {
    static let shared = HotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    func register(_ keyCode: Int, _ modifiers: Int, name: String, action: @escaping () -> Void) {
        installHandler()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x67726D6C, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("gremlin: %@ hotkey is taken (%d)", name, status)
        }
        refs.append(ref)
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            Unmanaged<HotKeys>.fromOpaque(context!).takeUnretainedValue().actions[hotKey.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}

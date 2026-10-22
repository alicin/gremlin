import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SystemConfiguration

protocol Feature: AnyObject {
    func start()
    func stop()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct Switch {
        let key: String
        let feature: Feature
        let defaultOn: Bool
    }

    private let defaults = UserDefaults.standard
    private let pluck = Pluck()
    private let focus = Focus()
    private let keepAwake = KeepAwake()
    private let sidecar = Sidecar()
    private let watcher = UniversalControlWatcher()
    private let link = PeerLink()
    private let meetings = Meetings()
    // Auto-fix focus is off by default because it needs Accessibility permission.
    private lazy var switches = [
        Switch(key: AppSwitch.autoFixFocus, feature: focus, defaultOn: false),
        Switch(key: AppSwitch.notificationCenterWatchdog, feature: NotificationCenterWatchdog(), defaultOn: true),
        Switch(key: AppSwitch.universalControlWatcher, feature: watcher, defaultOn: true),
    ]

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = MenuModel()
    private lazy var panel = MenuPanel(model: model)
    private var tick: Timer?
    private var remoteStatus: String?
    private var remoteCheckedAt = Date.distantPast
    private var seenTranscript: URL?
    private var disarmRestartAll: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var registered = Dictionary(uniqueKeysWithValues: switches.map { ($0.key, $0.defaultOn) })
        registered[AppSwitch.offerToRecordCalls] = true
        defaults.register(defaults: registered)
        keepLoginItem()

        pluck.start()
        HotKeys.shared.register(kVK_ANSI_F, controlKey | optionKey | cmdKey, name: "ctrl+opt+cmd+F") { [weak self] in
            self?.focus.fix()
        }
        if sidecar.isAvailable {
            HotKeys.shared.register(kVK_ANSI_S, controlKey | optionKey | cmdKey, name: "ctrl+opt+cmd+S") { [weak self] in
                self?.sidecar.toggle()
            }
        }
        HotKeys.shared.register(kVK_ANSI_R, controlKey | optionKey | cmdKey, name: "ctrl+opt+cmd+R") { [weak self] in
            self?.meetings.toggle()
        }
        HotKeys.shared.register(kVK_ANSI_A, controlKey | optionKey | cmdKey, name: "ctrl+opt+cmd+A") { [weak self] in
            self?.meetings.toggle(audioOnly: true)
        }
        sidecar.onChange = { [weak self] in self?.refresh() }
        meetings.onChange = { [weak self] in self?.refresh() }
        keepAwake.onChange = { [weak self] in self?.refresh() }
        watcher.onChange = { [weak self] in self?.refresh() }
        watcher.link = link
        link.localUCID = { [weak self] in self?.watcher.selfID }
        link.onRequest = { [weak self] message in self?.watcher.handle(message) ?? Message(type: "reply") }
        link.onChange = { [weak self] in
            self?.remoteStatus = nil
            self?.refresh()
        }
        link.start()
        for item in switches where defaults.bool(forKey: item.key) {
            item.feature.start()
        }

        model.thisMac = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac"
        model.perform = { [weak self] action in self?.perform(action) }
        panel.onOpen = { [weak self] in
            self?.model.awakeOthers = KeepAwake.others()
            self?.checkRemote()
            self?.refresh()
        }
        panel.onClose = { [weak self] in
            self?.model.restarted = []
            self?.model.confirmRestartAll = false
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meetings.recording != nil else { return .terminateNow }
        meetings.finish { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        switches.forEach { $0.feature.stop() }
        meetings.notes.stop()
        keepAwake.stop()
    }

    // While recording, a click on the record button stops it, and a right-click or Control-click opens the panel.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true
        if meetings.recording != nil, !secondary, !panel.isOpen { return meetings.toggle() }
        panel.toggle(below: statusItem.button)
    }

    private func checkRemote() {
        guard link.paired != nil, Date().timeIntervalSince(remoteCheckedAt) > 5 else { return }
        remoteCheckedAt = Date()
        link.request(Message(type: "status")) { [weak self] reply in
            self?.remoteStatus = reply.map { $0.status ?? MenuModel.reachable } ?? MenuModel.unreachable
            self?.refresh()
        }
    }

    private func refresh() {
        updateStatusButton()
        if meetings.recording != nil, tick == nil {
            let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusButton() }
            }
            RunLoop.main.add(tick, forMode: .common)
            self.tick = tick
        } else if meetings.recording == nil {
            tick?.invalidate()
            tick = nil
        }
        statusItem.button?.toolTip = meetings.recording == nil ? nil : "Click to stop recording, right-click for Gremlin"
        updateModel()
    }

    private func updateModel() {
        model.recording = meetings.recording.map { .init(started: $0.started, audioOnly: $0.audioOnly, hearing: meetings.hearing) }
        model.starting = meetings.starting
        model.banners = banners()

        let until = keepAwake.until
        model.awakeStop = Self.awakeStop(until)
        model.awakeText = until.map { $0 == .distantFuture ? "Until you turn it off" : "Until " + $0.formatted(date: .omitted, time: .shortened) }
            ?? "Off"

        if sidecar.isAvailable {
            let status = sidecar.status
            if let status {
                defaults.set(status.name, forKey: "sidecarLastName")
                defaults.set(Date(), forKey: "sidecarLastSeen")
            }
            let state: MenuModel.IPad.State = switch (status?.busy, status?.connected) {
            case (true, true): .disconnecting
            case (true, _): .connecting
            case (_, true): .connected
            case (false, false): .nearby
            default: .away
            }
            model.ipad = .init(name: status?.name ?? defaults.string(forKey: "sidecarLastName") ?? "iPad", state: state,
                               seen: status == nil ? defaults.object(forKey: "sidecarLastSeen") as? Date : nil)
        }

        model.watcher = .init(isOn: watcher.isRunning, tone: watcherTone(), status: watcher.statusText, detail: watcher.detailText,
                              lastReset: watcher.lastResetText)
        if let paired = link.paired {
            // The other Mac answers with its own status, whose "here" means itself, so only whether it answered shows.
            let reach = remoteStatus.map { $0 == MenuModel.unreachable ? MenuModel.unreachable : MenuModel.reachable }
            model.pairing = .paired(name: paired.name, status: reach ?? "checking…")
        } else {
            model.pairing = link.isPairing ? .pairing : .unpaired
        }

        var states = Dictionary(uniqueKeysWithValues: switches.map { ($0.key, defaults.bool(forKey: $0.key)) })
        states[AppSwitch.offerToRecordCalls] = defaults.bool(forKey: AppSwitch.offerToRecordCalls)
        model.switches = states
        model.accessibility = AXIsProcessTrusted()
        model.login = SMAppService.mainApp.status == .enabled
        model.language = defaults.string(forKey: "meetingLanguage")
    }

    private func banners() -> [MenuModel.Banner] {
        var banners: [MenuModel.Banner] = []
        if let problem = meetings.problem {
            banners.append(.init(id: "problem", kind: .problem, symbol: problem.title.contains("mic") ? "mic.slash.fill" : "exclamationmark",
                                 title: problem.title, detail: problem.message, button: problem.fix == nil ? "OK" : "Fix",
                                 action: problem.fix.map { .fix($0) } ?? .dismissProblem, dismiss: problem.fix == nil ? nil : .dismissProblem))
        }
        if let progress = meetings.notes.progress {
            banners.append(.init(id: "progress", kind: .working, title: progress.title, detail: progress.detail, button: "Open",
                                 action: .open(progress.folder)))
        } else if let outcome = meetings.notes.outcome, outcome.folder != seenTranscript, Date().timeIntervalSince(outcome.date) < 7200 {
            banners.append(.init(id: "outcome", kind: outcome.ok ? .done : .problem,
                                 title: outcome.ok ? "Transcript ready" : "Couldn't transcribe \(MeetingNotes.title(of: outcome.folder))",
                                 detail: outcome.detail, button: "Open", action: .openTranscript(outcome.folder), dismiss: .dismissTranscript))
        }
        return banners
    }

    // The slider stop that holds the time left, so the knob slides down as time passes.
    private static func awakeStop(_ until: Date?) -> Int {
        guard let until else { return 0 }
        guard until != .distantFuture else { return KeepAwake.choices.count }
        let left = until.timeIntervalSinceNow
        return 1 + (KeepAwake.choices.firstIndex { ($0.duration ?? .infinity) >= left - 1 } ?? KeepAwake.choices.count - 1)
    }

    private func watcherTone() -> Tone {
        guard watcher.isRunning else { return .off }
        guard watcher.streamRunning else { return .warning }
        switch watcher.phase {
        case .watching: return .good
        case .scheduled, .gaveUp: return .warning
        case .resetting, .peerHandling: return .busy
        }
    }

    // Shows how long the recording has run next to a red record button, so it's clear at a glance that it's going.
    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let recording = meetings.recording
        var image = NSImage(systemSymbolName: recording == nil ? "pawprint.fill" : "record.circle.fill", accessibilityDescription: "Gremlin")
        // The menu bar ignores a tint color, so the record button is drawn in color instead of as a template.
        if recording != nil { image = image?.withSymbolConfiguration(.init(paletteColors: [.white, .systemRed])) }
        image?.isTemplate = recording == nil
        button.image = image
        button.imagePosition = recording == nil ? .imageOnly : .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = recording.map { " " + Meetings.elapsed(since: $0.started) } ?? ""
    }

    private func perform(_ action: MenuModel.Action) {
        switch action {
        case .record(let audioOnly):
            panel.close()
            meetings.toggle(audioOnly: audioOnly)
        case .stopRecording:
            panel.close()
            if meetings.recording != nil { meetings.toggle() }
        case .open(let url):
            panel.close()
            NSWorkspace.shared.open(url)
        case .openTranscript(let folder):
            panel.close()
            seenTranscript = folder
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(MeetingNotes.transcript)])
        case .dismissTranscript:
            seenTranscript = meetings.notes.outcome?.folder
        case .fix(let url):
            panel.close()
            meetings.dismissProblem()
            NSWorkspace.shared.open(url)
        case .dismissProblem:
            meetings.dismissProblem()
        case .showRecordings:
            panel.close()
            try? FileManager.default.createDirectory(at: Meetings.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Meetings.folder)
        // These act on the app in front, or capture the screen, so the panel gets out of the way first.
        case .grabText:
            panel.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.pluck.grabText() }
        case .pickColor:
            panel.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.pluck.pickColor() }
        case .plainPaste:
            panel.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.pluck.pasteAsPlainText() }
        case .fixFocus:
            panel.close()
            focus.fix()
        case .keepAwake(let stop):
            stop == 0 ? keepAwake.stop() : keepAwake.keep(for: KeepAwake.choices[stop - 1].duration)
        case .toggleSidecar:
            sidecar.toggle()
        case .setSwitch(let key, let on):
            defaults.set(on, forKey: key)
            if let item = switches.first(where: { $0.key == key }) { on ? item.feature.start() : item.feature.stop() }
        case .resetUniversalControl(let target):
            watcher.resetNow(target)
        case .startPairing:
            link.startPairing()
        case .stopPairing:
            link.stopPairing()
        case .unpair:
            link.unpair()
        case .restart(let index):
            let item = Restart.items[index]
            Restart.restart(item.title, item.processes)
            model.restarted.insert(index)
        // Restarting everything also empties the clipboard, so it takes a second click.
        case .restartAll:
            guard model.confirmRestartAll else {
                model.confirmRestartAll = true
                disarmRestartAll?.cancel()
                let disarm = DispatchWorkItem { [weak self] in self?.model.confirmRestartAll = false }
                disarmRestartAll = disarm
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: disarm)
                return
            }
            model.confirmRestartAll = false
            Restart.restart("everything", Restart.all)
            model.restarted = Set(Restart.items.indices)
        case .setLogin(let on):
            setLogin(on)
        case .setLanguage(let code):
            defaults.set(code, forKey: "meetingLanguage")
        case .quit:
            NSApp.terminate(nil)
        }
        refresh()
    }

    // A login item opens the app from where it was registered, so after the app moves it's registered again from
    // here. The path is empty once Start at Login is turned off, and then Gremlin leaves it off.
    private func keepLoginItem() {
        let here = Bundle.main.bundlePath
        // Before the path was kept, Gremlin registered itself on its first launch, always from ~/Applications.
        let earlier = defaults.bool(forKey: "loginItemRegistered") ? NSHomeDirectory() + "/Applications/Gremlin.app" : nil
        let registered = defaults.string(forKey: "loginItemPath") ?? earlier
        guard registered != here, registered?.isEmpty != true else { return }
        Log.write("Registering the login item at \(here)")
        try? SMAppService.mainApp.unregister()
        try? SMAppService.mainApp.register()
        defaults.set(here, forKey: "loginItemPath")
    }

    private func setLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("gremlin: start at login: %@", error.localizedDescription)
        }
        defaults.set(on ? Bundle.main.bundlePath : "", forKey: "loginItemPath")
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
// install.sh stops Gremlin with SIGTERM; quitting through AppKit lets a meeting recording finish writing.
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { NSApp.terminate(nil) }
terminate.resume()
app.run()

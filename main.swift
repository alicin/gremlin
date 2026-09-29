import AppKit
import ServiceManagement

protocol Feature: AnyObject {
    func start()
    func stop()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct Switch {
        let key: String
        let title: String
        let feature: Feature
    }

    private let defaults = UserDefaults.standard
    private let pluck = Pluck()
    private let watcher = UniversalControlWatcher()
    private let link = PeerLink()
    private lazy var switches = [
        Switch(key: "universalControlWatcher", title: "Universal Control Watcher", feature: watcher),
    ]

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var switchItems: [NSMenuItem] = []
    private let watcherStatusItem = NSMenuItem()
    private let lastResetItem = NSMenuItem()
    private let resetItem = NSMenuItem(title: "Reset Universal Control Now", action: nil, keyEquivalent: "")
    private let remoteItem = NSMenuItem()
    private let pairItem = NSMenuItem(title: "", action: #selector(togglePairing), keyEquivalent: "")
    private var remoteStatus: String?
    private var remoteCheckedAt = Date.distantPast
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: switches.map { ($0.key, true) }))
        if !defaults.bool(forKey: "loginItemRegistered") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginItemRegistered")
        }

        pluck.start()
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

        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Gremlin")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.menu = buildMenu()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        switches.forEach { $0.feature.stop() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        checkRemote()
    }

    private func checkRemote() {
        guard link.paired != nil, Date().timeIntervalSince(remoteCheckedAt) > 5 else { return }
        remoteCheckedAt = Date()
        link.request(Message(type: "status")) { [weak self] reply in
            self?.remoteStatus = reply.map { $0.status ?? "reachable" } ?? "not reachable"
            self?.refresh()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(action("Grab Text", #selector(grabText), key: "1"))
        menu.addItem(action("Pick Color", #selector(pickColor), key: "2"))
        menu.addItem(.separator())

        for (index, item) in switches.enumerated() {
            let menuItem = action(item.title, #selector(toggleSwitch))
            menuItem.tag = index
            switchItems.append(menuItem)
            menu.addItem(menuItem)
        }
        for item in [watcherStatusItem, lastResetItem] {
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }
        resetItem.target = self
        resetItem.indentationLevel = 1
        menu.addItem(resetItem)
        menu.addItem(.separator())

        remoteItem.isEnabled = false
        menu.addItem(remoteItem)
        pairItem.target = self
        menu.addItem(pairItem)
        menu.addItem(.separator())

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Gremlin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        return item
    }

    private func refresh() {
        for (index, item) in switches.enumerated() where index < switchItems.count {
            switchItems[index].state = defaults.bool(forKey: item.key) ? .on : .off
        }
        watcherStatusItem.title = watcher.statusText
        watcherStatusItem.isHidden = !watcher.isRunning
        lastResetItem.title = watcher.lastResetText

        if let paired = link.paired {
            let submenu = NSMenu()
            for (title, tag) in [("On This Mac", 0), ("On \(paired.name)", 1), ("On Both Macs", 2)] {
                let item = NSMenuItem(title: title, action: #selector(resetUniversalControl), keyEquivalent: "")
                item.target = self
                item.tag = tag
                submenu.addItem(item)
            }
            resetItem.submenu = submenu
            resetItem.title = "Reset Universal Control"
            remoteItem.title = "\(paired.name): \(remoteStatus ?? "checking…")"
            remoteItem.isHidden = false
            pairItem.title = "Unpair \(paired.name)"
        } else {
            resetItem.submenu = nil
            resetItem.action = #selector(resetUniversalControl)
            resetItem.tag = 0
            resetItem.title = "Reset Universal Control Now"
            remoteItem.title = "Waiting for the other Mac: choose Pair Another Mac… there too"
            remoteItem.isHidden = !link.isPairing
            pairItem.title = link.isPairing ? "Cancel Pairing" : "Pair Another Mac…"
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func grabText() {
        pluck.grabText()
    }

    @objc private func pickColor() {
        pluck.pickColor()
    }

    @objc private func toggleSwitch(_ sender: NSMenuItem) {
        let item = switches[sender.tag]
        let on = !defaults.bool(forKey: item.key)
        defaults.set(on, forKey: item.key)
        on ? item.feature.start() : item.feature.stop()
        refresh()
    }

    @objc private func resetUniversalControl(_ sender: NSMenuItem) {
        watcher.resetNow([.local, .remote, .both][sender.tag])
    }

    @objc private func togglePairing() {
        if link.paired != nil {
            link.unpair()
        } else if link.isPairing {
            link.stopPairing()
        } else {
            link.startPairing()
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("gremlin: start at login: %@", error.localizedDescription)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

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
    private lazy var switches = [
        Switch(key: "universalControlWatcher", title: "Universal Control Watcher", feature: watcher),
    ]

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var switchItems: [NSMenuItem] = []
    private let watcherStatusItem = NSMenuItem()
    private let lastResetItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: switches.map { ($0.key, true) }))
        if !defaults.bool(forKey: "loginItemRegistered") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginItemRegistered")
        }

        pluck.start()
        watcher.onChange = { [weak self] in self?.refresh() }
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
        let resetItem = action("Reset Universal Control Now", #selector(resetUniversalControl))
        resetItem.indentationLevel = 1
        menu.addItem(resetItem)
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

    @objc private func resetUniversalControl() {
        watcher.resetNow()
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

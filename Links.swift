import AppKit
import UniformTypeIdentifiers

struct LinkConfig: Codable {
    enum Modifier: String, Codable, CaseIterable {
        case fn, option, control, shift

        var title: String {
            switch self {
            case .fn: "Fn"
            case .option: "Option"
            case .control: "Control"
            case .shift: "Shift"
            }
        }

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .fn: .function
            case .option: .option
            case .control: .control
            case .shift: .shift
            }
        }
    }

    var primary: LinkTarget?
    var alternative = LinkTarget.prompt
    var modifier = Modifier.fn
    var rules: [LinkRule] = []
    var appsOff: Set<String> = []
    var shown: [LinkTarget] = []
    var seenBrowsers: Set<String> = []
    var keys: [String: String] = [:]
    var profiles: [String: [BrowserProfile]] = [:]
    var removeTracking = true
    var expandShort = true
    var unwrapRedirects = true
    var shortHosts: [String] = []
    var script = ""
    var keepHistory = false

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        primary = try values.decodeIfPresent(LinkTarget.self, forKey: .primary)
        alternative = try values.decodeIfPresent(LinkTarget.self, forKey: .alternative) ?? .prompt
        modifier = try values.decodeIfPresent(Modifier.self, forKey: .modifier) ?? .fn
        rules = try values.decodeIfPresent([LinkRule].self, forKey: .rules) ?? []
        appsOff = try values.decodeIfPresent(Set<String>.self, forKey: .appsOff) ?? []
        shown = try values.decodeIfPresent([LinkTarget].self, forKey: .shown) ?? []
        seenBrowsers = try values.decodeIfPresent(Set<String>.self, forKey: .seenBrowsers) ?? []
        keys = try values.decodeIfPresent([String: String].self, forKey: .keys) ?? [:]
        profiles = try values.decodeIfPresent([String: [BrowserProfile]].self, forKey: .profiles) ?? [:]
        removeTracking = try values.decodeIfPresent(Bool.self, forKey: .removeTracking) ?? true
        expandShort = try values.decodeIfPresent(Bool.self, forKey: .expandShort) ?? true
        unwrapRedirects = try values.decodeIfPresent(Bool.self, forKey: .unwrapRedirects) ?? true
        shortHosts = try values.decodeIfPresent([String].self, forKey: .shortHosts) ?? []
        script = try values.decodeIfPresent(String.self, forKey: .script) ?? ""
        keepHistory = try values.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? false
    }
}

struct LinkDecision {
    var url: URL
    var target: LinkTarget
    var why: String
}

struct LinkEvent: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var received: String
    var opened: String
    var source: String?
    var target: String
    var why: String
}

// Takes every link once Gremlin is the default browser, and sends it to the right browser or app.
@MainActor
final class Links: NSObject, ObservableObject {
    private static let probe = URL(string: "https://example.com")!

    @Published var config: LinkConfig { didSet { save() } }
    @Published private(set) var browsers: [Browser] = []
    @Published private(set) var isDefault = false
    @Published private(set) var recent: [LinkEvent] = []
    @Published var profilesDenied: Set<String> = []
    @Published var editing: UUID?
    @Published var testText = ""
    @Published var testResult: String?

    var onChange: (() -> Void)?

    private let folder: URL
    private lazy var picker = LinkPicker(links: self)
    private var cachedApps: [(name: String, id: String)]?

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Gremlin")) {
        self.folder = folder
        let file = folder.appendingPathComponent("links.json")
        if let data = try? Data(contentsOf: file) {
            do {
                config = try JSONDecoder().decode(LinkConfig.self, from: data)
            } catch {
                // Starting from nothing would overwrite the rules on the next save, so a file that can't be read is kept.
                Log.write("Couldn't read links.json, setting it aside: \(error)")
                try? FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("links-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
                config = LinkConfig()
            }
        } else {
            config = LinkConfig()
        }
        super.init()
        if let data = try? Data(contentsOf: historyFile), let events = try? JSONDecoder().decode([LinkEvent].self, from: data), config.keepHistory {
            recent = events
        }
        refresh()
    }

    private var configFile: URL { folder.appendingPathComponent("links.json") }
    private var historyFile: URL { folder.appendingPathComponent("links-history.json") }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: configFile, options: .atomic)
        } catch {
            Log.write("Couldn't save links.json: \(error)")
        }
    }

    // MARK: State

    func refresh() {
        cachedApps = nil
        let installed = Browsers.installed()
        if installed != browsers { browsers = installed }
        isDefault = NSWorkspace.shared.urlForApplication(toOpen: Self.probe).flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        let fresh = installed.filter { !config.seenBrowsers.contains($0.id) }
        if !fresh.isEmpty {
            config.seenBrowsers.formUnion(fresh.map(\.id))
            config.shown += fresh.map { LinkTarget(app: $0.id) }
        }
        if config.primary == nil, let current = systemBrowser() {
            config.primary = LinkTarget(app: current)
        }
    }

    private func systemBrowser() -> String? {
        guard let id = NSWorkspace.shared.urlForApplication(toOpen: Self.probe).flatMap({ Bundle(url: $0)?.bundleIdentifier }),
              id != Bundle.main.bundleIdentifier else { return nil }
        return id
    }

    var primary: LinkTarget { config.primary ?? LinkTarget(app: "com.apple.Safari") }

    // The destinations the picker offers, in order, leaving out anything since uninstalled.
    var shownTargets: [LinkTarget] {
        config.shown.filter { target in browsers.contains { $0.id == target.app } || appURL(target.app) != nil }
    }

    // Everything that can be shown: each browser, then its profiles and private window.
    var allTargets: [LinkTarget] {
        browsers.flatMap { browser -> [LinkTarget] in
            var targets = [LinkTarget(app: browser.id)]
            targets += (config.profiles[browser.id] ?? []).map { LinkTarget(app: browser.id, profile: $0.id, profileName: $0.name) }
            if browser.privateFlag != nil { targets.append(LinkTarget(app: browser.id, isPrivate: true)) }
            return targets
        }
    }

    func title(of target: LinkTarget) -> String {
        guard !target.isPrompt else { return "Ask Every Time" }
        let name = appURL(target.app).map(Browsers.name) ?? target.app
        if target.isPrivate { return "\(name) (Private)" }
        return target.profileName.map { "\(name) · \($0)" } ?? name
    }

    func icon(of target: LinkTarget) -> NSImage? {
        guard !target.isPrompt, let url = appURL(target.app) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func appURL(_ id: String) -> URL? {
        browsers.first { $0.id == id }?.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    var installedLinkApps: [LinkApp] {
        LinkApp.all.filter { app in app.apps.contains { appURL($0) != nil } }
    }

    // The key that picks a target in the picker. Set by hand, or else the first free letter of its name.
    func pickerKeys(for targets: [LinkTarget]) -> [String: String] {
        var keys: [String: String] = [:]
        var taken = Set(targets.compactMap { config.keys[$0.id]?.lowercased() })
        for target in targets {
            if let key = config.keys[target.id]?.lowercased() {
                keys[target.id] = key
            } else if let letter = title(of: target).lowercased().first(where: { $0.isLetter && $0.isASCII && !taken.contains(String($0)) }) {
                keys[target.id] = String(letter)
                taken.insert(String(letter))
            }
        }
        return keys
    }

    // MARK: Being the default browser

    func makeDefault() {
        if let current = systemBrowser() { config.primary = LinkTarget(app: current) }
        setSystemBrowser(Bundle.main.bundleURL)
    }

    func stopBeingDefault() {
        let app = primary.isPrompt ? nil : appURL(primary.app)
        guard let url = app ?? appURL("com.apple.Safari") else { return }
        setSystemBrowser(url)
    }

    // macOS asks the user to confirm before it changes this.
    private func setSystemBrowser(_ url: URL) {
        NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "http") { error in
            if let error { Log.write("Couldn't set the default browser for http: \(error)") }
            NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "https") { [weak self] error in
                if let error { Log.write("Couldn't set the default browser for https: \(error)") }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.refresh()
                        self?.onChange?()
                    }
                }
            }
        }
    }

    // MARK: Receiving links

    func receive(_ urls: [URL], from source: NSRunningApplication?) {
        // The keys are read now: a short link can take seconds to expand, and they're long let go of by then.
        let modifiers = NSEvent.modifierFlags
        // Tools like `open` have exited by now. The app in front is the best guess then, unless that's Gremlin itself.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sourceID = source.flatMap(Self.owningApp) ?? (front == Bundle.main.bundleIdentifier ? nil : front)
        Task {
            var ask: [URL] = []
            for url in urls {
                switch url.scheme?.lowercased() {
                case "gremlin":
                    command(url)
                case "http", "https":
                    let decision = await decide(url, source: sourceID, modifiers: modifiers)
                    record(received: url, decision, source: sourceID)
                    if decision.target.isPrompt { ask.append(decision.url) } else { open(decision.url, in: decision.target) }
                case "file":
                    if primary.isPrompt { ask.append(url) } else { open(url, in: primary) }
                default:
                    Log.write("Ignoring a link with scheme \(url.scheme ?? "none")")
                }
            }
            if !ask.isEmpty { prompt(ask, source: sourceID) }
        }
    }

    func prompt(_ urls: [URL], source: String? = nil) {
        refresh()
        picker.show(urls, source: source)
    }

    // A helper inside an app counts as the app: Slack.app/Contents/Frameworks/Slack Helper.app is Slack.
    private static func owningApp(_ app: NSRunningApplication) -> String? {
        guard let path = app.bundleURL?.path else { return app.bundleIdentifier }
        var outer = ""
        for part in path.split(separator: "/") {
            outer += "/" + part
            if part.hasSuffix(".app") { break }
        }
        return outer.hasSuffix(".app") ? Bundle(path: outer)?.bundleIdentifier ?? app.bundleIdentifier : app.bundleIdentifier
    }

    // A URL from anywhere can reach this, so only web links get through, however it asks for them to be opened. A
    // file:// link opened with a chosen app could run something.
    private func command(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func has(_ name: String) -> Bool { items.contains { $0.name == name } }
        switch parts.host ?? parts.path {
        case "open":
            let links = items.filter { $0.name == "url" }.compactMap { $0.value.flatMap(LinkCleaner.httpURL) }
            guard !links.isEmpty else { return }
            if has("prompt") { return prompt(links) }
            if let app = value("app") {
                let target = LinkTarget(app: app, profile: value("profile"), profileName: value("profile"), isPrivate: has("private"))
                links.forEach { open($0, in: target) }
            } else {
                receive(links, from: nil)
            }
        case "set-default":
            config.primary = has("prompt") ? .prompt : value("app").map { LinkTarget(app: $0, profile: value("profile"), profileName: value("profile"), isPrivate: has("private")) } ?? config.primary
            onChange?()
        default:
            Log.write("Unknown gremlin link: \(parts.host ?? parts.path)")
        }
    }

    func decide(_ url: URL, source: String?, modifiers: NSEvent.ModifierFlags) async -> LinkDecision {
        var link = config.unwrapRedirects ? LinkCleaner.unwrap(url) : url
        if config.expandShort, LinkCleaner.isShort(link, extra: config.shortHosts) {
            link = await ShortLinkExpander.expand(link, extra: config.shortHosts)
            if config.unwrapRedirects { link = LinkCleaner.unwrap(link) }
        }
        if config.removeTracking { link = LinkCleaner.removeTracking(link) }
        link = await LinkCleaner.runScript(config.script, on: link, source: source)

        // Holding the key is a choice made for this one link, so it comes before anything set up in advance.
        if modifiers.contains(config.modifier.flag) {
            return LinkDecision(url: link, target: config.alternative, why: "Holding \(config.modifier.title)")
        }
        if let rule = config.rules.first(where: { $0.matches(link, source: source) }) {
            let result = await LinkCleaner.runScript(rule.script, on: link, source: source)
            return LinkDecision(url: result, target: rule.target, why: "Rule: \(rule.name.isEmpty ? "Untitled" : rule.name)")
        }
        for app in installedLinkApps where !config.appsOff.contains(app.id) {
            guard let rewritten = app.rewrite(link), let id = app.apps.first(where: { appURL($0) != nil }) else { continue }
            return LinkDecision(url: rewritten, target: LinkTarget(app: id), why: app.title)
        }
        return LinkDecision(url: link, target: primary, why: "Default")
    }

    func test(_ text: String) {
        guard let url = LinkCleaner.httpURL(text) else {
            testResult = text.isEmpty ? nil : "That isn't a web link"
            return
        }
        testResult = "Checking…"
        Task {
            let decision = await decide(url, source: nil, modifiers: [])
            testResult = "\(title(of: decision.target)) · \(decision.why)\n\(decision.url.absoluteString)"
        }
    }

    // MARK: Opening

    func open(_ url: URL, in target: LinkTarget, background: Bool = false, newWindow: Bool = false) {
        // Handing a web link back to Launch Services without naming an app would bring it straight back here.
        guard target.app != Bundle.main.bundleIdentifier, !target.isPrompt, let app = appURL(target.app) ?? fallbackApp() else {
            Log.write("Nowhere to open a link: \(target.app)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        let browser = browsers.first { $0.id == target.app }
        let arguments = browser.map { Browsers.arguments(for: $0, target: target, newWindow: newWindow) } ?? []
        let done: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            if let error { Log.write("Couldn't open a link in \(app.lastPathComponent): \(error.localizedDescription)") }
        }
        if !arguments.isEmpty, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            // A browser only reads its flags from a launch, which hands them on to the copy already running.
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments + [url.absoluteString]
            NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: done)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration, completionHandler: done)
        }
    }

    private func fallbackApp() -> URL? {
        primary.isPrompt ? appURL("com.apple.Safari") : appURL(primary.app) ?? appURL("com.apple.Safari")
    }

    func addRule(for url: URL, target: LinkTarget) {
        guard var host = url.host?.lowercased() else { return }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        config.rules.insert(LinkRule(name: host, target: target, matchers: [LinkMatcher(kind: .domain, value: host)]), at: 0)
    }

    func openCopiedLink() {
        let urls = Self.links(in: NSPasteboard.general)
        if !urls.isEmpty { receive(urls, from: nil) }
    }

    static func links(in pasteboard: NSPasteboard) -> [URL] {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.url.identifier]]) as? [URL] ?? []
        urls = urls.filter { LinkCleaner.httpURL($0.absoluteString) != nil }
        if urls.isEmpty, let text = pasteboard.string(forType: .string), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            urls = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).filter { LinkCleaner.httpURL($0.absoluteString) != nil }
        }
        return urls
    }

    // MARK: Services

    @objc func openLinks(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.links(in: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "There's no link in the selection."
            return
        }
        if userData == "prompt" || NSEvent.modifierFlags.contains(.option) {
            prompt(urls)
        } else {
            receive(urls, from: nil)
        }
    }

    // MARK: History

    private func record(received: URL, _ decision: LinkDecision, source: String?) {
        let event = LinkEvent(date: Date(), received: received.absoluteString, opened: decision.url.absoluteString,
                              source: source.flatMap(appURL).map(Browsers.name) ?? source, target: title(of: decision.target), why: decision.why)
        recent.insert(event, at: 0)
        recent = Array(recent.prefix(config.keepHistory ? 500 : 50))
        guard config.keepHistory else { return }
        if let data = try? JSONEncoder().encode(recent) { try? data.write(to: historyFile, options: .atomic) }
    }

    func clearHistory() {
        recent = []
        try? FileManager.default.removeItem(at: historyFile)
    }

    func setKeepHistory(_ on: Bool) {
        config.keepHistory = on
        if !on { try? FileManager.default.removeItem(at: historyFile) }
    }

    // MARK: Profiles and rules

    // Reading another browser's folder makes macOS ask for permission, so it only happens when asked for.
    func findProfiles() {
        for browser in browsers {
            if case .other = browser.family { continue }
            if let found = Browsers.profiles(of: browser) {
                config.profiles[browser.id] = found
                profilesDenied.remove(browser.id)
            } else {
                profilesDenied.insert(browser.id)
            }
        }
    }

    func toggleShown(_ target: LinkTarget) {
        if let index = config.shown.firstIndex(of: target) {
            config.shown.remove(at: index)
        } else {
            config.shown.append(target)
        }
    }

    func moveUp<Item>(_ item: Item, in list: WritableKeyPath<LinkConfig, [Item]>) where Item: Equatable {
        guard let index = config[keyPath: list].firstIndex(of: item), index > 0 else { return }
        config[keyPath: list].swapAt(index, index - 1)
    }

    func rulesText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(config.rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    // Pasted rules get new ids so that pasting the same ones twice leaves two separate sets to tidy up.
    @discardableResult
    func addRules(fromText text: String) -> Bool {
        guard let data = text.data(using: .utf8), let rules = try? JSONDecoder().decode([LinkRule].self, from: data) else { return false }
        config.rules += rules.map { rule in
            var rule = rule
            rule.id = UUID()
            return rule
        }
        return true
    }

    // Reading every app's bundle is too slow to repeat each time a menu redraws.
    func allApps() -> [(name: String, id: String)] {
        if let cachedApps { return cachedApps }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var found: [String: String] = [:]
        for folder in folders {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                if let id = Bundle(path: "\(folder)/\(item)")?.bundleIdentifier { found[id] = String(item.dropLast(4)) }
            }
        }
        let apps = found.map { (name: $0.value, id: $0.key) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedApps = apps
        return apps
    }

    func runningApps() -> [(name: String, id: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return (name: app.localizedName ?? id, id: id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

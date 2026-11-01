import AppKit

// The browsers on this Mac, with what each can be told at launch.
struct Browser: Identifiable, Hashable {
    enum Family {
        case chromium(support: String)
        case firefox(support: String)
        case other
    }

    let id: String
    let name: String
    let url: URL
    let family: Family
    let privateFlag: String?

    static func == (a: Browser, b: Browser) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    var newWindowFlag: String? {
        switch family {
        case .chromium, .firefox: "--new-window"
        case .other: nil
        }
    }
}

struct BrowserProfile: Codable, Hashable {
    let id: String
    let name: String
}

enum Browsers {
    private static let families: [String: (Browser.Family, String?)] = [
        "com.google.Chrome": (.chromium(support: "Google/Chrome"), "--incognito"),
        "com.google.Chrome.canary": (.chromium(support: "Google/Chrome Canary"), "--incognito"),
        "com.google.Chrome.beta": (.chromium(support: "Google/Chrome Beta"), "--incognito"),
        "com.google.Chrome.dev": (.chromium(support: "Google/Chrome Dev"), "--incognito"),
        "org.chromium.Chromium": (.chromium(support: "Chromium"), "--incognito"),
        "com.microsoft.edgemac": (.chromium(support: "Microsoft Edge"), "--inprivate"),
        "com.brave.Browser": (.chromium(support: "BraveSoftware/Brave-Browser"), "--incognito"),
        "com.vivaldi.Vivaldi": (.chromium(support: "Vivaldi"), "--incognito"),
        "com.operasoftware.Opera": (.other, "--private"),
        "org.mozilla.firefox": (.firefox(support: "Firefox"), "--private-window"),
        "org.mozilla.firefoxdeveloperedition": (.firefox(support: "Firefox"), "--private-window"),
        "org.mozilla.nightly": (.firefox(support: "Firefox"), "--private-window"),
        "app.zen-browser.zen": (.firefox(support: "zen"), "--private-window"),
        "io.gitlab.librewolf-community": (.firefox(support: "LibreWolf"), "--private-window"),
    ]

    static func installed() -> [Browser] {
        let probe = URL(string: "https://example.com")!
        var seen = Set<String>()
        var browsers: [Browser] = []
        // Launch Services also knows about copies on other disks and in backups, so the usual places come first.
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: probe).sorted { rank($0) < rank($1) }
        for url in urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  seen.insert(id).inserted else { continue }
            let known = families[id]
            browsers.append(Browser(id: id, name: name(of: url), url: url, family: known?.0 ?? .other, privateFlag: known?.1))
        }
        return browsers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func rank(_ url: URL) -> Int {
        if url.path.hasPrefix("/Applications/") || url.path.hasPrefix("/System/") { return 0 }
        return url.path.hasPrefix(NSHomeDirectory() + "/Applications/") ? 1 : 2
    }

    static func name(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // Nil when macOS won't let Gremlin read the browser's folder, which is different from having no profiles.
    static func profiles(of browser: Browser) -> [BrowserProfile]? {
        switch browser.family {
        case .chromium(let support): chromiumProfiles(support)
        case .firefox(let support): firefoxProfiles(support)
        case .other: []
        }
    }

    private static func supportFolder(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(name)")
    }

    static func chromiumProfiles(_ support: String) -> [BrowserProfile]? {
        let file = supportFolder(support).appendingPathComponent("Local State")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parseChromiumProfiles(data)
    }

    static func parseChromiumProfiles(_ data: Data) -> [BrowserProfile] {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.map { BrowserProfile(id: $0.key, name: $0.value["name"] as? String ?? $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func firefoxProfiles(_ support: String) -> [BrowserProfile]? {
        let file = supportFolder(support).appendingPathComponent("profiles.ini")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parseFirefoxProfiles(text)
    }

    static func parseFirefoxProfiles(_ text: String) -> [BrowserProfile] {
        var names: [String] = []
        var inProfile = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                inProfile = line.hasPrefix("[Profile")
            } else if inProfile, line.hasPrefix("Name=") {
                names.append(String(line.dropFirst(5)))
            }
        }
        return names.sorted().map { BrowserProfile(id: $0, name: $0) }
    }

    static func arguments(for browser: Browser, target: LinkTarget, newWindow: Bool) -> [String] {
        var arguments: [String] = []
        if target.isPrivate, let flag = browser.privateFlag {
            arguments.append(flag)
        } else if let profile = target.profile {
            switch browser.family {
            case .chromium: arguments.append("--profile-directory=\(profile)")
            case .firefox: arguments += ["-P", profile]
            case .other: break
            }
        }
        if newWindow, !target.isPrivate, let flag = browser.newWindowFlag { arguments.append(flag) }
        return arguments
    }
}

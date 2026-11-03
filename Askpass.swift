import AppKit
import Security

// ssh asks for passwords, key passphrases and unknown host keys through SSH_ASKPASS. Gremlin's own binary answers,
// started by ssh as a separate process, and can fill in a password saved in the Keychain.
enum Askpass {
    private static let marker = "GREMLIN_ASKPASS"
    private static let service = "Gremlin Drives"

    static func environment(host: String, name: String, state: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executablePath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[marker] = "1"
        environment["GREMLIN_ASKPASS_HOST"] = host
        environment["GREMLIN_ASKPASS_NAME"] = name
        environment["GREMLIN_ASKPASS_STATE"] = state.path
        return environment
    }

    // Returns at once unless ssh started this process to ask something.
    static func answerIfAsked() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[marker] != nil, CommandLine.arguments.count > 1 else { return }
        let prompt = CommandLine.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let host = environment["GREMLIN_ASKPASS_HOST"] ?? ""
        let name = environment["GREMLIN_ASKPASS_NAME"] ?? host
        let lower = prompt.lowercased()
        let account = host + " " + prompt

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        switch environment["SSH_ASKPASS_PROMPT"] {
        case "none":
            // ssh closes this once the key has been touched.
            _ = alert(title: name, message: prompt, buttons: ["OK"]).runModal()
            exit(0)
        case "confirm":
            let answer = alert(title: name, message: prompt, buttons: ["Allow", "Cancel"]).runModal()
            if answer == .alertFirstButtonReturn { print("yes") }
            exit(answer == .alertFirstButtonReturn ? 0 : 1)
        default:
            break
        }

        if lower.contains("(yes/no") {
            let alert = alert(title: "Trust \(name)?", message: prompt.replacingOccurrences(of: "Are you sure you want to continue connecting (yes/no/[fingerprint])?", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nGremlin adds it to ~/.ssh/known_hosts, as ssh does in Terminal.",
                buttons: ["Trust and Connect", "Cancel"])
            guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
            print("yes")
            exit(0)
        }

        let secret = ["password", "passphrase", "pin"].contains { lower.contains($0) }
        let tried = (try? String(contentsOfFile: environment["GREMLIN_ASKPASS_STATE"] ?? "", encoding: .utf8))?
            .split(separator: "\n").contains { $0 == account } ?? false
        if secret, !tried, let saved = saved(account) {
            markTried(account, in: environment["GREMLIN_ASKPASS_STATE"])
            print(saved)
            exit(0)
        }

        let field: NSTextField = secret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 24, width: 280, height: 24)
        let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
        remember.state = .on
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: secret ? 50 : 24))
        accessory.addSubview(field)
        if secret {
            accessory.addSubview(remember)
        } else {
            field.frame.origin.y = 0
        }
        let alert = alert(title: tried ? "That didn't work. Try again." : "Connecting to \(name)", message: prompt, buttons: ["Connect", "Cancel"])
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        if secret, remember.state == .on { save(field.stringValue, for: account) }
        print(field.stringValue)
        exit(0)
    }

    static func hasSaved(host: String) -> Bool {
        !accounts(host: host).isEmpty
    }

    static func forget(host: String) {
        for account in accounts(host: host) {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        }
    }

    private static func alert(title: String, message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.window.level = .modalPanel
        return alert
    }

    private static func markTried(_ account: String, in state: String?) {
        guard let state else { return }
        let earlier = (try? String(contentsOfFile: state, encoding: .utf8)) ?? ""
        try? (earlier + account + "\n").write(toFile: state, atomically: true, encoding: .utf8)
    }

    private static func saved(_ account: String) -> String? {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                     kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        var item: CFTypeRef?
        guard SecItemCopyMatching(query, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ secret: String, for account: String) {
        let item = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        SecItemDelete(item)
        let added = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                     kSecAttrLabel: "\(service): \(account)", kSecValueData: Data(secret.utf8)] as CFDictionary
        SecItemAdd(added, nil)
    }

    private static func accounts(host: String) -> [String] {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnAttributes: true,
                     kSecMatchLimit: kSecMatchLimitAll] as CFDictionary
        var items: CFTypeRef?
        guard SecItemCopyMatching(query, &items) == errSecSuccess, let found = items as? [[String: Any]] else { return [] }
        return found.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(host + " ") }
    }
}

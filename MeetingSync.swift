import AppKit
import CryptoKit
import Security

// Copies meetings between ~/Movies/Meetings and a Gremlin Meetings folder in Google Drive, so every Mac signed in to
// the same account has all of them. It only adds and updates: a meeting or file removed on one side stays on the
// other and isn't copied back, so sync never costs a local copy.
actor MeetingSyncEngine {
    struct Report {
        var uploaded = 0
        var downloaded = 0
    }

    private struct Synced: Codable {
        var id: String
        var md5: String
        var size: Int64
        var modified: Date
    }

    private struct State: Codable {
        // A meeting listed here was on both sides once, so missing from one side now means it was removed there.
        var meetings: [String: [String: Synced]] = [:]
    }

    private struct Local {
        let size: Int64
        let modified: Date
    }

    static let rootName = "Gremlin Meetings"
    // recording.mov is left out: it's gigabytes, and the smaller copy that replaces it syncs instead.
    static let files = [MeetingNotes.event, MeetingNotes.compressed, MeetingNotes.compressedAudio, MeetingNotes.transcript]

    private let drive: MeetingDrive
    private let folder: URL
    private let stateURL: URL
    private let discard: @Sendable (URL) throws -> Void
    private var state: State
    private var report = Report()
    private var rootID: String?

    init(drive: MeetingDrive, folder: URL, stateURL: URL,
         discard: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.drive = drive
        self.folder = folder
        self.stateURL = stateURL
        self.discard = discard
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    /// For a different Google account, whose Drive has none of what this Mac synced before.
    static func forget(_ stateURL: URL) {
        try? JSONEncoder().encode(State()).write(to: stateURL, options: .atomic)
    }

    func run(busy: Set<String>, progress: @escaping @Sendable (String) -> Void) async throws -> Report {
        report = Report()
        let remote = try await drive.list()
        let byAge = remote.sorted { ($0.createdTime ?? .distantPast) < ($1.createdTime ?? .distantPast) }
        // Two Macs starting at once can each make the folders, so same-named ones count as one, the oldest getting new files.
        let roots = byAge.filter { $0.isFolder && $0.name == Self.rootName }
        rootID = roots.first?.id
        let rootIDs = Set(roots.map(\.id))
        var folders: [String: DriveFile] = [:]
        var meetingOf: [String: String] = [:]
        for item in byAge where item.isFolder && item.parents?.contains(where: rootIDs.contains) == true {
            meetingOf[item.id] = item.name
            if folders[item.name] == nil { folders[item.name] = item }
        }
        var remoteFiles: [String: [String: DriveFile]] = [:]
        for item in remote where !item.isFolder && Self.files.contains(item.name) {
            guard let meeting = item.parents?.lazy.compactMap({ meetingOf[$0] }).first else { continue }
            if let current = remoteFiles[meeting]?[item.name], (current.modifiedTime ?? .distantPast) >= (item.modifiedTime ?? .distantPast) {
                continue
            }
            remoteFiles[meeting, default: [:]][item.name] = item
        }

        let local = localMeetings()
        // Newest first, since folder names start with the date.
        for name in local.union(folders.keys).sorted(by: >) where Self.isSafe(name) && !busy.contains(name) {
            try Task.checkCancellation()
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            let here = local.contains(name)
            if here && !Self.isFinished(dir) { continue }
            let linked = state.meetings[name] != nil
            let title = MeetingNotes.title(of: dir)
            if let remoteFolder = folders[name] {
                if !here {
                    guard !linked, !(remoteFiles[name] ?? [:]).isEmpty else { continue }
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                if !linked { link(name) }
                try await reconcile(name, dir: dir, in: remoteFolder.id, remote: remoteFiles[name] ?? [:], title: title, progress: progress)
            } else if here {
                guard !linked, Self.files.contains(where: { Self.attributes(dir.appendingPathComponent($0)) != nil }) else { continue }
                progress("Uploading \(title)")
                let made = try await drive.makeFolder(name, in: try await root())
                link(name)
                try await reconcile(name, dir: dir, in: made.id, remote: [:], title: title, progress: progress)
            }
        }
        return report
    }

    private func reconcile(_ name: String, dir: URL, in parent: String, remote: [String: DriveFile], title: String,
                           progress: @Sendable (String) -> Void) async throws {
        for file in Self.files {
            try Task.checkCancellation()
            let url = dir.appendingPathComponent(file)
            let known = state.meetings[name]?[file]
            let synced: Synced
            switch (Self.attributes(url), remote[file]) {
            case (nil, nil):
                continue
            case (let mine?, nil):
                guard known == nil else { continue }
                progress("Uploading \(title)")
                synced = try await send(url, mine, to: parent, replacing: nil)
            case (nil, let theirs?):
                guard known == nil else { continue }
                progress("Downloading \(title)")
                synced = try await fetch(theirs, to: url)
            case (let mine?, let theirs?):
                let mineChanged: Bool
                let theirsChanged: Bool
                if let known {
                    mineChanged = mine.size != known.size || abs(mine.modified.timeIntervalSince(known.modified)) > 1
                    theirsChanged = (theirs.md5Checksum ?? "") != known.md5
                } else {
                    let same = theirs.md5Checksum != nil && Self.md5(url) == theirs.md5Checksum
                    mineChanged = !same
                    theirsChanged = !same
                }
                if !mineChanged && !theirsChanged {
                    guard known == nil else { continue }
                    synced = Synced(id: theirs.id, md5: theirs.md5Checksum ?? "", size: mine.size, modified: mine.modified)
                } else if mineChanged && (!theirsChanged || mine.modified > (theirs.modifiedTime ?? .distantPast)) {
                    progress("Uploading \(title)")
                    synced = try await send(url, mine, to: parent, replacing: theirs.id)
                } else {
                    progress("Downloading \(title)")
                    synced = try await fetch(theirs, to: url)
                }
            }
            state.meetings[name, default: [:]][file] = synced
            save()
        }
    }

    private func send(_ url: URL, _ local: Local, to parent: String, replacing id: String?) async throws -> Synced {
        let uploaded = try await drive.upload(url, name: url.lastPathComponent, to: parent, replacing: id, modified: local.modified)
        report.uploaded += 1
        return Synced(id: uploaded.id, md5: uploaded.md5Checksum ?? Self.md5(url) ?? "", size: local.size, modified: local.modified)
    }

    private func fetch(_ remote: DriveFile, to url: URL) async throws -> Synced {
        let fileManager = FileManager.default
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).download")
        try await drive.download(remote.id, to: partial)
        // The copy being replaced goes to the Trash, in case it mattered.
        if fileManager.fileExists(atPath: url.path) { try discard(url) }
        try fileManager.moveItem(at: partial, to: url)
        if let modified = remote.modifiedTime { try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        guard let local = Self.attributes(url) else { throw DriveError(message: "\(url.lastPathComponent) vanished after downloading.") }
        report.downloaded += 1
        return Synced(id: remote.id, md5: remote.md5Checksum ?? "", size: local.size, modified: local.modified)
    }

    private func root() async throws -> String {
        if let rootID { return rootID }
        let made = try await drive.makeFolder(Self.rootName, in: nil)
        rootID = made.id
        return made.id
    }

    private func link(_ name: String) {
        state.meetings[name] = [:]
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func localMeetings() -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return Set(items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.lastPathComponent))
    }

    private static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
    }

    // Until it has a transcript, a recording is still on its way through transcribing and compressing.
    private static func isFinished(_ dir: URL) -> Bool {
        attributes(dir.appendingPathComponent(MeetingNotes.recording)) == nil || attributes(dir.appendingPathComponent(MeetingNotes.transcript)) != nil
    }

    // Not URL.resourceValues, which can hand back a replaced file's cached size and date.
    private static func attributes(_ url: URL) -> Local? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular else { return nil }
        return Local(size: (values[.size] as? NSNumber)?.int64Value ?? 0, modified: values[.modificationDate] as? Date ?? .distantPast)
    }

    private static func md5(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class MeetingSync {
    struct Status: Equatable {
        var clientID = ""
        var hasClient = false
        var clipboardHasClient = false
        var connected = false
        var account: String?
        var signingIn = false
        var syncing = false
        var detail: String?
        var lastSynced: Date?
        var problem: String?
    }

    var onChange: (() -> Void)?
    /// Meetings arrived from another Mac.
    var onArrival: (() -> Void)?
    /// Folder names still being recorded, transcribed or compressed.
    var unfinished: () -> Set<String> = { [] }
    private(set) var status = Status()

    private let defaults = UserDefaults.standard
    private var engine: MeetingSyncEngine?
    private var running: Task<Void, Never>?
    private var signingIn: Task<Void, Never>?
    private var paused = false
    private var again = false
    private var timer: Timer?
    private var soon: DispatchWorkItem?

    private static let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Gremlin/Meeting Sync.json")
    private static let accountKey = "meetingSyncAccount"
    private static let lastKey = "meetingSyncLast"

    func start() {
        configure()
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        syncSoon(after: 20)
    }

    func stop() {
        timer?.invalidate()
        running?.cancel()
        signingIn?.cancel()
    }

    private func configure() {
        let client = Self.client()
        status.clientID = client?.id ?? ""
        status.hasClient = client != nil
        status.clipboardHasClient = client == nil && Keychain.exists(Keychain.clipboardID, in: Keychain.clipboard)
            && Keychain.exists(Keychain.clipboardSecret, in: Keychain.clipboard)
        let refresh = Keychain.read(Keychain.refreshToken)
        status.connected = client != nil && refresh != nil
        status.account = status.connected ? defaults.string(forKey: Self.accountKey) : nil
        status.lastSynced = defaults.object(forKey: Self.lastKey) as? Date
        if let client, let refresh {
            engine = MeetingSyncEngine(drive: GoogleDrive(client: client, refreshToken: refresh), folder: Meetings.folder, stateURL: Self.stateURL)
        } else {
            engine = nil
        }
        onChange?()
    }

    private static func client() -> GoogleClient? {
        guard let id = Keychain.read(Keychain.clientID), let secret = Keychain.read(Keychain.clientSecret),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return GoogleClient(id: id, secret: secret)
    }

    // MARK: Syncing

    // Uploads would compete with the call for bandwidth.
    func setPaused(_ on: Bool) {
        guard on != paused else { return }
        paused = on
        if on {
            soon?.cancel()
            running?.cancel()
        } else {
            syncSoon(after: 10)
        }
    }

    func syncSoon(after delay: TimeInterval = 3) {
        guard engine != nil else { return }
        soon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        soon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func syncIfStale() {
        guard Date().timeIntervalSince(status.lastSynced ?? .distantPast) > 5 * 60 else { return }
        syncSoon()
    }

    func syncNow() {
        guard let engine, !paused else { return }
        guard running == nil else { return again = true }
        status.syncing = true
        status.detail = nil
        onChange?()
        let busy = unfinished()
        running = Task {
            do {
                let report = try await engine.run(busy: busy) { detail in
                    Task { @MainActor in
                        guard self.status.syncing else { return }
                        self.status.detail = detail
                        self.onChange?()
                    }
                }
                status.problem = nil
                status.lastSynced = Date()
                defaults.set(status.lastSynced, forKey: Self.lastKey)
                if report.uploaded + report.downloaded > 0 {
                    Log.write("Meeting sync: uploaded \(report.uploaded) files, downloaded \(report.downloaded)")
                }
                if report.downloaded > 0 { onArrival?() }
            } catch let error as DriveError where error.signedOut {
                Log.write("Meeting sync: Google signed Gremlin out")
                Keychain.write(nil, for: Keychain.refreshToken)
                status.problem = error.message
                configure()
            } catch let error as DriveError {
                Log.write("Meeting sync failed: \(error.message)")
                status.problem = error.message
            } catch is CancellationError {
            } catch let error as URLError {
                if error.code != .cancelled {
                    status.problem = "Couldn't reach Google Drive (\(error.localizedDescription)). Gremlin will try again."
                }
            } catch {
                Log.write("Meeting sync failed: \(error.localizedDescription)")
                status.problem = error.localizedDescription
            }
            running = nil
            status.syncing = false
            status.detail = nil
            onChange?()
            if again {
                again = false
                syncSoon()
            }
        }
    }

    // MARK: Signing in

    func signIn(clientID: String, secret: String) {
        let client = GoogleClient(id: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                  secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !client.id.isEmpty, !client.secret.isEmpty else { return }
        Keychain.write(client.id, for: Keychain.clientID)
        Keychain.write(client.secret, for: Keychain.clientSecret)
        begin(client)
    }

    // macOS asks once before Gremlin can read another app's keychain item.
    func signInWithClipboardsClient() {
        guard let id = Keychain.read(Keychain.clipboardID, in: Keychain.clipboard),
              let secret = Keychain.read(Keychain.clipboardSecret, in: Keychain.clipboard) else {
            status.problem = "Gremlin couldn't read Clipboard's Google app from the keychain."
            onChange?()
            return
        }
        signIn(clientID: id, secret: secret)
    }

    func signInAgain() {
        guard let client = Self.client() else { return }
        begin(client)
    }

    func cancelSignIn() {
        signingIn?.cancel()
    }

    func signOut() {
        running?.cancel()
        Keychain.write(nil, for: Keychain.refreshToken)
        status.problem = nil
        Log.write("Meeting sync: signed out of Google Drive")
        configure()
    }

    func forgetClient() {
        signOut()
        Keychain.write(nil, for: Keychain.clientID)
        Keychain.write(nil, for: Keychain.clientSecret)
        configure()
    }

    private func begin(_ client: GoogleClient) {
        signingIn?.cancel()
        running?.cancel()
        status.signingIn = true
        status.problem = nil
        configure()
        signingIn = Task {
            do {
                let refresh = try await GoogleSignIn.run(client: client) { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                let account = try? await GoogleDrive(client: client, refreshToken: refresh).accountEmail()
                if let account, let earlier = defaults.string(forKey: Self.accountKey), earlier != account {
                    MeetingSyncEngine.forget(Self.stateURL)
                }
                if let account { defaults.set(account, forKey: Self.accountKey) }
                Keychain.write(refresh, for: Keychain.refreshToken)
                Log.write("Meeting sync: signed in to Google Drive")
                status.signingIn = false
                configure()
                syncNow()
            } catch is CancellationError {
            } catch {
                status.problem = (error as? DriveError)?.message ?? "Google sign-in didn't finish: \(error.localizedDescription)"
            }
            status.signingIn = false
            signingIn = nil
            onChange?()
        }
    }
}

extension MeetingSync.Status {
    var summary: String {
        if signingIn { return "Waiting for Google in your browser…" }
        guard connected else { return hasClient ? "Signed out" : "Off" }
        if syncing { return detail ?? "Checking Google Drive…" }
        guard let lastSynced else { return "Not synced yet" }
        if Date().timeIntervalSince(lastSynced) < 60 { return "Synced just now" }
        return "Synced " + RelativeDateTimeFormatter().localizedString(for: lastSynced, relativeTo: Date())
    }
}

private enum Keychain {
    static let service = "com.bunniesinc.gremlin.google"
    static let clientID = "client-id"
    static let clientSecret = "client-secret"
    static let refreshToken = "refresh-token"
    static let clipboard = "com.bunniesinc.clipboard.sync"
    static let clipboardID = "google-client-id"
    static let clipboardSecret = "google-client-secret"

    static func read(_ account: String, in service: String = service) -> String? {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                     kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        var item: CFTypeRef?
        guard SecItemCopyMatching(query, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Asking only for attributes doesn't need the item's contents, so it never raises a keychain prompt.
    static func exists(_ account: String, in service: String) -> Bool {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                     kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        var item: CFTypeRef?
        return SecItemCopyMatching(query, &item) == errSecSuccess
    }

    static func write(_ value: String?, for account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        guard let value else { return }
        let item = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecAttrLabel: "Gremlin Google Drive: \(account)", kSecValueData: Data(value.utf8)] as CFDictionary
        SecItemAdd(item, nil)
    }
}

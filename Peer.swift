import AppKit
import CryptoKit
import Network

struct Message: Codable {
    var type: String
    var from = ""
    var name: String?
    var time = 0.0
    var nonce = ""
    var re: String?
    var ucID: String?
    var error: String?
    var status: String?
    var ok: Bool?
    var addresses: [String]?
    var port: UInt16?
    var key: Data?
    var commit: Data?
    var random: Data?

    init(type: String) { self.type = type }
}

private struct Envelope: Codable {
    var payload: Data
    var mac: Data?
}

// Lets the Gremlins on two Macs ask each other for their Universal Control status and to reset it.
// Only a fixed set of message types exists, and everything after pairing is signed with the shared secret.
final class PeerLink {
    struct Paired: Codable {
        var id: String
        var name: String
        var addresses: [String]
        var port: UInt16?
        var ucID: String?
    }

    static let port: NWEndpoint.Port = 47101
    private static let service = "_gremlin._tcp"

    let id: String
    let name = Host.current().localizedName ?? "Mac"
    private(set) var paired: Paired?
    private(set) var isPairing = false
    var onRequest: ((Message) -> Message)?
    var onChange: (() -> Void)?
    var localUCID: (() -> String?)?

    private let defaults = UserDefaults.standard
    private var secret: SymmetricKey?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var found: [String: (endpoint: NWEndpoint, pairing: Bool)] = [:]
    private var lines: [ObjectIdentifier: Line] = [:]
    private var seen: [String: Date] = [:]
    private var pairing: Pairing?
    private var pairingTimeout: DispatchWorkItem?

    init() {
        if let saved = defaults.string(forKey: "gremlinID") {
            id = saved
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: "gremlinID")
        }
        if let data = defaults.data(forKey: "pairedMac"),
           let saved = try? JSONDecoder().decode(Paired.self, from: data),
           let key = Keychain.load(account: saved.id) {
            paired = saved
            secret = SymmetricKey(data: key)
        }
    }

    func start() {
        startListener()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: Requests

    func request(_ message: Message, completion: @escaping (Message?) -> Void) {
        guard let paired else { return completion(nil) }
        var endpoints: [NWEndpoint] = []
        if let bonjour = found[paired.id]?.endpoint { endpoints.append(bonjour) }
        let port = paired.port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? Self.port
        endpoints += paired.addresses.map { .hostPort(host: NWEndpoint.Host($0), port: port) }
        attempt(endpoints[...], seal(message, key: secret), completion)
    }

    private func attempt(_ endpoints: ArraySlice<NWEndpoint>, _ data: Data, _ completion: @escaping (Message?) -> Void) {
        guard let endpoint = endpoints.first else { return completion(nil) }
        let line = Line(NWConnection(to: endpoint, using: .tcp))
        var finished = false
        let finish = { [weak self] (reply: Message?) in
            guard !finished else { return }
            finished = true
            line.close()
            if let reply {
                completion(reply)
            } else {
                self?.attempt(endpoints.dropFirst(), data, completion)
            }
        }
        line.onMessage = { [weak self] data in finish(self?.open(data)) }
        line.onClose = { finish(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
        line.start()
        line.send(data)
    }

    func unpair() {
        guard let paired else { return }
        request(Message(type: "unpair")) { _ in }
        Log.write("Unpaired from \(paired.name)")
        forget()
    }

    private func forget() {
        if let paired { Keychain.delete(account: paired.id) }
        defaults.removeObject(forKey: "pairedMac")
        paired = nil
        secret = nil
        onChange?()
    }

    // MARK: Server

    // The fixed port lets the other Mac reach this one by address when Bonjour can't see it, e.g. over Tailscale.
    private func startListener(fixedPort: Bool = true) {
        let listener = fixedPort ? try? NWListener(using: .tcp, on: Self.port) : try? NWListener(using: .tcp)
        guard let listener else { return Log.write("Couldn't listen for the other Mac") }
        listener.service = advertisement()
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed(let error) = state else { return }
            listener?.cancel()
            if fixedPort, case .posix(.EADDRINUSE) = error {
                Log.write("Port \(Self.port) is taken, listening on another one")
                self?.startListener(fixedPort: false)
            } else {
                Log.write("Listener failed: \(error), restarting in 10s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.startListener() }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func advertisement() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = id
        txt["pairing"] = isPairing ? "1" : "0"
        return NWListener.Service(name: name, type: Self.service, txtRecord: txt)
    }

    private func accept(_ connection: NWConnection) {
        let line = Line(connection)
        let key = ObjectIdentifier(line)
        lines[key] = line
        line.onClose = { [weak self] in self?.lines[key] = nil }
        line.onMessage = { [weak self] data in self?.received(data, on: line) }
        line.start()
    }

    private func received(_ data: Data, on line: Line) {
        if let message = Self.unsigned(data), message.type.hasPrefix("pair") {
            guard isPairing else { return line.close() }
            if message.type == "pair1" {
                pairing?.fail()
                pairing = Pairing(link: self, line: line, initiator: false)
            }
            pairing?.received(message, raw: data)
            return
        }
        guard let message = open(data) else { return line.close() }
        if var paired, let addresses = message.addresses {
            paired.addresses = addresses
            paired.port = message.port ?? paired.port
            paired.ucID = message.ucID ?? paired.ucID
            save(paired)
        }
        if message.type == "unpair" {
            Log.write("\(paired?.name ?? "The other Mac") unpaired")
            var answer = Message(type: "reply")
            answer.re = message.nonce
            answer.ok = true
            line.send(seal(answer, key: secret))
            return forget()
        }
        var answer = onRequest?(message) ?? Message(type: "reply")
        answer.re = message.nonce
        line.send(seal(answer, key: secret))
    }

    // MARK: Signing

    func seal(_ message: Message, key: SymmetricKey?) -> Data {
        var message = message
        message.from = id
        message.name = name
        message.time = Date().timeIntervalSince1970
        message.nonce = UUID().uuidString
        message.ucID = message.ucID ?? localUCID?()
        message.addresses = Self.addresses()
        message.port = listener?.port?.rawValue
        let payload = (try? JSONEncoder().encode(message)) ?? Data()
        let mac = key.map { Data(HMAC<SHA256>.authenticationCode(for: payload, using: $0)) }
        return (try? JSONEncoder().encode(Envelope(payload: payload, mac: mac))) ?? Data()
    }

    private func open(_ data: Data) -> Message? {
        guard let paired, let secret else { return nil }
        return Self.verify(data, key: secret, from: paired.id, seen: &seen)
    }

    static func verify(_ data: Data, key: SymmetricKey, from id: String, seen: inout [String: Date]) -> Message? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let mac = envelope.mac,
              HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: envelope.payload, using: key),
              let message = try? JSONDecoder().decode(Message.self, from: envelope.payload),
              message.from == id,
              abs(message.time - Date().timeIntervalSince1970) < 120,
              seen[message.nonce] == nil else { return nil }
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 300 }
        seen[message.nonce] = now
        return message
    }

    static func unsigned(_ data: Data) -> Message? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.mac == nil else { return nil }
        return try? JSONDecoder().decode(Message.self, from: envelope.payload)
    }

    private static func addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") { result.append(ip) }
        }
        return result
    }

    // MARK: Pairing

    func startPairing() {
        pairingTimeout?.cancel()
        isPairing = true
        listener?.service = advertisement()
        Log.write("Pairing mode on")
        let timeout = DispatchWorkItem { [weak self] in self?.stopPairing() }
        pairingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        initiateIfPossible()
        onChange?()
    }

    func stopPairing() {
        pairingTimeout?.cancel()
        pairing?.fail()
        pairing = nil
        isPairing = false
        listener?.service = advertisement()
        onChange?()
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        found = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let peer = txt["id"], peer != id else { continue }
            found[peer] = (result.endpoint, txt["pairing"] == "1")
        }
        initiateIfPossible()
    }

    // When both Macs are in pairing mode, the one with the smaller ID connects.
    private func initiateIfPossible() {
        guard isPairing, pairing == nil,
              let peer = found.first(where: { $0.value.pairing && $0.key > id })?.value else { return }
        let line = Line(NWConnection(to: peer.endpoint, using: .tcp))
        let session = Pairing(link: self, line: line, initiator: true)
        pairing = session
        line.start()
        session.begin()
    }

    fileprivate func pairingEnded(_ session: Pairing, peer: Paired?, key: SymmetricKey?) {
        guard pairing === session else { return }
        pairing = nil
        if let peer, let key {
            Keychain.save(key.withUnsafeBytes { Data($0) }, account: peer.id)
            secret = key
            save(peer)
            Log.write("Paired with \(peer.name)")
            stopPairing()
        } else if isPairing {
            initiateIfPossible()
        }
        onChange?()
    }

    private func save(_ peer: Paired) {
        paired = peer
        defaults.set(try? JSONEncoder().encode(peer), forKey: "pairedMac")
    }
}

// Numeric comparison: the responder commits to its random value before seeing the initiator's,
// so a man in the middle can't pick keys that make both screens show the same code.
private final class Pairing {
    private weak var link: PeerLink?
    private let line: Line
    private let initiator: Bool
    private let key = Curve25519.KeyAgreement.PrivateKey()
    private let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    private var peer: PeerLink.Paired?
    private var peerKey: Data?
    private var peerRandom: Data?
    private var peerCommit: Data?
    private var secret: SymmetricKey?
    private var localConfirmed = false
    private var remoteConfirmed = false
    private var done = false
    private var asking = false
    private var seen: [String: Date] = [:]

    init(link: PeerLink, line: Line, initiator: Bool) {
        self.link = link
        self.line = line
        self.initiator = initiator
        let closed = line.onClose
        line.onClose = { [weak self] in
            closed?()
            self?.fail()
        }
        line.onMessage = { [weak self] data in self?.received(PeerLink.unsigned(data), raw: data) }
    }

    private var ownKey: Data { key.publicKey.rawRepresentation }
    private var responderKey: Data { initiator ? peerKey ?? Data() : ownKey }
    private var initiatorKey: Data { initiator ? ownKey : peerKey ?? Data() }

    func begin() {
        var message = Message(type: "pair1")
        message.key = ownKey
        send(message)
    }

    func received(_ message: Message?, raw: Data) {
        guard !done else { return }
        guard let message else {
            guard let secret, let peer, let confirmed = PeerLink.verify(raw, key: secret, from: peer.id, seen: &seen),
                  confirmed.type == "pair5" else { return fail() }
            if confirmed.ok == true {
                remoteConfirmed = true
                finishIfConfirmed()
            } else {
                fail()
            }
            return
        }
        switch (initiator, message.type) {
        case (false, "pair1"):
            remember(message)
            var reply = Message(type: "pair2")
            reply.key = ownKey
            reply.commit = Data(SHA256.hash(data: ownKey + (message.key ?? Data()) + random))
            send(reply)
        case (true, "pair2"):
            remember(message)
            peerCommit = message.commit
            var reply = Message(type: "pair3")
            reply.random = random
            send(reply)
        case (false, "pair3"):
            peerRandom = message.random
            var reply = Message(type: "pair4")
            reply.random = random
            send(reply)
            confirm()
        case (true, "pair4"):
            peerRandom = message.random
            let expected = Data(SHA256.hash(data: responderKey + initiatorKey + (peerRandom ?? Data())))
            guard expected == peerCommit else { return fail() }
            confirm()
        default:
            fail()
        }
    }

    private func remember(_ message: Message) {
        peerKey = message.key
        peer = PeerLink.Paired(id: message.from, name: message.name ?? "the other Mac", addresses: message.addresses ?? [],
                               port: message.port, ucID: message.ucID)
    }

    private func confirm() {
        guard let peerKey, let peerRandom, let peer,
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey),
              let shared = try? key.sharedSecretFromKeyAgreement(with: publicKey) else { return fail() }
        let responderRandom = initiator ? peerRandom : random
        let initiatorRandom = initiator ? random : peerRandom
        secret = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: responderRandom + initiatorRandom,
                                                sharedInfo: Data("gremlin pairing".utf8), outputByteCount: 32)
        let digest = Array(SHA256.hash(data: responderKey + initiatorKey + responderRandom + initiatorRandom))
        let number = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let code = String(format: "%03d %03d", number / 1000, number % 1000)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pair with \(peer.name)?"
        alert.informativeText = "Pair only if \(peer.name) shows the same code:\n\n\(code)"
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        asking = true
        let answer = alert.runModal()
        asking = false
        guard !done else { return }
        guard answer == .alertFirstButtonReturn else {
            var reply = Message(type: "pair5")
            reply.ok = false
            send(reply, signed: true)
            return fail()
        }
        localConfirmed = true
        var reply = Message(type: "pair5")
        reply.ok = true
        send(reply, signed: true)
        finishIfConfirmed()
    }

    private func finishIfConfirmed() {
        guard localConfirmed, remoteConfirmed, !done else { return }
        done = true
        link?.pairingEnded(self, peer: peer, key: secret)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [line] in line.close() }
    }

    private func send(_ message: Message, signed: Bool = false) {
        guard let link else { return }
        line.send(link.seal(message, key: signed ? secret : nil))
    }

    func fail() {
        guard !done else { return }
        done = true
        if asking { NSApp.abortModal() }
        line.close()
        link?.pairingEnded(self, peer: nil, key: nil)
    }
}

private final class Line {
    let connection: NWConnection
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private var buffer = Data()
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        connection.send(content: data + [0x0A], completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let closed = onClose
        onClose = nil
        onMessage = nil
        closed?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = Data(self.buffer[self.buffer.startIndex..<newline])
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                self.onMessage?(line)
            }
            if complete || error != nil || self.buffer.count > 65536 {
                self.close()
            } else {
                self.receive()
            }
        }
    }
}

private enum Keychain {
    static let service = "com.bunniesinc.gremlin.peer"

    static func save(_ data: Data, account: String) {
        delete(account: account)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "Gremlin pairing",
            kSecValueData: data,
        ] as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ] as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    static func delete(account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}

import CryptoKit
import Foundation
import Network

// The user's own Google Cloud client, the one Clipboard uses too. Google treats an installed app's secret as not really
// secret, since any copy could read it, so the keychain is plenty.
struct GoogleClient: Equatable {
    let id: String
    let secret: String
}

struct DriveError: LocalizedError {
    let message: String
    var signedOut = false

    var errorDescription: String? { message }

    static let needsSignIn = DriveError(message: "Google signed Gremlin out. Sign in again to keep syncing.", signedOut: true)
}

private struct GoogleTokens: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private enum GoogleTokenEndpoint {
    static let url = URL(string: "https://oauth2.googleapis.com/token")!

    static func request(_ fields: [String: String]) async throws -> GoogleTokens {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(
            fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let problem = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch problem?["error"] as? String {
            case "invalid_grant": throw DriveError.needsSignIn
            case "invalid_client", "unauthorized_client":
                throw DriveError(message: "Google didn't accept that client ID and secret.")
            default: throw DriveError(message: "Google wouldn't sign Gremlin in: \(problem?["error"] as? String ?? "unknown error").")
            }
        }
        return try JSONDecoder().decode(GoogleTokens.self, from: data)
    }
}

enum GoogleSignIn {
    // Only files Gremlin made itself, so meetings sit in a normal folder the user can open, and nothing else is reachable.
    static let scope = "https://www.googleapis.com/auth/drive.file"

    // Clipboard's port: a Web application client only accepts a redirect it lists exactly.
    static let redirectPort: UInt16 = 53847

    private static func authorizationURL(client: GoogleClient, redirect: String, state: String, challenge: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            // Without this, signing in a second time returns no refresh token.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    private static func randomToken() -> String {
        base64URL(Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // If something else holds the usual port, a Desktop app client can still sign in on another.
    private static func openReceiver() async throws -> (LoopbackReceiver, UInt16) {
        let usual = try LoopbackReceiver(port: NWEndpoint.Port(rawValue: redirectPort) ?? .any)
        if let port = try? await usual.start() { return (usual, port) }
        usual.stop()
        let fallback = try LoopbackReceiver(port: .any)
        return (fallback, try await fallback.start())
    }

    /// Walks the user through Google's page in their browser, and returns the refresh token to keep.
    static func run(client: GoogleClient, open: @escaping (URL) -> Void) async throws -> String {
        let (receiver, port) = try await openReceiver()
        defer { receiver.stop() }
        let redirect = "http://127.0.0.1:\(port)"
        let state = randomToken()
        let verifier = randomToken()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        open(authorizationURL(client: client, redirect: redirect, state: state, challenge: challenge))

        let answer = try await receiver.waitForRedirect()
        guard answer["state"] == state else { throw DriveError(message: "Google's answer didn't match this sign-in. Try again.") }
        guard let code = answer["code"] else {
            throw DriveError(message: answer["error"] == "access_denied" ? "Google Drive access wasn't allowed." : "Google didn't finish signing in.")
        }
        let tokens = try await GoogleTokenEndpoint.request([
            "grant_type": "authorization_code", "code": code, "client_id": client.id, "client_secret": client.secret,
            "redirect_uri": redirect, "code_verifier": verifier,
        ])
        guard let refresh = tokens.refreshToken else { throw DriveError(message: "Google didn't return a long-lived sign-in. Try again.") }
        return refresh
    }
}

/// Answers the one request Google's page sends back. Bound to loopback, so nothing else on the network can reach it.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.bunniesinc.gremlin.google-sign-in")
    private var answer: CheckedContinuation<[String: String], Error>?

    private static let page = """
        <!doctype html><meta charset="utf-8"><title>Gremlin</title>
        <body style="font: 15px -apple-system, sans-serif; text-align: center; padding-top: 18vh">
        <h2>Back to Gremlin</h2><p>You can close this tab.</p></body>
        """

    init(port: NWEndpoint.Port) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            var pending: CheckedContinuation<UInt16, Error>? = continuation
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    pending?.resume(returning: listener.port?.rawValue ?? 0)
                    pending = nil
                case .failed(let error), .waiting(let error):
                    pending?.resume(throwing: error)
                    pending = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.answer = continuation }
            }
        } onCancel: {
            queue.async {
                self.answer?.resume(throwing: CancellationError())
                self.answer = nil
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let items = parts.count > 1 ? URLComponents(string: String(parts[1]))?.queryItems : nil
            let isAnswer = items?.contains { $0.name == "code" || $0.name == "error" } == true
            // Browsers also ask for a favicon.
            let reply = isAnswer
                ? "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(Self.page)"
                : "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isAnswer, let items else { return }
            self.answer?.resume(returning: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }))
            self.answer = nil
        }
    }
}

struct DriveFile: Decodable, Equatable {
    static let folderType = "application/vnd.google-apps.folder"

    let id: String
    let name: String
    let mimeType: String
    let parents: [String]?
    let md5Checksum: String?
    let modifiedTime: Date?
    let createdTime: Date?

    var isFolder: Bool { mimeType == Self.folderType }
}

protocol MeetingDrive: Sendable {
    func list() async throws -> [DriveFile]
    func makeFolder(_ name: String, in parent: String?) async throws -> DriveFile
    func upload(_ file: URL, name: String, to parent: String, replacing id: String?, modified: Date) async throws -> DriveFile
    func download(_ id: String, to destination: URL) async throws
}

actor GoogleDrive: MeetingDrive {
    private let client: GoogleClient
    private let refreshToken: String
    private var accessToken: String?
    private var tokenExpiry = Date.distantPast

    private static let files = "https://www.googleapis.com/drive/v3/files"
    private static let uploads = "https://www.googleapis.com/upload/drive/v3/files"
    private static let fields = "id,name,mimeType,parents,md5Checksum,modifiedTime,createdTime"

    init(client: GoogleClient, refreshToken: String) {
        self.client = client
        self.refreshToken = refreshToken
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()

    private static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Everything Gremlin can see, which with its scope is only what it made.
    func list() async throws -> [DriveFile] {
        struct Page: Decodable {
            let files: [DriveFile]
            let nextPageToken: String?
        }
        var found: [DriveFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: Self.files)!
            components.queryItems = [
                URLQueryItem(name: "q", value: "trashed = false"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fields))"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let (data, _) = try await send(URLRequest(url: components.url!))
            let page = try Self.decoder.decode(Page.self, from: data)
            found += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return found
    }

    func makeFolder(_ name: String, in parent: String?) async throws -> DriveFile {
        var request = URLRequest(url: URL(string: "\(Self.files)?fields=\(Self.fields)")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var metadata: [String: Any] = ["name": name, "mimeType": DriveFile.folderType]
        if let parent { metadata["parents"] = [parent] }
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (data, _) = try await send(request)
        return try Self.decoder.decode(DriveFile.self, from: data)
    }

    // A resumable session streams the file from disk, where a plain upload tops out at 5 MB.
    func upload(_ file: URL, name: String, to parent: String, replacing id: String?, modified: Date) async throws -> DriveFile {
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        var start: URLRequest
        var metadata: [String: Any] = ["modifiedTime": Self.format(modified)]
        if let id {
            start = URLRequest(url: URL(string: "\(Self.uploads)/\(id)?uploadType=resumable&fields=\(Self.fields)")!)
            start.httpMethod = "PATCH"
        } else {
            start = URLRequest(url: URL(string: "\(Self.uploads)?uploadType=resumable&fields=\(Self.fields)")!)
            start.httpMethod = "POST"
            metadata["name"] = name
            metadata["parents"] = [parent]
        }
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(Self.contentType(of: name), forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        let (_, response) = try await send(start)
        guard let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location) else {
            throw DriveError(message: "Google Drive didn't start the upload.")
        }
        var upload = URLRequest(url: target)
        upload.httpMethod = "PUT"
        upload.setValue(Self.contentType(of: name), forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(upload, from: file)
        return try Self.decoder.decode(DriveFile.self, from: data)
    }

    func download(_ id: String, to destination: URL) async throws {
        var request = URLRequest(url: URL(string: "\(Self.files)/\(id)?alt=media")!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        var (temporary, response) = try await URLSession.shared.download(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            try? FileManager.default.removeItem(at: temporary)
            request.setValue("Bearer \(try await token(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            (temporary, response) = try await URLSession.shared.download(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? Data(contentsOf: temporary)) ?? Data()
            try? FileManager.default.removeItem(at: temporary)
            throw DriveError(message: Self.problem(in: body, status: status))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// The Google account behind the sign-in, to show in Settings.
    func accountEmail() async throws -> String? {
        struct About: Decodable {
            struct User: Decodable { let emailAddress: String? }
            let user: User?
        }
        let (data, _) = try await send(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!))
        return try JSONDecoder().decode(About.self, from: data).user?.emailAddress
    }

    private static func contentType(of name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "json": return "application/json"
        case "md": return "text/markdown"
        case "mp4": return "video/mp4"
        case "m4a": return "audio/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    private func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, tokenExpiry > Date() { return accessToken }
        let tokens = try await GoogleTokenEndpoint.request(
            ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.id, "client_secret": client.secret])
        guard let fresh = tokens.accessToken else { throw DriveError.needsSignIn }
        accessToken = fresh
        tokenExpiry = Date().addingTimeInterval((tokens.expiresIn ?? 3600) - 60)
        return fresh
    }

    private func send(_ request: URLRequest, from file: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        func attempt(_ token: String) async throws -> (Data, URLResponse) {
            var authorized = request
            authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let file { return try await URLSession.shared.upload(for: authorized, fromFile: file) }
            return try await URLSession.shared.data(for: authorized)
        }
        var (data, response) = try await attempt(try await token())
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            (data, response) = try await attempt(try await token(forceRefresh: true))
        }
        guard let http = response as? HTTPURLResponse else { throw DriveError(message: "Google Drive sent an unreadable answer.") }
        guard (200..<300).contains(http.statusCode) else { throw DriveError(message: Self.problem(in: data, status: http.statusCode)) }
        return (data, http)
    }

    private static func problem(in data: Data, status: Int) -> String {
        struct Failure: Decodable {
            struct Body: Decodable {
                struct Detail: Decodable { let reason: String? }
                let message: String?
                let errors: [Detail]?
            }
            let error: Body?
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        switch failure?.error?.errors?.first?.reason {
        case "accessNotConfigured": return "The Google Drive API isn't turned on for this Google Cloud project."
        case "storageQuotaExceeded": return "Your Google Drive is full, so meetings can't sync until there's room."
        case "rateLimitExceeded", "userRateLimitExceeded": return "Google Drive asked Gremlin to slow down. It'll try again soon."
        default: return failure?.error?.message ?? "Google Drive answered with error \(status)."
        }
    }
}

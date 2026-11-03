import Foundation

// Big-endian fields, as both SFTP and NFS lay them out. XDR also pads opaque data to four bytes.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func bool(_ value: Bool) { u32(value ? 1 : 0) }

    mutating func string<C: Collection>(_ data: C) where C.Element == UInt8 {
        u32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func string(_ text: String) { string(Array(text.utf8)) }

    mutating func opaque<C: Collection>(_ data: C) where C.Element == UInt8 {
        string(data)
        pad(data.count)
    }

    mutating func fixed(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
        pad(data.count)
    }

    private mutating func pad(_ count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: (4 - count % 4) % 4))
    }
}

struct ByteReader {
    struct Truncated: Error {}

    let bytes: [UInt8]
    var at: Int

    init(_ bytes: [UInt8], at: Int = 0) {
        self.bytes = bytes
        self.at = at
    }

    var remaining: Int { bytes.count - at }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw Truncated() }
        defer { at += 1 }
        return bytes[at]
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw Truncated() }
        defer { at += 4 }
        return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        UInt64(try u32()) << 32 | UInt64(try u32())
    }

    mutating func bool() throws -> Bool { try u32() != 0 }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw Truncated() }
        defer { at += count }
        return Array(bytes[at..<at + count])
    }

    mutating func string(max: Int = 1 << 20) throws -> [UInt8] {
        let count = Int(try u32())
        guard count <= max else { throw Truncated() }
        return try take(count)
    }

    mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }

    mutating func opaque(max: Int) throws -> [UInt8] {
        let data = try string(max: max)
        _ = try take((4 - data.count % 4) % 4)
        return data
    }

    mutating func fixed(_ count: Int) throws -> [UInt8] {
        let data = try take(count)
        _ = try take((4 - count % 4) % 4)
        return data
    }
}

struct SFTPAttributes {
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var atime: UInt32?
    var mtime: UInt32?

    init(size: UInt64? = nil, permissions: UInt32? = nil, atime: UInt32? = nil, mtime: UInt32? = nil) {
        self.size = size
        self.permissions = permissions
        self.atime = atime
        self.mtime = mtime
    }

    init(from reader: inout ByteReader) throws {
        let flags = try reader.u32()
        if flags & 0x1 != 0 { size = try reader.u64() }
        if flags & 0x2 != 0 {
            uid = try reader.u32()
            gid = try reader.u32()
        }
        if flags & 0x4 != 0 { permissions = try reader.u32() }
        if flags & 0x8 != 0 {
            atime = try reader.u32()
            mtime = try reader.u32()
        }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try reader.u32()) {
                _ = try reader.string()
                _ = try reader.string()
            }
        }
    }

    var isEmpty: Bool { size == nil && permissions == nil && atime == nil && mtime == nil }
    var type: UInt32 { (permissions ?? 0o100000) & 0o170000 }
    var isDirectory: Bool { type == 0o040000 }
    var isSymlink: Bool { type == 0o120000 }

    func write(to writer: inout ByteWriter) {
        var flags: UInt32 = 0
        if size != nil { flags |= 0x1 }
        if permissions != nil { flags |= 0x4 }
        if atime != nil, mtime != nil { flags |= 0x8 }
        writer.u32(flags)
        if let size { writer.u64(size) }
        if let permissions { writer.u32(permissions) }
        if let atime, let mtime {
            writer.u32(atime)
            writer.u32(mtime)
        }
    }
}

struct SFTPError: Error, CustomStringConvertible {
    static let eof: UInt32 = 1
    static let noSuchFile: UInt32 = 2
    static let permissionDenied: UInt32 = 3
    static let failure: UInt32 = 4
    static let unsupported: UInt32 = 8
    static let connectionLost: UInt32 = 7

    let code: UInt32
    let message: String

    var description: String { message.isEmpty ? "SFTP error \(code)" : message }
}

// SFTP version 3, the one OpenSSH speaks, over a subsystem channel of the system ssh. Going through ssh keeps the
// user's ~/.ssh/config, keys, agent, ProxyJump and known hosts exactly as they are in Terminal.
final class SFTPClient: @unchecked Sendable {
    struct Reply {
        let type: UInt8
        var reader: ByteReader
    }

    struct Statvfs {
        let blockSize: UInt64
        let blocks: UInt64
        let free: UInt64
        let available: UInt64
        let files: UInt64
        let freeFiles: UInt64
    }

    enum OpenFlag {
        static let read: UInt32 = 0x01
        static let write: UInt32 = 0x02
        static let create: UInt32 = 0x08
        static let truncate: UInt32 = 0x10
        static let exclusive: UInt32 = 0x20
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writes = DispatchQueue(label: "gremlin.sftp.write")
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var waiting: [UInt32: CheckedContinuation<Reply, Error>] = [:]
    private var greeting: CheckedContinuation<Void, Error>?
    private var ended: SFTPError?
    private var errorText = ""
    private let errorsDrained = DispatchSemaphore(value: 0)
    private(set) var extensions: Set<String> = []
    // OpenSSH caps a read or write at a little under 256 KB, and some servers at 32 KB.
    private(set) var chunk = 32768

    var onEnd: (@Sendable (String) -> Void)?

    var isAlive: Bool { lock.withLock { ended == nil } }

    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() async throws {
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        Thread.detachNewThread { [self] in drainErrors() }
        Thread.detachNewThread { [self] in readReplies() }
        var hello = ByteWriter()
        hello.u32(5)
        hello.u8(1)
        hello.u32(3)
        let packet = hello.bytes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ended = lock.withLock {
                if ended == nil { greeting = continuation }
                return ended
            }
            if let ended { return continuation.resume(throwing: ended) }
            send(packet)
        }
        if extensions.contains("limits@openssh.com"), let limits = try? await extended("limits@openssh.com", { _ in }) {
            var reader = limits
            _ = try? reader.u64()
            let read = (try? reader.u64()) ?? 0
            let write = (try? reader.u64()) ?? 0
            let most = min(read, write)
            if most >= 65536 { chunk = 65536 }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    // MARK: Requests

    func realpath(_ path: String) async throws -> String {
        var reader = try expect(104, await request(16) { $0.string(path) })
        guard try reader.u32() >= 1 else { throw SFTPError(code: SFTPError.failure, message: "No path") }
        return try reader.text()
    }

    func stat(_ path: String) async throws -> SFTPAttributes {
        var reader = try expect(105, await request(17) { $0.string(path) })
        return try SFTPAttributes(from: &reader)
    }

    func lstat(_ path: String) async throws -> SFTPAttributes {
        var reader = try expect(105, await request(7) { $0.string(path) })
        return try SFTPAttributes(from: &reader)
    }

    func setstat(_ path: String, _ attributes: SFTPAttributes) async throws {
        try status(await request(9) {
            $0.string(path)
            attributes.write(to: &$0)
        })
    }

    func open(_ path: String, flags: UInt32, attributes: SFTPAttributes = SFTPAttributes()) async throws -> [UInt8] {
        var reader = try expect(102, await request(3) {
            $0.string(path)
            $0.u32(flags)
            attributes.write(to: &$0)
        })
        return try reader.string(max: 256)
    }

    func close(_ handle: [UInt8]) async throws {
        try status(await request(4) { $0.string(handle) })
    }

    // Empty at the end of the file.
    func read(_ handle: [UInt8], offset: UInt64, length: Int) async throws -> [UInt8] {
        let reply = try await request(5) {
            $0.string(handle)
            $0.u64(offset)
            $0.u32(UInt32(length))
        }
        if reply.type == 101 {
            var reader = reply.reader
            if try reader.u32() == SFTPError.eof { return [] }
        }
        var reader = try expect(103, reply)
        return try reader.string(max: 1 << 22)
    }

    func write(_ handle: [UInt8], offset: UInt64, data: ArraySlice<UInt8>) async throws {
        try status(await request(6) {
            $0.string(handle)
            $0.u64(offset)
            $0.string(data)
        })
    }

    func list(_ path: String) async throws -> [(name: String, attributes: SFTPAttributes)] {
        var reader = try expect(102, await request(11) { $0.string(path) })
        let handle = try reader.string(max: 256)
        var entries: [(String, SFTPAttributes)] = []
        do {
            while true {
                let reply = try await request(12) { $0.string(handle) }
                if reply.type == 101 {
                    var reader = reply.reader
                    if try reader.u32() == SFTPError.eof { break }
                }
                var reader = try expect(104, reply)
                for _ in 0..<(try reader.u32()) {
                    let name = try reader.text()
                    _ = try reader.string()
                    let attributes = try SFTPAttributes(from: &reader)
                    if name != ".", name != ".." { entries.append((name, attributes)) }
                }
            }
        } catch {
            try? await close(handle)
            throw error
        }
        try? await close(handle)
        return entries
    }

    func remove(_ path: String) async throws {
        try status(await request(13) { $0.string(path) })
    }

    func mkdir(_ path: String, permissions: UInt32) async throws {
        try status(await request(14) {
            $0.string(path)
            SFTPAttributes(permissions: permissions).write(to: &$0)
        })
    }

    func rmdir(_ path: String) async throws {
        try status(await request(15) { $0.string(path) })
    }

    func readlink(_ path: String) async throws -> String {
        var reader = try expect(104, await request(19) { $0.string(path) })
        guard try reader.u32() >= 1 else { throw SFTPError(code: SFTPError.failure, message: "No target") }
        return try reader.text()
    }

    // OpenSSH takes the target first, the reverse of the draft, and other servers copy it.
    func symlink(_ path: String, to target: String) async throws {
        try status(await request(20) {
            $0.string(target)
            $0.string(path)
        })
    }

    // Plain SFTP rename refuses to replace a file, which is what a safe save does.
    func rename(_ from: String, to: String) async throws {
        if extensions.contains("posix-rename@openssh.com") {
            return try status(await request(200) {
                $0.string("posix-rename@openssh.com")
                $0.string(from)
                $0.string(to)
            })
        }
        do {
            try status(await request(18) {
                $0.string(from)
                $0.string(to)
            })
        } catch let error as SFTPError where error.code == SFTPError.failure {
            guard let target = try? await lstat(to), !target.isDirectory else { throw error }
            try await remove(to)
            try status(await request(18) {
                $0.string(from)
                $0.string(to)
            })
        }
    }

    func hardlink(_ path: String, to existing: String) async throws {
        guard extensions.contains("hardlink@openssh.com") else { throw SFTPError(code: SFTPError.unsupported, message: "") }
        try status(await request(200) {
            $0.string("hardlink@openssh.com")
            $0.string(existing)
            $0.string(path)
        })
    }

    func statvfs(_ path: String) async throws -> Statvfs? {
        guard extensions.contains("statvfs@openssh.com") else { return nil }
        var reader = try await extended("statvfs@openssh.com") { $0.string(path) }
        _ = try reader.u64()
        let fragment = try reader.u64()
        return Statvfs(blockSize: fragment, blocks: try reader.u64(), free: try reader.u64(), available: try reader.u64(),
                       files: try reader.u64(), freeFiles: try reader.u64())
    }

    private func extended(_ name: String, _ fill: (inout ByteWriter) -> Void) async throws -> ByteReader {
        try expect(201, await request(200) {
            $0.string(name)
            fill(&$0)
        })
    }

    // MARK: Plumbing

    private func request(_ type: UInt8, _ fill: (inout ByteWriter) -> Void) async throws -> Reply {
        let id = lock.withLock {
            defer { nextID &+= 1 }
            return nextID
        }
        var writer = ByteWriter()
        writer.u32(0)
        writer.u8(type)
        writer.u32(id)
        fill(&writer)
        let length = UInt32(writer.bytes.count - 4).bigEndian
        withUnsafeBytes(of: length) { writer.bytes.replaceSubrange(0..<4, with: $0) }
        let packet = writer.bytes
        return try await withCheckedThrowingContinuation { continuation in
            let ended = lock.withLock {
                if ended == nil { waiting[id] = continuation }
                return ended
            }
            if let ended { return continuation.resume(throwing: ended) }
            send(packet)
        }
    }

    private func send(_ packet: [UInt8]) {
        let fd = input.fileHandleForWriting.fileDescriptor
        writes.async { [self] in
            guard Self.writeAll(fd, packet) else { return end() }
        }
    }

    private func expect(_ type: UInt8, _ reply: Reply) throws -> ByteReader {
        try status(reply, unless: type)
        return reply.reader
    }

    private func status(_ reply: Reply, unless type: UInt8? = nil) throws {
        if let type, reply.type == type { return }
        guard reply.type == 101 else { throw SFTPError(code: SFTPError.failure, message: "Unexpected reply \(reply.type)") }
        var reader = reply.reader
        let code = try reader.u32()
        guard code == 0 else { throw SFTPError(code: code, message: (try? reader.text()) ?? "") }
        if type != nil { throw SFTPError(code: SFTPError.failure, message: "Unexpected status") }
    }

    private func readReplies() {
        let fd = output.fileHandleForReading.fileDescriptor
        var header = [UInt8](repeating: 0, count: 4)
        while Self.readAll(fd, &header) {
            let length = Int(header.reduce(0) { $0 << 8 | UInt32($1) })
            guard length >= 1, length <= 1 << 22 else { break }
            var body = [UInt8](repeating: 0, count: length)
            guard Self.readAll(fd, &body) else { break }
            deliver(body)
        }
        process.waitUntilExit()
        _ = errorsDrained.wait(timeout: .now() + 2)
        end()
    }

    private func deliver(_ body: [UInt8]) {
        var reader = ByteReader(body, at: 1)
        if body[0] == 2 {
            _ = try? reader.u32()
            var names: Set<String> = []
            while reader.remaining > 0, let name = try? reader.text(), (try? reader.string()) != nil { names.insert(name) }
            let continuation = lock.withLock {
                extensions = names
                defer { greeting = nil }
                return greeting
            }
            continuation?.resume()
            return
        }
        guard let id = try? reader.u32() else { return }
        let continuation = lock.withLock { waiting.removeValue(forKey: id) }
        continuation?.resume(returning: Reply(type: body[0], reader: reader))
    }

    private func drainErrors() {
        let fd = errors.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            lock.withLock { errorText = String((errorText + text).suffix(4000)) }
        }
        errorsDrained.signal()
    }

    private func end() {
        let (pending, hello, error): ([CheckedContinuation<Reply, Error>], CheckedContinuation<Void, Error>?, SFTPError?) = lock.withLock {
            guard ended == nil else { return ([], nil, nil) }
            let lines = errorText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let error = SFTPError(code: SFTPError.connectionLost, message: lines.last ?? "The connection closed")
            ended = error
            defer {
                waiting = [:]
                greeting = nil
            }
            return (Array(waiting.values), greeting, error)
        }
        guard let error else { return }
        terminate()
        pending.forEach { $0.resume(throwing: error) }
        hello?.resume(throwing: error)
        onEnd?(error.message)
    }

    private static func readAll(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
        var done = 0
        let total = buffer.count
        while done < total {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + done, total - done) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            done += count
        }
        return true
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var done = 0
        while done < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            done += count
        }
        return true
    }
}

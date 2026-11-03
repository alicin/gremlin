import Foundation

// NFS version 3 on 127.0.0.1, for macOS's own NFS client to mount. It needs no kernel extension or macFUSE, and a
// user can mount it without being an administrator.
final class NFSServer: @unchecked Sendable {
    private final class Connection {
        let fd: Int32
        private let lock = NSLock()
        private var open = true

        init(fd: Int32) {
            self.fd = fd
        }

        func send(_ bytes: [UInt8]) {
            lock.withLock {
                guard open else { return }
                if !SFTPClient.writeAll(fd, bytes) {
                    open = false
                    Darwin.shutdown(fd, SHUT_RDWR)
                }
            }
        }

        func shutdown() {
            lock.withLock {
                open = false
                Darwin.shutdown(fd, SHUT_RDWR)
            }
        }

        // Only the thread reading it closes it, so a write never lands on a descriptor that was reused.
        func close() {
            lock.withLock {
                open = false
                Darwin.close(fd)
            }
        }
    }

    private struct Call {
        let xid: UInt32
        let program: UInt32
        let version: UInt32
        let procedure: UInt32
        let uid: UInt32?
        var args: ByteReader
    }

    private enum Outcome {
        case done([UInt8])
        case garbage
        case unavailable
    }

    private enum Duplicate {
        case running
        case done([UInt8], Date)
    }

    private struct Listing {
        let directory: UInt64
        let entries: [DriveFS.Entry]
        let at: Date
    }

    // What a failed reply carries after its status, by procedure: attributes and handles that don't follow.
    private static let failureWords: [UInt32: Int] = [
        1: 0, 2: 2, 3: 1, 4: 1, 5: 1, 6: 1, 7: 2, 8: 2, 9: 2, 10: 2, 11: 2, 12: 2, 13: 2, 14: 4, 15: 3, 16: 1, 17: 1, 18: 1, 19: 1,
        20: 1, 21: 2,
    ]
    // Done twice, these give a different answer the second time, so a retransmission gets the first answer again.
    private static let unrepeatable: Set<UInt32> = [8, 9, 10, 11, 12, 13, 14, 15]

    let port: UInt16
    let export: String
    private let fs: DriveFS
    private let listener: Int32
    private let source: DispatchSourceRead
    private let secret: [UInt8]
    private let verifier: [UInt8]
    private let owner = getuid()
    private let lock = NSLock()
    private var connections: [Connection] = []
    private var mountable = false
    private var duplicates: [UInt64: Duplicate] = [:]
    private var listings: [UInt64: Listing] = [:]
    private var nextVerifier = UInt64.random(in: 1...UInt64(UInt32.max))

    init(fs: DriveFS, export: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound, listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        port = UInt16(bigEndian: address.sin_port)
        self.export = export
        self.fs = fs
        listener = fd
        // Handles carry a secret, so another program on this Mac can't make up one and skip the mount.
        secret = (0..<8).map { _ in UInt8.random(in: 0...255) }
        verifier = (0..<8).map { _ in UInt8.random(in: 0...255) }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    // The root handle is handed out only while Gremlin's own mount is running.
    func allowMount(_ allow: Bool) {
        lock.withLock { mountable = allow }
    }

    func stop() {
        source.cancel()
        lock.withLock { connections }.forEach { $0.shutdown() }
    }

    private func accept() {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(fd: fd)
            lock.withLock { connections.append(connection) }
            Thread.detachNewThread { [weak self] in
                self?.serve(connection)
                connection.close()
            }
        }
    }

    private func serve(_ connection: Connection) {
        var record: [UInt8] = []
        var header = [UInt8](repeating: 0, count: 4)
        while Self.readAll(connection.fd, &header) {
            let mark = header.reduce(0) { $0 << 8 | UInt32($1) }
            let length = Int(mark & 0x7fff_ffff)
            guard record.count + length <= 4 << 20 else { break }
            var fragment = [UInt8](repeating: 0, count: length)
            guard Self.readAll(connection.fd, &fragment) else { break }
            record += fragment
            if mark & 0x8000_0000 != 0 {
                receive(record, on: connection)
                record = []
            }
        }
        lock.withLock { connections.removeAll { $0 === connection } }
    }

    private func receive(_ record: [UInt8], on connection: Connection) {
        var reader = ByteReader(record)
        guard let xid = try? reader.u32(), (try? reader.u32()) == 0, (try? reader.u32()) == 2,
              let program = try? reader.u32(), let version = try? reader.u32(), let procedure = try? reader.u32(),
              let flavor = try? reader.u32(), let credential = try? reader.opaque(max: 400),
              (try? reader.u32()) != nil, (try? reader.opaque(max: 400)) != nil
        else { return }
        let call = Call(xid: xid, program: program, version: version, procedure: procedure,
                        uid: flavor == 1 ? Self.uid(credential) : nil, args: reader)
        let key = UInt64(xid) << 8 | UInt64(procedure & 0xff)
        let remember = program == 100_003 && Self.unrepeatable.contains(procedure)
        if remember {
            let earlier: Duplicate? = lock.withLock {
                if let earlier = duplicates[key] { return earlier }
                duplicates[key] = .running
                return nil
            }
            switch earlier {
            case .running: return
            case .done(let reply, _): return connection.send(reply)
            case nil: break
            }
        }
        Task {
            let reply = await self.reply(to: call)
            if remember { self.remember(reply, for: key) }
            connection.send(reply)
        }
    }

    private func remember(_ reply: [UInt8], for key: UInt64) {
        lock.withLock {
            let now = Date()
            duplicates[key] = .done(reply, now)
            if duplicates.count > 512 {
                duplicates = duplicates.filter {
                    if case .done(_, let at) = $0.value { return now.timeIntervalSince(at) < 120 }
                    return true
                }
            }
        }
    }

    private func reply(to call: Call) async -> [UInt8] {
        let outcome: Outcome = switch (call.program, call.version) {
        case (100_003, 3): await nfs(call)
        case (100_005, 1...3): mount(call)
        default: .unavailable
        }
        var out = ByteWriter()
        out.u32(0)
        out.u32(call.xid)
        out.u32(1)
        out.u32(0)
        out.u32(0)
        out.u32(0)
        switch outcome {
        case .done(let body):
            out.u32(0)
            out.bytes += body
        case .garbage:
            out.u32(4)
        case .unavailable where call.program != 100_003 && call.program != 100_005:
            out.u32(1)
        case .unavailable where call.program == 100_003 && call.version != 3:
            out.u32(2)
            out.u32(3)
            out.u32(3)
        case .unavailable where call.program == 100_005 && !(1...3).contains(call.version):
            out.u32(2)
            out.u32(1)
            out.u32(3)
        case .unavailable:
            out.u32(3)
        }
        let mark = (0x8000_0000 | UInt32(out.bytes.count - 4)).bigEndian
        withUnsafeBytes(of: mark) { out.bytes.replaceSubrange(0..<4, with: $0) }
        return out.bytes
    }

    // MARK: MOUNT

    private func mount(_ call: Call) -> Outcome {
        var args = call.args
        var out = ByteWriter()
        switch call.procedure {
        case 0, 3, 4:
            break
        case 1:
            guard (try? args.opaque(max: 1024)) != nil else { return .garbage }
            guard call.version == 3, lock.withLock({ mountable }), call.uid == owner || call.uid == 0 else {
                out.u32(13)
                break
            }
            out.u32(0)
            out.opaque(handle(DriveFS.rootID))
            out.u32(1)
            out.u32(1)
        case 2:
            out.bool(false)
        case 5:
            out.bool(true)
            out.opaque(Array(export.utf8))
            out.bool(false)
            out.bool(false)
        default:
            return .unavailable
        }
        return .done(out.bytes)
    }

    // MARK: NFS

    private func nfs(_ call: Call) async -> Outcome {
        guard call.procedure != 0 else { return .done([]) }
        guard let words = Self.failureWords[call.procedure] else { return .unavailable }
        var out = ByteWriter()
        func failed(_ status: UInt32) -> Outcome {
            var out = ByteWriter()
            out.u32(status)
            for _ in 0..<words { out.u32(0) }
            return .done(out.bytes)
        }
        // Another account on this Mac reaching into the mount would be using this user's server login.
        guard call.uid == owner || call.uid == 0 else { return failed(NFSError.acces.status) }
        var args = call.args
        do {
            try await procedure(call.procedure, &args, &out)
            return .done(out.bytes)
        } catch is ByteReader.Truncated {
            return .garbage
        } catch let error as NFSError {
            return failed(error.status)
        } catch {
            return failed(NFSError.io.status)
        }
    }

    private func procedure(_ number: UInt32, _ args: inout ByteReader, _ out: inout ByteWriter) async throws {
        switch number {
        case 1:
            let info = try await fs.attributes(try id(&args))
            out.u32(0)
            attributes(info, &out)
        case 2:
            let id = try id(&args)
            let changes = try changes(&args)
            if try args.bool() { _ = try args.fixed(8) }
            let unchanged = changes.mode == nil && changes.size == nil && changes.atime == nil && changes.mtime == nil
            let info: FileInfo
            if unchanged {
                info = try await fs.attributes(id)
            } else {
                info = try await fs.setAttributes(id, changes)
            }
            out.u32(0)
            out.bool(false)
            after(info, &out)
        case 3:
            let directory = try id(&args)
            let (id, info) = try await fs.lookup(directory, try name(&args))
            out.u32(0)
            out.opaque(handle(id))
            after(info, &out)
            out.bool(false)
        case 4:
            let id = try id(&args)
            let (info, granted) = try await fs.access(id, try args.u32())
            out.u32(0)
            after(info, &out)
            out.u32(granted)
        case 5:
            let target = try await fs.readlink(try id(&args))
            out.u32(0)
            out.bool(false)
            out.opaque(Array(target.utf8))
        case 6:
            let id = try id(&args)
            let offset = try args.u64()
            let count = min(Int(try args.u32()), 1 << 20)
            let (data, eof) = try await fs.read(id, offset: offset, count: count)
            out.u32(0)
            out.bool(false)
            out.u32(UInt32(data.count))
            out.bool(eof)
            out.opaque(data)
        case 7:
            let id = try id(&args)
            let offset = try args.u64()
            _ = try args.u32()
            _ = try args.u32()
            let data = try args.opaque(max: 1 << 21)
            try await fs.write(id, offset: offset, data: data)
            out.u32(0)
            out.bool(false)
            out.bool(false)
            out.u32(UInt32(data.count))
            // Each write is on the server before the reply, so there's nothing for a COMMIT to wait for.
            out.u32(2)
            out.fixed(verifier)
        case 8:
            let directory = try id(&args)
            let name = try name(&args)
            var mode: UInt32 = 0o644
            var exclusive = false
            var later: FileChanges?
            var truncate = false
            switch try args.u32() {
            case let how where how < 2:
                let changes = try changes(&args)
                mode = changes.mode ?? mode
                exclusive = how == 1
                truncate = changes.size == 0
                if changes.atime != nil || changes.mtime != nil || (changes.size ?? 0) > 0 { later = changes }
            case 2:
                _ = try args.fixed(8)
                exclusive = true
            default:
                throw NFSError.inval
            }
            let (id, made) = try await fs.create(directory, name, mode: mode, exclusive: exclusive, truncate: truncate)
            var info = made
            if let later { info = try await fs.setAttributes(id, later) }
            created(id, info, &out)
        case 9:
            let directory = try id(&args)
            let name = try name(&args)
            let mode = try changes(&args).mode ?? 0o755
            let (id, info) = try await fs.mkdir(directory, name, mode: mode)
            created(id, info, &out)
        case 10:
            let directory = try id(&args)
            let name = try name(&args)
            _ = try changes(&args)
            let target = String(decoding: try args.opaque(max: 4096), as: UTF8.self)
            let (id, info) = try await fs.symlink(directory, name, target: target)
            created(id, info, &out)
        case 11:
            throw NFSError.notsupp
        case 12, 13:
            let directory = try id(&args)
            let name = try name(&args)
            if number == 12 {
                try await fs.remove(directory, name)
            } else {
                try await fs.rmdir(directory, name)
            }
            out.u32(0)
            out.bool(false)
            out.bool(false)
        case 14:
            let from = try id(&args)
            let fromName = try name(&args)
            let to = try id(&args)
            try await fs.rename(from, fromName, to: to, try name(&args))
            out.u32(0)
            for _ in 0..<4 { out.bool(false) }
        case 15:
            let id = try id(&args)
            let directory = try self.id(&args)
            try await fs.link(id, into: directory, try name(&args))
            out.u32(0)
            for _ in 0..<3 { out.bool(false) }
        case 16, 17:
            try await readdir(plus: number == 17, &args, &out)
        case 18:
            _ = try id(&args)
            let space = await fs.space()
            out.u32(0)
            out.bool(false)
            // Finder won't copy to a volume that reports no room, so a server that can't say gets a large guess.
            let guess: UInt64 = 1 << 40
            out.u64(space?.total ?? guess)
            out.u64(space?.free ?? guess)
            out.u64(space?.available ?? guess)
            out.u64(space?.files ?? 1 << 32)
            out.u64(space?.freeFiles ?? 1 << 32)
            out.u64(space?.freeFiles ?? 1 << 32)
            out.u32(0)
        case 19:
            _ = try id(&args)
            out.u32(0)
            out.bool(false)
            for value in [1 << 20, 131_072, 4096, 1 << 20, 131_072, 4096, 65536] as [UInt32] { out.u32(value) }
            out.u64(UInt64(Int64.max))
            // SFTP keeps times to the second.
            out.u32(1)
            out.u32(0)
            out.u32(0x1b)
        case 20:
            _ = try id(&args)
            out.u32(0)
            out.bool(false)
            out.u32(32000)
            out.u32(255)
            out.bool(true)
            out.bool(true)
            out.bool(false)
            out.bool(true)
        case 21:
            _ = try id(&args)
            out.u32(0)
            out.bool(false)
            out.bool(false)
            out.fixed(verifier)
        default:
            throw NFSError.notsupp
        }
    }

    private func readdir(plus: Bool, _ args: inout ByteReader, _ out: inout ByteWriter) async throws {
        let directory = try id(&args)
        let cookie = try args.u64()
        let wanted = try args.fixed(8).reduce(0) { $0 << 8 | UInt64($1) }
        let dircount = Int(try args.u32())
        let maxcount = plus ? Int(try args.u32()) : dircount
        let (verifier, entries) = try await listing(directory, cookie: cookie, verifier: wanted)
        let info = try? await fs.attributes(directory)
        let parent = fs.parent(of: directory)
        out.u32(0)
        after(info, &out)
        out.u64(verifier)
        var size = out.bytes.count + 8
        var names = 0
        let total = entries.count + 2
        let start = Int(min(cookie, UInt64(total)))
        var index = start
        while index < total {
            let (name, id, info): (String, UInt64, FileInfo?) = switch index {
            case 0: (".", directory, nil)
            case 1: ("..", parent, nil)
            default: (entries[index - 2].name, entries[index - 2].id, entries[index - 2].info)
            }
            var entry = ByteWriter()
            entry.bool(true)
            entry.u64(id)
            entry.opaque(Array(name.utf8))
            entry.u64(UInt64(index + 1))
            let nameSize = entry.bytes.count
            if plus {
                after(info, &entry)
                if info == nil {
                    entry.bool(false)
                } else {
                    entry.bool(true)
                    entry.opaque(handle(id))
                }
            }
            guard size + entry.bytes.count <= maxcount, !plus || names + nameSize <= dircount else { break }
            out.bytes += entry.bytes
            size += entry.bytes.count
            names += nameSize
            index += 1
        }
        guard index > start || index == total else { throw NFSError.toosmall }
        out.bool(false)
        out.bool(index == total)
    }

    // A long listing comes in several replies, which all page through the same snapshot.
    private func listing(_ directory: UInt64, cookie: UInt64, verifier: UInt64) async throws -> (UInt64, [DriveFS.Entry]) {
        if cookie != 0, let listing = lock.withLock({ listings[verifier] }), listing.directory == directory {
            return (verifier, listing.entries)
        }
        let entries = try await fs.list(directory)
        let verifier = lock.withLock {
            nextVerifier += 1
            let now = Date()
            listings = listings.filter { now.timeIntervalSince($0.value.at) < 60 }
            listings[nextVerifier] = Listing(directory: directory, entries: entries, at: now)
            return nextVerifier
        }
        return (verifier, entries)
    }

    // MARK: Encoding

    private func handle(_ id: UInt64) -> [UInt8] {
        var writer = ByteWriter(bytes: secret)
        writer.u64(id)
        return writer.bytes
    }

    private func id(_ args: inout ByteReader) throws -> UInt64 {
        let handle = try args.opaque(max: 64)
        guard handle.count == 16 else { throw NFSError.badhandle }
        guard Array(handle[0..<8]) == secret else { throw NFSError.stale }
        return handle[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func name(_ args: inout ByteReader) throws -> String {
        String(decoding: try args.opaque(max: 1024), as: UTF8.self)
    }

    private func changes(_ args: inout ByteReader) throws -> FileChanges {
        var changes = FileChanges()
        if try args.bool() { changes.mode = try args.u32() }
        if try args.bool() { _ = try args.u32() }
        if try args.bool() { _ = try args.u32() }
        if try args.bool() { changes.size = try args.u64() }
        func time() throws -> FileInfo.Time? {
            switch try args.u32() {
            case 1: return FileInfo.Time(seconds: UInt32(Date().timeIntervalSince1970))
            case 2: return FileInfo.Time(seconds: try args.u32(), nanoseconds: try args.u32())
            default: return nil
            }
        }
        changes.atime = try time()
        changes.mtime = try time()
        return changes
    }

    private func attributes(_ info: FileInfo, _ out: inout ByteWriter) {
        out.u32(info.kind.rawValue)
        out.u32(info.mode)
        out.u32(1)
        out.u32(info.uid)
        out.u32(info.gid)
        out.u64(info.size)
        out.u64(info.used)
        out.u64(0)
        out.u64(fs.fsid)
        out.u64(info.fileid)
        for time in [info.atime, info.mtime, info.ctime] {
            out.u32(time.seconds)
            out.u32(time.nanoseconds)
        }
    }

    private func after(_ info: FileInfo?, _ out: inout ByteWriter) {
        guard let info else { return out.bool(false) }
        out.bool(true)
        attributes(info, &out)
    }

    private func created(_ id: UInt64, _ info: FileInfo, _ out: inout ByteWriter) {
        out.u32(0)
        out.bool(true)
        out.opaque(handle(id))
        after(info, &out)
        out.bool(false)
        out.bool(false)
    }

    private static func uid(_ credential: [UInt8]) -> UInt32? {
        var reader = ByteReader(credential)
        guard (try? reader.u32()) != nil, (try? reader.opaque(max: 255)) != nil else { return nil }
        return try? reader.u32()
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
}

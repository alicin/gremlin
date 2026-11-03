import Foundation

struct NFSError: Error {
    let status: UInt32

    static let perm = NFSError(status: 1)
    static let noent = NFSError(status: 2)
    static let io = NFSError(status: 5)
    static let acces = NFSError(status: 13)
    static let exist = NFSError(status: 17)
    static let xdev = NFSError(status: 18)
    static let notdir = NFSError(status: 20)
    static let isdir = NFSError(status: 21)
    static let inval = NFSError(status: 22)
    static let nospc = NFSError(status: 28)
    static let rofs = NFSError(status: 30)
    static let nametoolong = NFSError(status: 63)
    static let notempty = NFSError(status: 66)
    static let stale = NFSError(status: 70)
    static let badhandle = NFSError(status: 10001)
    static let notsupp = NFSError(status: 10004)
    static let toosmall = NFSError(status: 10005)

    init(status: UInt32) {
        self.status = status
    }

    init(errno code: Int32) {
        status = switch code {
        case EPERM: 1
        case ENOENT: 2
        case EACCES: 13
        case EEXIST: 17
        case EXDEV: 18
        case ENOTDIR: 20
        case EISDIR: 21
        case EINVAL: 22
        case ENOSPC: 28
        case EROFS: 30
        case ENAMETOOLONG: 63
        case ENOTEMPTY: 66
        default: 5
        }
    }
}

struct FileInfo {
    enum Kind: UInt32 {
        case file = 1, directory, block, character, symlink, socket, fifo
    }

    struct Time {
        var seconds: UInt32
        var nanoseconds: UInt32 = 0
    }

    var kind: Kind
    var mode: UInt32
    var uid: UInt32
    var gid: UInt32
    var size: UInt64
    var used: UInt64
    var fileid: UInt64
    var atime: Time
    var mtime: Time
    var ctime: Time
}

struct FileChanges {
    var mode: UInt32?
    var size: UInt64?
    var atime: FileInfo.Time?
    var mtime: FileInfo.Time?
}

// One drive's files: a folder on the server, reached over SFTP, with the files only a Mac wants (._ files and
// .DS_Store) kept in a folder on this Mac instead. NFS names files by handle, so each path seen gets an ID that
// follows it through renames.
final class DriveFS: @unchecked Sendable {
    enum Access {
        static let read: UInt32 = 0x01
        static let lookup: UInt32 = 0x02
        static let modify: UInt32 = 0x04
        static let extend: UInt32 = 0x08
        static let delete: UInt32 = 0x10
        static let execute: UInt32 = 0x20
    }

    struct Entry {
        let name: String
        let id: UInt64
        let info: FileInfo
    }

    struct Space {
        let total: UInt64
        let free: UInt64
        let available: UInt64
        let files: UInt64
        let freeFiles: UInt64
    }

    enum Connection {
        case connected
        case lost(String)
        case failed(String)
    }

    private final class OpenFile {
        let handle: [UInt8]
        let client: SFTPClient
        var users = 0
        var lastUsed = Date()
        var doomed = false

        init(handle: [UInt8], client: SFTPClient) {
            self.handle = handle
            self.client = client
        }
    }

    private struct OpenKey: Hashable {
        let id: UInt64
        let write: Bool
    }

    static let rootID: UInt64 = 1

    let folder: String
    let readOnly: Bool
    let keepMacFiles: Bool
    let overlay: String
    let fsid: UInt64
    var onConnection: (@Sendable (Connection) -> Void)?

    private let launch: () -> SFTPClient
    private let lock = NSLock()
    private var sftp: SFTPClient?
    private var connecting: Task<SFTPClient, Error>?
    private var failedAt: Date?
    private var closed = false
    private(set) var root = "/"
    private var remoteUID: UInt32?
    private var remoteGID: UInt32?
    private let localUID = getuid()
    private let localGID = getgid()

    private var paths: [UInt64: String] = [DriveFS.rootID: ""]
    private var ids: [String: UInt64] = ["": DriveFS.rootID]
    private var nextID: UInt64 = 2
    private var cached: [String: (SFTPAttributes, Date)] = [:]
    private var missing: [String: Date] = [:]
    private var spaceCache: (Space, Date)?
    private var openFiles: [OpenKey: OpenFile] = [:]
    private var opening: [OpenKey: Task<OpenFile, Error>] = [:]
    private var sweeper: DispatchSourceTimer?

    init(folder: String, readOnly: Bool, keepMacFiles: Bool, overlay: String, fsid: UInt64, launch: @escaping () -> SFTPClient) {
        self.folder = folder
        self.readOnly = readOnly
        self.keepMacFiles = keepMacFiles
        self.overlay = overlay
        self.fsid = fsid
        self.launch = launch
    }

    // Connects for the first time and finds the folder. Later connections happen on their own when one drops.
    func connect() async throws {
        let client = try await reconnect(force: true)
        let home = try await client.realpath(".")
        let wanted = folder.trimmingCharacters(in: .whitespaces)
        let relative = wanted == "~" ? "" : wanted.hasPrefix("~/") ? String(wanted.dropFirst(2)) : wanted
        root = relative.isEmpty ? home : try await client.realpath(relative)
        if let attributes = try? await client.stat(home) {
            remoteUID = attributes.uid
            remoteGID = attributes.gid
        }
        guard try await client.stat(root).isDirectory else { throw SFTPError(code: SFTPError.failure, message: "\(root) isn't a folder") }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        lock.withLock { sweeper = timer }
    }

    func close() {
        let (client, timer) = lock.withLock {
            closed = true
            defer {
                sftp = nil
                openFiles = [:]
                sweeper = nil
            }
            return (sftp, sweeper)
        }
        timer?.cancel()
        client?.onEnd = nil
        client?.terminate()
    }

    // After a sleep or a network change the connection can look fine and be dead. One that doesn't answer in a few
    // seconds is dropped, and the next one starts right away.
    func check() async {
        guard let client = lock.withLock({ sftp }), client.isAlive else {
            _ = try? await reconnect(force: true)
            return
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(6))
            client.terminate()
        }
        _ = try? await client.stat(root)
        watchdog.cancel()
        if !client.isAlive { _ = try? await reconnect(force: true) }
    }

    // MARK: Files

    func attributes(_ id: UInt64) async throws -> FileInfo {
        let path = try path(of: id)
        if isLocal(path) { return try localInfo(path, id: id) }
        return info(try await remoteAttributes(path), id: id)
    }

    func lookup(_ directory: UInt64, _ name: String) async throws -> (UInt64, FileInfo) {
        let parent = try path(of: directory)
        if name == "." { return (directory, try await attributes(directory)) }
        if name == ".." {
            let up = parent.isEmpty ? "" : Self.parent(of: parent)
            let id = id(for: up)
            return (id, try await attributes(id))
        }
        try check(name)
        let path = Self.join(parent, name)
        if isLocal(path) {
            var status = stat()
            guard lstat(localPath(path), &status) == 0 else { throw NFSError(errno: errno) }
            let id = id(for: path)
            return (id, info(status, id: id))
        }
        if let when = lock.withLock({ missing[path] }), Date().timeIntervalSince(when) < 2 { throw NFSError.noent }
        let attributes = try await remoteAttributes(path)
        let id = id(for: path)
        return (id, info(attributes, id: id))
    }

    func access(_ id: UInt64, _ wanted: UInt32) async throws -> (FileInfo, UInt32) {
        let path = try path(of: id)
        if isLocal(path) { return (try localInfo(path, id: id), wanted) }
        let attributes = try await remoteAttributes(path)
        let permissions = attributes.permissions ?? 0o777
        let bits: UInt32 = if remoteUID == 0 {
            7
        } else if attributes.uid == nil || attributes.uid == remoteUID {
            permissions >> 6 & 7
        } else {
            // Group membership beyond the primary group isn't visible over SFTP, so this errs on the side of letting
            // the server say no.
            (permissions >> 3 | permissions) & 7
        }
        var granted: UInt32 = 0
        if bits & 4 != 0 { granted |= Access.read }
        if bits & 2 != 0, !readOnly { granted |= Access.modify | Access.extend | Access.delete }
        if attributes.isDirectory {
            if bits & 1 != 0 { granted |= Access.lookup }
        } else if bits & 1 != 0, remoteUID != 0 || permissions & 0o111 != 0 {
            granted |= Access.execute
        }
        return (info(attributes, id: id), granted & wanted)
    }

    func setAttributes(_ id: UInt64, _ changes: FileChanges) async throws -> FileInfo {
        guard !readOnly else { throw NFSError.rofs }
        let path = try path(of: id)
        if isLocal(path) {
            let local = localPath(path)
            if let size = changes.size, truncate(local, off_t(size)) != 0 { throw NFSError(errno: errno) }
            if let mode = changes.mode, chmod(local, mode_t(mode & 0o7777)) != 0 { throw NFSError(errno: errno) }
            if changes.atime != nil || changes.mtime != nil {
                var status = stat()
                guard lstat(local, &status) == 0 else { throw NFSError(errno: errno) }
                let atime = changes.atime.map { timespec(tv_sec: Int($0.seconds), tv_nsec: Int($0.nanoseconds)) } ?? status.st_atimespec
                let mtime = changes.mtime.map { timespec(tv_sec: Int($0.seconds), tv_nsec: Int($0.nanoseconds)) } ?? status.st_mtimespec
                let times = [atime, mtime]
                if utimensat(AT_FDCWD, local, times, AT_SYMLINK_NOFOLLOW) != 0 { throw NFSError(errno: errno) }
            }
            return try localInfo(path, id: id)
        }
        let current = try await remoteAttributes(path, fresh: true)
        // SFTP would change the file a link points to, not the link.
        guard !current.isSymlink else { return info(current, id: id) }
        var wanted = SFTPAttributes(size: changes.size, permissions: changes.mode.map { $0 & 0o7777 })
        if changes.atime != nil || changes.mtime != nil {
            let now = UInt32(Date().timeIntervalSince1970)
            wanted.atime = changes.atime?.seconds ?? current.atime ?? now
            wanted.mtime = changes.mtime?.seconds ?? current.mtime ?? now
        }
        if !wanted.isEmpty {
            try await remote(retry: true) { try await $0.setstat(self.remotePath(path), wanted) }
            forgetAttributes(path)
        }
        return info(try await remoteAttributes(path, fresh: true), id: id)
    }

    func readlink(_ id: UInt64) async throws -> String {
        let path = try path(of: id)
        if isLocal(path) {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = Darwin.readlink(localPath(path), &buffer, buffer.count - 1)
            guard count >= 0 else { throw NFSError(errno: errno) }
            return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let target = try await remote(retry: true) { try await $0.readlink(self.remotePath(path)) }
        return relative(target, from: Self.parent(of: path))
    }

    // An absolute link would point into this Mac, so one into the drive is made relative to where the link is.
    private func relative(_ target: String, from directory: String) -> String {
        let prefix = root == "/" ? "/" : root + "/"
        guard target == root || target.hasPrefix(prefix) else { return target }
        let to = target == root ? [] : target.dropFirst(prefix.count).split(separator: "/")
        let from = directory.split(separator: "/")
        let shared = zip(from, to).prefix { $0 == $1 }.count
        let parts = Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared).map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    func read(_ id: UInt64, offset: UInt64, count: Int) async throws -> (data: [UInt8], eof: Bool) {
        let path = try path(of: id)
        if isLocal(path) {
            let fd = Darwin.open(localPath(path), O_RDONLY)
            guard fd >= 0 else { throw NFSError(errno: errno) }
            defer { Darwin.close(fd) }
            var data = [UInt8](repeating: 0, count: count)
            let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            guard read >= 0 else { throw NFSError(errno: errno) }
            return (Array(data[0..<read]), read < count)
        }
        return try await withOpenFile(id, path: path, write: false) { client, handle in
            let pieces = Self.pieces(offset: offset, count: count, chunk: client.chunk)
            let data = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group in
                for (index, piece) in pieces.enumerated() {
                    group.addTask { (index, try await client.read(handle, offset: piece.offset, length: piece.count)) }
                }
                var parts = [[UInt8]?](repeating: nil, count: pieces.count)
                for try await (index, part) in group { parts[index] = part }
                // A short piece is the end of the file, so whatever comes after it doesn't count.
                var data: [UInt8] = []
                for (index, part) in parts.enumerated() {
                    data += part ?? []
                    if (part?.count ?? 0) < pieces[index].count { break }
                }
                return data
            }
            return (data, data.count < count)
        }
    }

    func write(_ id: UInt64, offset: UInt64, data: [UInt8]) async throws {
        guard !readOnly else { throw NFSError.rofs }
        let path = try path(of: id)
        if isLocal(path) {
            let fd = Darwin.open(localPath(path), O_WRONLY)
            guard fd >= 0 else { throw NFSError(errno: errno) }
            defer { Darwin.close(fd) }
            let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
            guard written == data.count else { throw NFSError(errno: written < 0 ? errno : EIO) }
            return
        }
        defer { forgetAttributes(path) }
        try await withOpenFile(id, path: path, write: true) { client, handle in
            let pieces = Self.pieces(offset: offset, count: data.count, chunk: client.chunk)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for piece in pieces {
                    let start = Int(piece.offset - offset)
                    group.addTask { try await client.write(handle, offset: piece.offset, data: data[start..<start + piece.count]) }
                }
                try await group.waitForAll()
            }
        }
    }

    func create(_ directory: UInt64, _ name: String, mode: UInt32, exclusive: Bool, truncate: Bool) async throws -> (UInt64, FileInfo) {
        guard !readOnly else { throw NFSError.rofs }
        try check(name)
        let path = Self.join(try self.path(of: directory), name)
        if isLocal(path) {
            try makeLocalParent(path)
            let flags = O_WRONLY | O_CREAT | (exclusive ? O_EXCL : 0) | (truncate ? O_TRUNC : 0)
            let fd = Darwin.open(localPath(path), flags, mode_t(mode & 0o7777))
            guard fd >= 0 else { throw NFSError(errno: errno) }
            Darwin.close(fd)
            let id = id(for: path)
            return (id, try localInfo(path, id: id))
        }
        let client = try await client()
        var flags = SFTPClient.OpenFlag.write | SFTPClient.OpenFlag.create
        if exclusive { flags |= SFTPClient.OpenFlag.exclusive } else if truncate { flags |= SFTPClient.OpenFlag.truncate }
        let handle: [UInt8]
        do {
            handle = try await client.open(remotePath(path), flags: flags, attributes: SFTPAttributes(permissions: mode & 0o7777))
        } catch let error as SFTPError where error.code == SFTPError.failure && exclusive {
            throw (try? await client.lstat(remotePath(path))) != nil ? NFSError.exist : Self.nfsError(error)
        } catch {
            throw Self.nfsError(error)
        }
        let id = id(for: path)
        created(path)
        // The writes that follow use the handle the create opened.
        let file = OpenFile(handle: handle, client: client)
        let replaced = lock.withLock {
            defer { openFiles[OpenKey(id: id, write: true)] = file }
            return openFiles[OpenKey(id: id, write: true)]
        }
        if let replaced { retire(replaced) }
        return (id, info(try await remoteAttributes(path, fresh: true), id: id))
    }

    func mkdir(_ directory: UInt64, _ name: String, mode: UInt32) async throws -> (UInt64, FileInfo) {
        guard !readOnly else { throw NFSError.rofs }
        try check(name)
        let path = Self.join(try self.path(of: directory), name)
        if isLocal(path) {
            try makeLocalParent(path)
            guard Darwin.mkdir(localPath(path), mode_t(mode & 0o7777)) == 0 else { throw NFSError(errno: errno) }
            let id = id(for: path)
            return (id, try localInfo(path, id: id))
        }
        let client = try await client()
        do {
            try await client.mkdir(remotePath(path), permissions: mode & 0o7777)
        } catch let error as SFTPError where error.code == SFTPError.failure {
            throw (try? await client.lstat(remotePath(path))) != nil ? NFSError.exist : Self.nfsError(error)
        } catch {
            throw Self.nfsError(error)
        }
        created(path)
        let id = id(for: path)
        return (id, info(try await remoteAttributes(path, fresh: true), id: id))
    }

    func symlink(_ directory: UInt64, _ name: String, target: String) async throws -> (UInt64, FileInfo) {
        guard !readOnly else { throw NFSError.rofs }
        try check(name)
        let path = Self.join(try self.path(of: directory), name)
        if isLocal(path) {
            try makeLocalParent(path)
            guard Darwin.symlink(target, localPath(path)) == 0 else { throw NFSError(errno: errno) }
            let id = id(for: path)
            return (id, try localInfo(path, id: id))
        }
        let client = try await client()
        do {
            try await client.symlink(remotePath(path), to: target)
        } catch let error as SFTPError where error.code == SFTPError.failure {
            throw (try? await client.lstat(remotePath(path))) != nil ? NFSError.exist : Self.nfsError(error)
        } catch {
            throw Self.nfsError(error)
        }
        created(path)
        let id = id(for: path)
        return (id, info(try await remoteAttributes(path, fresh: true), id: id))
    }

    func link(_ id: UInt64, into directory: UInt64, _ name: String) async throws {
        guard !readOnly else { throw NFSError.rofs }
        try check(name)
        let existing = try path(of: id)
        let path = Self.join(try self.path(of: directory), name)
        guard isLocal(existing) == isLocal(path) else { throw NFSError.xdev }
        if isLocal(path) {
            guard Darwin.link(localPath(existing), localPath(path)) == 0 else { throw NFSError(errno: errno) }
        } else {
            try await remote(retry: false) { try await $0.hardlink(self.remotePath(path), to: self.remotePath(existing)) }
            created(path)
        }
        forgetAttributes(existing)
    }

    func remove(_ directory: UInt64, _ name: String) async throws {
        guard !readOnly else { throw NFSError.rofs }
        try check(name)
        let path = Self.join(try self.path(of: directory), name)
        if isLocal(path) {
            guard unlink(localPath(path)) == 0 else { throw NFSError(errno: errno) }
        } else {
            let client = try await client()
            do {
                try await client.remove(remotePath(path))
            } catch let error as SFTPError where error.code == SFTPError.failure {
                throw (try? await client.lstat(remotePath(path)))?.isDirectory == true ? NFSError.isdir : Self.nfsError(error)
            } catch {
                throw Self.nfsError(error)
            }
        }
        forget(path)
    }

    func rmdir(_ directory: UInt64, _ name: String) async throws {
        guard !readOnly else { throw NFSError.rofs }
        try check(name)
        let path = Self.join(try self.path(of: directory), name)
        if isLocal(path) {
            guard Darwin.rmdir(localPath(path)) == 0 else { throw NFSError(errno: errno) }
        } else {
            let client = try await client()
            do {
                try await client.rmdir(remotePath(path))
            } catch let error as SFTPError where error.code == SFTPError.failure {
                guard let attributes = try? await client.lstat(remotePath(path)) else { throw Self.nfsError(error) }
                guard attributes.isDirectory else { throw NFSError.notdir }
                throw (try? await client.list(remotePath(path)))?.isEmpty == false ? NFSError.notempty : Self.nfsError(error)
            } catch {
                throw Self.nfsError(error)
            }
            // The ._ files of what was in it; the folder they described is gone.
            try? FileManager.default.removeItem(atPath: localPath(path))
        }
        forget(path)
    }

    func rename(_ fromDirectory: UInt64, _ fromName: String, to toDirectory: UInt64, _ toName: String) async throws {
        guard !readOnly else { throw NFSError.rofs }
        try check(fromName)
        try check(toName)
        let from = Self.join(try path(of: fromDirectory), fromName)
        let to = Self.join(try path(of: toDirectory), toName)
        guard from != to else { return }
        guard isLocal(from) == isLocal(to) else { throw NFSError.xdev }
        if isLocal(from) {
            try makeLocalParent(to)
            guard Darwin.rename(localPath(from), localPath(to)) == 0 else { throw NFSError(errno: errno) }
        } else {
            let client = try await client()
            do {
                try await client.rename(remotePath(from), to: remotePath(to))
            } catch let error as SFTPError where error.code == SFTPError.failure {
                if let target = try? await client.lstat(remotePath(to)), target.isDirectory {
                    throw (try? await client.list(remotePath(to)))?.isEmpty == false ? NFSError.notempty : NFSError.exist
                }
                throw Self.nfsError(error)
            } catch {
                throw Self.nfsError(error)
            }
            var status = stat()
            if lstat(localPath(from), &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
                try? FileManager.default.removeItem(atPath: localPath(to))
                try? makeLocalParent(to)
                Darwin.rename(localPath(from), localPath(to))
            }
        }
        moved(from, to: to)
    }

    func list(_ directory: UInt64) async throws -> [Entry] {
        let path = try path(of: directory)
        var entries: [Entry] = []
        if !isLocal(path) {
            let items = try await remote(retry: true) { try await $0.list(self.remotePath(path)) }
            let now = Date()
            for item in items where !isMacFile(item.name) {
                let child = Self.join(path, item.name)
                let id = id(for: child)
                lock.withLock { cached[child] = (item.attributes, now) }
                entries.append(Entry(name: item.name, id: id, info: info(item.attributes, id: id)))
            }
            guard keepMacFiles else { return entries }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: localPath(path))) ?? []
        for name in names where isLocal(path) || isMacFile(name) {
            let child = Self.join(path, name)
            var status = stat()
            guard lstat(localPath(child), &status) == 0 else { continue }
            let id = id(for: child)
            entries.append(Entry(name: name, id: id, info: info(status, id: id)))
        }
        return entries
    }

    func space() async -> Space? {
        if let (space, at) = lock.withLock({ spaceCache }), Date().timeIntervalSince(at) < 10 { return space }
        guard let client = try? await client(), let stats = try? await client.statvfs(root) else { return nil }
        let space = Space(total: stats.blocks * stats.blockSize, free: stats.free * stats.blockSize,
                          available: stats.available * stats.blockSize, files: stats.files, freeFiles: stats.freeFiles)
        lock.withLock { spaceCache = (space, Date()) }
        return space
    }

    // MARK: Paths

    static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    func parent(of id: UInt64) -> UInt64 {
        guard let path = try? path(of: id), !path.isEmpty else { return Self.rootID }
        return self.id(for: Self.parent(of: path))
    }

    func id(for path: String) -> UInt64 {
        lock.withLock {
            if let id = ids[path] { return id }
            let id = nextID
            nextID += 1
            ids[path] = id
            paths[id] = path
            return id
        }
    }

    private func path(of id: UInt64) throws -> String {
        guard let path = lock.withLock({ paths[id] }) else { throw NFSError.stale }
        return path
    }

    private func check(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw NFSError.inval }
        guard name.utf8.count <= 255 else { throw NFSError.nametoolong }
    }

    private func remotePath(_ path: String) -> String {
        path.isEmpty ? root : root == "/" ? "/" + path : root + "/" + path
    }

    private func localPath(_ path: String) -> String {
        path.isEmpty ? overlay : overlay + "/" + path
    }

    private func isMacFile(_ name: String) -> Bool {
        keepMacFiles && (name.hasPrefix("._") || name == ".DS_Store")
    }

    private func isLocal(_ path: String) -> Bool {
        keepMacFiles && !path.isEmpty && path.split(separator: "/").contains { isMacFile(String($0)) }
    }

    private func makeLocalParent(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: localPath(Self.parent(of: path)), withIntermediateDirectories: true)
        } catch {
            throw NFSError.io
        }
    }

    private func created(_ path: String) {
        lock.withLock {
            missing[path] = nil
            cached[path] = nil
        }
    }

    private func forget(_ path: String) {
        let retired: [OpenFile] = lock.withLock {
            var retired: [OpenFile] = []
            let prefix = path + "/"
            for (known, id) in ids where known == path || known.hasPrefix(prefix) {
                ids[known] = nil
                paths[id] = nil
                for write in [false, true] {
                    if let file = openFiles.removeValue(forKey: OpenKey(id: id, write: write)) { retired.append(file) }
                }
            }
            cached = cached.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
            return retired
        }
        retired.forEach(retire)
    }

    private func moved(_ from: String, to: String) {
        forget(to)
        lock.withLock {
            let prefix = from + "/"
            for (known, id) in ids where known == from || known.hasPrefix(prefix) {
                let path = to + known.dropFirst(from.count)
                ids[known] = nil
                ids[path] = id
                paths[id] = path
            }
            cached = cached.filter { $0.key != from && !$0.key.hasPrefix(prefix) }
            missing[to] = nil
        }
    }

    // MARK: Attributes

    private func remoteAttributes(_ path: String, fresh: Bool = false) async throws -> SFTPAttributes {
        if !fresh, let (attributes, at) = lock.withLock({ cached[path] }), Date().timeIntervalSince(at) < 2 { return attributes }
        do {
            let attributes = try await remote(retry: true) { client in
                if path.isEmpty { return try await client.stat(self.root) }
                return try await client.lstat(self.remotePath(path))
            }
            lock.withLock {
                cached[path] = (attributes, Date())
                missing[path] = nil
            }
            return attributes
        } catch let error as NFSError where error.status == NFSError.noent.status {
            lock.withLock { missing[path] = Date() }
            throw error
        }
    }

    private func forgetAttributes(_ path: String) {
        lock.withLock { cached[path] = nil }
    }

    private func info(_ attributes: SFTPAttributes, id: UInt64) -> FileInfo {
        let permissions = attributes.permissions ?? 0o100644
        let kind: FileInfo.Kind = switch permissions & 0o170000 {
        case 0o040000: .directory
        case 0o120000: .symlink
        case 0o060000: .block
        case 0o020000: .character
        case 0o140000: .socket
        case 0o010000: .fifo
        default: .file
        }
        let mtime = FileInfo.Time(seconds: attributes.mtime ?? 0)
        return FileInfo(kind: kind, mode: permissions & 0o7777, uid: owner(attributes.uid, remote: remoteUID, local: localUID),
                        gid: owner(attributes.gid, remote: remoteGID, local: localGID), size: attributes.size ?? 0,
                        used: attributes.size ?? 0, fileid: id, atime: FileInfo.Time(seconds: attributes.atime ?? 0), mtime: mtime,
                        ctime: mtime)
    }

    // The account on the server is this Mac's user here. Any other owner keeps its number, unless that number is this
    // Mac's user, who would then seem to own someone else's files.
    private func owner(_ id: UInt32?, remote: UInt32?, local: UInt32) -> UInt32 {
        guard let id, id != remote else { return local }
        return id == local ? 4_294_967_294 : id
    }

    private func info(_ status: stat, id: UInt64) -> FileInfo {
        let kind: FileInfo.Kind = switch status.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        case S_IFBLK: .block
        case S_IFCHR: .character
        case S_IFSOCK: .socket
        case S_IFIFO: .fifo
        default: .file
        }
        func time(_ spec: timespec) -> FileInfo.Time {
            FileInfo.Time(seconds: UInt32(truncatingIfNeeded: spec.tv_sec), nanoseconds: UInt32(spec.tv_nsec))
        }
        return FileInfo(kind: kind, mode: UInt32(status.st_mode) & 0o7777, uid: localUID, gid: localGID,
                        size: UInt64(status.st_size), used: UInt64(status.st_blocks) * 512, fileid: id,
                        atime: time(status.st_atimespec), mtime: time(status.st_mtimespec), ctime: time(status.st_ctimespec))
    }

    private func localInfo(_ path: String, id: UInt64) throws -> FileInfo {
        var status = stat()
        guard lstat(localPath(path), &status) == 0 else { throw NFSError(errno: errno) }
        return info(status, id: id)
    }

    // MARK: Connection

    private func client() async throws -> SFTPClient {
        do {
            return try await reconnect(force: false)
        } catch {
            throw Self.nfsError(error)
        }
    }

    // Finder asks again and again while the server is away, so a failed connection waits a while before the next try.
    private func reconnect(force: Bool) async throws -> SFTPClient {
        let task: Task<SFTPClient, Error> = try lock.withLock {
            if let sftp, sftp.isAlive { return Task { sftp } }
            if let connecting { return connecting }
            guard !closed else { throw SFTPError(code: SFTPError.connectionLost, message: "Ejected") }
            if !force, let failedAt, Date().timeIntervalSince(failedAt) < 15 {
                throw SFTPError(code: SFTPError.connectionLost, message: "Not connected")
            }
            let task = Task { try await self.open() }
            connecting = task
            return task
        }
        return try await task.value
    }

    private func open() async throws -> SFTPClient {
        let client = launch()
        do {
            try await client.start()
        } catch {
            let message = (error as? SFTPError)?.message ?? error.localizedDescription
            lock.withLock {
                connecting = nil
                failedAt = Date()
            }
            onConnection?(.failed(message))
            throw error
        }
        client.onEnd = { [weak self, weak client] message in
            guard let self, let client else { return }
            let current = self.lock.withLock {
                defer { if self.sftp === client { self.sftp = nil } }
                return self.sftp === client && !self.closed
            }
            if current { self.onConnection?(.lost(message)) }
        }
        let wasClosed = lock.withLock {
            connecting = nil
            failedAt = nil
            if !closed { sftp = client }
            return closed
        }
        if wasClosed {
            client.terminate()
            throw SFTPError(code: SFTPError.connectionLost, message: "Ejected")
        }
        onConnection?(.connected)
        return client
    }

    // Runs a request, and if the connection dropped under it, runs it once more on a new one when that's safe.
    private func remote<T>(retry: Bool, _ body: (SFTPClient) async throws -> T) async throws -> T {
        let client = try await client()
        do {
            return try await body(client)
        } catch let error as SFTPError where error.code == SFTPError.connectionLost && retry {
            do {
                return try await body(try await self.client())
            } catch {
                throw Self.nfsError(error)
            }
        } catch {
            throw Self.nfsError(error)
        }
    }

    private static func nfsError(_ error: Error) -> NFSError {
        if let error = error as? NFSError { return error }
        guard let error = error as? SFTPError else { return .io }
        switch error.code {
        case SFTPError.noSuchFile: return .noent
        case SFTPError.permissionDenied: return .acces
        case SFTPError.unsupported: return .notsupp
        default: return .io
        }
    }

    // MARK: Open files

    private func withOpenFile<T>(_ id: UInt64, path: String, write: Bool, _ body: (SFTPClient, [UInt8]) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            let file: OpenFile
            do {
                file = try await acquire(OpenKey(id: id, write: write), path: path)
            } catch {
                throw Self.nfsError(error)
            }
            do {
                defer { release(file) }
                return try await body(file.client, file.handle)
            } catch let error as SFTPError where error.code == SFTPError.connectionLost && attempt == 0 {
                attempt += 1
            } catch {
                throw Self.nfsError(error)
            }
        }
    }

    private func acquire(_ key: OpenKey, path: String) async throws -> OpenFile {
        let ready: OpenFile?, task: Task<OpenFile, Error>?
        (ready, task) = lock.withLock {
            if let file = openFiles[key], file.client.isAlive, !file.doomed {
                file.users += 1
                return (file, nil)
            }
            if let task = opening[key] { return (nil, task) }
            let task = Task {
                do {
                    let client = try await self.client()
                    let handle = try await client.open(self.remotePath(path), flags: key.write ? SFTPClient.OpenFlag.write : SFTPClient.OpenFlag.read)
                    let file = OpenFile(handle: handle, client: client)
                    let replaced = self.lock.withLock {
                        defer {
                            self.openFiles[key] = file
                            self.opening[key] = nil
                        }
                        return self.openFiles[key]
                    }
                    if let replaced { self.retire(replaced) }
                    return file
                } catch {
                    self.lock.withLock { self.opening[key] = nil }
                    throw error
                }
            }
            opening[key] = task
            return (nil, task)
        }
        if let ready { return ready }
        let file = try await task!.value
        let usable = lock.withLock {
            file.users += 1
            file.lastUsed = Date()
            return !file.doomed
        }
        guard usable else {
            release(file)
            return try await acquire(key, path: path)
        }
        return file
    }

    private func release(_ file: OpenFile) {
        let close = lock.withLock {
            file.users -= 1
            file.lastUsed = Date()
            return file.doomed && file.users <= 0
        }
        if close { Task { try? await file.client.close(file.handle) } }
    }

    private func retire(_ file: OpenFile) {
        let close = lock.withLock {
            file.doomed = true
            return file.users <= 0
        }
        if close { Task { try? await file.client.close(file.handle) } }
    }

    private func sweep() {
        let now = Date()
        let idle: [OpenFile] = lock.withLock {
            let idle = openFiles.filter { $0.value.users <= 0 && now.timeIntervalSince($0.value.lastUsed) > 3 }
            idle.keys.forEach { openFiles[$0] = nil }
            return Array(idle.values)
        }
        for file in idle where file.client.isAlive {
            Task { try? await file.client.close(file.handle) }
        }
    }

    private static func pieces(offset: UInt64, count: Int, chunk: Int) -> [(offset: UInt64, count: Int)] {
        stride(from: 0, to: count, by: chunk).map { (offset + UInt64($0), min(chunk, count - $0)) }
    }
}

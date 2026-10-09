import Foundation
import Darwin
import os

enum SizeMetric: String, CaseIterable {
    case logical = "파일 크기", allocated = "할당 크기", purgeable = "회수 대상"
}

// Share the common zero/unknown results rather than allocating metadata for every file.
final class FileRecovery: @unchecked Sendable {
    static let none = FileRecovery()
    static let unknown = FileRecovery(unknownFiles: 1)
    let allocatedBytes: Int64
    let privateBytes: Int64
    let fileCount: Int
    let unknownFiles: Int
    let privateUnknownFiles: Int

    init(allocated: Int64 = 0, privateBytes: Int64 = 0, files: Int = 0,
         unknownFiles: Int = 0, privateUnknownFiles: Int = 0) {
        allocatedBytes = max(0, allocated)
        self.privateBytes = max(0, privateBytes)
        fileCount = files
        self.unknownFiles = unknownFiles
        self.privateUnknownFiles = privateUnknownFiles
    }
}

enum RecoveryMetadata {
    enum State { case ordinary, purgeable, unknown }

    // One bulk metadata stream per directory; no URL/resourceValues call per ordinary file.
    static func directory(_ path: String, buffer: inout [UInt8], token: ScanToken) throws -> [UInt64: State]? {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_FILEID)
        attributes.forkattr = UInt32(ATTR_CMNEXT_EXT_FLAGS)
        var states: [UInt64: State] = [:]
        while true {
            if token.isCancelled { throw ScanError.cancelled }
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(fd, &attributes, $0.baseAddress!, $0.count,
                                UInt64(FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS))
            }
            guard count >= 0 else { return nil }
            if count == 0 { return states }
            let valid = buffer.withUnsafeBytes { bytes -> Bool in
                // FSOPT_PACK_INVAL_ATTRS keeps this 4-byte-aligned layout fixed:
                // length, returned attributes, entry error, name reference, inode, extended flags.
                var offset = 0
                for _ in 0..<count {
                    guard offset + 52 <= bytes.count else { return false }
                    let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    guard length >= 52, length <= bytes.count - offset else { return false }
                    let returned = bytes.loadUnaligned(fromByteOffset: offset + 4, as: attribute_set_t.self)
                    let error = bytes.loadUnaligned(fromByteOffset: offset + 24, as: UInt32.self)
                    let inode = bytes.loadUnaligned(fromByteOffset: offset + 36, as: UInt64.self)
                    let flags = bytes.loadUnaligned(fromByteOffset: offset + 44, as: UInt64.self)
                    if returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 {
                        states[inode] = error == 0 && returned.forkattr & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0
                            ? (flags & UInt64(EF_IS_PURGEABLE) != 0 ? .purgeable : .ordinary) : .unknown
                    }
                    offset += length
                }
                return true
            }
            guard valid else { return nil }
        }
    }

    // Query potentially expensive private extents only for confirmed purgeable files.
    static func privateBytes(_ path: UnsafePointer<CChar>, inode: UInt64) -> Int64? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_FILEID)
        attributes.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_EXT_FLAGS)
        var buffer = [UInt8](repeating: 0, count: 48)
        let result = buffer.withUnsafeMutableBytes {
            getattrlist(path, &attributes, $0.baseAddress!, $0.count,
                        UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS))
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            let returned = bytes.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0,
                  returned.forkattr & attributes.forkattr == attributes.forkattr,
                  bytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self) == inode,
                  bytes.loadUnaligned(fromByteOffset: 40, as: UInt64.self) & UInt64(EF_IS_PURGEABLE) != 0 else { return nil }
            return max(0, bytes.loadUnaligned(fromByteOffset: 32, as: Int64.self))
        }
    }
}

// Published only after construction; unchanged subtrees are shared across snapshots.
final class FileNode: @unchecked Sendable {
    let name: String
    let isDirectory: Bool
    let isLink: Bool
    let isVolumeBoundary: Bool
    let children: [FileNode]
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let recovery: FileRecovery
    let fileCount: Int
    let folderCount: Int
    let unreadableCount: Int
    let ownError: Int32
    let excludedVolumeCount: Int
    let isPendingScan: Bool
    let pendingFolderCount: Int

    init(name: String, isDirectory: Bool = false, isLink: Bool = false,
         logical: Int64 = 0, allocated: Int64 = 0, children: [FileNode] = [], error: Int32 = 0,
         isVolumeBoundary: Bool = false, isPendingScan: Bool = false, recovery: FileRecovery = .none) {
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.isVolumeBoundary = isVolumeBoundary
        self.isPendingScan = isPendingScan
        self.ownError = error
        self.children = children.sorted {
            $0.logicalBytes == $1.logicalBytes ? $0.name < $1.name : $0.logicalBytes > $1.logicalBytes
        }
        logicalBytes = children.reduce(max(0, logical)) { $0 + $1.logicalBytes }
        allocatedBytes = children.reduce(max(0, allocated)) { $0 + $1.allocatedBytes }
        fileCount = children.reduce(isDirectory ? 0 : 1) { $0 + $1.fileCount }
        folderCount = children.reduce(isDirectory ? 1 : 0) { $0 + $1.folderCount }
        unreadableCount = children.reduce(error == 0 ? 0 : 1) { $0 + $1.unreadableCount }
        excludedVolumeCount = children.reduce(isVolumeBoundary ? 1 : 0) { $0 + $1.excludedVolumeCount }
        pendingFolderCount = children.reduce(isPendingScan ? 1 : 0) { $0 + $1.pendingFolderCount }
        if children.isEmpty { self.recovery = recovery }
        else {
            var allocated = recovery.allocatedBytes, privateBytes = recovery.privateBytes
            var files = recovery.fileCount, unknown = recovery.unknownFiles, privateUnknown = recovery.privateUnknownFiles
            for child in children {
                allocated += child.recovery.allocatedBytes
                privateBytes += child.recovery.privateBytes
                files += child.recovery.fileCount
                unknown += child.recovery.unknownFiles
                privateUnknown += child.recovery.privateUnknownFiles
            }
            self.recovery = files == 0 && unknown == 0 ? .none
                : FileRecovery(allocated: allocated, privateBytes: privateBytes, files: files,
                               unknownFiles: unknown, privateUnknownFiles: privateUnknown)
        }
    }

    func bytes(_ metric: SizeMetric) -> Int64 {
        switch metric {
        case .logical: return logicalBytes
        case .allocated: return allocatedBytes
        case .purgeable: return recovery.allocatedBytes
        }
    }

    func node(at components: ArraySlice<String>) -> FileNode? {
        var node = self
        for name in components {
            guard let child = node.children.first(where: { $0.name == name }) else { return nil }
            node = child
        }
        return node
    }

    func replacing(_ components: ArraySlice<String>, with replacement: FileNode) -> FileNode {
        guard let first = components.first else { return replacement }
        let rest = components.dropFirst()
        return FileNode(name: name, isDirectory: isDirectory, children: children.map {
            $0.name == first ? $0.replacing(rest, with: replacement) : $0
        }, error: ownError, isVolumeBoundary: isVolumeBoundary, isPendingScan: isPendingScan)
    }
}

final class ScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum ScanError: LocalizedError {
    case cancelled
    case filesystem(String, Int32)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "스캔이 취소되었습니다."
        case let .filesystem(path, code): return "\(path): \(String(cString: strerror(code)))"
        }
    }
}

struct ScanResult {
    let root: FileNode
    let visited: Int
    let seconds: Double
}

enum FileScanner {
    private static let log = OSLog(subsystem: "local.spacetree", category: "Scanner")
    static func canonicalURL(_ url: URL) -> URL {
        // Foundation can shorten /private/var to /var; FSEvents always reports the real pathname.
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
    private struct Frame {
        let name: String
        let level: Int
        let isVolumeBoundary: Bool
        let isPendingScan: Bool
        var recoveryCandidates: [(index: Int, inode: UInt64, links: nlink_t)] = []
        var children: [FileNode] = []
    }

    // A bounded pool owns independent fts streams; only completed immutable nodes cross workers.
    private final class ScanBatch: @unchecked Sendable {
        private var jobs: [(URL, String)]
        private let root: FileNode
        private let url: URL
        private let workers: Int
        private let partialInterval: UInt64
        private let condition = NSCondition()
        private var next = 0
        private var remaining: Int
        private var aborted = false
        private var nodes: [String: FileNode] = [:]
        private var branches = Set<String>()
        private var visited: Int
        private var active: [String: Int] = [:]
        private var lastProgress = DispatchTime.now().uptimeNanoseconds
        private var lastPartial: UInt64 = 0
        init(root: FileNode, url: URL, jobs: [(URL, String)], visited: Int, workers: Int, partialInterval: UInt64) {
            self.root = root
            self.url = url
            self.workers = workers
            self.partialInterval = partialInterval
            self.jobs = jobs
            remaining = jobs.count
            self.visited = visited
        }
        var needsWork: Bool {
            condition.lock(); defer { condition.unlock() }
            return !aborted && remaining < workers
        }
        func take() -> (URL, String)? {
            condition.lock(); defer { condition.unlock() }
            while next == jobs.count && remaining > 0 && !aborted { condition.wait() }
            guard !aborted, next < jobs.count else { return nil }
            let job = jobs[next]
            next += 1
            // Keep only the waiting frontier, rather than every URL visited during a volume scan.
            if next >= 1024 { jobs.removeFirst(next); next = 0 }
            return job
        }
        func enqueue(_ child: URL, name: String) {
            condition.lock(); defer { condition.unlock() }
            guard !aborted else { return }
            jobs.append((child, name))
            remaining += 1
            var path = url.path
            for component in ChangeBatch.relativeComponents(child.path, root: path).dropLast() {
                path = path == "/" ? path + component : path + "/" + component
                branches.insert(path)
            }
            condition.broadcast()
        }
        func abort() {
            condition.lock(); aborted = true; condition.broadcast(); condition.unlock()
        }
        func finish(path: String, node: FileNode, count: Int,
                    partial: ((FileNode) -> Void)?, progress: ((Int) -> Void)?) {
            condition.lock()
            nodes[path] = node
            active.removeValue(forKey: path)
            visited += max(0, count - 1) // The shallow pass already counted this directory.
            remaining -= 1
            condition.broadcast()
            let now = DispatchTime.now().uptimeNanoseconds
            let report = now - lastProgress > 150_000_000 ? visited + active.values.reduce(0, +) : nil
            if report != nil { lastProgress = now }
            publish(partial, force: remaining == 0)
            condition.unlock()
            if let report { progress?(report) }
        }
        func update(path: String, count: Int, node: FileNode? = nil,
                    partial: ((FileNode) -> Void)? = nil, progress: ((Int) -> Void)? = nil) {
            condition.lock()
            active[path] = max(0, count - 1)
            if let node { nodes[path] = node }
            let now = DispatchTime.now().uptimeNanoseconds
            let report = now - lastProgress > 150_000_000 ? visited + active.values.reduce(0, +) : nil
            if report != nil { lastProgress = now }
            if node != nil { publish(partial) }
            condition.unlock()
            if let report { progress?(report) }
        }
        private func publish(_ callback: ((FileNode) -> Void)?, force: Bool = false) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard let callback, force || now - lastPartial >= partialInterval else { return }
            lastPartial = now
            // Serialize delivery separately from progress; progress must not starve tree updates.
            callback(mergedRoot())
        }
        func result() -> (FileNode, Int) {
            condition.lock(); defer { condition.unlock() }
            return (mergedRoot(), visited)
        }
        private func mergedRoot() -> FileNode {
            func merge(_ node: FileNode, at path: String, isRoot: Bool = false) -> FileNode {
                guard isRoot || branches.contains(path) else { return node }
                let children = node.children.map { child -> FileNode in
                    guard child.isDirectory else { return child }
                    let childPath = path == "/" ? path + child.name : path + "/" + child.name
                    return merge(nodes[childPath] ?? child, at: childPath)
                }
                return FileNode(name: node.name, isDirectory: node.isDirectory, children: children,
                                error: node.ownError, isVolumeBoundary: node.isVolumeBoundary, isPendingScan: node.isPendingScan)
            }
            return merge(root, at: url.path, isRoot: true)
        }
    }

    static func scan(_ url: URL, token: ScanToken = ScanToken(),
                     parallelism: Int = 4,
                     partialInterval: TimeInterval = 0.5,
                     partial: ((FileNode) -> Void)? = nil,
                     progress: ((Int) -> Void)? = nil) throws -> ScanResult {
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Scan", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "Scan", signpostID: signpost) }
        let start = DispatchTime.now().uptimeNanoseconds
        let interval = UInt64(max(0, partialInterval) * 1e9)
        let (shallow, jobs) = try walk(url, token: token, splitChildren: parallelism > 1,
                                      partialInterval: interval,
                                      partial: partial.map { callback in { node, _ in callback(node) } }, progress: progress)
        partial?(shallow.root)
        guard !jobs.isEmpty else { return shallow }
        let workers = min(4, max(1, parallelism))
        let batch = ScanBatch(root: shallow.root, url: url, jobs: jobs, visited: shallow.visited,
                              workers: workers, partialInterval: interval)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while let (childURL, name) = batch.take() {
                if token.isCancelled { batch.abort(); break }
                do {
                    // A queued parent may have been replaced by a link after the shallow pass.
                    var ancestor = url.path
                    for component in ChangeBatch.relativeComponents(childURL.path, root: url.path) {
                        ancestor = ancestor == "/" ? ancestor + component : ancestor + "/" + component
                        var metadata = stat()
                        guard lstat(ancestor, &metadata) == 0 else { throw ScanError.filesystem(ancestor, errno) }
                        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw ScanError.filesystem(ancestor, ENOTDIR) }
                    }
                    let (scan, _) = try walk(childURL, token: token, splitChildren: false,
                        shouldHandOff: { batch.needsWork }, handOff: batch.enqueue, partialInterval: interval,
                        partial: partial.map { callback in { node, count in
                            batch.update(path: childURL.path, count: count, node: node, partial: callback)
                        } }) { count in
                        batch.update(path: childURL.path, count: count, progress: progress)
                    }
                    batch.finish(path: childURL.path, node: scan.root, count: scan.visited,
                                 partial: partial, progress: progress)
                } catch ScanError.cancelled { batch.abort(); break }
                catch {
                    let code: Int32
                    if case let ScanError.filesystem(_, value) = error { code = value } else { code = EIO }
                    batch.finish(path: childURL.path, node: FileNode(name: name, isDirectory: true, error: code),
                                 count: 1, partial: partial, progress: progress)
                }
            }
        }
        if token.isCancelled { throw ScanError.cancelled }
        let (root, visited) = batch.result()
        partial?(root)
        return ScanResult(root: root, visited: visited,
                          seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    private static func walk(_ url: URL, token: ScanToken, splitChildren: Bool,
                             shouldHandOff: (() -> Bool)? = nil, handOff: ((URL, String) -> Void)? = nil,
                             partialInterval: UInt64,
                             partial: ((FileNode, Int) -> Void)? = nil,
                             progress: ((Int) -> Void)? = nil) throws -> (ScanResult, [(URL, String)]) {
        let start = DispatchTime.now().uptimeNanoseconds
        var rootStat = stat()
        guard lstat(url.path, &rootStat) == 0 else { throw ScanError.filesystem(url.path, errno) }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else { throw ScanError.filesystem(url.path, ENOTDIR) }
        guard let path = strdup(url.path) else { throw ScanError.filesystem(url.path, ENOMEM) }
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let stream = paths.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { throw ScanError.filesystem(url.path, errno) }
        defer { fts_close(stream) }

        var frames: [Frame] = []
        var root: FileNode?
        var jobs: [(URL, String)] = []
        var visited = 0
        var lastProgress = start
        var lastPartial = start
        var recoveryBuffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            // errno must be reset just before fts_read, not before other Swift/runtime work.
            errno = 0
            guard let entry = fts_read(stream) else {
                if errno != 0 { throw ScanError.filesystem(url.path, errno) }
                break
            }
            if visited & 127 == 0, token.isCancelled { throw ScanError.cancelled }
            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            let name = withUnsafePointer(to: &entry.pointee.fts_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            var finished: FileNode?
            switch info {
            case FTS_D:
                let boundary = entry.pointee.fts_statp?.pointee.st_dev != rootStat.st_dev
                let pending = !boundary && level > 0 && (splitChildren && level == 1 || shouldHandOff?() == true)
                frames.append(Frame(name: name, level: level, isVolumeBoundary: boundary,
                                    isPendingScan: pending))
                if pending { fts_set(stream, entry, FTS_SKIP) }
                visited += 1
            case FTS_DP:
                guard var frame = frames.popLast() else { continue }
                // Wait for fts to finish its own traversal. Only folders with regular files
                // need recovery metadata; ordinary immutable file nodes can be reused.
                if !frame.recoveryCandidates.isEmpty {
                    let path = String(cString: entry.pointee.fts_path)
                    let states = try RecoveryMetadata.directory(path, buffer: &recoveryBuffer, token: token)
                    for candidate in frame.recoveryCandidates {
                        let child = frame.children[candidate.index]
                        let recovery: FileRecovery
                        switch states?[candidate.inode] ?? .unknown {
                        case .ordinary: continue
                        case .unknown: recovery = .unknown
                        case .purgeable:
                            let childPath = path == "/" ? path + child.name : path + "/" + child.name
                            // Surviving hard links keep the inode's blocks allocated.
                            let privateBytes = candidate.links > 1 ? 0 : childPath.withCString {
                                RecoveryMetadata.privateBytes($0, inode: candidate.inode)
                            }
                            recovery = FileRecovery(allocated: child.allocatedBytes,
                                privateBytes: min(child.allocatedBytes, privateBytes ?? 0), files: 1,
                                privateUnknownFiles: privateBytes == nil ? 1 : 0)
                        }
                        frame.children[candidate.index] = FileNode(name: child.name, logical: child.logicalBytes,
                                                                  allocated: child.allocatedBytes, recovery: recovery)
                    }
                }
                finished = FileNode(name: frame.name, isDirectory: true, children: frame.children,
                                    isVolumeBoundary: frame.isVolumeBoundary,
                                    isPendingScan: frame.isPendingScan)
                if frame.isPendingScan {
                    let child = URL(fileURLWithPath: String(cString: entry.pointee.fts_path))
                    if let handOff { handOff(child, frame.name) }
                    else { jobs.append((child, frame.name)) }
                }
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_DC:
                let frame = frames.last?.level == level ? frames.removeLast() : nil
                if level == 0 { throw ScanError.filesystem(url.path, entry.pointee.fts_errno == 0 ? EACCES : entry.pointee.fts_errno) }
                finished = FileNode(name: name, isDirectory: info == FTS_DNR || frame != nil,
                                    children: frame?.children ?? [], error: entry.pointee.fts_errno == 0 ? EIO : entry.pointee.fts_errno)
                visited += frame == nil ? 1 : 0
            default:
                let metadata = entry.pointee.fts_statp?.pointee
                let allocated = Int64(metadata?.st_blocks ?? 0) * 512
                if let metadata, metadata.st_mode & S_IFMT == S_IFREG, !frames.isEmpty {
                    let index = frames.count - 1
                    frames[index].recoveryCandidates.append((frames[index].children.count, UInt64(metadata.st_ino), metadata.st_nlink))
                }
                finished = FileNode(name: name, isLink: info == FTS_SL || info == FTS_SLNONE,
                                    logical: Int64(metadata?.st_size ?? 0),
                                    allocated: allocated)
                visited += 1
            }
            if let node = finished {
                if frames.isEmpty { root = node } else { frames[frames.count - 1].children.append(node) }
            }
            if visited & 4095 == 0 {
                let now = DispatchTime.now().uptimeNanoseconds
                if let partial, now - lastPartial >= partialInterval, !frames.isEmpty {
                    // Share completed subtrees; copy only the open ancestor chain twice per second.
                    var snapshot: FileNode?
                    for frame in frames.reversed() {
                        var children = frame.children
                        if let snapshot { children.append(snapshot) }
                        snapshot = FileNode(name: frame.name, isDirectory: true, children: children,
                                            isVolumeBoundary: frame.isVolumeBoundary, isPendingScan: true)
                    }
                    if let snapshot { partial(snapshot, visited) }
                    lastPartial = now
                }
                if now - lastProgress > 150_000_000 { progress?(visited); lastProgress = now }
            }
        }
        if token.isCancelled { throw ScanError.cancelled }
        guard let root else { throw ScanError.filesystem(url.path, EIO) }
        return (ScanResult(root: root, visited: visited,
                          seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9), jobs)
    }

    static func refresh(_ root: FileNode, at url: URL, paths: Set<String>, token: ScanToken) throws -> ScanResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let roots = ChangeBatch.minimalDirectories(paths, root: url.path, snapshot: root)
        var updated = root
        var visited = 0
        for path in roots {
            if token.isCancelled { throw ScanError.cancelled }
            let components = ChangeBatch.relativeComponents(path, root: url.path)
            let subtree: ScanResult
            do { subtree = try scan(URL(fileURLWithPath: path), token: token) }
            catch let error as ScanError {
                // A known protected folder must not block unrelated changes in a whole-volume batch.
                if case let .filesystem(_, code) = error, code == EACCES || code == EPERM,
                   let previous = root.node(at: components[...]),
                   previous.ownError == EACCES || previous.ownError == EPERM { continue }
                throw error
            }
            updated = updated.replacing(components[...], with: subtree.root)
            visited += subtree.visited
        }
        return ScanResult(root: updated, visited: visited,
                          seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }
}

enum ChangeBatch {
    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func relativeComponents(_ path: String, root: String) -> [String] {
        guard path != root else { return [] }
        return String(path.dropFirst(root == "/" ? 1 : root.count + 1)).split(separator: "/").map(String.init)
    }

    static func minimalDirectories(_ paths: Set<String>, root: String, snapshot: FileNode) -> [String] {
        var candidates = Set<String>()
        for original in paths where isInside(original, root: root) {
            var path = root
            var directory = root
            var node = snapshot
            // Check every ancestor: lstat(deep) alone follows a replaced parent's symlink.
            for component in relativeComponents(original, root: root) {
                path = path == "/" ? path + component : path + "/" + component
                var metadata = stat()
                guard let child = node.children.first(where: { $0.name == component }), child.isDirectory, !child.isVolumeBoundary,
                      lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { break }
                node = child
                directory = path
            }
            candidates.insert(directory)
        }
        var accepted: [String] = []
        for path in candidates.sorted() {
            if !accepted.contains(where: { isInside(path, root: $0) }) { accepted.append(path) }
        }
        return accepted
    }
}

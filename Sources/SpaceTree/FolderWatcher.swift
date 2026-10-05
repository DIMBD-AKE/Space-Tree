import Foundation
import CoreServices

struct FileChange {
    let path: String
    let flags: FSEventStreamEventFlags
    var requiresFullScan: Bool {
        let mask = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        return flags & UInt32(mask) != 0
    }
}

// All lifecycle operations and callbacks run on the main queue.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    let onChange: ([FileChange]) -> Void
    private let rootPath: String

    init(url: URL, onChange: @escaping ([FileChange]) -> Void) throws {
        self.onChange = onChange
        rootPath = url.path
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        // Directory events avoid a per-file event flood; each reported subtree is rescanned.
        guard let created = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, _ in
            guard let context else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(context).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            watcher.onChange((0..<count).map {
                var path = paths[$0]
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                // Startup Data events use firmlink paths (/Users, /private), even when watching its mount point.
                let data = "/System/Volumes/Data"
                if ChangeBatch.isInside(watcher.rootPath, root: data), !ChangeBatch.isInside(path, root: watcher.rootPath) {
                    let alias = String(watcher.rootPath.dropFirst(data.count))
                    if ChangeBatch.isInside(path, root: alias.isEmpty ? "/" : alias) { path = data + path }
                }
                return FileChange(path: path, flags: flags[$0])
            })
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.25, FSEventStreamCreateFlags(flags)) else { throw ScanError.filesystem(url.path, EIO) }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        if !FSEventStreamStart(created) { stop(); throw ScanError.filesystem(url.path, EIO) }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}

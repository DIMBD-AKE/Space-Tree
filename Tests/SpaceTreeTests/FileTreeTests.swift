import XCTest
import Combine
import SwiftUI
@testable import SpaceTree

final class FileTreeTests: XCTestCase {
    func testRecoveryAggregationAndDiskEstimates() {
        let marked = FileNode(name: "cache", allocated: 4096,
                              recovery: FileRecovery(allocated: 4096, privateBytes: 2048, files: 1))
        let unknown = FileNode(name: "unknown", recovery: .unknown)
        let nested = FileNode(name: "nested", isDirectory: true, children: [marked, unknown])
        let root = FileNode(name: "root", isDirectory: true, children: [nested])
        XCTAssertEqual(root.bytes(.purgeable), 4096)
        XCTAssertEqual(root.recovery.privateBytes, 2048)
        XCTAssertEqual(root.recovery.fileCount, 1)
        XCTAssertEqual(root.recovery.unknownFiles, 1)
        let replaced = root.replacing(["nested"][...], with: FileNode(name: "nested", isDirectory: true))
        XCTAssertEqual(replaced.recovery.fileCount, 0)
        XCTAssertEqual(replaced.recovery.unknownFiles, 0)
        let disk = DiskSpace(total: 500, available: 70, importantAvailable: 240)
        XCTAssertEqual(disk.used, 430)
        XCTAssertEqual(disk.reclaimableEstimate, 170)
        XCTAssertEqual(disk.estimatedUsed, 260)
        XCTAssertNil(DiskSpace(total: 500, available: 70).estimatedUsed)
        XCTAssertNil(DiskSpace(total: 500, available: 70, importantAvailable: -1).estimatedUsed)
        XCTAssertEqual(DiskSpace(total: 500, available: 70, importantAvailable: 20).reclaimableEstimate, 0)
        XCTAssertEqual(DiskSpace(total: 500, available: 70, importantAvailable: 600).estimatedUsed, 0)
    }

    @MainActor
    func testNativePurgeableFilesNavigationAndLiveRefresh() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("spacetree-recovery-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("nested")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let cache = folder.appendingPathComponent("cache")
        try Data(repeating: 0x53, count: 65_536).write(to: cache)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("ordinary"))
        func mark(_ verb: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util")
            process.arguments = ["-m", verb, cache.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("Cannot mark the owned temporary fixture purgeable") }
        }
        try mark("-low")
        XCTAssertEqual(try cache.resourceValues(forKeys: [.isPurgeableKey]).isPurgeable, true)
        let serial = try FileScanner.scan(root, parallelism: 1).root
        let parallel = try FileScanner.scan(root).root
        XCTAssertEqual(serial.recovery.fileCount, 1)
        XCTAssertEqual(serial.recovery.unknownFiles, 0)
        XCTAssertEqual(serial.recovery.allocatedBytes, serial.node(at: ["nested", "cache"][...])!.allocatedBytes)
        XCTAssertGreaterThan(serial.recovery.allocatedBytes, 0)
        XCTAssertEqual(parallel.recovery.allocatedBytes, serial.recovery.allocatedBytes)
        XCTAssertEqual(parallel.recovery.privateBytes, serial.recovery.privateBytes)
        XCTAssertEqual(parallel.recovery.privateUnknownFiles, 0)
        XCTAssertGreaterThan(serial.recovery.privateBytes, 0)

        // Hard links are visible paths, but deleting one cannot release the inode's blocks.
        try fm.linkItem(at: cache, to: root.appendingPathComponent("alias"))
        let linked = try FileScanner.scan(root).root
        XCTAssertEqual(linked.recovery.fileCount, 2)
        XCTAssertEqual(linked.recovery.privateBytes, 0)

        let model = BrowserModel()
        defer { model.shutdown() }
        model.open(root)
        try await eventually { model.root?.recovery.fileCount == 2 && !model.isScanning }
        model.metric = .purgeable
        try await eventually { Set(model.rows.map(\.name)) == ["nested", "alias"] }
        if let snapshotPath = ProcessInfo.processInfo.environment["SPACETREE_UI_SNAPSHOT"] {
            // Render a test-owned view offscreen; no interaction with the user's app/window.
            _ = NSApplication.shared
            let view = NSHostingView(rootView: BrowserView(model: model).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: snapshotPath))
            window.close()
        }
        model.enter(model.rows.first { $0.name == "nested" }!)
        try await eventually { model.rows.map(\.name) == ["cache"] }
        try mark("-clear")
        try await eventually { model.root?.recovery.fileCount == 0 && !model.isScanning }
        try await eventually { model.rows.isEmpty }
        XCTAssertEqual(model.components, ["nested"])
    }

    func testRefreshContinuesPastPreviouslyUnreadableDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let denied = root.appendingPathComponent("a-denied")
        let readable = root.appendingPathComponent("b-readable")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        try fm.createDirectory(at: readable, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
            try? fm.removeItem(at: root)
        }
        try Data([1]).write(to: readable.appendingPathComponent("file"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let before = try FileScanner.scan(root).root
        XCTAssertEqual(before.unreadableCount, 1)
        try Data([1, 2, 3]).write(to: readable.appendingPathComponent("file"))
        let after = try FileScanner.refresh(before, at: root, paths: [denied.path, readable.path], token: ScanToken())
        XCTAssertEqual(after.root.logicalBytes, 3)
        XCTAssertEqual(after.root.unreadableCount, 1)
        // Permissions becoming available must also be picked up on the next change.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        try Data([4, 5]).write(to: denied.appendingPathComponent("new"))
        let recovered = try FileScanner.refresh(after.root, at: root, paths: [denied.path], token: ScanToken())
        XCTAssertEqual(recovered.root.logicalBytes, 5)
        XCTAssertEqual(recovered.root.unreadableCount, 0)
    }

    @MainActor
    func testDataVolumeWatcherReportsPathsInsideRoot() async throws {
        let fm = FileManager.default
        let folder = FileScanner.canonicalURL(fm.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let volume = URL(fileURLWithPath: "/System/Volumes/Data")
        var events: [FileChange] = []
        let watcher = try FolderWatcher(url: volume) { changes in
            events.append(contentsOf: changes.filter { $0.path.contains(folder.lastPathComponent) })
        }
        defer { watcher.stop() }
        try Data([1]).write(to: folder.appendingPathComponent("file"))
        try await eventually { !events.isEmpty }
        XCTAssertTrue(events.allSatisfy { ChangeBatch.isInside($0.path, root: volume.path) },
                      "Data volume events must match its root: \(events.map(\.path))")
    }

    func testMountedVolumesAreExcludedFromParentScan() throws {
        let parent = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw XCTSkip("Requires installed simulator volumes")
        }
        let result = try FileScanner.scan(parent)
        let boundaries = result.root.children.filter { $0.isVolumeBoundary }
        guard !boundaries.isEmpty else { throw XCTSkip("No mounted simulator volumes") }
        XCTAssertTrue(boundaries.allSatisfy { $0.children.isEmpty })
        XCTAssertGreaterThan(result.root.excludedVolumeCount, 0)
    }

    func testParallelScanMatchesSerialAndCancels() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for index in 0..<12 {
            let folder = root.appendingPathComponent("폴더-\(index)/nested")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: index + 1).write(to: folder.appendingPathComponent("file"))
        }
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: root.path)
        let denied = root.appendingPathComponent("denied")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let serial = try FileScanner.scan(root, parallelism: 1)
        let snapshotLock = NSLock()
        var partialSnapshots: [FileNode] = []
        let parallel = try FileScanner.scan(root, parallelism: 4, partial: { snapshot in
            snapshotLock.lock(); partialSnapshots.append(snapshot); snapshotLock.unlock()
        })
        XCTAssertGreaterThan(partialSnapshots.first?.pendingFolderCount ?? 0, 0)
        XCTAssertEqual(partialSnapshots.last?.pendingFolderCount, 0)
        XCTAssertEqual(partialSnapshots.last?.logicalBytes, serial.root.logicalBytes)
        XCTAssertEqual(parallel.root.logicalBytes, serial.root.logicalBytes)
        XCTAssertEqual(parallel.root.allocatedBytes, serial.root.allocatedBytes)
        XCTAssertEqual(parallel.root.fileCount, serial.root.fileCount)
        XCTAssertEqual(parallel.root.folderCount, serial.root.folderCount)
        XCTAssertEqual(parallel.root.unreadableCount, serial.root.unreadableCount)
        XCTAssertEqual(parallel.visited, serial.visited)
        XCTAssertEqual(parallel.root.children.map(\.name), serial.root.children.map(\.name))
        let token = ScanToken()
        token.cancel()
        XCTAssertThrowsError(try FileScanner.scan(root, token: token, parallelism: 4))
        let during = ScanToken()
        XCTAssertThrowsError(try FileScanner.scan(root, token: during, partial: { snapshot in
            if snapshot.pendingFolderCount > 0 { during.cancel() }
        }))
    }

    func testDeepScanPublishesBytesBeforeFolderCompletes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Users/person/Desktop/projects/deep")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for index in 0..<20_000 {
            let path = folder.appendingPathComponent("file-\(index)").path
            let fd = Darwin.open(path, O_CREAT | O_WRONLY, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(ftruncate(fd, 1024), 0)
            Darwin.close(fd)
        }
        let token = ScanToken()
        let lock = NSLock()
        var streamed = false
        XCTAssertThrowsError(try FileScanner.scan(root, token: token, partialInterval: 0, partial: { snapshot in
            if snapshot.fileCount > 0 && snapshot.pendingFolderCount > 0 {
                lock.lock(); streamed = true; lock.unlock()
                token.cancel()
            }
        })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        XCTAssertTrue(streamed, "A deep folder must publish growing totals while it is still being read")
    }

    @MainActor
    func testFullRescansKeepCurrentTreeUntilCompletion() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("a/deep/file"))
        let previousFolder = UserDefaults.standard.object(forKey: "lastFolder")
        let model = BrowserModel()
        defer {
            model.shutdown()
            try? fm.removeItem(at: folder)
            if let previousFolder { UserDefaults.standard.set(previousFolder, forKey: "lastFolder") }
            else { UserDefaults.standard.removeObject(forKey: "lastFolder") }
        }
        var snapshots: [FileNode] = []
        let subscription = model.$root.sink { node in
            if let node { snapshots.append(node) }
        }
        defer { subscription.cancel() }
        model.open(folder)
        try await eventually { model.root?.logicalBytes == 3 && !model.isScanning }
        XCTAssertTrue(snapshots.contains { $0.pendingFolderCount > 0 }, "Initial scans still stream partial results")
        model.enter(model.root!.children[0])
        model.enter(model.currentNode!.children[0])
        model.selectedName = "file"
        model.query = "file"
        try await eventually { model.rows.map(\.name) == ["file"] }

        // Exercise manual reload, event overflow, and dropped daemon events with the same deep folder open.
        for mode in 0..<3 {
            model.cancelScan() // Isolate injected batches from real FSEvents.
            snapshots.removeAll()
            let previous = model.root
            let updatedAt = model.updatedAt
            let size = 5 + mode
            try Data(repeating: 1, count: size).write(to: folder.appendingPathComponent("a/deep/file"))
            var sawScan = false
            let scanning = model.$isScanning.dropFirst().sink { active in
                if active {
                    sawScan = true
                    XCTAssertTrue(model.root === previous)
                    XCTAssertEqual(model.currentNode?.logicalBytes, previous?.logicalBytes)
                    XCTAssertEqual(model.rows.map(\.name), ["file"])
                }
            }
            defer { scanning.cancel() }
            switch mode {
            case 0: model.reload()
            case 1: model.receive((0..<4097).map {
                FileChange(path: model.rootURL!.appendingPathComponent("changed-\($0)").path, flags: 0)
            })
            default: model.receive([FileChange(path: model.rootURL!.path,
                flags: UInt32(kFSEventStreamEventFlagKernelDropped))])
            }
            try await eventually { model.updatedAt != updatedAt && !model.isScanning }
            XCTAssertTrue(sawScan)
            XCTAssertEqual(snapshots.count, 1, "Existing results must only be replaced by the completed tree")
            XCTAssertTrue(snapshots.allSatisfy { $0.pendingFolderCount == 0 && $0.node(at: ["a", "deep"][...]) != nil })
            XCTAssertEqual(model.currentNode?.logicalBytes, Int64(size))
            XCTAssertEqual(model.components, ["a", "deep"])
            XCTAssertEqual(model.selectedName, "file")
            XCTAssertEqual(model.query, "file")
            try await eventually { model.rows.first?.logicalBytes == Int64(size) }
        }
    }

    @MainActor
    func testAccessSetupIsShownOnceBeforeScanning() async throws {
        let defaults = UserDefaults.standard
        let previousSeen = defaults.object(forKey: "accessSetupSeen")
        let previousFolder = defaults.object(forKey: "lastFolder")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = BrowserModel()
        defer {
            model.shutdown()
            try? FileManager.default.removeItem(at: folder)
            if let previousSeen { defaults.set(previousSeen, forKey: "accessSetupSeen") }
            else { defaults.removeObject(forKey: "accessSetupSeen") }
            if let previousFolder { defaults.set(previousFolder, forKey: "lastFolder") }
            else { defaults.removeObject(forKey: "lastFolder") }
        }
        defaults.set(false, forKey: "accessSetupSeen")
        model.prepareToOpen(folder)
        XCTAssertTrue(model.showsAccessSetup)
        XCTAssertNil(model.rootURL)
        XCTAssertFalse(model.isScanning)
        defaults.set(true, forKey: "accessSetupSeen")
        model.showsAccessSetup = false
        model.prepareToOpen(folder)
        try await eventually { model.root != nil && !model.isScanning }
        XCTAssertFalse(model.showsAccessSetup)
    }

    func testRefreshDoesNotFollowReplacedAncestorSymlink() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("root")
        let outside = parent.appendingPathComponent("outside")
        try fm.createDirectory(at: root.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside.appendingPathComponent("deep"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        try Data([1]).write(to: root.appendingPathComponent("a/deep/inside"))
        try Data(repeating: 1, count: 500).write(to: outside.appendingPathComponent("deep/outside"))
        let snapshot = try FileScanner.scan(root).root
        try fm.removeItem(at: root.appendingPathComponent("a"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("a").path, withDestinationPath: outside.path)
        let refreshed = try FileScanner.refresh(snapshot, at: root,
            paths: [root.appendingPathComponent("a/deep").path], token: ScanToken())
        XCTAssertTrue(refreshed.root.node(at: ["a"][...])!.isLink)
        XCTAssertNil(refreshed.root.node(at: ["a", "deep"][...]))
        XCTAssertEqual(refreshed.root.logicalBytes, Int64(outside.path.utf8.count))
    }

    @MainActor
    func testFailedRefreshRetriesOnNextExternalChange() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: a.path); try? fm.removeItem(at: root) }
        try Data(repeating: 1, count: 10).write(to: a.appendingPathComponent("file"))
        try Data(repeating: 1, count: 3).write(to: b.appendingPathComponent("file"))
        let previousFolder = UserDefaults.standard.string(forKey: "lastFolder")
        let model = BrowserModel()
        defer {
            model.shutdown()
            if let previousFolder { UserDefaults.standard.set(previousFolder, forKey: "lastFolder") }
            else { UserDefaults.standard.removeObject(forKey: "lastFolder") }
        }
        model.open(root)
        try await eventually { model.root?.logicalBytes == 13 && !model.isScanning }
        model.cancelScan() // Stop live events so the two injected daemon batches have deterministic ordering.
        try fm.removeItem(at: a.appendingPathComponent("file"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        model.receive([FileChange(path: model.rootURL!.appendingPathComponent("a").path, flags: 0)])
        try await eventually { !model.isScanning && model.message?.contains("Permission denied") == true }
        XCTAssertEqual(model.root?.logicalBytes, 13)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: a.path)
        try Data(repeating: 1, count: 5).write(to: b.appendingPathComponent("file"))
        model.receive([FileChange(path: model.rootURL!.appendingPathComponent("b").path, flags: 0)])
        try await eventually { model.root?.logicalBytes == 5 && !model.isScanning }
        XCTAssertEqual(model.root?.unreadableCount, 0)
        let stale = FileNode(name: "nonexistent", isDirectory: true)
        model.enter(stale)
        XCTAssertTrue(model.components.isEmpty)
    }

    @MainActor
    func testTreemapAccessibility() {
        let canvas = TreemapCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let file = FileNode(name: "Accessible.txt", logical: 100)
        canvas.nodes = [file]
        var activated = false
        canvas.activate = { activated = $0 === file }
        canvas.needsLayout = true
        canvas.layoutSubtreeIfNeeded()
        let element = canvas.accessibilityChildren()?.first as? NSAccessibilityElement
        XCTAssertEqual(element?.accessibilityLabel(), "Accessible.txt, \(formatBytes(100))")
        XCTAssertEqual(element?.isAccessibilityEnabled(), true)
        XCTAssertEqual(element?.accessibilityPerformPress(), true)
        XCTAssertTrue(activated)
    }
    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for file changes", file: file, line: line)
        if !condition() { throw ScanError.filesystem("event timeout", ETIMEDOUT) }
    }

    @MainActor
    func testLiveUpdatesNavigationRootMoveAndSwitch() async throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("root")
        try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("a/file"))
        let previousFolder = UserDefaults.standard.string(forKey: "lastFolder")
        let model = BrowserModel()
        defer {
            model.shutdown()
            if let previousFolder { UserDefaults.standard.set(previousFolder, forKey: "lastFolder") }
            else { UserDefaults.standard.removeObject(forKey: "lastFolder") }
        }
        model.open(root)
        try await eventually { model.root?.logicalBytes == 3 && !model.isScanning }
        XCTAssertEqual(model.rootURL, FileScanner.canonicalURL(root))
        XCTAssertTrue(model.isWatching)
        model.enter(model.root!.children[0])
        XCTAssertEqual(model.components, ["a"])

        try Data(repeating: 7, count: 1024).write(to: root.appendingPathComponent("a/new"))
        try await eventually { model.currentNode?.fileCount == 2 && model.root?.logicalBytes == 1027 }
        try Data(repeating: 8, count: 2048).write(to: root.appendingPathComponent("a/new"))
        try await eventually { model.root?.logicalBytes == 2051 }
        try fm.moveItem(at: root.appendingPathComponent("a/new"), to: root.appendingPathComponent("a/renamed"))
        try await eventually { model.currentNode?.children.contains(where: { $0.name == "renamed" }) == true }
        try fm.removeItem(at: root.appendingPathComponent("a/renamed"))
        try await eventually { model.root?.logicalBytes == 3 && model.currentNode?.fileCount == 1 }

        try fm.moveItem(at: root.appendingPathComponent("a"), to: root.appendingPathComponent("b"))
        try await eventually { model.components.isEmpty && model.root?.children.first?.name == "b" }
        let moved = parent.appendingPathComponent("moved")
        try fm.moveItem(at: root, to: moved)
        try await eventually { model.rootURL?.lastPathComponent == "moved" && !model.isScanning }
        try Data([1, 2]).write(to: moved.appendingPathComponent("b/after-move"))
        try await eventually { model.root?.logicalBytes == 5 }

        let second = parent.appendingPathComponent("second")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 77).write(to: second.appendingPathComponent("only"))
        model.open(moved)
        model.open(second)
        try await eventually { model.root?.logicalBytes == 77 && !model.isScanning }
        XCTAssertEqual(model.root?.name, "second")
        model.cancelScan()
        XCTAssertFalse(model.isWatching)
        try Data([9]).write(to: second.appendingPathComponent("when-paused"))
        model.reload()
        try await eventually { model.root?.logicalBytes == 78 && !model.isScanning }
        XCTAssertTrue(model.isWatching)
        try fm.removeItem(at: second)
        try await eventually { model.message != nil && !model.isScanning }
        XCTAssertEqual(model.root?.logicalBytes, 78, "Last snapshot retained with explicit error")
    }

    func testSparseFilesHiddenPackagesAndPermissionErrors() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let denied = root.appendingPathComponent("denied")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Demo.app/Contents"), withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
            try? fm.removeItem(at: root)
        }
        try Data([1]).write(to: denied.appendingPathComponent("secret"))
        try Data([1, 2]).write(to: root.appendingPathComponent(".hidden"))
        try Data([3]).write(to: root.appendingPathComponent("Demo.app/Contents/file"))
        let sparse = root.appendingPathComponent("sparse")
        let fd = Darwin.open(sparse.path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 128 * 1024 * 1024), 0)
        Darwin.close(fd)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let scan = try FileScanner.scan(root)
        XCTAssertEqual(scan.root.logicalBytes, 128 * 1024 * 1024 + 3)
        XCTAssertEqual(scan.root.fileCount, 3)
        XCTAssertEqual(scan.root.unreadableCount, 1)
        XCTAssertTrue(scan.root.node(at: ["denied"][...])!.isDirectory)
        XCTAssertEqual(scan.root.node(at: ["sparse"][...])!.allocatedBytes, 0)
        XCTAssertNotNil(scan.root.node(at: ["Demo.app", "Contents", "file"][...]))
    }

    func testTreemapAreaAndDrawingBudget() {
        let nodes = (1...10_000).map { FileNode(name: "file\($0)", logical: Int64($0)) }
            .sorted { $0.logicalBytes > $1.logicalBytes }
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tiles = TreemapLayout.layout(nodes, metric: .logical, in: bounds)
        XCTAssertEqual(tiles.count, TreemapLayout.tileLimit)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, bounds.width * bounds.height, accuracy: 0.001)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.bytes }, nodes.reduce(0) { $0 + $1.logicalBytes })
        XCTAssertEqual(tiles.last!.groupedCount, nodes.count - TreemapLayout.tileLimit + 1)
        for tile in tiles {
            XCTAssertGreaterThan(tile.rect.width, 0)
            XCTAssertGreaterThan(tile.rect.height, 0)
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
        }
        XCTAssertTrue(TreemapLayout.layout([FileNode(name: "empty")], metric: .logical, in: bounds).isEmpty)
        XCTAssertTrue(TreemapLayout.layout(nodes, metric: .logical, in: .zero).isEmpty)
    }

    func testScanRefreshAndCancellation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("ab"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 123).write(to: root.appendingPathComponent("a/one"))
        try Data(repeating: 1, count: 456).write(to: root.appendingPathComponent("a/deep/two"))
        try Data().write(to: root.appendingPathComponent("ab/empty"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("a/loop").path, withDestinationPath: root.path)
        let scan = try FileScanner.scan(root)
        XCTAssertEqual(scan.root.fileCount, 4)
        XCTAssertEqual(scan.root.folderCount, 4)
        XCTAssertEqual(scan.root.logicalBytes, 579 + Int64(root.path.utf8.count))
        XCTAssertTrue(scan.root.node(at: ["a", "loop"][...])!.isLink)
        XCTAssertEqual(scan.visited, 8)
        let untouched = scan.root.node(at: ["ab"][...])!

        try Data(repeating: 2, count: 1000).write(to: root.appendingPathComponent("a/deep/two"))
        let updated = try FileScanner.refresh(scan.root, at: root,
            paths: [root.appendingPathComponent("a/deep").path], token: ScanToken())
        XCTAssertEqual(updated.root.logicalBytes, 1123 + Int64(root.path.utf8.count))
        XCTAssertTrue(updated.root.node(at: ["ab"][...]) === untouched)
        XCTAssertEqual(updated.visited, 2)
        try fm.removeItem(at: root.appendingPathComponent("a/deep"))
        let deleted = try FileScanner.refresh(updated.root, at: root,
            paths: [root.appendingPathComponent("a/deep").path], token: ScanToken())
        XCTAssertNil(deleted.root.node(at: ["a", "deep"][...]))
        XCTAssertEqual(deleted.root.fileCount, 3)

        let paths: Set<String> = [root.appendingPathComponent("a").path,
            root.appendingPathComponent("a/deep").path, root.appendingPathComponent("ab").path,
            root.path + "-outside"]
        XCTAssertEqual(ChangeBatch.minimalDirectories(paths, root: root.path, snapshot: scan.root),
                       [root.appendingPathComponent("a").path, root.appendingPathComponent("ab").path])
        XCTAssertTrue(ChangeBatch.isInside("/Users/test", root: "/"))
        XCTAssertFalse(ChangeBatch.isInside("/Users/testing", root: "/Users/test"))
        let token = ScanToken(); token.cancel()
        XCTAssertThrowsError(try FileScanner.scan(root, token: token)) {
            guard case ScanError.cancelled = $0 else { return XCTFail("Expected cancellation") }
        }
        XCTAssertThrowsError(try FileScanner.scan(root.appendingPathComponent("missing")))
    }
}

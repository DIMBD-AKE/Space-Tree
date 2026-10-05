import Foundation
import Darwin

enum Benchmark {
    private static func milliseconds<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try operation()
        return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func stats(_ samples: [Double]) -> [String: Double] {
        let sorted = samples.sorted()
        return ["median_ms": sorted[sorted.count / 2], "min_ms": sorted.first!,
                "p95_ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]]
    }

    static func run(_ args: [String]) throws {
        func argument(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
            return args[index + 1]
        }
        let count = max(1, min(1_000_000, Int(argument("--files") ?? "50000") ?? 50000))
        let runs = max(3, min(30, Int(argument("--runs") ?? "5") ?? 5))
        let parallelism = max(1, min(4, Int(argument("--parallelism") ?? "4") ?? 4))
        let fm = FileManager.default
        let supplied = argument("--path")
        let url = supplied.map { FileScanner.canonicalURL(URL(fileURLWithPath: $0)) }
            ?? fm.temporaryDirectory.appendingPathComponent("spacetree-bench-\(UUID().uuidString)")
        let shouldKeep = args.contains("--keep-fixture")
        defer { if supplied == nil && !shouldKeep { try? fm.removeItem(at: url) } }
        if supplied == nil { try makeFixture(at: url, count: count) }
        var report: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()), "path": url.path, "runs": runs, "parallelism": parallelism,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processors": ProcessInfo.processInfo.processorCount,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "cache_note": supplied == nil
                ? "First pass follows fixture creation; warm passes use OS metadata cache. Not a cold disk benchmark."
                : "Existing tree; first pass has uncontrolled cache state, subsequent passes use the OS metadata cache.",
            "memory_note": "Process RSS includes Swift runtime and linked UI frameworks. Peak includes baseline and benchmark data."
        ]
        let observe = args.contains("--observe-progress")
        let observationStart = DispatchTime.now().uptimeNanoseconds
        var partials: [[String: Any]] = []
        let (first, firstMS) = try milliseconds {
            try FileScanner.scan(url, parallelism: parallelism, partial: observe ? { node in
                // The scanner serializes callbacks; only this first pass observes GUI-style snapshots.
                partials.append(["elapsed_ms": Double(DispatchTime.now().uptimeNanoseconds - observationStart) / 1e6,
                    "files": node.fileCount, "logical_bytes": node.logicalBytes, "pending_folders": node.pendingFolderCount,
                    "top_level": node.children.filter(\.isDirectory).map {
                        ["name": $0.name, "files": $0.fileCount, "logical_bytes": $0.logicalBytes,
                         "pending_folders": $0.pendingFolderCount] as [String: Any]
                    }])
            } : nil)
        }
        if observe { report["partial_snapshots"] = partials }
        var snapshot = first.root
        report["entries"] = first.visited
        report["files"] = snapshot.fileCount
        report["allocated_bytes"] = snapshot.allocatedBytes
        report["unreadable_items"] = snapshot.unreadableCount
        report["logical_bytes"] = snapshot.logicalBytes
        report["first_scan_ms"] = firstMS
        report["snapshot_rss_bytes"] = residentBytes()
        if let space = DiskSpace.read(url) {
            report["disk_total_bytes"] = space.total
            report["disk_used_bytes"] = space.used
            report["disk_available_bytes"] = space.available
        }
        if args.contains("--single-pass") {
            report["runs"] = 1
            report["native_scan"] = stats([firstMS])
            report["excluded_volumes"] = snapshot.excludedVolumeCount
            report["top_level"] = snapshot.children.map { node -> [String: Any] in
                ["name": node.name, "logical_bytes": node.logicalBytes, "allocated_bytes": node.allocatedBytes,
                 "files": node.fileCount, "unreadable_items": node.unreadableCount]
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        var full: [Double] = []
        for _ in 0..<runs {
            let (result, elapsed) = try milliseconds { try FileScanner.scan(url, parallelism: parallelism) }
            guard result.root.logicalBytes == snapshot.logicalBytes, result.root.fileCount == snapshot.fileCount else {
                throw ScanError.filesystem("Tree changed during benchmark", EAGAIN)
            }
            snapshot = result.root
            full.append(elapsed)
        }
        report["native_scan"] = stats(full)
        var nativeUsage = rusage()
        getrusage(RUSAGE_SELF, &nativeUsage)
        report["native_peak_rss_bytes"] = nativeUsage.ru_maxrss

        if !args.contains("--skip-baseline") {
            var baseline: [Double] = []
            for _ in 0..<runs {
                let (tree, elapsed) = try milliseconds { try autoreleasepool { try foundationScan(url) } }
                guard tree.logicalBytes == snapshot.logicalBytes, tree.fileCount == snapshot.fileCount else {
                    throw ScanError.filesystem("Foundation/native totals differ", EIO)
                }
                baseline.append(elapsed)
            }
            report["foundation_scan"] = stats(baseline)
            report["scan_speedup"] = stats(baseline)["median_ms"]! / stats(full)["median_ms"]!
        }

        if supplied == nil {
            let changed = url.appendingPathComponent("bucket-000")
            var incremental: [Double] = []
            var visited = 0
            for index in 0..<runs {
                let file = changed.appendingPathComponent("file-000000.dat")
                let descriptor = Darwin.open(file.path, O_WRONLY)
                guard descriptor >= 0 else { throw ScanError.filesystem(file.path, errno) }
                let truncated = ftruncate(descriptor, off_t(10_000 + index))
                Darwin.close(descriptor)
                guard truncated == 0 else { throw ScanError.filesystem(file.path, errno) }
                let (result, elapsed) = try milliseconds {
                    try FileScanner.refresh(snapshot, at: url, paths: [changed.path], token: ScanToken())
                }
                snapshot = result.root
                visited = result.visited
                incremental.append(elapsed)
            }
            let verification = try FileScanner.scan(url)
            guard snapshot.logicalBytes == verification.root.logicalBytes else { throw ScanError.filesystem("Incremental total mismatch", EIO) }
            report["incremental_scan"] = stats(incremental)
            report["incremental_visited"] = visited
            report["incremental_speedup"] = stats(full)["median_ms"]! / stats(incremental)["median_ms"]!
        }

        var files: [FileNode] = [], stack = [snapshot]
        while let node = stack.popLast() {
            if node.isDirectory { stack.append(contentsOf: node.children) }
            else { files.append(node) }
        }
        files.sort { $0.logicalBytes > $1.logicalBytes }
        var layout: [Double] = []
        var tileCount = 0
        for _ in 0..<runs * 10 {
            let (tiles, elapsed) = milliseconds {
                TreemapLayout.layout(files, metric: .logical, in: CGRect(x: 0, y: 0, width: 1000, height: 700))
            }
            tileCount = tiles.count
            layout.append(elapsed)
        }
        report["layout"] = stats(layout)
        report["drawn_tiles"] = tileCount
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        report["peak_rss_bytes"] = usage.ru_maxrss
        report["cpu_user_seconds"] = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        report["cpu_system_seconds"] = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func makeFixture(at root: URL, count: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let buckets = min(100, count)
        for bucket in 0..<buckets {
            try fm.createDirectory(at: root.appendingPathComponent(String(format: "bucket-%03d", bucket)), withIntermediateDirectories: true)
        }
        for index in 0..<count {
            let file = root.appendingPathComponent(String(format: "bucket-%03d/file-%06d.dat", index % buckets, index))
            let descriptor = Darwin.open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard descriptor >= 0 else { throw ScanError.filesystem(file.path, errno) }
            let size = (index * 7919 % 4_000_000) + 64
            let success = ftruncate(descriptor, off_t(size)) == 0
            let failure = errno
            Darwin.close(descriptor)
            if !success { throw ScanError.filesystem(file.path, failure) }
        }
    }

    // Baseline builds the same tree and includes hidden files/packages, using prefetched Foundation metadata.
    private static func foundationScan(_ url: URL) throws -> FileNode {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .fileAllocatedSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        var children: [FileNode] = []
        for child in urls {
            let values = try child.resourceValues(forKeys: keys)
            if values.isDirectory == true && values.isSymbolicLink != true { children.append(try foundationScan(child)) }
            else {
                children.append(FileNode(name: child.lastPathComponent, isLink: values.isSymbolicLink == true,
                    logical: Int64(values.fileSize ?? 0), allocated: Int64(values.fileAllocatedSize ?? 0)))
            }
        }
        return FileNode(name: url.lastPathComponent, isDirectory: true, children: children)
    }
}

import Foundation

struct TreeTile {
    let node: FileNode?
    let rect: CGRect
    let bytes: Int64
    let groupedCount: Int
    var opacity: CGFloat = 1
    var title: String { node?.name ?? "그 외 \(groupedCount.formatted())개" }
}

enum TreemapLayout {
    static let tileLimit = 1200

    static func transition(from: [TreeTile], to: [TreeTile]) -> [(from: TreeTile, to: TreeTile)] {
        let previous = Dictionary(uniqueKeysWithValues: from.map { ($0.node?.name ?? "\0", $0) })
        let next = Set(to.map { $0.node?.name ?? "\0" })
        func collapsed(_ tile: TreeTile) -> TreeTile {
            TreeTile(node: tile.node, rect: CGRect(x: tile.rect.midX, y: tile.rect.midY, width: 0, height: 0),
                     bytes: 0, groupedCount: tile.groupedCount, opacity: 0)
        }
        var pairs = to.map { tile in (from: previous[tile.node?.name ?? "\0"] ?? collapsed(tile), to: tile) }
        // shortcut: retire only within the 1,200-cell budget; raise this only if profiling permits it.
        for tile in from where !next.contains(tile.node?.name ?? "\0") && pairs.count < tileLimit {
            pairs.append((from: tile, to: collapsed(tile)))
        }
        return pairs
    }

    static func interpolate(_ pair: (from: TreeTile, to: TreeTile), progress: CGFloat) -> TreeTile {
        let t = min(1, max(0, progress))
        if t == 1 { return pair.to }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let a = pair.from.rect, b = pair.to.rect
        let bytes = Double(pair.from.bytes) + (Double(pair.to.bytes) - Double(pair.from.bytes)) * Double(t)
        return TreeTile(node: pair.to.node,
                        rect: CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY),
                                     width: mix(a.width, b.width), height: mix(a.height, b.height)),
                        bytes: bytes >= Double(Int64.max) ? Int64.max : max(0, Int64(bytes.rounded())),
                        groupedCount: pair.to.groupedCount, opacity: mix(pair.from.opacity, pair.to.opacity))
    }

    // Balanced binary partition uses prefix sums: O(n) preparation, O(k log n) layout.
    // ponytail: cap drawing at 1,200 cells; all entries remain in the virtualized file list.
    static func layout(_ sortedNodes: [FileNode], metric: SizeMetric, in bounds: CGRect) -> [TreeTile] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let positive = sortedNodes.filter { $0.bytes(metric) > 0 }
        guard !positive.isEmpty else { return [] }
        let visibleCount = min(positive.count, tileLimit)
        let hasGroup = positive.count > tileLimit
        let individualCount = hasGroup ? visibleCount - 1 : visibleCount
        var weights = positive.prefix(individualCount).map { Double($0.bytes(metric)) }
        if hasGroup { weights.append(positive.dropFirst(individualCount).reduce(0) { $0 + Double($1.bytes(metric)) }) }
        var prefix = [0.0]
        prefix.reserveCapacity(weights.count + 1)
        for weight in weights { prefix.append(prefix.last! + weight) }
        var tiles: [TreeTile] = []
        tiles.reserveCapacity(weights.count)

        func divide(_ lower: Int, _ upper: Int, _ rect: CGRect) {
            if upper - lower == 1 {
                let grouped = hasGroup && lower == individualCount
                tiles.append(TreeTile(node: grouped ? nil : positive[lower], rect: rect,
                                      bytes: Int64(weights[lower]),
                                      groupedCount: grouped ? positive.count - individualCount : 0))
                return
            }
            let total = prefix[upper] - prefix[lower]
            let target = prefix[lower] + total / 2
            var lo = lower + 1, hi = upper - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if prefix[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            var split = lo
            if split > lower + 1 && abs(prefix[split - 1] - target) < abs(prefix[split] - target) { split -= 1 }
            let ratio = (prefix[split] - prefix[lower]) / total
            var first = rect, second = rect
            if rect.width >= rect.height {
                first.size.width = rect.width * ratio
                second.origin.x += first.width
                second.size.width -= first.width
            } else {
                first.size.height = rect.height * ratio
                second.origin.y += first.height
                second.size.height -= first.height
            }
            divide(lower, split, first)
            divide(split, upper, second)
        }
        divide(0, weights.count, bounds)
        return tiles
    }
}

enum FileCategory: String, CaseIterable {
    case folder = "폴더", video = "영상", image = "이미지", audio = "오디오"
    case archive = "압축", code = "코드", document = "문서", other = "기타"
    static func of(_ node: FileNode) -> FileCategory {
        if node.isDirectory { return .folder }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return .video
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "svg", "psd": return .image
        case "mp3", "wav", "aac", "flac", "m4a", "aiff": return .audio
        case "zip", "gz", "tar", "rar", "7z", "dmg", "iso", "pkg": return .archive
        case "swift", "js", "ts", "tsx", "py", "rs", "go", "c", "cpp", "h", "cs", "json", "html", "css", "sh": return .code
        case "pdf", "doc", "docx", "txt", "md", "pages", "xlsx", "csv", "key", "pptx": return .document
        default: return .other
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

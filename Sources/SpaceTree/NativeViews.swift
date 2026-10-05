import AppKit
import SwiftUI

extension FileCategory {
    var nsColor: NSColor {
        switch self {
        case .folder: return NSColor(red: 0.32, green: 0.53, blue: 0.91, alpha: 1)
        case .video: return NSColor(red: 0.64, green: 0.43, blue: 0.85, alpha: 1)
        case .image: return NSColor(red: 0.30, green: 0.69, blue: 0.64, alpha: 1)
        case .audio: return NSColor(red: 0.86, green: 0.49, blue: 0.66, alpha: 1)
        case .archive: return NSColor(red: 0.86, green: 0.63, blue: 0.34, alpha: 1)
        case .code: return NSColor(red: 0.43, green: 0.65, blue: 0.83, alpha: 1)
        case .document: return NSColor(red: 0.63, green: 0.67, blue: 0.85, alpha: 1)
        case .other: return NSColor(red: 0.48, green: 0.53, blue: 0.61, alpha: 1)
        }
    }
    var icon: String {
        switch self {
        case .folder: return "folder.fill"
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .code: return "curlybraces"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }
}

struct TreemapView: NSViewRepresentable {
    let nodes: [FileNode]
    let metric: SizeMetric
    let selected: String?
    let activate: (FileNode) -> Void
    let reveal: (FileNode) -> Void

    func makeNSView(context: Context) -> TreemapCanvas { TreemapCanvas() }
    func updateNSView(_ view: TreemapCanvas, context: Context) {
        view.activate = activate
        view.reveal = reveal
        if metric != view.metric || nodes.count != view.nodes.count || zip(nodes, view.nodes).contains(where: { $0 !== $1 }) {
            view.nodes = nodes
            view.metric = metric
            view.needsLayout = true
        }
        if view.selected != selected { view.selected = selected; view.needsDisplay = true }
    }
}

final class TreemapCanvas: NSView {
    var nodes: [FileNode] = []
    var metric: SizeMetric = .logical
    var selected: String?
    var activate: ((FileNode) -> Void)?
    var reveal: ((FileNode) -> Void)?
    private var tiles: [TreeTile] = []
    private var hovered: Int?
    private var lastSize = CGSize.zero
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        setAccessibilityLabel("파일 용량 트리맵")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        tiles = TreemapLayout.layout(nodes, metric: metric, in: bounds.insetBy(dx: 1, dy: 1))
        hovered = nil
        lastSize = bounds.size
        removeAllToolTips()
        for (index, tile) in tiles.enumerated() where tile.rect.width > 3 && tile.rect.height > 3 {
            addToolTip(tile.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        let elements = tiles.filter { $0.rect.width > 3 && $0.rect.height > 3 }.map { tile -> NSAccessibilityElement in
            let item = TileAccessibility()
            item.setAccessibilityParent(self)
            item.setAccessibilityRole(tile.node == nil ? .staticText : .button)
            item.setAccessibilityEnabled(tile.node != nil)
            item.setAccessibilityLabel("\(tile.title), \(formatBytes(tile.bytes))")
            item.setAccessibilityFrameInParentSpace(tile.rect)
            if let node = tile.node { item.action = { [weak self] in self?.activate?(node) } }
            return item
        }
        setAccessibilityChildren(elements)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize != lastSize { needsLayout = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, tile) in tiles.enumerated() where tile.rect.intersects(dirtyRect) {
            let rect = tile.rect.insetBy(dx: 2, dy: 2)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let category = tile.node.map(FileCategory.of) ?? .other
            let color = category.nsColor
            let active = index == hovered || tile.node?.name == selected
            let path = NSBezierPath(roundedRect: rect, xRadius: min(7, rect.width / 5), yRadius: min(7, rect.height / 5))
            color.withAlphaComponent(active ? 0.90 : 0.66).setFill()
            path.fill()
            color.withAlphaComponent(active ? 1 : 0.8).setStroke()
            path.lineWidth = active ? 2 : 0.6
            path.stroke()
            if rect.width > 65 && rect.height > 42 {
                let inset: CGFloat = rect.width > 140 ? 13 : 8
                let fontSize: CGFloat = rect.width > 180 && rect.height > 90 ? 15 : 12
                let titleAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: NSColor.white, .paragraphStyle: paragraph
                ]
                (tile.title as NSString).draw(in: CGRect(x: rect.minX + inset, y: rect.minY + inset,
                    width: rect.width - inset * 2, height: 21), withAttributes: titleAttributes)
                (formatBytes(tile.bytes) as NSString).draw(in: CGRect(x: rect.minX + inset, y: rect.minY + inset + 23,
                    width: rect.width - inset * 2, height: 17), withAttributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.76), .paragraphStyle: paragraph
                    ])
                if tile.node?.isDirectory == true && rect.width > 120 && rect.height > 85 {
                    let count = "\(tile.node!.fileCount.formatted())개 파일  ↗"
                    (count as NSString).draw(in: CGRect(x: rect.minX + inset, y: rect.maxY - 28,
                        width: rect.width - inset * 2, height: 18), withAttributes: [
                            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.65)
                        ])
                }
            }
        }
    }

    private func tile(at point: NSPoint) -> Int? { tiles.firstIndex { $0.rect.contains(point) } }

    override func mouseMoved(with event: NSEvent) {
        let next = tile(at: convert(event.locationInWindow, from: nil))
        guard next != hovered else { return }
        if let hovered { setNeedsDisplay(tiles[hovered].rect) }
        hovered = next
        if let next { setNeedsDisplay(tiles[next].rect) }
        if let next, tiles[next].node != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) {
        if let hovered { setNeedsDisplay(tiles[hovered].rect) }
        hovered = nil
        NSCursor.arrow.set()
    }
    override func mouseDown(with event: NSEvent) {
        if let index = tile(at: convert(event.locationInWindow, from: nil)), let node = tiles[index].node { activate?(node) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = tile(at: convert(event.locationInWindow, from: nil)), let node = tiles[index].node else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Finder에서 보기", action: #selector(revealMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = node
        menu.addItem(item)
        return menu
    }
    @objc private func revealMenu(_ sender: NSMenuItem) { if let node = sender.representedObject as? FileNode { reveal?(node) } }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard tiles.indices.contains(index) else { return "" }
        let tile = tiles[index]
        return "\(tile.title)\n\(formatBytes(tile.bytes))" + (tile.node == nil ? "\n전체 항목은 오른쪽 목록에서 확인하세요." : "")
    }
}

private final class TileAccessibility: NSAccessibilityElement {
    var action: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
}

struct FileListView: NSViewRepresentable {
    let nodes: [FileNode]
    let metric: SizeMetric
    let selected: String?
    let select: (FileNode?) -> Void
    let activate: (FileNode) -> Void
    let reveal: (FileNode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.minWidth = 140
        name.width = 220
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        size.width = 82
        size.minWidth = 75
        size.maxWidth = 100
        table.addTableColumn(name)
        table.addTableColumn(size)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openRow)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Finder에서 보기", action: #selector(Coordinator.revealRow), keyEquivalent: "")
        item.target = context.coordinator
        menu.addItem(item)
        table.menu = menu
        table.setAccessibilityLabel("파일과 폴더 목록, 용량순")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.select = select
        coordinator.activate = activate
        coordinator.reveal = reveal
        let changed = coordinator.metric != metric || coordinator.nodes.count != nodes.count
            || zip(coordinator.nodes, nodes).contains { $0 !== $1 }
        coordinator.nodes = nodes
        coordinator.metric = metric
        coordinator.updating = true
        if changed { coordinator.table?.reloadData() }
        if let selected, let index = nodes.firstIndex(where: { $0.name == selected }) {
            coordinator.table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { coordinator.table?.deselectAll(nil) }
        coordinator.updating = false
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        var nodes: [FileNode] = []
        var metric: SizeMetric = .logical
        var updating = false
        var select: ((FileNode?) -> Void)?
        var activate: ((FileNode) -> Void)?
        var reveal: ((FileNode) -> Void)?
        func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            select?(nodes.indices.contains(table.selectedRow) ? nodes[table.selectedRow] : nil)
        }
        @objc func openRow() {
            guard let table, nodes.indices.contains(table.clickedRow) else { return }
            activate?(nodes[table.clickedRow])
        }
        @objc func revealRow() {
            guard let table else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            if nodes.indices.contains(row) { reveal?(nodes[row]) }
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let node = nodes[row]
            let isName = tableColumn?.identifier.rawValue == "name"
            let identifier = NSUserInterfaceItemIdentifier(isName ? "nameCell" : "sizeCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier, isName: isName)
            cell.textField?.stringValue = isName ? node.name : (node.isPendingScan && node.bytes(metric) == 0 ? "분석 중" : formatBytes(node.bytes(metric)) + (node.pendingFolderCount > 0 ? "…" : ""))
            cell.textField?.textColor = isName ? .labelColor : .secondaryLabelColor
            if isName {
                let category = FileCategory.of(node)
                cell.imageView?.image = NSImage(systemSymbolName: node.isLink ? "link" : category.icon, accessibilityDescription: category.rawValue)
                cell.imageView?.contentTintColor = category.nsColor
            }
            cell.toolTip = node.name + (node.ownError == 0 ? "" : " — 읽기 권한이 없습니다.")
            return cell
        }
        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, isName: Bool) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = isName ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textField = text
            cell.addSubview(text)
            if isName {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.imageView = image
                cell.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 17), image.heightAnchor.constraint(equalToConstant: 17),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9)
                ])
            } else {
                text.alignment = .right
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -9),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
    }
}

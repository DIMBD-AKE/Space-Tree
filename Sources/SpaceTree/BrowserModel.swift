import AppKit
import Combine

struct DiskSpace {
    let total: Int64
    let available: Int64
    var used: Int64 { max(0, total - available) }
    static func read(_ url: URL) -> DiskSpace? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return DiskSpace(total: Int64(info.f_blocks) * Int64(info.f_bsize),
                         available: Int64(info.f_bavail) * Int64(info.f_bsize))
    }
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var root: FileNode?
    @Published private(set) var components: [String] = []
    @Published private(set) var rows: [FileNode] = []
    @Published var selectedName: String?
    @Published var metric: SizeMetric = .logical { didSet { updateRows() } }
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published private(set) var isScanning = false
    @Published private(set) var isWatching = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var lastScanSeconds = 0.0
    @Published private(set) var lastVisited = 0
    @Published private(set) var updatedAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var diskSpace: DiskSpace?
    @Published var showsAccessSetup = false
    @Published private(set) var accessSetupError: String?
    private var requestedURL: URL?

    private let worker = DispatchQueue(label: "SpaceTree.scan", qos: .utility)
    private var token = ScanToken()
    private var generation = 0
    private var rowGeneration = 0
    private var watcher: FolderWatcher?
    private var pendingPaths = Set<String>()
    private var pendingFullScan = false
    private var failedPaths = Set<String>()
    private var fullScanRequired = false
    private var debounce: DispatchWorkItem?
    private var searchDebounce: DispatchWorkItem?
    private var rootHandle: Int32 = -1

    var currentNode: FileNode? { root?.node(at: components[...]) }
    var currentURL: URL? { components.reduce(rootURL) { $0?.appendingPathComponent($1) } }
    var selectedNode: FileNode? { currentNode?.children.first { $0.name == selectedName } }
    var selectionURL: URL? {
        guard let name = selectedName else { return currentURL }
        return currentURL?.appendingPathComponent(name)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "분석하기"
        panel.message = "분석하고 자동으로 추적할 폴더를 선택하세요."
        if panel.runModal() == .OK, let url = panel.url { prepareToOpen(url) }
    }

    func prepareToOpen(_ selected: URL) {
        // The macOS root is a sealed System volume; Data contains the user's files without firmlink duplicates.
        let url = selected.path == "/" ? URL(fileURLWithPath: "/System/Volumes/Data") : selected
        accessSetupError = nil
        guard UserDefaults.standard.bool(forKey: "accessSetupSeen") else {
            requestedURL = url
            showsAccessSetup = true
            return
        }
        open(url)
    }

    func finishAccessSetup() {
        // Check the folder we need, rather than reading TCC's private permission database.
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if let directory = opendir(trash.path) { closedir(directory) }
        else if errno == EPERM || errno == EACCES {
            accessSetupError = "아직 휴지통에 접근할 수 없습니다. 전체 디스크 접근을 켜고 앱을 재실행한 뒤 다시 시도하세요."
            return
        }
        UserDefaults.standard.set(true, forKey: "accessSetupSeen")
        showsAccessSetup = false
        if let url = requestedURL { requestedURL = nil; open(url) }
        else if rootURL != nil { reload() }
    }

    func openAccessSettings() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func open(_ selected: URL) {
        token.cancel()
        debounce?.cancel()
        watcher?.stop()
        watcher = nil
        if rootHandle >= 0 { Darwin.close(rootHandle) }
        let url = FileScanner.canonicalURL(selected)
        rootHandle = Darwin.open(url.path, O_EVTONLY)
        generation += 1
        rootURL = url
        root = nil
        diskSpace = nil
        components = []
        rows = []
        selectedName = nil
        query = ""
        pendingPaths.removeAll()
        pendingFullScan = false
        failedPaths.removeAll()
        fullScanRequired = false
        message = nil
        isScanning = false
        isWatching = false
        do {
            watcher = try FolderWatcher(url: url) { [weak self] changes in self?.receive(changes) }
            isWatching = true
        } catch { message = "자동 추적을 시작할 수 없습니다: \(error.localizedDescription)" }
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        startScan(full: true)
    }

    func reload() {
        if watcher == nil, let url = rootURL {
            do {
                watcher = try FolderWatcher(url: url) { [weak self] in self?.receive($0) }
                isWatching = true
            } catch { message = "자동 추적을 시작할 수 없습니다: \(error.localizedDescription)" }
        }
        if isScanning { pendingFullScan = true; token.cancel() }
        else { startScan(full: true) }
    }

    func cancelScan() {
        token.cancel()
        pendingFullScan = false
        pendingPaths.removeAll()
        debounce?.cancel()
        watcher?.stop()
        watcher = nil
        isWatching = false
        message = "스캔을 중지했습니다. 새로 고침하면 자동 추적을 다시 시작합니다."
    }

    func enter(_ node: FileNode) {
        guard currentNode?.children.contains(where: { $0 === node }) == true else { return }
        if node.isVolumeBoundary, let url = currentURL?.appendingPathComponent(node.name) {
            prepareToOpen(url)
            return
        }
        selectedName = node.name
        guard node.isDirectory else { return }
        components.append(node.name)
        rows = []
        selectedName = nil
        query = ""
        updateRows()
    }

    func go(to depth: Int) {
        components = Array(components.prefix(max(0, depth)))
        rows = []
        selectedName = nil
        query = ""
        updateRows()
    }

    func reveal(_ node: FileNode? = nil) {
        let url = node.map { currentURL?.appendingPathComponent($0.name) } ?? selectionURL
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func updateRows() {
        rowGeneration += 1
        let stamp = rowGeneration
        let children = currentNode?.children ?? []
        let metric = metric
        let query = query
        if query.isEmpty && metric == .logical { rows = children; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var nodes = query.isEmpty ? children : children.filter { $0.name.localizedStandardContains(query) }
            if metric == .allocated {
                nodes.sort { $0.allocatedBytes == $1.allocatedBytes ? $0.name < $1.name : $0.allocatedBytes > $1.allocatedBytes }
            }
            DispatchQueue.main.async {
                guard let self, self.rowGeneration == stamp else { return }
                self.rows = nodes
            }
        }
    }

    private func scheduleSearch() {
        searchDebounce?.cancel()
        // Invalidate an already-running search before waiting for the next keystroke.
        rowGeneration += 1
        if query.isEmpty { updateRows(); return }
        let work = DispatchWorkItem { [weak self] in self?.updateRows() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func receive(_ changes: [FileChange]) {
        guard let url = rootURL else { return }
        for event in changes {
            if event.requiresFullScan {
                pendingFullScan = true
                if event.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { followMovedRoot() }
            }
            if ChangeBatch.isInside(event.path, root: url.path) { pendingPaths.insert(event.path) }
        }
        // Bound burst memory. A full scan also covers events the daemon has dropped.
        if pendingPaths.count > 4096 { pendingPaths.removeAll(); pendingFullScan = true }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drainChanges() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func followMovedRoot() {
        guard rootHandle >= 0 else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(rootHandle, F_GETPATH, &buffer) == 0 {
            let url = URL(fileURLWithPath: String(cString: buffer))
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
               url != rootURL {
                // Restart the stream on the new pathname, keeping the old snapshot until the scan completes.
                rootURL = url
                UserDefaults.standard.set(url.path, forKey: "lastFolder")
                watcher?.stop()
                watcher = try? FolderWatcher(url: url) { [weak self] in self?.receive($0) }
                isWatching = watcher != nil
                token.cancel()
                generation += 1
                isScanning = false
                pendingPaths.removeAll()
            }
        }
    }

    private func drainChanges() {
        guard !isScanning, pendingFullScan || !pendingPaths.isEmpty else { return }
        // Retry failed batches only when another external event arrives, avoiding an error loop.
        pendingPaths.formUnion(failedPaths)
        failedPaths.removeAll()
        startScan(full: pendingFullScan || fullScanRequired || root == nil)
    }

    private func startScan(full: Bool) {
        guard let url = rootURL else { return }
        let oldRoot = root
        let paths = pendingPaths
        pendingPaths.removeAll()
        pendingFullScan = false
        let stamp = generation
        let token = ScanToken()
        self.token = token
        isScanning = true
        if full { fullScanRequired = true }
        scannedCount = 0
        worker.async(qos: full ? .userInitiated : .utility, flags: .enforceQoS) { [weak self] in
            let initialSpace = DiskSpace.read(url)
            DispatchQueue.main.async {
                guard let self, self.generation == stamp, self.token === token else { return }
                self.diskSpace = initialSpace
            }
            let result = Result {
                if !full, let oldRoot {
                    return try FileScanner.refresh(oldRoot, at: url, paths: paths, token: token)
                }
                // Stream the first scan; rescans keep the navigable snapshot until replacement is complete.
                return try FileScanner.scan(url, token: token, partial: oldRoot == nil ? { snapshot in
                    DispatchQueue.main.async {
                        guard let self, self.generation == stamp, self.token === token, !token.isCancelled,
                              self.isScanning else { return }
                        self.root = snapshot
                        self.updateRows()
                    }
                } : nil) { count in
                    DispatchQueue.main.async {
                        guard let self, self.generation == stamp, self.token === token, !token.isCancelled else { return }
                        self.scannedCount = max(self.scannedCount, count)
                    }
                }
            }
            let space = DiskSpace.read(url)
            DispatchQueue.main.async {
                guard let self, self.generation == stamp else { return }
                self.isScanning = false
                self.diskSpace = space
                switch result {
                case let .success(scan):
                    if full { self.fullScanRequired = false; self.failedPaths.removeAll() }
                    self.root = scan.root
                    self.scannedCount = scan.visited
                    self.lastVisited = scan.visited
                    self.lastScanSeconds = scan.seconds
                    self.updatedAt = Date()
                    self.message = self.isWatching ? nil : "자동 추적이 꺼져 있습니다. 새로 고침을 사용하세요."
                    while !self.components.isEmpty && self.currentNode == nil { self.components.removeLast() }
                    if self.selectedNode == nil { self.selectedName = nil }
                    self.updateRows()
                case .failure(ScanError.cancelled): break
                case let .failure(error):
                    if full { self.fullScanRequired = true }
                    else { self.failedPaths.formUnion(paths) }
                    self.message = error.localizedDescription
                    // Keep the last snapshot for transient permissions/I/O errors, but label it as stale.
                }
                self.drainChanges()
            }
        }
    }

    func shutdown() {
        token.cancel()
        debounce?.cancel()
        searchDebounce?.cancel()
        watcher?.stop()
        watcher = nil
        if rootHandle >= 0 { Darwin.close(rootHandle); rootHandle = -1 }
    }
}

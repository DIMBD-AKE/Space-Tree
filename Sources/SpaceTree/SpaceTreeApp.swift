import SwiftUI
import AppKit

@main
struct SpaceTreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = BrowserModel()

    init() {
        if CommandLine.arguments.contains("--benchmark") {
            do { try Benchmark.run(CommandLine.arguments); exit(0) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    }

    var body: some Scene {
        WindowGroup {
            BrowserView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model
                    guard model.rootURL == nil else { return }
                    if let index = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > index + 1 {
                        model.prepareToOpen(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    } else if let path = UserDefaults.standard.string(forKey: "lastFolder") {
                        model.prepareToOpen(URL(fileURLWithPath: path))
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("폴더 열기…", action: model.chooseFolder).keyboardShortcut("o")
            }
            CommandMenu("탐색") {
                Button("상위 폴더") { model.go(to: model.components.count - 1) }
                    .keyboardShortcut(.upArrow, modifiers: .command).disabled(model.components.isEmpty)
                Button("새로 고침", action: model.reload).keyboardShortcut("r").disabled(model.rootURL == nil)
                Button("Finder에서 보기") { model.reveal() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("선택한 폴더 진입") { if let node = model.selectedNode { model.enter(node) } }
                    .keyboardShortcut(.return, modifiers: []).disabled(model.selectedNode?.isDirectory != true)
                Button("전체 디스크 접근 설정…") { model.showsAccessSetup = true }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows { window.title = "Space Tree"; window.backgroundColor = NSColor(red: 0.055, green: 0.07, blue: 0.10, alpha: 1) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

private enum Theme {
    static let background = Color(red: 0.055, green: 0.07, blue: 0.10)
    static let panel = Color(red: 0.085, green: 0.10, blue: 0.14)
    static let muted = Color(red: 0.52, green: 0.57, blue: 0.65)
    static let accent = Color(red: 0.58, green: 0.81, blue: 0.67)
    static let line = Color.white.opacity(0.075)
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.rootURL != nil {
                Divider().overlay(Theme.line)
                breadcrumbs
                if let root = model.currentNode {
                    stats(root)
                    explorer(root)
                } else if model.isScanning {
                    Spacer()
                    ProgressView().controlSize(.large)
                    Text("폴더를 분석하고 있습니다").font(.title3).padding(.top, 16)
                    Text("\(model.scannedCount.formatted())개 항목 탐색 · 파일 내용은 읽지 않습니다")
                        .foregroundStyle(Theme.muted).padding(.top, 2)
                    Button("스캔 중지", action: model.cancelScan).padding(.top, 12)
                    Spacer()
                } else {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundStyle(Theme.muted)
                    Text("아직 분석 결과가 없습니다").font(.title2).padding(12)
                    Button("다른 폴더 열기", action: model.chooseFolder)
                    Spacer()
                }
                status
            } else { welcome }
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .sheet(isPresented: $model.showsAccessSetup) { accessSetup }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "square.split.2x2.fill")
                .font(.system(size: 24)).foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("Space Tree").font(.system(size: 20, weight: .semibold))
                Text("YOUR FILES, IN PERSPECTIVE").font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.8).foregroundStyle(Theme.muted)
            }
            Spacer()
            if model.rootURL != nil {
                HStack(spacing: 6) {
                    Circle().fill(model.isWatching ? Theme.accent : Theme.muted).frame(width: 6, height: 6)
                    Text(model.isWatching ? "자동 추적 중" : "추적 중지").font(.system(size: 11))
                }.foregroundStyle(Theme.muted).padding(.trailing, 12)
                Button(action: model.reload) { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).help("새로 고침 (⌘R)")
            }
            Button(action: model.chooseFolder) { Label("폴더 열기", systemImage: "folder.badge.plus").padding(.horizontal, 7).padding(.vertical, 4) }
                .buttonStyle(.bordered)
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 12) {
            Button { model.go(to: model.components.count - 1) } label: { Image(systemName: "arrow.up").font(.system(size: 12)) }
                .buttonStyle(.plain).disabled(model.components.isEmpty).help("상위 폴더 (⌘↑)")
            Rectangle().fill(Theme.line).frame(width: 1, height: 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive").foregroundStyle(Theme.muted)
                    Button(model.rootURL?.lastPathComponent.isEmpty == false ? model.rootURL!.lastPathComponent : "/") { model.go(to: 0) }
                        .buttonStyle(.plain)
                    ForEach(Array(model.components.enumerated()), id: \.offset) { index, component in
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.muted)
                        Button(component) { model.go(to: index + 1) }.buttonStyle(.plain)
                    }
                }.font(.system(size: 12))
            }
            Button { model.reveal() } label: { Label("Finder", systemImage: "arrow.up.forward.square").font(.system(size: 11)) }
                .buttonStyle(.bordered).help("선택한 항목 또는 현재 폴더를 Finder에서 보기 (⇧⌘R)")
        }.padding(.horizontal, 28).padding(.vertical, 17)
    }

    private func stats(_ node: FileNode) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.metric.rawValue + (node.pendingFolderCount > 0 ? " · 부분 결과" : ""))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
                Text(formatBytes(node.bytes(model.metric))).font(.system(size: 30, weight: .medium, design: .rounded)).tracking(-1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 46)
            statCard("파일", value: node.fileCount.formatted())
            statCard("하위 폴더", value: max(0, node.folderCount - 1).formatted())
            let unknown = node.recovery.unknownFiles + node.recovery.privateUnknownFiles + node.unreadableCount
            statCard(node.pendingFolderCount > 0 ? "폴더 회수 · 분석 중" : "폴더 회수 대상",
                     value: formatBytes(node.recovery.allocatedBytes),
                     detail: "단독 \(formatBytes(node.recovery.privateBytes))" + (node.recovery.privateUnknownFiles > 0 ? " 이상" : ""), accent: true)
                .help("이 폴더의 회수 대상 \(node.recovery.fileCount.formatted())개 파일 · \(unknown.formatted())개 항목 확인 불가. 회수 대상으로 확인된 파일의 할당량이며, 디스크 전체 회수 예상과 별개입니다. 단독 회수 예상은 다른 파일·스냅샷과 공유하지 않는 블록만 합산합니다. 여러 공유 파일을 함께 삭제하면 더 많은 공간이 돌아올 수 있습니다.")
            if let space = model.diskSpace {
                statCard("디스크 전체 사용", value: formatBytes(space.used))
                    .help("현재 비어 있는 공간을 제외한 전체 사용량입니다. 총 \(formatBytes(space.total)) · 빈 공간 \(formatBytes(space.available)). 다른 볼륨과 접근 불가 영역을 포함합니다.")
                statCard("macOS 사용 · 추정", value: space.estimatedUsed.map(formatBytes) ?? "확인 불가")
                    .help("macOS가 회수 예상 공간을 여유로 취급하는 기준의 사용량입니다. 시스템 설정의 표시와 시점·계산 기준에 따라 다를 수 있습니다.")
                statCard("디스크 회수 예상", value: space.reclaimableEstimate.map(formatBytes) ?? "확인 불가")
                    .help("macOS가 비필수·캐시 자원 등을 정리해 추가로 확보할 수 있다고 추정한 공간입니다. 현재 폴더의 회수 대상 합계와 다르며 모두 특정 경로에 배분할 수는 없습니다.")
            }
        }.padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 20)
    }

    private func statCard(_ title: String, value: String, detail: String? = nil, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(accent ? Theme.accent : Color.white.opacity(0.85))
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(Theme.muted) }
        }.lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 64, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }

    private func explorer(_ node: FileNode) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("공간 지도").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("면적 기준", selection: $model.metric) {
                        ForEach(SizeMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).controlSize(.small).frame(width: 240)
                        .help("폴더를 클릭하면 내부로 진입합니다. 회수 대상은 파일시스템이 회수 가능하다고 표시한 파일만 보여줍니다. 할당량은 공유 블록 때문에 실제 회수되는 공간과 다를 수 있습니다.")
                }
                if model.rows.contains(where: { $0.bytes(model.metric) > 0 }) {
                    TreemapView(nodes: model.rows, metric: model.metric, selected: model.selectedName,
                        activate: model.enter, reveal: { model.reveal($0) })
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: node.isPendingScan ? "hourglass" : (model.query.isEmpty ? "folder" : "magnifyingglass")).font(.system(size: 30))
                        Text(node.isPendingScan ? "이 폴더를 분석하고 있습니다" : (model.metric == .purgeable && !model.rows.isEmpty ? "회수 대상의 할당량이 0입니다" : (model.metric == .purgeable && model.query.isEmpty ? "확인된 회수 대상이 없습니다" : (model.query.isEmpty ? "표시할 용량이 없습니다" : "일치하는 항목이 없습니다"))))
                        Text(node.isPendingScan ? "분석이 끝난 폴더는 바로 탐색할 수 있습니다." : (model.metric == .purgeable && model.rows.isEmpty ? "디스크 전체 회수 예상치에는 여기에 표시되지 않는 공간도 포함됩니다." : "빈 파일과 폴더도 오른쪽 목록에서 탐색할 수 있습니다.")).font(.system(size: 11))
                    }.foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 14) {
                    ForEach(FileCategory.allCases, id: \.self) { category in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: category.nsColor)).frame(width: 6, height: 6)
                            Text(category.rawValue).font(.system(size: 9)).foregroundStyle(Theme.muted)
                        }
                    }
                }.padding(.top, 3)
            }.padding(18).frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                HStack {
                    Text("폴더 내용").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(model.rows.count.formatted())개").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("이 폴더에서 이름 검색", text: $model.query).textFieldStyle(.plain).font(.system(size: 11))
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                            .buttonStyle(.plain).accessibilityLabel("검색 지우기")
                    }
                }.padding(9).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12).padding(.bottom, 12)
                HStack {
                    Text("이름")
                    Spacer()
                    Text("용량 ↓")
                }.font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 18).padding(.bottom, 8)
                FileListView(nodes: model.rows, metric: model.metric, selected: model.selectedName,
                    select: { model.selectedName = $0?.name }, activate: model.enter, reveal: { model.reveal($0) })
                Text("폴더는 더블 클릭 또는 Return으로 진입")
                    .font(.system(size: 9)).foregroundStyle(Theme.muted).padding(12)
            }.frame(minWidth: 280, idealWidth: 320, maxWidth: 400).background(Theme.panel.opacity(0.65))
        }.background(Theme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .padding(.horizontal, 28).padding(.bottom, 18)
    }

    private var status: some View {
        HStack(spacing: 7) {
            if model.isScanning {
                ProgressView().controlSize(.mini)
                Text("분석 중 · \(model.scannedCount.formatted())개 항목")
                Button("중지", action: model.cancelScan).buttonStyle(.plain).foregroundStyle(Theme.accent)
            } else if let message = model.message {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message).lineLimit(1).help(message)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
                Text(String(format: "최근 스캔 %.0f ms · %@개 항목", model.lastScanSeconds * 1000, model.lastVisited.formatted()))
            }
            if let root = model.root, root.unreadableCount > 0 {
                Text("· 읽지 못한 항목 \(root.unreadableCount)개").foregroundStyle(.orange)
                    .help("macOS 개인정보 보호로 접근할 수 없는 폴더는 제외됩니다. 필요한 경우 시스템 설정에서 전체 디스크 접근 권한을 허용하세요.")
                Button("접근 설정") { model.showsAccessSetup = true }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if let root = model.root, root.excludedVolumeCount > 0 {
                Text("· 다른 볼륨 \(root.excludedVolumeCount)개 제외")
                    .help("마운트된 디스크 이미지나 다른 볼륨은 중복 합산하지 않습니다. 해당 볼륨을 직접 선택하면 분석할 수 있습니다.")
            }
            Spacer()
            Text("읽기 전용 · 메타데이터만 분석").foregroundStyle(Theme.muted)
        }.font(.system(size: 9)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 28).padding(.vertical, 11).background(Color.black.opacity(0.16))
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.split.2x2.fill").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Theme.accent)
                .padding(.bottom, 10)
            Text("파일 공간을 한눈에.").font(.system(size: 34, weight: .medium)).tracking(-1)
            Text("큰 폴더를 찾고, 안으로 들어가고, 변화를 따라가세요.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
            Button(action: model.chooseFolder) { Label("폴더 선택해 분석하기", systemImage: "folder").padding(.horizontal, 14).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).padding(.top, 9)
            HStack(spacing: 22) {
                quickFolder("디스크", symbol: "internaldrive", url: URL(fileURLWithPath: "/System/Volumes/Data"))
                quickFolder("홈", symbol: "house", url: FileManager.default.homeDirectoryForCurrentUser)
                quickFolder("다운로드", symbol: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                quickFolder("응용 프로그램", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications"))
            }.padding(.top, 6)
            Spacer()
            HStack(spacing: 25) {
                Label("빠른 네이티브 스캔", systemImage: "bolt")
                Label("실시간 변경 추적", systemImage: "waveform.path")
                Label("파일 내용 읽지 않음", systemImage: "lock")
            }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.bottom, 32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("전체 디스크 접근", systemImage: "externaldrive.badge.checkmark")
                .font(.system(size: 22, weight: .semibold))
            Text("휴지통과 보호된 폴더까지 분석하려면 Space Tree에 전체 디스크 접근을 한 번 허용하세요. 폴더별 권한 요청도 줄일 수 있습니다.")
            Text("1. 아래 버튼으로 시스템 설정을 엽니다.\n2. ‘전체 디스크 접근’ 목록에 Finder에서 선택된 Space Tree.app을 추가하고 켭니다.\n3. macOS가 재실행을 요청하면 앱을 다시 열어 분석을 시작하세요.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(6)
            Text("이 앱은 파일 내용이나 파일을 변경하지 않습니다. macOS의 권한은 사용자가 직접 허용해야 하며, 일부 시스템 보호 영역은 계속 제외될 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if let error = model.accessSetupError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("나중에") { model.showsAccessSetup = false }
                Spacer()
                Button("설정 열기", action: model.openAccessSettings)
                Button("설정 완료 · 분석 시작", action: model.finishAccessSetup).buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 520)
    }

    private func quickFolder(_ name: String, symbol: String, url: URL) -> some View {
        Button { model.prepareToOpen(url) } label: { Label(name, systemImage: symbol).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            .buttonStyle(.plain)
    }
}

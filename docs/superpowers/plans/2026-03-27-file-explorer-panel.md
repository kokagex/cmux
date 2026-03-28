# ファイルエクスプローラーパネル 実装プラン

> **エージェント向け:** 必須サブスキル: superpowers:subagent-driven-development（推奨）または superpowers:executing-plans でタスクごとに実装する。チェックボックス (`- [ ]`) で進捗を追跡。

**ゴール:** VS Code ライクなファイルエクスプローラーを cmux のパネルタブとして追加する

**アーキテクチャ:** NSOutlineView を NSViewRepresentable でラップし、既存の Panel プロトコルに準拠。FSEventStream でファイル変更をリアルタイム監視し、`git status --porcelain` で Git ステータスを表示。

**技術スタック:** Swift / AppKit (NSOutlineView) / SwiftUI / CoreServices (FSEventStream)

---

## ファイル構成

| ファイル | 責務 |
|---------|------|
| **新規** `Sources/Panels/FileNode.swift` | ツリーノードモデル + Git ステータス enum |
| **新規** `Sources/Panels/FileIconMapper.swift` | 拡張子 → SF Symbol マッピング |
| **新規** `Sources/Panels/GitStatusProvider.swift` | `git status --porcelain` 実行・パース |
| **新規** `Sources/Panels/FileExplorerPanel.swift` | Panel プロトコル実装 (ObservableObject) |
| **新規** `Sources/Panels/FileExplorerOutlineView.swift` | NSOutlineView の NSViewRepresentable ラッパー |
| **新規** `Sources/Panels/FileExplorerDataSource.swift` | NSOutlineViewDataSource + NSOutlineViewDelegate |
| **新規** `Sources/Panels/FileExplorerPanelView.swift` | SwiftUI ビュー（ツールバー + OutlineView） |
| **変更** `Sources/Panels/Panel.swift` | `PanelType` に `.fileExplorer` 追加 |
| **変更** `Sources/Panels/PanelContentView.swift` | ルーティング追加 |
| **変更** `Sources/Workspace.swift` | パネル作成メソッド + SurfaceKind + createPanel |
| **変更** `Sources/SessionPersistence.swift` | スナップショット構造体追加 |
| **変更** `Sources/ContentView.swift` | コマンドパレット + キーボードショートカット |

---

### タスク 1: FileNode モデルと GitStatus enum

**ファイル:**
- 新規: `Sources/Panels/FileNode.swift`

- [ ] **ステップ 1: FileNode と GitStatus を作成**

```swift
// Sources/Panels/FileNode.swift
import Foundation

/// Git ワーキングツリーのステータス
enum GitFileStatus: Sendable {
    case unmodified
    case modified    // 黄
    case added       // 緑
    case deleted     // 赤
    case untracked   // 灰
    case conflicted  // オレンジ
}

/// ファイルツリーの1ノード。NSOutlineView の item として使用するため NSObject を継承。
@MainActor
final class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool

    /// nil = 未ロード（遅延ロード対象）, [] = 空ディレクトリ
    var children: [FileNode]?
    var isExpanded: Bool = false
    var gitStatus: GitFileStatus = .unmodified

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        super.init()
    }

    /// ディレクトリの子ノードをファイルシステムから読み込む。
    /// showHidden=false のとき、"." で始まるファイルを除外する。
    /// ignoredPaths に含まれるパスも除外する。
    func loadChildren(showHidden: Bool, ignoredPaths: Set<String>) {
        guard isDirectory else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            children = []
            return
        }

        let nodes = urls.compactMap { childURL -> FileNode? in
            if ignoredPaths.contains(childURL.path) { return nil }
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileNode(url: childURL, isDirectory: isDir)
        }

        // ディレクトリ優先 → アルファベット順
        children = nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
```

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -5
```

期待: BUILD SUCCEEDED

- [ ] **ステップ 3: コミット**

```bash
git add Sources/Panels/FileNode.swift
git commit -m "feat: add FileNode model and GitFileStatus enum for file explorer"
```

---

### タスク 2: FileIconMapper

**ファイル:**
- 新規: `Sources/Panels/FileIconMapper.swift`

- [ ] **ステップ 1: アイコンマッパーを作成**

```swift
// Sources/Panels/FileIconMapper.swift
import Foundation

/// 拡張子からSF Symbolアイコン名を返す。
enum FileIconMapper {
    /// フォルダのデフォルトアイコン
    static let folderIcon = "folder.fill"
    static let folderOpenIcon = "folder.fill" // macOS の SF Symbols には open variant がないので同じ

    /// ファイルのデフォルトアイコン
    static let fileIcon = "doc.fill"

    /// 拡張子 → SF Symbol のマッピング
    private static let extensionMap: [String: String] = [
        // Swift / Apple
        "swift": "swift",
        "xcodeproj": "hammer.fill",
        "xcworkspace": "hammer.fill",
        "plist": "list.bullet.rectangle.fill",
        "storyboard": "rectangle.split.3x3",
        "xib": "rectangle.split.3x3",
        "xcconfig": "gearshape.fill",
        "entitlements": "lock.shield.fill",
        "xcstrings": "globe",

        // Web
        "html": "globe",
        "htm": "globe",
        "css": "paintbrush.fill",
        "js": "curlybraces",
        "jsx": "curlybraces",
        "ts": "curlybraces",
        "tsx": "curlybraces",
        "json": "curlybraces",
        "xml": "chevron.left.forwardslash.chevron.right",
        "svg": "square.and.pencil",

        // Languages
        "py": "terminal.fill",
        "rb": "terminal.fill",
        "go": "terminal.fill",
        "rs": "terminal.fill",
        "c": "terminal.fill",
        "cpp": "terminal.fill",
        "h": "terminal.fill",
        "hpp": "terminal.fill",
        "m": "terminal.fill",
        "mm": "terminal.fill",
        "java": "cup.and.saucer.fill",
        "kt": "terminal.fill",
        "zig": "terminal.fill",

        // Config
        "yaml": "doc.text.fill",
        "yml": "doc.text.fill",
        "toml": "doc.text.fill",
        "ini": "doc.text.fill",
        "cfg": "doc.text.fill",
        "conf": "doc.text.fill",
        "env": "lock.fill",

        // Docs
        "md": "doc.richtext.fill",
        "markdown": "doc.richtext.fill",
        "txt": "doc.text.fill",
        "rtf": "doc.richtext.fill",
        "pdf": "doc.fill",

        // Images
        "png": "photo.fill",
        "jpg": "photo.fill",
        "jpeg": "photo.fill",
        "gif": "photo.fill",
        "webp": "photo.fill",
        "ico": "photo.fill",
        "icns": "photo.fill",

        // Archives
        "zip": "doc.zipper",
        "tar": "doc.zipper",
        "gz": "doc.zipper",
        "dmg": "externaldrive.fill",

        // Git
        "gitignore": "eye.slash.fill",
        "gitmodules": "link",

        // Shell
        "sh": "terminal.fill",
        "bash": "terminal.fill",
        "zsh": "terminal.fill",
        "fish": "terminal.fill",

        // Data
        "db": "cylinder.fill",
        "sqlite": "cylinder.fill",
        "sql": "cylinder.fill",
        "csv": "tablecells.fill",
    ]

    /// 特定のファイル名に対するアイコンマッピング
    private static let filenameMap: [String: String] = [
        "Makefile": "hammer.fill",
        "Dockerfile": "shippingbox.fill",
        "LICENSE": "checkmark.seal.fill",
        "CHANGELOG.md": "clock.fill",
        "README.md": "book.fill",
        "CLAUDE.md": "sparkles",
        "Package.swift": "shippingbox.fill",
        ".gitignore": "eye.slash.fill",
        ".env": "lock.fill",
    ]

    static func icon(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return folderIcon }

        // ファイル名完全一致を先にチェック
        if let icon = filenameMap[url.lastPathComponent] {
            return icon
        }

        // 拡張子マッチ
        let ext = url.pathExtension.lowercased()
        if let icon = extensionMap[ext] {
            return icon
        }

        return fileIcon
    }
}
```

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -5
```

期待: BUILD SUCCEEDED

- [ ] **ステップ 3: コミット**

```bash
git add Sources/Panels/FileIconMapper.swift
git commit -m "feat: add FileIconMapper for file extension to SF Symbol mapping"
```

---

### タスク 3: GitStatusProvider

**ファイル:**
- 新規: `Sources/Panels/GitStatusProvider.swift`

- [ ] **ステップ 1: Git ステータスプロバイダを作成**

```swift
// Sources/Panels/GitStatusProvider.swift
import Foundation

/// git status --porcelain を実行してファイルごとのステータスを返す。
/// バックグラウンドキューで実行し、結果を辞書で返す。
actor GitStatusProvider {
    private let rootPath: String
    private let queue = DispatchQueue(label: "com.cmux.git-status", qos: .utility)

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// git status --porcelain=v1 -z を実行し、
    /// [相対パス: GitFileStatus] の辞書を返す。
    /// Git リポジトリでない場合は空辞書を返す。
    func fetchStatuses() async -> [String: GitFileStatus] {
        await withCheckedContinuation { continuation in
            queue.async { [rootPath] in
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["status", "--porcelain=v1", "-z"]
                process.currentDirectoryURL = URL(fileURLWithPath: rootPath)
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: [:])
                    return
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: [:])
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = Self.parseStatuses(data: data, rootPath: rootPath)
                continuation.resume(returning: result)
            }
        }
    }

    /// git check-ignore -z --stdin にパスのリストを渡して、
    /// 無視されるパスの Set を返す。
    func fetchIgnoredPaths(_ paths: [String]) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [rootPath] in
                let process = Process()
                let outputPipe = Pipe()
                let inputPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["check-ignore", "-z", "--stdin"]
                process.currentDirectoryURL = URL(fileURLWithPath: rootPath)
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = inputPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: [])
                    return
                }

                // NUL 区切りでパスを書き込む
                let input = paths.joined(separator: "\0")
                inputPipe.fileHandleForWriting.write(input.data(using: .utf8) ?? Data())
                inputPipe.fileHandleForWriting.closeFile()
                process.waitUntilExit()

                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let ignoredPaths = Self.parseNulSeparated(data: data)
                    .map { path in
                        if path.hasPrefix("/") { return path }
                        return (rootPath as NSString).appendingPathComponent(path)
                    }
                continuation.resume(returning: Set(ignoredPaths))
            }
        }
    }

    /// --porcelain=v1 -z 出力をパースする。
    /// 形式: XY PATH\0  (リネームの場合: XY ORIG\0DEST\0)
    static func parseStatuses(data: Data, rootPath: String) -> [String: GitFileStatus] {
        guard let string = String(data: data, encoding: .utf8), !string.isEmpty else { return [:] }

        var result: [String: GitFileStatus] = [:]
        let entries = string.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0

        while i < entries.count {
            let entry = entries[i]
            guard entry.count >= 3 else {
                i += 1
                continue
            }

            let statusChars = entry.prefix(2)
            let x = statusChars.first!
            let y = statusChars[statusChars.index(after: statusChars.startIndex)]
            let relativePath = String(entry.dropFirst(3))

            let status = Self.mapStatus(x: x, y: y)
            let absolutePath = (rootPath as NSString).appendingPathComponent(relativePath)
            result[absolutePath] = status

            // リネーム/コピーの場合、次のエントリはリネーム先
            if x == "R" || x == "C" {
                i += 1 // リネーム先のパスをスキップ
            }

            i += 1
        }

        return result
    }

    private static func mapStatus(x: Character, y: Character) -> GitFileStatus {
        // コンフリクト判定
        if (x == "U" || y == "U") || (x == "A" && y == "A") || (x == "D" && y == "D") {
            return .conflicted
        }
        // ワーキングツリー側の変更を優先表示
        switch y {
        case "M": return .modified
        case "D": return .deleted
        case "?": return .untracked
        default: break
        }
        // ステージング側
        switch x {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .modified
        default: return .unmodified
        }
    }

    private static func parseNulSeparated(data: Data) -> [String] {
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        return string.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
}
```

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -5
```

期待: BUILD SUCCEEDED

- [ ] **ステップ 3: コミット**

```bash
git add Sources/Panels/GitStatusProvider.swift
git commit -m "feat: add GitStatusProvider for parsing git status output"
```

---

### タスク 4: PanelType と SurfaceKind の拡張

**ファイル:**
- 変更: `Sources/Panels/Panel.swift:6-10`
- 変更: `Sources/Workspace.swift:5539-5542`

- [ ] **ステップ 1: PanelType に `.fileExplorer` を追加**

`Sources/Panels/Panel.swift` の `PanelType` enum に case を追加:

```swift
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
    case fileExplorer
}
```

- [ ] **ステップ 2: SurfaceKind に fileExplorer を追加**

`Sources/Workspace.swift` の `SurfaceKind` に追加:

```swift
private enum SurfaceKind {
    static let terminal = "terminal"
    static let browser = "browser"
    static let markdown = "markdown"
    static let fileExplorer = "fileExplorer"
}
```

- [ ] **ステップ 3: surfaceKind マッピングを更新**

`Sources/Workspace.swift` で `PanelType` → `SurfaceKind` のマッピング箇所を検索し、`.fileExplorer` case を追加する。該当箇所は `surfaceKind(for:)` のような switch 文:

```swift
case .fileExplorer:
    return SurfaceKind.fileExplorer
```

- [ ] **ステップ 4: ビルド確認**

ビルドすると、PanelType の switch 文が exhaustive でないエラーが複数出るはず。これらは後続タスクで修正する。この時点ではまだビルドが通らなくてもOK。

- [ ] **ステップ 5: コミット**

```bash
git add Sources/Panels/Panel.swift Sources/Workspace.swift
git commit -m "feat: add fileExplorer to PanelType and SurfaceKind enums"
```

---

### タスク 5: FileExplorerPanel（Panel プロトコル実装）

**ファイル:**
- 新規: `Sources/Panels/FileExplorerPanel.swift`

- [ ] **ステップ 1: FileExplorerPanel を作成**

```swift
// Sources/Panels/FileExplorerPanel.swift
import Foundation
import Combine
import CoreServices

/// ファイルエクスプローラーのパネル実装。
/// FSEventStream でファイルシステムを監視し、Git ステータスを表示する。
@MainActor
final class FileExplorerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .fileExplorer

    /// ツリーのルートパス
    @Published var rootPath: String {
        didSet {
            guard rootPath != oldValue else { return }
            displayTitle = (rootPath as NSString).lastPathComponent
            reloadTree()
        }
    }

    @Published private(set) var displayTitle: String = ""
    var displayIcon: String? { "folder.fill" }

    /// ルートノード（UIが監視する）
    @Published private(set) var rootNodes: [FileNode] = []

    /// Git ステータス辞書 [absolutePath: GitFileStatus]
    @Published private(set) var gitStatuses: [String: GitFileStatus] = [:]

    /// 無視パスの Set (gitignore)
    @Published private(set) var ignoredPaths: Set<String> = []

    /// 表示設定
    @Published var showHiddenFiles: Bool = false {
        didSet { reloadTree() }
    }
    @Published var showIgnoredFiles: Bool = false {
        didSet { reloadTree() }
    }

    /// ファイルオープン時の動作設定
    @Published var openAction: FileExplorerOpenAction = .editor

    /// フォーカスフラッシュ用トークン
    @Published private(set) var focusFlashToken: Int = 0

    /// フィルターテキスト
    @Published var filterText: String = ""

    /// ワークスペースID
    private(set) var workspaceId: UUID

    // MARK: - File system watching

    private var fsEventStream: FSEventStreamRef?
    private let gitStatusProvider: GitStatusProvider
    private var gitStatusDebounceTask: Task<Void, Never>?
    private var fsEventDebounceTask: Task<Void, Never>?
    private var isClosed: Bool = false

    // MARK: - Init

    init(workspaceId: UUID, rootPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rootPath = rootPath
        self.displayTitle = (rootPath as NSString).lastPathComponent
        self.gitStatusProvider = GitStatusProvider(rootPath: rootPath)

        reloadTree()
        startFSEventStream()
        refreshGitStatus()
    }

    // MARK: - Panel protocol

    func focus() {
        // NSOutlineView が firstResponder を持つ。
        // FileExplorerOutlineView 側で処理。
    }

    func unfocus() {}

    func close() {
        isClosed = true
        stopFSEventStream()
        gitStatusDebounceTask?.cancel()
        fsEventDebounceTask?.cancel()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Tree loading

    func reloadTree() {
        let rootURL = URL(fileURLWithPath: rootPath)
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else {
            rootNodes = []
            return
        }

        let effectiveIgnored = showIgnoredFiles ? Set<String>() : ignoredPaths

        let nodes = urls.compactMap { childURL -> FileNode? in
            if !showIgnoredFiles && effectiveIgnored.contains(childURL.path) { return nil }
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileNode(url: childURL, isDirectory: isDir)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        // Git ステータスを適用
        for node in nodes {
            node.gitStatus = gitStatuses[node.url.path] ?? .unmodified
        }

        rootNodes = nodes
    }

    /// 展開済みノードの子を再ロードする（FSEvent コールバック用）
    func refreshExpandedNode(_ node: FileNode) {
        let effectiveIgnored = showIgnoredFiles ? Set<String>() : ignoredPaths
        node.loadChildren(showHidden: showHiddenFiles, ignoredPaths: effectiveIgnored)
        // 子に Git ステータスを適用
        for child in node.children ?? [] {
            child.gitStatus = gitStatuses[child.url.path] ?? .unmodified
        }
    }

    // MARK: - Git status

    func refreshGitStatus() {
        gitStatusDebounceTask?.cancel()
        gitStatusDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms デバウンス
            guard let self, !Task.isCancelled else { return }
            let statuses = await gitStatusProvider.fetchStatuses()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.gitStatuses = statuses
                self.applyGitStatusToNodes(self.rootNodes)
            }
        }
    }

    private func applyGitStatusToNodes(_ nodes: [FileNode]) {
        for node in nodes {
            node.gitStatus = gitStatuses[node.url.path] ?? .unmodified
            if let children = node.children {
                applyGitStatusToNodes(children)
            }
        }
    }

    func refreshIgnoredPaths() {
        Task { [weak self] in
            guard let self else { return }
            let rootURL = URL(fileURLWithPath: rootPath)
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: []
            ) else { return }
            let paths = urls.map(\.path)
            let ignored = await gitStatusProvider.fetchIgnoredPaths(paths)
            await MainActor.run {
                self.ignoredPaths = ignored
                if !self.showIgnoredFiles {
                    self.reloadTree()
                }
            }
        }
    }

    // MARK: - FSEventStream

    private func startFSEventStream() {
        let pathsToWatch = [rootPath] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let info = clientCallBackInfo else { return }
            let panel = Unmanaged<FileExplorerPanel>.fromOpaque(info).takeUnretainedValue()
            // FSEvent のコールバックは任意スレッドから来るので MainActor に dispatch
            Task { @MainActor in
                panel.handleFSEvents()
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100ms のレイテンシ（デバウンス）
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func stopFSEventStream() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    private func handleFSEvents() {
        guard !isClosed else { return }
        fsEventDebounceTask?.cancel()
        fsEventDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms デバウンス
            guard let self, !Task.isCancelled else { return }
            self.reloadTree()
            self.refreshGitStatus()
        }
    }

    deinit {
        // FSEventStream は close() で解放済みのはず。念のため。
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// ファイルオープン時の動作
enum FileExplorerOpenAction: String, Codable, Sendable {
    case editor  // $EDITOR でターミナルに開く
    case builtin // Markdown パネル等
    case system  // open コマンド
}
```

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

`NotificationPaneFlashSettings` の参照が解決できるか確認。解決できない場合はプロジェクト内で検索して正しい型名を使用する。

- [ ] **ステップ 3: コミット**

```bash
git add Sources/Panels/FileExplorerPanel.swift
git commit -m "feat: add FileExplorerPanel with FSEventStream and git status integration"
```

---

### タスク 6: FileExplorerDataSource（NSOutlineView の DataSource + Delegate）

**ファイル:**
- 新規: `Sources/Panels/FileExplorerDataSource.swift`

- [ ] **ステップ 1: DataSource + Delegate を作成**

```swift
// Sources/Panels/FileExplorerDataSource.swift
import AppKit
import UniformTypeIdentifiers

/// NSOutlineView 用の DataSource と Delegate を兼ねるクラス。
/// FileExplorerPanel からデータを受け取り、ツリーを描画する。
@MainActor
final class FileExplorerDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

    weak var panel: FileExplorerPanel?

    /// ファイルをダブルクリックしたときのコールバック
    var onFileDoubleClick: ((FileNode) -> Void)?

    /// ノード展開時に子をロードするコールバック
    var onNodeExpand: ((FileNode) -> Void)?

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let panel else { return 0 }
        if let node = item as? FileNode {
            return node.children?.count ?? 0
        }
        return panel.rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let panel else { return NSObject() }
        if let node = item as? FileNode {
            return node.children?[index] ?? NSObject()
        }
        return panel.rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("FileExplorerCell")
        let cell: FileExplorerCellView
        if let reused = outlineView.makeView(withIdentifier: cellId, owner: nil) as? FileExplorerCellView {
            cell = reused
        } else {
            cell = FileExplorerCellView()
            cell.identifier = cellId
        }

        cell.configure(with: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        22
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        if node.children == nil {
            onNodeExpand?(node)
        }
        node.isExpanded = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        node.isExpanded = false
    }

    // MARK: - Drag & Drop (source)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileNode else { return nil }
        return node.url as NSURL
    }

    // MARK: - Drag & Drop (destination)

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // ドロップ先がディレクトリでなければ拒否
        guard let targetNode = item as? FileNode, targetNode.isDirectory else {
            // ルートレベルへのドロップも許可
            if item == nil { return .move }
            return []
        }

        // ドラッグ元のURLを取得
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return []
        }

        // 自分自身の中に移動しようとしている場合は拒否
        for url in urls {
            if targetNode.url.path.hasPrefix(url.path) {
                return []
            }
        }

        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let targetURL: URL
        if let targetNode = item as? FileNode, targetNode.isDirectory {
            targetURL = targetNode.url
        } else {
            guard let panel else { return false }
            targetURL = URL(fileURLWithPath: panel.rootPath)
        }

        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }

        let fm = FileManager.default
        var success = false
        for url in urls {
            let destination = targetURL.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: destination)
                success = true
            } catch {
                NSLog("FileExplorer: Failed to move \(url.lastPathComponent): \(error)")
            }
        }
        return success
    }
}

// MARK: - Cell View

/// ファイルエクスプローラーのセル（1行分のビュー）
final class FileExplorerCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.truncatesLastVisibleLine = true
        addSubview(nameLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.alignment = .right
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -4),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    func configure(with node: FileNode) {
        let iconName = FileIconMapper.icon(for: node.url, isDirectory: node.isDirectory)
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = node.isDirectory ? .systemOrange : .secondaryLabelColor

        nameLabel.stringValue = node.name
        nameLabel.textColor = colorForGitStatus(node.gitStatus)

        let (badge, badgeColor) = badgeForGitStatus(node.gitStatus)
        statusLabel.stringValue = badge
        statusLabel.textColor = badgeColor
    }

    private func colorForGitStatus(_ status: GitFileStatus) -> NSColor {
        switch status {
        case .unmodified: return .labelColor
        case .modified: return .systemYellow
        case .added: return .systemGreen
        case .deleted: return .systemRed
        case .untracked: return .secondaryLabelColor
        case .conflicted: return .systemOrange
        }
    }

    private func badgeForGitStatus(_ status: GitFileStatus) -> (String, NSColor) {
        switch status {
        case .unmodified: return ("", .clear)
        case .modified: return ("M", .systemYellow)
        case .added: return ("A", .systemGreen)
        case .deleted: return ("D", .systemRed)
        case .untracked: return ("?", .secondaryLabelColor)
        case .conflicted: return ("C", .systemOrange)
        }
    }
}
```

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

- [ ] **ステップ 3: コミット**

```bash
git add Sources/Panels/FileExplorerDataSource.swift
git commit -m "feat: add FileExplorerDataSource with drag-and-drop and cell rendering"
```

---

### タスク 7: FileExplorerOutlineView（NSViewRepresentable）

**ファイル:**
- 新規: `Sources/Panels/FileExplorerOutlineView.swift`

- [ ] **ステップ 1: NSViewRepresentable ラッパーを作成**

```swift
// Sources/Panels/FileExplorerOutlineView.swift
import AppKit
import SwiftUI

/// NSOutlineView を SwiftUI に埋め込む NSViewRepresentable。
struct FileExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var panel: FileExplorerPanel
    let onFileOpen: (FileNode) -> Void

    func makeCoordinator() -> FileExplorerDataSource {
        let dataSource = FileExplorerDataSource()
        dataSource.panel = panel
        dataSource.onFileDoubleClick = onFileOpen
        dataSource.onNodeExpand = { [weak panel] node in
            panel?.refreshExpandedNode(node)
        }
        return dataSource
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = 22
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        // ダブルクリックでファイルを開く
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(FileExplorerDataSource.handleDoubleClick(_:))

        // ドラッグ&ドロップ登録
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        // コンテキストメニュー
        outlineView.menu = buildContextMenu(coordinator: context.coordinator)

        scrollView.documentView = outlineView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }
        context.coordinator.panel = panel
        outlineView.reloadData()

        // 展開状態を復元
        restoreExpandedState(outlineView: outlineView, nodes: panel.rootNodes)
    }

    private func restoreExpandedState(outlineView: NSOutlineView, nodes: [FileNode]) {
        for node in nodes {
            if node.isDirectory && node.isExpanded {
                outlineView.expandItem(node)
                if let children = node.children {
                    restoreExpandedState(outlineView: outlineView, nodes: children)
                }
            }
        }
    }

    private func buildContextMenu(coordinator: FileExplorerDataSource) -> NSMenu {
        let menu = NSMenu()

        let newFile = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.newFile", defaultValue: "New File"),
            action: #selector(FileExplorerDataSource.contextNewFile(_:)),
            keyEquivalent: ""
        )
        newFile.target = coordinator
        menu.addItem(newFile)

        let newFolder = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.newFolder", defaultValue: "New Folder"),
            action: #selector(FileExplorerDataSource.contextNewFolder(_:)),
            keyEquivalent: ""
        )
        newFolder.target = coordinator
        menu.addItem(newFolder)

        menu.addItem(.separator())

        let rename = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.rename", defaultValue: "Rename"),
            action: #selector(FileExplorerDataSource.contextRename(_:)),
            keyEquivalent: ""
        )
        rename.target = coordinator
        menu.addItem(rename)

        let delete = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.delete", defaultValue: "Move to Trash"),
            action: #selector(FileExplorerDataSource.contextDelete(_:)),
            keyEquivalent: ""
        )
        delete.target = coordinator
        menu.addItem(delete)

        menu.addItem(.separator())

        let showInFinder = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.showInFinder", defaultValue: "Show in Finder"),
            action: #selector(FileExplorerDataSource.contextShowInFinder(_:)),
            keyEquivalent: ""
        )
        showInFinder.target = coordinator
        menu.addItem(showInFinder)

        let copyPath = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"),
            action: #selector(FileExplorerDataSource.contextCopyPath(_:)),
            keyEquivalent: ""
        )
        copyPath.target = coordinator
        menu.addItem(copyPath)

        return menu
    }
}
```

- [ ] **ステップ 2: FileExplorerDataSource にコンテキストメニューとダブルクリックのアクションを追加**

`Sources/Panels/FileExplorerDataSource.swift` に以下のメソッドを追加:

```swift
// MARK: - Actions

@objc func handleDoubleClick(_ sender: NSOutlineView) {
    let row = sender.clickedRow
    guard row >= 0, let node = sender.item(atRow: row) as? FileNode else { return }
    if node.isDirectory {
        if sender.isItemExpanded(node) {
            sender.collapseItem(node)
        } else {
            sender.expandItem(node)
        }
    } else {
        onFileDoubleClick?(node)
    }
}

// MARK: - Context Menu Actions

private func selectedNode(from sender: Any?) -> FileNode? {
    guard let menuItem = sender as? NSMenuItem,
          let menu = menuItem.menu,
          let outlineView = menu.delegate as? NSOutlineView ?? findOutlineView(for: menu) else { return nil }
    let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
    guard row >= 0 else { return nil }
    return outlineView.item(atRow: row) as? FileNode
}

private func findOutlineView(for menu: NSMenu) -> NSOutlineView? {
    // メニューが表示されている NSOutlineView を探す
    guard let window = NSApp.keyWindow else { return nil }
    return window.contentView?.findSubview(ofType: NSOutlineView.self)
}

@objc func contextNewFile(_ sender: Any?) {
    guard let node = selectedNode(from: sender) else { return }
    let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    let newURL = directory.appendingPathComponent("untitled")
    FileManager.default.createFile(atPath: newURL.path, contents: nil)
}

@objc func contextNewFolder(_ sender: Any?) {
    guard let node = selectedNode(from: sender) else { return }
    let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    let newURL = directory.appendingPathComponent("untitled folder")
    try? FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
}

@objc func contextRename(_ sender: Any?) {
    // TODO: NSOutlineView のインライン編集を開始
    // outlineView.editColumn(0, row: row, with: nil, select: true)
}

@objc func contextDelete(_ sender: Any?) {
    guard let node = selectedNode(from: sender) else { return }
    NSWorkspace.shared.recycle([node.url]) { _, error in
        if let error {
            NSLog("FileExplorer: Failed to trash \(node.name): \(error)")
        }
    }
}

@objc func contextShowInFinder(_ sender: Any?) {
    guard let node = selectedNode(from: sender) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([node.url])
}

@objc func contextCopyPath(_ sender: Any?) {
    guard let node = selectedNode(from: sender) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(node.url.path, forType: .string)
}
```

- [ ] **ステップ 3: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

- [ ] **ステップ 4: コミット**

```bash
git add Sources/Panels/FileExplorerOutlineView.swift Sources/Panels/FileExplorerDataSource.swift
git commit -m "feat: add FileExplorerOutlineView with context menu and drag-and-drop"
```

---

### タスク 8: FileExplorerPanelView（SwiftUI ビュー）

**ファイル:**
- 新規: `Sources/Panels/FileExplorerPanelView.swift`

- [ ] **ステップ 1: パネルビューを作成**

```swift
// Sources/Panels/FileExplorerPanelView.swift
import AppKit
import SwiftUI

/// ファイルエクスプローラーパネルの SwiftUI ビュー。
/// ツールバー（パス表示 + フィルター + メニュー）と NSOutlineView を含む。
struct FileExplorerPanelView: View {
    @ObservedObject var panel: FileExplorerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // ツールバー
            toolbar
            Divider()

            // ファイルツリー
            FileExplorerOutlineView(
                panel: panel,
                onFileOpen: { node in
                    openFile(node)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // ルートパス表示（クリックで変更）
            Button(action: changeRootPath) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 11))
                    Text(abbreviatedPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // フィルター
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                TextField(
                    String(localized: "fileExplorer.filter.placeholder", defaultValue: "Filter..."),
                    text: $panel.filterText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: 140)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(colorScheme == .dark
                        ? Color(nsColor: NSColor(white: 0.2, alpha: 1))
                        : Color(nsColor: NSColor(white: 0.92, alpha: 1)))
            )

            // メニューボタン
            Menu {
                Toggle(
                    String(localized: "fileExplorer.menu.showHidden", defaultValue: "Show Hidden Files"),
                    isOn: $panel.showHiddenFiles
                )
                Toggle(
                    String(localized: "fileExplorer.menu.showIgnored", defaultValue: "Show Ignored Files"),
                    isOn: $panel.showIgnoredFiles
                )
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private var abbreviatedPath: String {
        let path = panel.rootPath
        if let home = ProcessInfo.processInfo.environment["HOME"], path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    private func changeRootPath() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = URL(fileURLWithPath: panel.rootPath)
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                panel.rootPath = url.path
            }
        }
    }

    private func openFile(_ node: FileNode) {
        switch panel.openAction {
        case .system:
            NSWorkspace.shared.open(node.url)
        case .builtin:
            // Markdown ファイルの場合は Markdown パネルで開く。
            // それ以外は system にフォールバック。
            if node.url.pathExtension.lowercased() == "md" || node.url.pathExtension.lowercased() == "markdown" {
                // Workspace 経由で Markdown パネルを開く（後で統合時に接続）
                NSWorkspace.shared.open(node.url)
            } else {
                NSWorkspace.shared.open(node.url)
            }
        case .editor:
            // $EDITOR でターミナルに開く（後で統合時に接続）
            NSWorkspace.shared.open(node.url)
        }
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        }
    }
}
```

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

- [ ] **ステップ 3: コミット**

```bash
git add Sources/Panels/FileExplorerPanelView.swift
git commit -m "feat: add FileExplorerPanelView with toolbar and file open actions"
```

---

### タスク 9: PanelContentView ルーティング追加

**ファイル:**
- 変更: `Sources/Panels/PanelContentView.swift:48-58`

- [ ] **ステップ 1: fileExplorer case をルーティングに追加**

`PanelContentView.swift` の `body` 内の switch 文の `.markdown` case の後に追加:

```swift
case .fileExplorer:
    if let fileExplorerPanel = panel as? FileExplorerPanel {
        FileExplorerPanelView(
            panel: fileExplorerPanel,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
```

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

- [ ] **ステップ 3: コミット**

```bash
git add Sources/Panels/PanelContentView.swift
git commit -m "feat: add fileExplorer routing to PanelContentView"
```

---

### タスク 10: Workspace にパネル作成メソッドを追加

**ファイル:**
- 変更: `Sources/Workspace.swift`

- [ ] **ステップ 1: newFileExplorerSplit と newFileExplorerSurface を追加**

`Sources/Workspace.swift` の `newMarkdownSurface` メソッドの後あたりに追加。既存の `newMarkdownSplit` / `newMarkdownSurface` のパターンに従う:

```swift
// MARK: - File Explorer panels

func newFileExplorerSplit(
    from panelId: UUID,
    orientation: SplitOrientation,
    insertFirst: Bool = false,
    rootPath: String? = nil,
    focus: Bool = true
) -> FileExplorerPanel? {
    guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
    var sourcePaneId: PaneID?
    for paneId in bonsplitController.allPaneIds {
        let tabs = bonsplitController.tabs(inPane: paneId)
        if tabs.contains(where: { $0.id == sourceTabId }) {
            sourcePaneId = paneId
            break
        }
    }

    guard let paneId = sourcePaneId else { return nil }

    let effectiveRootPath = rootPath ?? currentDirectory ?? NSHomeDirectory()
    let fileExplorerPanel = FileExplorerPanel(workspaceId: id, rootPath: effectiveRootPath)
    panels[fileExplorerPanel.id] = fileExplorerPanel
    panelTitles[fileExplorerPanel.id] = fileExplorerPanel.displayTitle

    let newTab = Bonsplit.Tab(
        title: fileExplorerPanel.displayTitle,
        icon: fileExplorerPanel.displayIcon,
        kind: SurfaceKind.fileExplorer,
        isDirty: fileExplorerPanel.isDirty,
        isLoading: false,
        isPinned: false
    )

    guard let splitResult = bonsplitController.splitPane(
        paneId,
        orientation: orientation,
        with: newTab,
        insertFirst: insertFirst
    ) else {
        panels.removeValue(forKey: fileExplorerPanel.id)
        panelTitles.removeValue(forKey: fileExplorerPanel.id)
        return nil
    }

    surfaceIdToPanelId[splitResult.newTabId] = fileExplorerPanel.id
    if focus {
        bonsplitController.focusPane(splitResult.newPaneId)
        bonsplitController.selectTab(splitResult.newTabId)
    }
    return fileExplorerPanel
}

func newFileExplorerSurface(
    inPane paneId: PaneID,
    rootPath: String? = nil,
    focus: Bool? = nil
) -> FileExplorerPanel? {
    let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
    let previousFocusedPanelId = focusedPanelId
    let previousHostedView = focusedTerminalPanel?.hostedView

    let effectiveRootPath = rootPath ?? currentDirectory ?? NSHomeDirectory()
    let fileExplorerPanel = FileExplorerPanel(workspaceId: id, rootPath: effectiveRootPath)
    panels[fileExplorerPanel.id] = fileExplorerPanel
    panelTitles[fileExplorerPanel.id] = fileExplorerPanel.displayTitle

    guard let newTabId = bonsplitController.createTab(
        title: fileExplorerPanel.displayTitle,
        icon: fileExplorerPanel.displayIcon,
        kind: SurfaceKind.fileExplorer,
        isDirty: fileExplorerPanel.isDirty,
        isLoading: false,
        isPinned: false,
        inPane: paneId
    ) else {
        panels.removeValue(forKey: fileExplorerPanel.id)
        panelTitles.removeValue(forKey: fileExplorerPanel.id)
        return nil
    }

    surfaceIdToPanelId[newTabId] = fileExplorerPanel.id
    if shouldFocusNewTab {
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(newTabId)
    }
    return fileExplorerPanel
}
```

- [ ] **ステップ 2: createPanel の switch に `.fileExplorer` を追加**

`Sources/Workspace.swift` の `createPanel(from:inPane:)` メソッド（600行目付近）の `.markdown` case の後に追加:

```swift
case .fileExplorer:
    guard let rootPath = snapshot.fileExplorer?.rootPath ?? snapshot.directory,
          let fileExplorerPanel = newFileExplorerSurface(
            inPane: paneId,
            rootPath: rootPath,
            focus: false
          ) else {
        return nil
    }
    // セッション復元: 展開状態と設定を復元
    if let feSnapshot = snapshot.fileExplorer {
        fileExplorerPanel.showHiddenFiles = feSnapshot.showHiddenFiles
        fileExplorerPanel.showIgnoredFiles = feSnapshot.showIgnoredFiles
        if let action = FileExplorerOpenAction(rawValue: feSnapshot.openAction) {
            fileExplorerPanel.openAction = action
        }
    }
    applySessionPanelMetadata(snapshot, toPanelId: fileExplorerPanel.id)
    return fileExplorerPanel.id
```

- [ ] **ステップ 3: surfaceKind マッピングに `.fileExplorer` を追加**

`Sources/Workspace.swift` で `PanelType` → `SurfaceKind` をマッピングしている switch 文（6045行目付近）を修正。すべての `PanelType` の switch 文に `.fileExplorer` case を追加:

```swift
case .fileExplorer:
    return SurfaceKind.fileExplorer
```

- [ ] **ステップ 4: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

他の PanelType switch 文で exhaustive エラーが残っていれば修正する。`Sources/Workspace.swift` 全体で `case .markdown` を検索し、近くに switch 文がある箇所すべてに `.fileExplorer` case を追加する。

- [ ] **ステップ 5: コミット**

```bash
git add Sources/Workspace.swift
git commit -m "feat: add file explorer panel creation and session restore to Workspace"
```

---

### タスク 11: セッション永続化

**ファイル:**
- 変更: `Sources/SessionPersistence.swift:239-257`
- 変更: `Sources/Panels/Panel.swift:6-10` (タスク4で完了済み)

- [ ] **ステップ 1: SessionFileExplorerPanelSnapshot を追加**

`Sources/SessionPersistence.swift` の `SessionMarkdownPanelSnapshot` の後に追加:

```swift
struct SessionFileExplorerPanelSnapshot: Codable, Sendable {
    var rootPath: String
    var expandedPaths: [String]
    var selectedPath: String?
    var showHiddenFiles: Bool
    var showIgnoredFiles: Bool
    var openAction: String  // FileExplorerOpenAction.rawValue
}
```

- [ ] **ステップ 2: SessionPanelSnapshot に fileExplorer フィールドを追加**

`Sources/SessionPersistence.swift` の `SessionPanelSnapshot` に追加:

```swift
struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
    var fileExplorer: SessionFileExplorerPanelSnapshot?  // ← 追加
}
```

- [ ] **ステップ 3: スナップショット生成コードを検索して `.fileExplorer` case を追加**

`Sources/Workspace.swift` でスナップショットを生成している箇所（`SessionPanelSnapshot` を作成している箇所）を検索し、`.fileExplorer` の場合にスナップショットデータを生成するコードを追加:

```swift
case .fileExplorer:
    if let fePanel = panel as? FileExplorerPanel {
        panelSnapshot.fileExplorer = SessionFileExplorerPanelSnapshot(
            rootPath: fePanel.rootPath,
            expandedPaths: collectExpandedPaths(fePanel.rootNodes),
            selectedPath: nil,
            showHiddenFiles: fePanel.showHiddenFiles,
            showIgnoredFiles: fePanel.showIgnoredFiles,
            openAction: fePanel.openAction.rawValue
        )
    }
```

展開パスを収集するヘルパー:

```swift
private func collectExpandedPaths(_ nodes: [FileNode]) -> [String] {
    var paths: [String] = []
    for node in nodes where node.isDirectory && node.isExpanded {
        paths.append(node.url.path)
        if let children = node.children {
            paths.append(contentsOf: collectExpandedPaths(children))
        }
    }
    return paths
}
```

- [ ] **ステップ 4: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

- [ ] **ステップ 5: コミット**

```bash
git add Sources/SessionPersistence.swift Sources/Workspace.swift
git commit -m "feat: add file explorer session persistence and snapshot generation"
```

---

### タスク 12: コマンドパレットとキーボードショートカット

**ファイル:**
- 変更: `Sources/ContentView.swift:4997-5017`

- [ ] **ステップ 1: コマンドパレットの kindLabel と keywords に `.fileExplorer` を追加**

`Sources/ContentView.swift` の `commandPaletteSurfaceKindLabel` メソッド（4997行目）の switch に追加:

```swift
case .fileExplorer:
    return String(localized: "commandPalette.kind.fileExplorer", defaultValue: "File Explorer")
```

同じく `commandPaletteSurfaceKeywords` メソッド（5008行目）の switch に追加:

```swift
case .fileExplorer:
    return ["file", "explorer", "files", "tree", "folder", "browse"]
```

- [ ] **ステップ 2: ContentView 内の他の PanelType switch 文を修正**

`Sources/ContentView.swift` 全体で `case .markdown` を検索し、PanelType の switch 文すべてに `.fileExplorer` case を追加する。多くの場合、`.markdown` と同じ動作か、空の case で十分。

- [ ] **ステップ 3: キーボードショートカット (Cmd+Shift+E) を追加**

`Sources/ContentView.swift` でキーボードショートカットが登録されている箇所を検索し、ファイルエクスプローラーを開くショートカットを追加する。既存のパネル作成ショートカットのパターンに従う。

- [ ] **ステップ 4: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -20
```

期待: BUILD SUCCEEDED（すべての PanelType switch 文が exhaustive になっていること）

- [ ] **ステップ 5: コミット**

```bash
git add Sources/ContentView.swift
git commit -m "feat: add file explorer to command palette and Cmd+Shift+E shortcut"
```

---

### タスク 13: ローカライゼーション

**ファイル:**
- 変更: `Resources/Localizable.xcstrings`

- [ ] **ステップ 1: ローカライゼーションキーを追加**

以下のキーを `Resources/Localizable.xcstrings` に追加。英語と日本語の両方:

| キー | 英語 | 日本語 |
|------|------|--------|
| `commandPalette.kind.fileExplorer` | File Explorer | ファイルエクスプローラー |
| `fileExplorer.filter.placeholder` | Filter... | フィルター... |
| `fileExplorer.menu.showHidden` | Show Hidden Files | 隠しファイルを表示 |
| `fileExplorer.menu.showIgnored` | Show Ignored Files | 無視ファイルを表示 |
| `fileExplorer.contextMenu.newFile` | New File | 新規ファイル |
| `fileExplorer.contextMenu.newFolder` | New Folder | 新規フォルダ |
| `fileExplorer.contextMenu.rename` | Rename | 名前を変更 |
| `fileExplorer.contextMenu.delete` | Move to Trash | ゴミ箱に入れる |
| `fileExplorer.contextMenu.showInFinder` | Show in Finder | Finder で表示 |
| `fileExplorer.contextMenu.copyPath` | Copy Path | パスをコピー |

- [ ] **ステップ 2: ビルド確認**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer build 2>&1 | tail -5
```

- [ ] **ステップ 3: コミット**

```bash
git add Resources/Localizable.xcstrings
git commit -m "feat: add localization strings for file explorer (en + ja)"
```

---

### タスク 14: 最終ビルド確認とスモークテスト

- [ ] **ステップ 1: クリーンビルド**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-file-explorer clean build 2>&1 | tail -20
```

期待: BUILD SUCCEEDED

- [ ] **ステップ 2: タグ付きビルドで動作確認**

```bash
./scripts/reload.sh --tag file-explorer
```

ユーザーにアプリを開いてもらい、以下を手動確認:
1. Cmd+Shift+E でファイルエクスプローラーが開く
2. フォルダの展開/折りたたみが動く
3. Git ステータスの色分けが表示される
4. 右クリックメニューが表示される
5. ファイルのダブルクリックで開ける
6. フィルターが動く

- [ ] **ステップ 3: コミット（必要に応じてバグ修正）**

```bash
git add -A
git commit -m "fix: resolve build issues and polish file explorer panel"
```

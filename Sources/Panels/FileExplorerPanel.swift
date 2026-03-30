import Foundation
import Combine
import CoreServices

// MARK: - Weak (FSEventStream callback helper)

/// Weak wrapper for FSEventStream C callback context.
private final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - FileExplorerPanel

/// A panel that displays a file explorer tree for a given directory.
/// Watches the directory for changes via FSEventStream and reflects git status.
@MainActor
final class FileExplorerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .fileExplorer

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    // MARK: - Published properties

    /// Absolute path to the root directory being displayed.
    @Published var rootPath: String {
        didSet {
            displayTitle = (rootPath as NSString).lastPathComponent
            reloadTree()
        }
    }

    /// Title shown in the tab bar (directory name).
    @Published private(set) var displayTitle: String

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "folder.fill" }

    /// Top-level file nodes in the tree.
    @Published private(set) var rootNodes: [FileNode] = []

    /// Git status keyed by absolute file path.
    @Published private(set) var gitStatuses: [String: GitFileStatus] = [:]

    /// Set of absolute paths that are git-ignored.
    @Published private(set) var ignoredPaths: Set<String> = []

    /// Directory paths that should be auto-expanded because they contain git-changed files.
    @Published private(set) var gitAutoExpandPaths: Set<String> = []

    /// Directory paths the user has manually collapsed — auto-expand will not override these.
    var userCollapsedPaths: Set<String> = []

    /// Whether to show files whose names start with `.`.
    @Published var showHiddenFiles: Bool = true {
        didSet { reloadTree() }
    }

    /// Whether to show git-ignored files.
    @Published var showIgnoredFiles: Bool = false {
        didSet { reloadTree() }
    }


    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Text used to filter the file list.
    @Published var filterText: String = "" {
        didSet { reloadTree() }
    }

    /// When true, rootPath follows the active terminal's CWD (resolved to git repo root).
    @Published var followsActiveTerminal: Bool = true

    // MARK: - Internal state

    private var isClosed: Bool = false
    private var gitStatusProvider: GitStatusProvider?
    private var directorySubscription: AnyCancellable?

    // FSEventStream — nonisolated(unsafe) because the stream may be stopped from deinit
    // which is not guaranteed to run on the main actor, but FSEventStreamStop/Invalidate/Release
    // are safe to call from any thread.
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?
    private let fsEventQueue = DispatchQueue(label: "com.cmux.file-explorer-fsevents", qos: .utility)

    // Debounce work items
    private var fsEventDebounceWork: DispatchWorkItem?

    // Git status throttle — serializes git status calls instead of debouncing.
    // At most one git status runs at a time; if a request arrives during execution,
    // a single pending re-run is scheduled after completion.
    private var gitStatusRunning = false
    private var gitStatusPending = false

    // .git/index watcher — fires on git add, commit, checkout, reset, stash, etc.
    private var gitIndexWatcher: FileWatcherHelper?

    // Burst-deferral flags — set to true when a refresh is skipped during a typing burst
    private var gitStatusDeferredDuringBurst = false
    private var fsEventsDeferredDuringBurst = false
    private var burstEndObserver: NSObjectProtocol?

    // Inline editing state — suppresses tree reloads while the user is renaming a file.
    var isEditing: Bool = false
    private var reloadDeferredDuringEditing = false

    // Async task handles
    private var gitStatusTask: Task<Void, Never>?
    private var ignoredPathsTask: Task<Void, Never>?

    // MARK: - Init

    /// Generation counter incremented each time rootNodes changes.
    /// Used by the outline view to avoid unnecessary reloads.
    @Published private(set) var treeGeneration: Int = 0

    /// Generation counter incremented when only git statuses change (no structural tree change).
    /// The outline view uses this to reconfigure visible cells without a full reloadData.
    @Published private(set) var gitStatusGeneration: Int = 0

    init(workspaceId: UUID, rootPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId

        // Resolve to git repo root if possible
        let resolvedRoot = Self.gitRepoRoot(for: rootPath) ?? rootPath
        self.rootPath = resolvedRoot
        self.displayTitle = (resolvedRoot as NSString).lastPathComponent

        let provider = GitStatusProvider(rootPath: resolvedRoot)
        self.gitStatusProvider = provider

        reloadTree()
        startFSEventStream()
        startGitIndexWatcher()
        refreshIgnoredPaths()
        refreshGitStatus()

        burstEndObserver = NotificationCenter.default.addObserver(
            forName: TypingBurstTracker.burstDidEndNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isClosed else { return }
            if self.fsEventsDeferredDuringBurst {
                self.fsEventsDeferredDuringBurst = false
                self.reloadTree()
            }
            if self.gitStatusDeferredDuringBurst {
                self.gitStatusDeferredDuringBurst = false
                self.refreshGitStatus()
            }
        }
    }

    /// Bind the file explorer to a workspace's currentDirectory so it follows
    /// the active terminal's CWD (resolved to git repo root).
    func bindToWorkspaceDirectory(_ workspace: Workspace) {
        directorySubscription?.cancel()
        directorySubscription = workspace.$currentDirectory
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] newDirectory in
                guard let self, self.followsActiveTerminal, !self.isClosed else { return }
                guard !newDirectory.isEmpty else { return }
                let currentRoot = self.rootPath
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let newRoot = Self.gitRepoRoot(for: newDirectory) ?? newDirectory
                    guard newRoot != currentRoot else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isClosed else { return }
                        guard newRoot != self.rootPath else { return }
                        self.updateRoot(newRoot)
                    }
                }
            }
    }

    /// Update root path and restart FS watching + git status.
    private func updateRoot(_ newRoot: String) {
        stopFSEventStream()
        gitIndexWatcher?.stop()
        rootPath = newRoot
        gitStatusProvider = GitStatusProvider(rootPath: newRoot)
        startFSEventStream()
        startGitIndexWatcher()
        refreshIgnoredPaths()
        refreshGitStatus()
    }

    /// Returns the git repository root for the given path, or nil if not in a git repo.
    private static func gitRepoRoot(for path: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        return output
    }

    // MARK: - Panel protocol

    func focus() {
        // NSOutlineView handles focus — no-op here.
    }

    func unfocus() {
        // No-op.
    }

    func close() {
        isClosed = true
        directorySubscription?.cancel()
        directorySubscription = nil
        if let observer = burstEndObserver {
            NotificationCenter.default.removeObserver(observer)
            burstEndObserver = nil
        }
        stopFSEventStream()
        gitIndexWatcher?.stop()
        gitIndexWatcher = nil
        fsEventDebounceWork?.cancel()
        gitStatusTask?.cancel()
        ignoredPathsTask?.cancel()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    /// Called when inline editing ends. Flushes any deferred tree reloads.
    func endEditing() {
        isEditing = false
        if reloadDeferredDuringEditing {
            reloadDeferredDuringEditing = false
            reloadTree()
            refreshGitStatus()
        }
    }

    // MARK: - File tree

    /// Structural fingerprint of the current tree — used to skip full reloads
    /// when the file list hasn't actually changed (only file contents modified).
    private var treeFingerprint: [String] = []

    /// Reloads the root-level nodes from the filesystem.
    func reloadTree() {
        if isEditing {
            reloadDeferredDuringEditing = true
            return
        }
        let rootURL = URL(fileURLWithPath: rootPath)
        let rootNode = FileNode(url: rootURL, name: (rootPath as NSString).lastPathComponent, isDirectory: true)
        rootNode.loadChildren(showHidden: showHiddenFiles, ignoredPaths: showIgnoredFiles ? [] : ignoredPaths)

        var nodes = rootNode.children ?? []

        // Apply filter
        let filter = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !filter.isEmpty {
            nodes = Self.filterNodes(nodes, matching: filter)
        }

        // Build structural fingerprint: sorted paths of all loaded nodes.
        // If the structure hasn't changed, skip the expensive full reload.
        let newFingerprint = buildFingerprint(nodes)
        if newFingerprint == treeFingerprint {
            // Structure unchanged — refresh git statuses on existing nodes
            if !gitStatuses.isEmpty {
                applyGitStatuses(gitStatuses, to: rootNodes)
                gitAutoExpandPaths = computeAutoExpandPaths(statuses: gitStatuses)
                gitStatusGeneration += 1
            }
            return
        }
        treeFingerprint = newFingerprint

        rootNodes = nodes
        if !gitStatuses.isEmpty {
            applyGitStatuses(gitStatuses, to: rootNodes)
        }
        gitAutoExpandPaths = computeAutoExpandPaths(statuses: gitStatuses)
        treeGeneration += 1
    }

    /// Builds a flat list of path strings from loaded nodes for structural comparison.
    private func buildFingerprint(_ nodes: [FileNode]) -> [String] {
        var paths: [String] = []
        appendFingerprint(nodes, to: &paths)
        return paths
    }

    private func appendFingerprint(_ nodes: [FileNode], to paths: inout [String]) {
        for node in nodes {
            paths.append(node.url.path)
            // Include children of previously-expanded directories
            // so changes inside them are detected.
            if node.isDirectory, let existing = existingNode(for: node.url),
               existing.isExpanded {
                // Load children from disk so the fingerprint reflects current state
                if node.children == nil {
                    node.loadChildren(showHidden: showHiddenFiles, ignoredPaths: showIgnoredFiles ? [] : ignoredPaths)
                }
                if let children = node.children {
                    appendFingerprint(children, to: &paths)
                }
            }
        }
    }

    /// Recursively filter nodes, keeping directories that contain matching descendants.
    private static func filterNodes(_ nodes: [FileNode], matching filter: String) -> [FileNode] {
        var result: [FileNode] = []
        for node in nodes {
            if node.name.lowercased().contains(filter) {
                result.append(node)
            } else if node.isDirectory, let children = node.children {
                let filtered = filterNodes(children, matching: filter)
                if !filtered.isEmpty {
                    node.children = filtered
                    result.append(node)
                }
            }
        }
        return result
    }

    /// Find the existing node in the current tree by URL path.
    private func existingNode(for url: URL) -> FileNode? {
        return findNode(in: rootNodes, path: url.path)
    }

    private func findNode(in nodes: [FileNode], path: String) -> FileNode? {
        for node in nodes {
            if node.url.path == path { return node }
            if node.isDirectory, let children = node.children {
                if let found = findNode(in: children, path: path) { return found }
            }
        }
        return nil
    }

    /// Loads children for a node on first expand. Skips if already loaded —
    /// FSEvents triggers full reloadTree() when directory contents change on disk.
    func refreshExpandedNode(_ node: FileNode) {
        if node.children == nil {
            node.loadChildren(showHidden: showHiddenFiles, ignoredPaths: showIgnoredFiles ? [] : ignoredPaths)
            applyGitStatuses(gitStatuses, to: node.children ?? [])
        }
    }

    /// Applies a git status dictionary to nodes, recursing into expanded children.
    /// Directories inherit the most significant status from their descendants.
    private func applyGitStatuses(_ statuses: [String: GitFileStatus], to nodes: [FileNode]) {
        // Precompute ignored directory prefixes for ancestor checks
        let ignoredPrefixes = statuses.compactMap { (path, status) -> String? in
            guard status == .ignored else { return nil }
            return path + "/"
        }
        for node in nodes {
            applyGitStatusRecursive(node, statuses: statuses, ignoredPrefixes: ignoredPrefixes)
        }
    }

    private func applyGitStatusRecursive(
        _ node: FileNode,
        statuses: [String: GitFileStatus],
        ignoredPrefixes: [String]
    ) {
        let path = node.url.path

        if node.isDirectory {
            // Check if this directory itself is ignored
            if statuses[path] == .ignored {
                node.gitStatus = .ignored
                // Mark all loaded children as ignored too
                if let children = node.children {
                    for child in children { child.gitStatus = .ignored }
                }
                return
            }

            // Directories stay unmodified — individual files show their own status
            node.gitStatus = .unmodified

            if let children = node.children {
                for child in children {
                    applyGitStatusRecursive(child, statuses: statuses, ignoredPrefixes: ignoredPrefixes)
                }
            }
        } else {
            if let status = statuses[path] {
                node.gitStatus = status
            } else {
                // Check if under an ignored directory
                let isIgnored = ignoredPrefixes.contains { path.hasPrefix($0) }
                node.gitStatus = isIgnored ? .ignored : .unmodified
            }
        }
    }

    /// Computes directory paths that should be auto-expanded because they contain
    /// files with non-trivial git status (modified, added, deleted, etc.).
    private func computeAutoExpandPaths(statuses: [String: GitFileStatus]) -> Set<String> {
        let rootPrefix = rootPath + "/"
        var paths = Set<String>()

        for (filePath, status) in statuses {
            guard status != .unmodified && status != .ignored else { continue }
            guard filePath.hasPrefix(rootPrefix) else { continue }

            // Walk up from the file's parent to the root, adding each directory
            var current = (filePath as NSString).deletingLastPathComponent
            while current.count > rootPath.count, current.hasPrefix(rootPrefix) {
                paths.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }

        return paths
    }

    /// Priority order for git statuses — higher means more significant.
    private static func statusPriority(_ status: GitFileStatus) -> Int {
        switch status {
        case .unmodified: return 0
        case .ignored:    return 1
        case .untracked:  return 2
        case .added:      return 3
        case .deleted:    return 4
        case .modified:   return 5
        case .conflicted: return 6
        }
    }

    // MARK: - Git status (throttle)

    /// Requests a git status refresh. Serialized: at most one `git status`
    /// process runs at a time. If called while one is already running, a
    /// single re-run is scheduled after completion. This avoids piling up
    /// redundant git processes while staying responsive.
    func refreshGitStatus() {
        if TypingBurstTracker.shared.isBurstingUnchecked {
            gitStatusDeferredDuringBurst = true
            return
        }
        if gitStatusRunning {
            gitStatusPending = true
            return
        }
        gitStatusRunning = true
        gitStatusTask?.cancel()
        gitStatusTask = Task { @MainActor in
            await self.performGitStatusRefresh()
        }
    }

    private func performGitStatusRefresh() async {
        guard !isClosed, let provider = gitStatusProvider else {
            gitStatusRunning = false
            return
        }
        let statuses = await provider.fetchStatuses()
        guard !isClosed else {
            gitStatusRunning = false
            return
        }
        gitStatuses = statuses
        applyGitStatuses(statuses, to: rootNodes)
        gitAutoExpandPaths = computeAutoExpandPaths(statuses: statuses)
        if isEditing {
            reloadDeferredDuringEditing = true
        } else {
            // Only bump gitStatusGeneration — no structural tree change,
            // so the outline view can reconfigure cells without full reloadData.
            gitStatusGeneration += 1
        }

        // Throttle drain: if another request arrived while running, re-run once.
        gitStatusRunning = false
        if gitStatusPending {
            gitStatusPending = false
            refreshGitStatus()
        }
    }

    /// Asynchronously refreshes the set of git-ignored paths.
    func refreshIgnoredPaths() {
        ignoredPathsTask?.cancel()
        ignoredPathsTask = Task { @MainActor in
            await self.performIgnoredPathsRefresh()
        }
    }

    private func performIgnoredPathsRefresh() async {
        guard !isClosed, let provider = gitStatusProvider else { return }

        // Gather immediate children to check for ignored status
        let rootURL = URL(fileURLWithPath: rootPath)
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [])) ?? []
        let paths = contents.map { $0.path }

        let ignored = await provider.fetchIgnoredPaths(paths)
        guard !isClosed, !Task.isCancelled else { return }
        ignoredPaths = ignored

        // If we're hiding ignored files, reload the tree to apply the new filter
        if !showIgnoredFiles {
            reloadTree()
        }
    }

    // MARK: - FSEventStream

    func startFSEventStream() {
        guard eventStream == nil else { return }

        let pathsToWatch = [rootPath] as CFArray
        let latency: CFTimeInterval = 0.3

        // Use a weak wrapper instead of retaining self directly.
        let weak = Weak(self)
        let ref = Unmanaged.passRetained(weak).toOpaque()

        var context = FSEventStreamContext(
            version: 0,
            info: ref,
            retain: nil,
            release: { ptr in
                if let ptr { Unmanaged<Weak<FileExplorerPanel>>.fromOpaque(ptr).release() }
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let weak = Unmanaged<Weak<FileExplorerPanel>>.fromOpaque(info).takeUnretainedValue()
            guard let panel = weak.value else { return }
            DispatchQueue.main.async { [weak panel] in
                panel?.handleFSEvents()
            }
        }

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, fsEventQueue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    func stopFSEventStream() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    /// Debounced handler for FSEvent callbacks.
    /// Reloads the file tree and refreshes git status for working-tree changes.
    func handleFSEvents() {
        if TypingBurstTracker.shared.isBurstingUnchecked {
            fsEventsDeferredDuringBurst = true
            return
        }
        fsEventDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            self.reloadTree()
            self.refreshGitStatus()
            self.refreshIgnoredPaths()
        }
        fsEventDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Git index watcher

    /// Watches `.git/index` with a DispatchSource for immediate git-operation
    /// detection. Fires on git add, commit, checkout, reset, stash, merge, etc.
    private func startGitIndexWatcher() {
        gitIndexWatcher?.stop()
        let indexPath = rootPath + "/.git/index"
        guard FileManager.default.fileExists(atPath: indexPath) else { return }

        let watcher = FileWatcherHelper(
            onChange: { [weak self] changeKind in
                guard let self, !self.isClosed else { return }
                // Route through the same debounced handler as FSEvents
                // to avoid double git status calls.
                self.handleFSEvents()
                if case .deletedOrRenamed = changeKind {
                    self.gitIndexWatcher?.reattach()
                }
            },
            onReattach: { [weak self] in
                guard let self, !self.isClosed else { return }
                self.handleFSEvents()
            }
        )
        self.gitIndexWatcher = watcher
        watcher.start(filePath: indexPath)
    }

    // MARK: - Deinit

    deinit {
        // FSEventStream stop/invalidate/release are thread-safe.
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

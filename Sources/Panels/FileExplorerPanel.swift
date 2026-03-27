import Foundation
import Combine
import CoreServices

// MARK: - FileExplorerOpenAction

enum FileExplorerOpenAction: String, Codable, Sendable {
    case editor
    case builtin
    case system
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

    /// Whether to show files whose names start with `.`.
    @Published var showHiddenFiles: Bool = true {
        didSet { reloadTree() }
    }

    /// Whether to show git-ignored files.
    @Published var showIgnoredFiles: Bool = false {
        didSet { reloadTree() }
    }

    /// What happens when the user opens a file in the explorer.
    @Published var openAction: FileExplorerOpenAction = .editor

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Text used to filter the file list.
    @Published var filterText: String = ""

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
    private var gitStatusDebounceWork: DispatchWorkItem?

    // Async task handles
    private var gitStatusTask: Task<Void, Never>?
    private var ignoredPathsTask: Task<Void, Never>?

    // MARK: - Init

    /// Generation counter incremented each time rootNodes changes.
    /// Used by the outline view to avoid unnecessary reloads.
    @Published private(set) var treeGeneration: Int = 0

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
        refreshIgnoredPaths()
        refreshGitStatus()
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
        rootPath = newRoot
        gitStatusProvider = GitStatusProvider(rootPath: newRoot)
        startFSEventStream()
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
        stopFSEventStream()
        fsEventDebounceWork?.cancel()
        gitStatusDebounceWork?.cancel()
        gitStatusTask?.cancel()
        ignoredPathsTask?.cancel()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File tree

    /// Reloads the root-level nodes from the filesystem.
    func reloadTree() {
        let rootURL = URL(fileURLWithPath: rootPath)
        let rootNode = FileNode(url: rootURL, name: (rootPath as NSString).lastPathComponent, isDirectory: true)
        rootNode.loadChildren(showHidden: showHiddenFiles, ignoredPaths: showIgnoredFiles ? [] : ignoredPaths)

        let nodes = rootNode.children ?? []
        rootNodes = nodes
        applyGitStatuses(gitStatuses, to: rootNodes)
        treeGeneration += 1
    }

    /// Reloads children for a specific node (e.g., when it is expanded).
    func refreshExpandedNode(_ node: FileNode) {
        node.loadChildren(showHidden: showHiddenFiles, ignoredPaths: showIgnoredFiles ? [] : ignoredPaths)
        applyGitStatuses(gitStatuses, to: node.children ?? [])
    }

    /// Applies a git status dictionary to a flat array of nodes (non-recursive, top-level only).
    private func applyGitStatuses(_ statuses: [String: GitFileStatus], to nodes: [FileNode]) {
        for node in nodes {
            if let status = statuses[node.url.path] {
                node.gitStatus = status
            }
        }
    }

    // MARK: - Git status

    /// Asynchronously refreshes the git status, debounced by 1 second.
    func refreshGitStatus() {
        gitStatusDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.performGitStatusRefresh()
            }
        }
        gitStatusDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func performGitStatusRefresh() async {
        guard !isClosed, let provider = gitStatusProvider else { return }
        let statuses = await provider.fetchStatuses()
        guard !isClosed else { return }
        gitStatuses = statuses
        applyGitStatuses(statuses, to: rootNodes)
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
        let latency: CFTimeInterval = 0.5 // 500 ms coalesce window

        // Use Unmanaged to bridge self as a raw pointer into the C callback.
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        var context = FSEventStreamContext(
            version: 0,
            info: selfPtr,
            retain: nil,
            release: { ptr in
                // Release the retained reference when the stream is invalidated.
                if let ptr { Unmanaged<FileExplorerPanel>.fromOpaque(ptr).release() }
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let panel = Unmanaged<FileExplorerPanel>.fromOpaque(info).takeUnretainedValue()
            // Dispatch onto main actor — handleFSEvents is @MainActor.
            DispatchQueue.main.async {
                panel.handleFSEvents()
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
    func handleFSEvents() {
        fsEventDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            self.reloadTree()
            self.refreshGitStatus()
        }
        fsEventDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
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

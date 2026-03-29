import SwiftUI
import AppKit

// MARK: - KeyboardOutlineView

/// NSOutlineView subclass that handles keyboard navigation.
final class KeyboardOutlineView: NSOutlineView {
    var onReturn: ((FileNode) -> Void)?
    var onDelete: (([URL]) -> Void)?

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        let row = selectedRow
        guard row >= 0, let node = item(atRow: row) as? FileNode else {
            super.keyDown(with: event)
            return
        }

        switch chars {
        case "\r": // Return — open file or toggle directory
            if node.isDirectory {
                if isItemExpanded(node) { collapseItem(node) }
                else { expandItem(node) }
            } else {
                onReturn?(node)
            }
        case "\u{7F}", "\u{F728}": // Delete / Forward Delete — trash
            var urls: [URL] = []
            for row in selectedRowIndexes {
                if let n = item(atRow: row) as? FileNode { urls.append(n.url) }
            }
            if !urls.isEmpty { onDelete?(urls) }
        case " ": // Space — toggle expand/collapse for directories
            if node.isDirectory {
                if isItemExpanded(node) { collapseItem(node) }
                else { expandItem(node) }
            }
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - FileExplorerOutlineView

/// NSViewRepresentable that wraps an NSOutlineView for browsing a FileExplorerPanel's file tree.
struct FileExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var panel: FileExplorerPanel
    let onFileOpen: (FileNode) -> Void
    let onFilePreview: ((FileNode) -> Void)?

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        let dataSource: FileExplorerDataSource
        var lastRenderedGeneration: Int = -1
        var lastRenderedGitGeneration: Int = -1
        /// Set to true during programmatic auto-expand to avoid recording as user action.
        var isAutoExpanding: Bool = false

        init(panel: FileExplorerPanel, onFileOpen: @escaping (FileNode) -> Void, onFilePreview: ((FileNode) -> Void)?) {
            self.dataSource = FileExplorerDataSource()
            self.dataSource.panel = panel
            self.dataSource.onFileDoubleClick = onFileOpen
            self.dataSource.onFileSingleClick = onFilePreview
            self.dataSource.onNodeExpand = { [weak panel, weak self] node in
                if self?.isAutoExpanding != true {
                    panel?.userCollapsedPaths.remove(node.url.path)
                }
                panel?.refreshExpandedNode(node)
            }
            self.dataSource.onNodeCollapse = { [weak panel, weak self] node in
                if self?.isAutoExpanding != true {
                    panel?.userCollapsedPaths.insert(node.url.path)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel, onFileOpen: onFileOpen, onFilePreview: onFilePreview)
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        // Scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        // Force an opaque backing layer so the sourceList vibrancy effect
        // does not bleed through when the window itself is non-opaque
        // (Ghostty transparent background).
        scrollView.wantsLayer = true
        scrollView.layer?.isOpaque = true
        scrollView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Outline view
        let outlineView = KeyboardOutlineView()
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = 22
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.backgroundColor = .controlBackgroundColor

        // Single column — auto-resize to fill width
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let ds = context.coordinator.dataSource

        // Wire data source and delegate
        outlineView.dataSource = ds
        outlineView.delegate = ds

        // Double-click action
        outlineView.target = ds
        outlineView.doubleAction = #selector(FileExplorerDataSource.handleDoubleClick(_:))

        // Drag-and-drop registration
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        // Context menu
        let contextMenu = buildContextMenu(coordinator: ds)
        contextMenu.delegate = ds
        outlineView.menu = contextMenu

        // Store reference so context menu actions can find the outline view
        ds.outlineView = outlineView

        // Multi-select support
        outlineView.allowsMultipleSelection = true

        // Keyboard navigation callbacks
        outlineView.onReturn = { [weak ds] node in
            ds?.onFileDoubleClick?(node)
        }
        outlineView.onDelete = { [weak ds] urls in
            NSWorkspace.shared.recycle(urls) { _, error in
                guard error == nil else { return }
                DispatchQueue.main.async { ds?.panel?.reloadTree() }
            }
        }

        // Mount in scroll view
        scrollView.documentView = outlineView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.dataSource.panel = panel

        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }

        // Keep column width in sync with scroll view
        if let column = outlineView.tableColumns.first {
            let availableWidth = scrollView.contentSize.width
            if abs(column.width - availableWidth) > 1 {
                column.width = availableWidth
            }
        }

        // Full reload only when tree structure changed
        let currentGen = panel.treeGeneration
        let currentGitGen = panel.gitStatusGeneration

        if coordinator.lastRenderedGeneration != currentGen {
            // Don't reload while inline editing — the field editor would be destroyed.
            guard !panel.isEditing else { return }
            coordinator.lastRenderedGeneration = currentGen
            coordinator.lastRenderedGitGeneration = currentGitGen

            // Save state before reload
            let expandedPaths = collectExpandedPaths(outlineView: outlineView)
            let selectedPaths = collectSelectedPaths(outlineView: outlineView)
            let scrollPosition = outlineView.enclosingScrollView?.contentView.bounds.origin

            outlineView.reloadData()

            // Restore expanded state by matching URL paths
            restoreExpandedPaths(outlineView: outlineView, nodes: panel.rootNodes, expandedPaths: expandedPaths)

            // Auto-expand directories containing git-changed files
            coordinator.isAutoExpanding = true
            autoExpandGitPaths(
                outlineView: outlineView,
                nodes: panel.rootNodes,
                autoExpandPaths: panel.gitAutoExpandPaths,
                userCollapsedPaths: panel.userCollapsedPaths
            )
            coordinator.isAutoExpanding = false

            // Restore selection
            restoreSelectedPaths(outlineView: outlineView, selectedPaths: selectedPaths)

            // Restore scroll position
            if let scrollPosition {
                outlineView.enclosingScrollView?.contentView.scroll(to: scrollPosition)
            }
            return
        }

        // Lightweight: only git statuses changed — reconfigure visible cells in-place
        if coordinator.lastRenderedGitGeneration != currentGitGen {
            coordinator.lastRenderedGitGeneration = currentGitGen
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileNode,
                      let cellView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileExplorerCellView
                else { continue }
                cellView.configure(with: node)
            }
        }
    }

    /// Collect the URL paths of all currently expanded items.
    private func collectExpandedPaths(outlineView: NSOutlineView) -> Set<String> {
        var paths = Set<String>()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode,
                  outlineView.isItemExpanded(node) else { continue }
            paths.insert(node.url.path)
        }
        return paths
    }

    /// Collect the URL paths of all currently selected items.
    private func collectSelectedPaths(outlineView: NSOutlineView) -> Set<String> {
        var paths = Set<String>()
        for row in outlineView.selectedRowIndexes {
            guard let node = outlineView.item(atRow: row) as? FileNode else { continue }
            paths.insert(node.url.path)
        }
        return paths
    }

    /// Re-select rows whose URL path was previously selected.
    private func restoreSelectedPaths(outlineView: NSOutlineView, selectedPaths: Set<String>) {
        guard !selectedPaths.isEmpty else { return }
        var indexSet = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode,
                  selectedPaths.contains(node.url.path) else { continue }
            indexSet.insert(row)
        }
        if !indexSet.isEmpty {
            outlineView.selectRowIndexes(indexSet, byExtendingSelection: false)
        }
    }

    /// Expand nodes whose URL path was previously expanded.
    private func restoreExpandedPaths(outlineView: NSOutlineView, nodes: [FileNode], expandedPaths: Set<String>) {
        for node in nodes {
            guard node.isDirectory, expandedPaths.contains(node.url.path) else { continue }
            outlineView.expandItem(node)
            node.isExpanded = true
            if let children = node.children {
                restoreExpandedPaths(outlineView: outlineView, nodes: children, expandedPaths: expandedPaths)
            }
        }
    }

    /// Auto-expand directories that contain files with git changes,
    /// unless the user has manually collapsed them.
    private func autoExpandGitPaths(
        outlineView: NSOutlineView,
        nodes: [FileNode],
        autoExpandPaths: Set<String>,
        userCollapsedPaths: Set<String>
    ) {
        for node in nodes {
            guard node.isDirectory else { continue }
            let path = node.url.path
            guard autoExpandPaths.contains(path) else { continue }
            guard !userCollapsedPaths.contains(path) else { continue }

            if !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
                node.isExpanded = true
            }

            if let children = node.children {
                autoExpandGitPaths(
                    outlineView: outlineView,
                    nodes: children,
                    autoExpandPaths: autoExpandPaths,
                    userCollapsedPaths: userCollapsedPaths
                )
            }
        }
    }

    // MARK: - Context menu

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

        menu.addItem(NSMenuItem.separator())

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

        menu.addItem(NSMenuItem.separator())

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

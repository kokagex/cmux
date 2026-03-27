import SwiftUI
import AppKit

// MARK: - FileExplorerOutlineView

/// NSViewRepresentable that wraps an NSOutlineView for browsing a FileExplorerPanel's file tree.
struct FileExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var panel: FileExplorerPanel
    let onFileOpen: (FileNode) -> Void

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        let dataSource: FileExplorerDataSource
        var lastRenderedGeneration: Int = -1

        init(panel: FileExplorerPanel, onFileOpen: @escaping (FileNode) -> Void) {
            self.dataSource = FileExplorerDataSource()
            self.dataSource.panel = panel
            self.dataSource.onFileDoubleClick = onFileOpen
            self.dataSource.onNodeExpand = { [weak panel] node in
                panel?.refreshExpandedNode(node)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel, onFileOpen: onFileOpen)
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        // Scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        // Outline view
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = 22
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .sourceList

        // Single column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

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
        outlineView.menu = buildContextMenu(coordinator: ds)

        // Mount in scroll view
        scrollView.documentView = outlineView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.dataSource.panel = panel

        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }

        // Only reload when the tree data actually changed
        let currentGen = panel.treeGeneration
        guard coordinator.lastRenderedGeneration != currentGen else { return }
        coordinator.lastRenderedGeneration = currentGen

        // Save expanded paths before reload
        let expandedPaths = collectExpandedPaths(outlineView: outlineView)

        outlineView.reloadData()

        // Restore expanded state by matching URL paths
        restoreExpandedPaths(outlineView: outlineView, nodes: panel.rootNodes, expandedPaths: expandedPaths)
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

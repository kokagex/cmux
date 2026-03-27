import SwiftUI
import AppKit

// MARK: - FileExplorerOutlineView

/// NSViewRepresentable that wraps an NSOutlineView for browsing a FileExplorerPanel's file tree.
struct FileExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var panel: FileExplorerPanel
    let onFileOpen: (FileNode) -> Void

    // MARK: - Coordinator

    func makeCoordinator() -> FileExplorerDataSource {
        let coordinator = FileExplorerDataSource()
        coordinator.panel = panel
        coordinator.onFileDoubleClick = onFileOpen
        coordinator.onNodeExpand = { [weak panel] node in
            panel?.refreshExpandedNode(node)
        }
        return coordinator
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

        // Wire data source and delegate
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        // Double-click action
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(FileExplorerDataSource.handleDoubleClick(_:))

        // Drag-and-drop registration
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        // Context menu
        outlineView.menu = buildContextMenu(coordinator: context.coordinator)

        // Mount in scroll view
        scrollView.documentView = outlineView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.panel = panel

        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }

        outlineView.reloadData()

        // Restore expanded state
        restoreExpandedState(outlineView: outlineView, nodes: panel.rootNodes)
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

    // MARK: - Expanded state restoration

    private func restoreExpandedState(outlineView: NSOutlineView, nodes: [FileNode]) {
        for node in nodes {
            guard node.isDirectory && node.isExpanded else { continue }
            outlineView.expandItem(node)
            if let children = node.children {
                restoreExpandedState(outlineView: outlineView, nodes: children)
            }
        }
    }
}

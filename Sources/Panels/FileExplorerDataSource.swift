import AppKit
import UniformTypeIdentifiers

// MARK: - FileExplorerDataSource

@MainActor
final class FileExplorerDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

    weak var panel: FileExplorerPanel?
    var onFileDoubleClick: ((FileNode) -> Void)?
    var onNodeExpand: ((FileNode) -> Void)?

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return panel?.rootNodes.count ?? 0
        }
        guard let node = item as? FileNode else { return 0 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return panel!.rootNodes[index]
        }
        let node = item as! FileNode
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory
    }

    // Drag source: write the node's URL to the pasteboard
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode else { return nil }
        return node.url as NSURL
    }

    // Drag destination: validate
    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard info.draggingSourceOperationMask.contains(.move) else { return [] }

        // Destination must be a directory (or root)
        let destinationNode = item as? FileNode
        if let dest = destinationNode, !dest.isDirectory { return [] }

        // Collect dragged URLs
        let pb = info.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty
        else { return [] }

        // Determine destination directory URL
        let destURL = destinationNode?.url ?? URL(fileURLWithPath: panel?.rootPath ?? "/")

        // Reject if any dragged item is the destination itself or an ancestor
        for url in urls {
            if url == destURL { return [] }
            if destURL.path.hasPrefix(url.path + "/") { return [] }
        }

        return .move
    }

    // Drag destination: accept
    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let pb = info.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty
        else { return false }

        let destinationNode = item as? FileNode
        let destDirURL = destinationNode?.url ?? URL(fileURLWithPath: panel?.rootPath ?? "/")
        let fm = FileManager.default
        var moved = false
        for sourceURL in urls {
            let destURL = destDirURL.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                try fm.moveItem(at: sourceURL, to: destURL)
                moved = true
            } catch {
                // Continue trying other items; individual failures are silently skipped
            }
        }
        return moved
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileExplorerCell")
        var cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileExplorerCellView
        if cell == nil {
            cell = FileExplorerCellView()
            cell!.identifier = identifier
        }
        cell!.configure(with: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 22
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

    @objc func contextNewFile(_ sender: Any?) {
        guard let outlineView = sender as? NSOutlineView ?? (sender as? NSMenuItem)?.representedObject as? NSOutlineView,
              let node = clickedDirectoryNode(in: outlineView),
              let panel
        else { return }

        let dirURL: URL
        if node.isDirectory {
            dirURL = node.url
        } else {
            dirURL = node.url.deletingLastPathComponent()
        }

        var destURL = dirURL.appendingPathComponent("untitled")
        var counter = 1
        while FileManager.default.fileExists(atPath: destURL.path) {
            destURL = dirURL.appendingPathComponent("untitled \(counter)")
            counter += 1
        }
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        panel.reloadTree()
    }

    @objc func contextNewFolder(_ sender: Any?) {
        guard let outlineView = sender as? NSOutlineView ?? (sender as? NSMenuItem)?.representedObject as? NSOutlineView,
              let node = clickedDirectoryNode(in: outlineView),
              let panel
        else { return }

        let dirURL: URL
        if node.isDirectory {
            dirURL = node.url
        } else {
            dirURL = node.url.deletingLastPathComponent()
        }

        var destURL = dirURL.appendingPathComponent("untitled folder")
        var counter = 1
        while FileManager.default.fileExists(atPath: destURL.path) {
            destURL = dirURL.appendingPathComponent("untitled folder \(counter)")
            counter += 1
        }
        try? FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        panel.reloadTree()
    }

    @objc func contextRename(_ sender: Any?) {
        // TODO: Implement inline editing via outlineView(_:shouldEdit:item:) and text field editing
    }

    @objc func contextDelete(_ sender: Any?) {
        guard let outlineView = sender as? NSOutlineView ?? (sender as? NSMenuItem)?.representedObject as? NSOutlineView,
              let node = clickedNode(in: outlineView)
        else { return }
        NSWorkspace.shared.recycle([node.url]) { _, _ in }
    }

    @objc func contextShowInFinder(_ sender: Any?) {
        guard let outlineView = sender as? NSOutlineView ?? (sender as? NSMenuItem)?.representedObject as? NSOutlineView,
              let node = clickedNode(in: outlineView)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc func contextCopyPath(_ sender: Any?) {
        guard let outlineView = sender as? NSOutlineView ?? (sender as? NSMenuItem)?.representedObject as? NSOutlineView,
              let node = clickedNode(in: outlineView)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    // MARK: - Helpers

    private func clickedNode(in outlineView: NSOutlineView) -> FileNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileNode
    }

    private func clickedDirectoryNode(in outlineView: NSOutlineView) -> FileNode? {
        guard let node = clickedNode(in: outlineView) else { return nil }
        return node
    }
}

// MARK: - FileExplorerCellView

final class FileExplorerCellView: NSView {

    let iconView: NSImageView
    let nameLabel: NSTextField
    let statusLabel: NSTextField

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        iconView = NSImageView()
        nameLabel = NSTextField(labelWithString: "")
        statusLabel = NSTextField(labelWithString: "")

        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            // Icon: 16x16, vertically centered
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            // Status badge: fixed 16pt wide, right side, vertically centered
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 16),

            // Name label: fills space between icon and status
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -2),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Configure

    func configure(with node: FileNode) {
        // Icon
        let symbolName = FileIconMapper.icon(for: node.name, isDirectory: node.isDirectory)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.image = image

        if node.isDirectory {
            iconView.contentTintColor = .systemOrange
        } else {
            iconView.contentTintColor = .labelColor
        }

        // Name label color based on git status
        nameLabel.stringValue = node.name
        nameLabel.textColor = textColor(for: node.gitStatus)

        // Status badge
        let badge = statusBadge(for: node.gitStatus)
        statusLabel.stringValue = badge
        statusLabel.textColor = textColor(for: node.gitStatus)
        statusLabel.isHidden = badge.isEmpty
    }

    private func textColor(for status: GitFileStatus) -> NSColor {
        switch status {
        case .unmodified:  return .labelColor
        case .modified:    return .systemYellow
        case .added:       return .systemGreen
        case .deleted:     return .systemRed
        case .untracked:   return .secondaryLabelColor
        case .conflicted:  return .systemOrange
        }
    }

    private func statusBadge(for status: GitFileStatus) -> String {
        switch status {
        case .unmodified:  return ""
        case .modified:    return "M"
        case .added:       return "A"
        case .deleted:     return "D"
        case .untracked:   return "?"
        case .conflicted:  return "C"
        }
    }
}

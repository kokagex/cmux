import AppKit
import UniformTypeIdentifiers

// MARK: - FileExplorerDataSource

@MainActor
final class FileExplorerDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuItemValidation, NSMenuDelegate {

    weak var panel: FileExplorerPanel?
    weak var outlineView: NSOutlineView?
    var onFileDoubleClick: ((FileNode) -> Void)?
    var onFileSingleClick: ((FileNode) -> Void)?
    var onNodeExpand: ((FileNode) -> Void)?
    var onNodeCollapse: ((FileNode) -> Void)?

    /// Debounce work item for single-click preview to avoid rapid editor creation.
    private var previewDebounceWork: DispatchWorkItem?

    /// The node currently being renamed via inline editing, or nil.
    private var editingNode: FileNode?

    /// Cached node from right-click, captured when context menu opens (clickedRow is
    /// only valid at that point; it gets reset before the menu action fires).
    private var contextMenuNode: FileNode?

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
            guard let panel else { return FileNode(url: URL(fileURLWithPath: "/"), name: "/", isDirectory: true) }
            return panel.rootNodes[index]
        }
        guard let node = item as? FileNode, let children = node.children else {
            return FileNode(url: URL(fileURLWithPath: "/"), name: "/", isDirectory: true)
        }
        return children[index]
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
        onNodeCollapse?(node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if !node.isDirectory {
            // Debounce preview to avoid rapid editor creation when navigating
            previewDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onFileSingleClick?(node)
            }
            previewDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
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
        guard let panel else { return }

        let dirURL: URL
        if let node = clickedNode() {
            dirURL = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        } else {
            dirURL = URL(fileURLWithPath: panel.rootPath)
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
        guard let panel else { return }

        let dirURL: URL
        if let node = clickedNode() {
            dirURL = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        } else {
            dirURL = URL(fileURLWithPath: panel.rootPath)
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
        guard let node = clickedNode(), let outlineView else {
            return
        }
        // Find row by URL path — the cached node may be a stale object if the
        // tree reloaded between menuWillOpen and the action dispatch.
        let targetPath = node.url.path
        var row = outlineView.row(forItem: node)
        if row < 0 {
            for r in 0..<outlineView.numberOfRows {
                if let n = outlineView.item(atRow: r) as? FileNode, n.url.path == targetPath {
                    row = r
                    break
                }
            }
        }
        guard row >= 0,
              let cellView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileExplorerCellView
        else { return }
        // Use the current node object from the outline view for editingNode
        let currentNode = outlineView.item(atRow: row) as? FileNode ?? node

        editingNode = currentNode
        panel?.isEditing = true

        let textField = cellView.nameLabel
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        textField.focusRingType = .none
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor

        // Delay makeFirstResponder to the next run loop iteration so that
        // the context menu's tracking loop cleanup does not steal focus back
        // from the field editor.
        DispatchQueue.main.async {
            outlineView.window?.makeFirstResponder(textField)

            // Select the name without extension for files
            if !currentNode.isDirectory, let fieldEditor = textField.currentEditor() {
                let name = currentNode.name
                if let dotRange = name.range(of: ".", options: .backwards), dotRange.lowerBound != name.startIndex {
                    let prefixLength = name.distance(from: name.startIndex, to: dotRange.lowerBound)
                    fieldEditor.selectedRange = NSRange(location: 0, length: prefixLength)
                }
            }
        }
    }

    // MARK: - NSTextFieldDelegate (inline rename)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              let node = editingNode else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reset cell to label state
        textField.isEditable = false
        textField.isSelectable = false
        textField.delegate = nil
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        editingNode = nil

        // Validate and perform rename
        guard !newName.isEmpty, newName != node.name else {
            textField.stringValue = node.name
            panel?.endEditing()
            return
        }

        let sourceURL = node.url
        let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
        } catch {
            textField.stringValue = node.name
        }

        panel?.endEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape — cancel rename
            guard let node = editingNode else { return false }
            if let textField = control as? NSTextField {
                textField.stringValue = node.name
                textField.isEditable = false
                textField.isSelectable = false
                textField.delegate = nil
                textField.drawsBackground = false
                textField.backgroundColor = .clear
            }
            editingNode = nil
            panel?.endEditing()
            outlineView?.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    @objc func contextDelete(_ sender: Any?) {
        guard let node = clickedNode() else {
            return
        }
        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                self?.panel?.reloadTree()
            }
        }
    }

    // MARK: - NSMenuItemValidation

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        if action == #selector(contextNewFile(_:)) || action == #selector(contextNewFolder(_:)) {
            return true
        }
        return clickedNode() != nil
    }

    @objc func contextShowInFinder(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc func contextCopyPath(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard let outlineView else { return }
        let row = outlineView.clickedRow
        contextMenuNode = row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
    }

    func menuDidClose(_ menu: NSMenu) {
        // Defer clearing so the action method can still read the cached node.
        // Actions are dispatched after menuDidClose on the same run-loop pass.
        DispatchQueue.main.async { [weak self] in
            self?.contextMenuNode = nil
        }
    }

    // MARK: - Helpers

    private func clickedNode() -> FileNode? {
        // Prefer the cached node (captured when the menu opened, before clickedRow resets)
        if let contextMenuNode { return contextMenuNode }
        guard let outlineView else { return nil }
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileNode
    }
}

// MARK: - FileExplorerCellView

final class FileExplorerCellView: NSView {

    let iconView: NSImageView
    let nameLabel: NSTextField
    let statusLabel: NSTextField
    private var statusWidthConstraint: NSLayoutConstraint!

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
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(statusLabel)
        addSubview(nameLabel)

        statusWidthConstraint = statusLabel.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Icon: 16x16, vertically centered
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            // Status badge: left side, between icon and name
            statusLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusWidthConstraint,

            // Name label: fills remaining space
            nameLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Configure

    func configure(with node: FileNode) {
        // Reset editing state (cell may be reused from an editing session)
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.delegate = nil
        nameLabel.drawsBackground = false
        nameLabel.backgroundColor = .clear

        // Icon
        let symbolName = FileIconMapper.icon(for: node.name, isDirectory: node.isDirectory)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.image = image

        let color = textColor(for: node.gitStatus)
        if node.isDirectory {
            // Tint directory icon with git status color, fallback to orange for unmodified
            iconView.contentTintColor = node.gitStatus == .unmodified ? .systemOrange : color
        } else {
            iconView.contentTintColor = node.gitStatus == .unmodified ? .labelColor : color
        }

        // Name label color based on git status
        nameLabel.stringValue = node.name
        nameLabel.textColor = color

        // Status badge (left side)
        let badge = statusBadge(for: node.gitStatus)
        statusLabel.stringValue = badge
        statusLabel.textColor = color
        if badge.isEmpty {
            statusLabel.isHidden = true
            statusWidthConstraint.constant = 0
        } else {
            statusLabel.isHidden = false
            statusWidthConstraint.constant = 14
        }
    }

    private func textColor(for status: GitFileStatus) -> NSColor {
        switch status {
        case .unmodified:  return .labelColor
        case .modified:    return .systemYellow
        case .added:       return .systemGreen
        case .deleted:     return .systemRed
        case .untracked:   return .systemTeal
        case .conflicted:  return .systemOrange
        case .ignored:     return .tertiaryLabelColor
        }
    }

    private func statusBadge(for status: GitFileStatus) -> String {
        switch status {
        case .unmodified:  return ""
        case .modified:    return "M"
        case .added:       return "A"
        case .deleted:     return "D"
        case .untracked:   return "U"
        case .conflicted:  return "C"
        case .ignored:     return ""
        }
    }
}

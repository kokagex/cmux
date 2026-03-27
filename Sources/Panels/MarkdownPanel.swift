import Foundation
import Combine

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.richtext" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    // MARK: - File watching

    private var fileWatcher: FileWatcherHelper?

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()

        let watcher = FileWatcherHelper(
            onChange: { [weak self] kind in
                guard let self else { return }
                switch kind {
                case .contentChanged:
                    self.loadFileContent()
                case .deletedOrRenamed:
                    self.loadFileContent()
                    // Reattach to the new inode. If the file is not yet
                    // available, reattach() starts the retry loop.
                    self.fileWatcher?.reattach()
                }
            },
            onReattach: { [weak self] in
                // File reappeared after retry — reload content.
                self?.loadFileContent()
            }
        )
        self.fileWatcher = watcher
        watcher.start(filePath: filePath)
    }

    // MARK: - Panel protocol

    func focus() {
        // Markdown panel is read-only; no first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            content = newContent
            isFileUnavailable = false
        } catch {
            // Fallback: try ISO Latin-1, which accepts all 256 byte values,
            // covering legacy encodings like Windows-1252.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                content = decoded
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
    }
}

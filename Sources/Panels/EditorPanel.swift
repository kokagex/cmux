import AppKit
import Foundation
import Combine

/// Represents a language for syntax highlighting.
enum EditorLanguage: String, Codable, Sendable {
    case json, markdown, swift, yaml, toml, generic

    init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "json": self = .json
        case "md", "markdown": self = .markdown
        case "swift": self = .swift
        case "yaml", "yml": self = .yaml
        case "toml": self = .toml
        default: self = .generic
        }
    }
}

/// A panel that edits a file with live file-watching.
///
/// **Architecture:** NSTextView is the source of truth for content.
/// EditorPanel loads file content on init and provides it to the view via
/// `fileContent`. The view (NSTextView) owns the live text. `isDirty` is set
/// by the view via `markDirty()` when text changes. `save(text:)` takes text
/// from the NSTextView and writes to disk. On external file change, if not
/// dirty, EditorPanel reloads and bumps `fileContentGeneration` so the view
/// knows to update.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Absolute path to the file being edited. Can change for preview tab reuse.
    @Published private(set) var filePath: String

    /// Whether content has unsaved modifications. Set by the view.
    @Published private(set) var isDirty: Bool = false

    /// Whether this is a preview (temporary) tab.
    @Published private(set) var isPreview: Bool

    /// Detected language for syntax highlighting.
    @Published private(set) var language: EditorLanguage

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.text" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Content loaded from file -- used to initialize the NSTextView.
    /// Updated on file reload. NOT updated on user edits.
    @Published private(set) var fileContent: String = ""

    /// Incremented when fileContent changes from external reload,
    /// so the view knows to update NSTextView.
    @Published private(set) var fileContentGeneration: Int = 0

    /// Weak reference to the backing NSTextView for programmatic focus.
    weak var focusableTextView: EditorNSTextView?

    private(set) var workspaceId: UUID
    private var fileWatcher: FileWatcherHelper?

    // MARK: - Init

    init(workspaceId: UUID, filePath: String, isPreview: Bool = false) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.isPreview = isPreview
        self.language = EditorLanguage(fileExtension: (filePath as NSString).pathExtension)
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        setupFileWatcher()
    }

    // MARK: - Panel protocol

    func focus() {
        guard let textView = focusableTextView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func unfocus() {
        // No-op; NSTextView handles its own first responder state.
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

    // MARK: - Public API

    /// Save text to disk. Called by the view with current NSTextView content.
    func save(text: String) {
        guard isDirty else { return }
        do {
            try text.write(toFile: filePath, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            // Save failed -- isDirty stays true.
        }
    }

    /// Mark content as modified. Called by EditorTextView on text changes.
    func markDirty() {
        guard !isDirty else { return }
        isDirty = true
        if isPreview { promoteToFixed() }
    }

    /// Promote from preview tab to fixed tab.
    func promoteToFixed() {
        guard isPreview else { return }
        isPreview = false
    }

    /// Replace the file this panel is editing (for preview tab reuse).
    func replaceFile(_ newPath: String) {
        fileWatcher?.stop()
        filePath = newPath
        language = EditorLanguage(fileExtension: (newPath as NSString).pathExtension)
        displayTitle = (newPath as NSString).lastPathComponent
        isDirty = false
        loadFileContent()
        setupFileWatcher()
    }

    // MARK: - Binary detection

    static func isBinaryFile(at path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return true }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: 8192)
        return data.contains(0x00)
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            fileContent = content
            isFileUnavailable = false
        } catch {
            // Fallback: try ISO Latin-1, which accepts all 256 byte values,
            // covering legacy encodings like Windows-1252.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                fileContent = decoded
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
        fileContentGeneration += 1
    }

    // MARK: - File watcher

    private func setupFileWatcher() {
        let watcher = FileWatcherHelper(
            onChange: { [weak self] changeKind in
                guard let self else { return }
                switch changeKind {
                case .contentChanged:
                    if !self.isDirty { self.loadFileContent() }
                case .deletedOrRenamed:
                    if !self.isDirty {
                        self.loadFileContent()
                    }
                    // Reattach to the new inode. If the file is not yet
                    // available, reattach() starts the retry loop.
                    self.fileWatcher?.reattach()
                }
            },
            onReattach: { [weak self] in
                // File reappeared after retry -- reload content.
                guard let self else { return }
                if !self.isDirty { self.loadFileContent() }
            }
        )
        self.fileWatcher = watcher
        watcher.start(filePath: filePath)
    }
}

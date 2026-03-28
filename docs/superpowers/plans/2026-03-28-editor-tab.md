# Editor Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in editor panel to cmux that opens files from the file explorer as tabs, with lightweight syntax highlighting and Cmd+S save.

**Architecture:** New `EditorPanel` + `EditorPanelView` following the MarkdownPanel pattern. NSTextView wrapped in NSViewRepresentable for the editor body. File explorer gets single-click (preview tab) and double-click (pinned tab) integration. Preview tabs are tracked per-workspace with at most one active at a time.

**Tech Stack:** SwiftUI, AppKit (NSTextView, NSScrollView, DispatchSource), NSAttributedString for syntax highlighting.

**Spec:** `docs/superpowers/specs/2026-03-28-editor-tab-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Panels/EditorPanel.swift` | Create | Panel model: file I/O, isDirty, file watching, preview/pinned state |
| `Sources/Panels/EditorPanelView.swift` | Create | SwiftUI view: toolbar + EditorTextView wrapper |
| `Sources/Panels/EditorTextView.swift` | Create | NSViewRepresentable wrapping NSTextView in NSScrollView |
| `Sources/Panels/SyntaxHighlighter.swift` | Create | Regex-based syntax coloring for JSON/Markdown/Swift/YAML/TOML |
| `Sources/Panels/Panel.swift` | Modify | Add `.editor` to PanelType, `.editor()` to PanelFocusIntent |
| `Sources/Panels/PanelContentView.swift` | Modify | Add `.editor` routing case |
| `Sources/Workspace.swift` | Modify | Add `newEditorSurface()`, `previewEditorPanelId`, subscription |
| `Sources/SessionPersistence.swift` | Modify | Add `SessionEditorPanelSnapshot`, snapshot/restore |
| `Sources/Panels/FileExplorerDataSource.swift` | Modify | Add single-click handler for preview tabs |
| `Sources/Panels/FileExplorerOutlineView.swift` | Modify | Wire single-click callback |
| `Sources/Panels/FileExplorerPanelView.swift` | Modify | Handle preview/open via workspace |
| `Sources/TerminalController.swift` | Modify | Add `editor.open` socket command |
| `Sources/ContentView.swift` | Modify | Add editor to command palette kind |

---

### Task 1: Add PanelType.editor and PanelFocusIntent.editor

**Files:**
- Modify: `Sources/Panels/Panel.swift`

- [ ] **Step 1: Add `.editor` to PanelType enum**

In `Sources/Panels/Panel.swift`, add `.editor` case to the `PanelType` enum (after `.fileExplorer`):

```swift
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
    case fileExplorer
    case editor
}
```

- [ ] **Step 2: Add EditorPanelFocusIntent and update PanelFocusIntent**

Add a new enum and a case in `PanelFocusIntent`:

```swift
public enum EditorPanelFocusIntent: Codable, Sendable {
    case textView
}
```

Add to the `PanelFocusIntent` enum (alongside the existing terminal/browser cases):

```swift
case editor(EditorPanelFocusIntent)
```

- [ ] **Step 3: Build to verify compilation**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

This will produce errors for exhaustive switch statements in Workspace.swift, PanelContentView.swift, SessionPersistence.swift, ContentView.swift, and TerminalController.swift. That's expected — we'll fix them in subsequent tasks.

- [ ] **Step 4: Fix all exhaustive switch compile errors**

Add placeholder cases wherever the compiler complains. For every `switch` on `PanelType` or `PanelFocusIntent`, add a `case .editor:` that either returns a sensible default or mirrors the `.markdown` case. Common locations:

- `Workspace.swift` — `surfaceKind()`: add `case .editor: return SurfaceKind.editor` (and add `static let editor = "editor"` to the `SurfaceKind` enum)
- `Workspace.swift` — `sessionPanelSnapshot()`: add `case .editor: return nil` (temporary, will be replaced in Task 7)
- `Workspace.swift` — `createPanel(from:)`: add `case .editor: return nil` (temporary)
- `PanelContentView.swift` — body switch: add `case .editor: EmptyView()` (temporary)
- `SessionPersistence.swift` — `SessionPanelSnapshot`: add `var editor: SessionEditorPanelSnapshot?` (define the struct as empty for now: `struct SessionEditorPanelSnapshot: Codable, Sendable { var filePath: String }`)
- `ContentView.swift` — command palette kind: add `case .editor` with display name "Editor" and search keywords `["editor", "text", "file", "edit"]`
- `TerminalController.swift` — any switch on PanelType: add `case .editor:` with appropriate fallthrough or empty handling

Search for all switch sites:
```bash
cd /Users/kokage/cmux && grep -rn 'switch.*panelType\|case \.markdown.*:\|case \.fileExplorer.*:' Sources/ --include='*.swift' | grep -v '//' | head -40
```

- [ ] **Step 5: Build to verify all switches compile**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Sources/Panels/Panel.swift Sources/Panels/PanelContentView.swift Sources/Workspace.swift Sources/SessionPersistence.swift Sources/ContentView.swift Sources/TerminalController.swift
git commit -m "feat(editor): add PanelType.editor and fix exhaustive switches"
```

---

### Task 2: Create EditorPanel model

**Files:**
- Create: `Sources/Panels/EditorPanel.swift`

- [ ] **Step 1: Create EditorPanel.swift**

Create `Sources/Panels/EditorPanel.swift`:

```swift
import Foundation
import Combine

/// Represents a language for syntax highlighting.
enum EditorLanguage: String, Codable, Sendable {
    case json
    case markdown
    case swift
    case yaml
    case toml
    case generic

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

/// A panel that provides a text editor for viewing and editing files.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Absolute path to the file being edited.
    @Published private(set) var filePath: String

    /// Current text content.
    @Published var content: String = ""

    /// Whether content has unsaved modifications.
    @Published private(set) var isDirty: Bool = false

    /// Whether this is a preview (temporary) tab.
    @Published private(set) var isPreview: Bool

    /// Detected language for syntax highlighting.
    @Published private(set) var language: EditorLanguage

    /// Title shown in the tab bar.
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.text" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    // MARK: - File watching

    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.editor-file-watch", qos: .utility)
    private static let maxReattachAttempts = 6
    private static let reattachDelay: TimeInterval = 0.5

    /// Content snapshot at last save/load — used for isDirty comparison.
    private var savedContent: String = ""

    // MARK: - Init

    init(workspaceId: UUID, filePath: String, isPreview: Bool = false) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.isPreview = isPreview
        self.language = EditorLanguage(fileExtension: (filePath as NSString).pathExtension)
        self.displayTitle = (filePath as NSString).lastPathComponent
        loadFileContent()
        startFileWatcher()
    }

    // MARK: - Panel protocol

    func focus() {
        // Focus will be managed by EditorTextView (NSTextView first responder).
    }

    func unfocus() {}

    func close() {
        isClosed = true
        stopFileWatcher()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Public API

    /// Save current content to disk.
    func save() {
        guard isDirty else { return }
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            savedContent = content
            isDirty = false
        } catch {
            // Save failed — isDirty stays true.
        }
    }

    /// Promote from preview (temporary) tab to a pinned (fixed) tab.
    func promoteToFixed() {
        guard isPreview else { return }
        isPreview = false
    }

    /// Replace the file this panel is editing (for preview tab reuse).
    func replaceFile(_ newPath: String) {
        stopFileWatcher()
        filePath = newPath
        language = EditorLanguage(fileExtension: (newPath as NSString).pathExtension)
        displayTitle = (newPath as NSString).lastPathComponent
        isDirty = false
        loadFileContent()
        startFileWatcher()
    }

    /// Mark content as modified. Called by EditorTextView on text changes.
    func markDirty() {
        guard !isDirty else { return }
        isDirty = true
        if isPreview {
            promoteToFixed()
        }
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            content = newContent
            savedContent = newContent
            isDirty = false
            isFileUnavailable = false
        } catch {
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                content = decoded
                savedContent = decoded
                isDirty = false
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
    }

    // MARK: - File watcher

    private func startFileWatcher() {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    if !self.isDirty {
                        self.loadFileContent()
                    }
                    if self.isFileUnavailable {
                        self.scheduleReattach(attempt: 1)
                    } else {
                        self.startFileWatcher()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    if !self.isDirty {
                        self.loadFileContent()
                    }
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.isFileUnavailable = false
                    if !self.isDirty {
                        self.loadFileContent()
                    }
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }

    deinit {
        fileWatchSource?.cancel()
    }

    // MARK: - Binary detection

    /// Check if a file is likely binary by scanning for NUL bytes in the first 8KB.
    static func isBinaryFile(at path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return true }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: 8192)
        return data.contains(0x00)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/EditorPanel.swift
git commit -m "feat(editor): add EditorPanel model with file I/O and watching"
```

---

### Task 3: Create SyntaxHighlighter

**Files:**
- Create: `Sources/Panels/SyntaxHighlighter.swift`

- [ ] **Step 1: Create SyntaxHighlighter.swift**

Create `Sources/Panels/SyntaxHighlighter.swift`:

```swift
import AppKit
import Foundation

/// Lightweight regex-based syntax highlighter for common file types.
/// Applies NSAttributedString attributes to an NSTextStorage.
enum SyntaxHighlighter {

    // MARK: - Token types and colors

    enum TokenType {
        case keyword
        case string
        case number
        case comment
        case key       // JSON/YAML keys
        case heading   // Markdown headings
        case bold
        case codeSpan

        var color: NSColor {
            switch self {
            case .keyword:  return .systemPurple
            case .string:   return .systemGreen
            case .number:   return .systemBlue
            case .comment:  return .systemGray
            case .key:      return .systemTeal
            case .heading:  return .systemOrange
            case .bold:     return .systemPink
            case .codeSpan: return .systemIndigo
            }
        }
    }

    // MARK: - Language patterns

    private struct TokenPattern {
        let type: TokenType
        let regex: NSRegularExpression
    }

    private static let jsonPatterns: [TokenPattern] = {
        return [
            TokenPattern(type: .key, regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*"\s*(?=:)"#)),
            TokenPattern(type: .string, regex: try! NSRegularExpression(pattern: #":\s*"[^"\\]*(?:\\.[^"\\]*)*""#)),
            TokenPattern(type: .number, regex: try! NSRegularExpression(pattern: #"(?<=:\s)-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)),
            TokenPattern(type: .keyword, regex: try! NSRegularExpression(pattern: #"\b(?:true|false|null)\b"#)),
        ]
    }()

    private static let swiftPatterns: [TokenPattern] = {
        return [
            TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"//.*$"#, options: .anchorsMatchLines)),
            TokenPattern(type: .string, regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)),
            TokenPattern(type: .keyword, regex: try! NSRegularExpression(
                pattern: #"\b(?:import|class|struct|enum|protocol|func|var|let|if|else|guard|return|switch|case|for|while|do|try|catch|throw|throws|async|await|public|private|internal|fileprivate|open|static|final|override|init|deinit|self|super|true|false|nil|weak|unowned|lazy|mutating|nonmutating|inout|some|any|where|extension|typealias|associatedtype|subscript|didSet|willSet|get|set)\b"#)),
            TokenPattern(type: .number, regex: try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)),
        ]
    }()

    private static let markdownPatterns: [TokenPattern] = {
        return [
            TokenPattern(type: .heading, regex: try! NSRegularExpression(pattern: #"^#{1,6}\s+.*$"#, options: .anchorsMatchLines)),
            TokenPattern(type: .bold, regex: try! NSRegularExpression(pattern: #"\*\*[^*]+\*\*"#)),
            TokenPattern(type: .codeSpan, regex: try! NSRegularExpression(pattern: #"`[^`]+`"#)),
            TokenPattern(type: .string, regex: try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]+\)"#)),
        ]
    }()

    private static let yamlPatterns: [TokenPattern] = {
        return [
            TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"#.*$"#, options: .anchorsMatchLines)),
            TokenPattern(type: .key, regex: try! NSRegularExpression(pattern: #"^[\w.\-]+(?=\s*:)"#, options: .anchorsMatchLines)),
            TokenPattern(type: .string, regex: try! NSRegularExpression(pattern: #"(?<=:\s)[""'][^""']*[""']"#)),
            TokenPattern(type: .keyword, regex: try! NSRegularExpression(pattern: #"\b(?:true|false|null|yes|no)\b"#, options: .caseInsensitive)),
            TokenPattern(type: .number, regex: try! NSRegularExpression(pattern: #"(?<=:\s)-?\d+(?:\.\d+)?"#)),
        ]
    }()

    private static let tomlPatterns: [TokenPattern] = {
        return [
            TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"#.*$"#, options: .anchorsMatchLines)),
            TokenPattern(type: .heading, regex: try! NSRegularExpression(pattern: #"^\[+[^\]]+\]+"#, options: .anchorsMatchLines)),
            TokenPattern(type: .key, regex: try! NSRegularExpression(pattern: #"^[\w.\-]+(?=\s*=)"#, options: .anchorsMatchLines)),
            TokenPattern(type: .string, regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)),
            TokenPattern(type: .keyword, regex: try! NSRegularExpression(pattern: #"\b(?:true|false)\b"#)),
            TokenPattern(type: .number, regex: try! NSRegularExpression(pattern: #"(?<==\s*)-?\d+(?:\.\d+)?"#)),
        ]
    }()

    private static let genericPatterns: [TokenPattern] = {
        return [
            TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"(?://|#).*$"#, options: .anchorsMatchLines)),
            TokenPattern(type: .string, regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)),
            TokenPattern(type: .number, regex: try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)),
        ]
    }()

    // MARK: - Public API

    /// Apply syntax highlighting to the given text storage.
    /// Call from the main thread after text changes (debounced).
    static func highlight(_ textStorage: NSTextStorage, language: EditorLanguage, font: NSFont) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string

        textStorage.beginEditing()

        // Reset to default attributes.
        textStorage.setAttributes([
            .foregroundColor: NSColor.labelColor,
            .font: font
        ], range: fullRange)

        // Apply token patterns for the language.
        let patterns = Self.patterns(for: language)
        for pattern in patterns {
            pattern.regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let matchRange = match?.range else { return }
                textStorage.addAttribute(.foregroundColor, value: pattern.type.color, range: matchRange)
            }
        }

        textStorage.endEditing()
    }

    private static func patterns(for language: EditorLanguage) -> [TokenPattern] {
        switch language {
        case .json: return jsonPatterns
        case .swift: return swiftPatterns
        case .markdown: return markdownPatterns
        case .yaml: return yamlPatterns
        case .toml: return tomlPatterns
        case .generic: return genericPatterns
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/SyntaxHighlighter.swift
git commit -m "feat(editor): add regex-based SyntaxHighlighter for JSON/Swift/Markdown/YAML/TOML"
```

---

### Task 4: Create EditorTextView (NSViewRepresentable)

**Files:**
- Create: `Sources/Panels/EditorTextView.swift`

- [ ] **Step 1: Create EditorTextView.swift**

Create `Sources/Panels/EditorTextView.swift`:

```swift
import SwiftUI
import AppKit

/// NSViewRepresentable wrapping NSTextView in NSScrollView for editing files.
struct EditorTextView: NSViewRepresentable {
    @ObservedObject var panel: EditorPanel

    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate {
        let panel: EditorPanel
        weak var textView: NSTextView?
        private var isUpdatingFromModel: Bool = false
        private var highlightWorkItem: DispatchWorkItem?

        init(panel: EditorPanel) {
            self.panel = panel
        }

        // MARK: - NSTextStorageDelegate

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isUpdatingFromModel else { return }
                self.panel.content = textStorage.string
                self.panel.markDirty()
                self.scheduleHighlight()
            }
        }

        func setIsUpdatingFromModel(_ value: Bool) {
            isUpdatingFromModel = value
        }

        func scheduleHighlight() {
            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let textView = self.textView else { return }
                guard let textStorage = textView.textStorage else { return }
                SyntaxHighlighter.highlight(textStorage, language: self.panel.language, font: EditorTextView.editorFont)
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        }

        /// Handle Cmd+S to save the file.
        func handleKeyDown(_ event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
                panel.save()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = EditorNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = Self.editorFont
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true

        // Layout: wrap to scroll view width.
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.keyDownHandler = context.coordinator.handleKeyDown

        scrollView.documentView = textView
        context.coordinator.textView = textView

        textView.textStorage?.delegate = context.coordinator

        // Set initial content.
        context.coordinator.setIsUpdatingFromModel(true)
        textView.string = panel.content
        context.coordinator.setIsUpdatingFromModel(false)

        // Initial highlight.
        if let textStorage = textView.textStorage {
            SyntaxHighlighter.highlight(textStorage, language: panel.language, font: Self.editorFont)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Only update text if the model content differs (e.g., file reload).
        if textView.string != panel.content {
            context.coordinator.setIsUpdatingFromModel(true)
            let selectedRanges = textView.selectedRanges
            textView.string = panel.content
            textView.selectedRanges = selectedRanges
            context.coordinator.setIsUpdatingFromModel(false)

            if let textStorage = textView.textStorage {
                SyntaxHighlighter.highlight(textStorage, language: panel.language, font: Self.editorFont)
            }
        }
    }
}

// MARK: - EditorNSTextView

/// Custom NSTextView subclass that intercepts key events for Cmd+S.
final class EditorNSTextView: NSTextView {
    var keyDownHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/EditorTextView.swift
git commit -m "feat(editor): add EditorTextView NSViewRepresentable with Cmd+S save"
```

---

### Task 5: Create EditorPanelView

**Files:**
- Create: `Sources/Panels/EditorPanelView.swift`

- [ ] **Step 1: Create EditorPanelView.swift**

Create `Sources/Panels/EditorPanelView.swift`:

```swift
import SwiftUI

/// SwiftUI view for displaying an EditorPanel.
struct EditorPanelView: View {
    @ObservedObject var panel: EditorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0
    @State private var focusFlashAnimationGeneration: UInt = 0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if panel.isFileUnavailable {
                    fileUnavailableView
                } else {
                    EditorTextView(panel: panel)
                }
            }

            // Focus flash overlay.
            if focusFlashOpacity > 0 {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(focusFlashOpacity))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: panel.focusFlashToken) { _, _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            // File icon.
            if let icon = panel.displayIcon {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }

            // File name — italic if preview tab.
            Text(panel.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .italic(panel.isPreview)
                .lineLimit(1)

            // Dirty indicator.
            if panel.isDirty {
                Circle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 6, height: 6)
            }

            Spacer()

            // Language badge.
            Text(panel.language.rawValue.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - File unavailable

    private var fileUnavailableView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(String(localized: "editorPanel.fileUnavailable", defaultValue: "File not available"))
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.tertiaryLabel)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
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

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/EditorPanelView.swift
git commit -m "feat(editor): add EditorPanelView with toolbar and focus flash"
```

---

### Task 6: Wire EditorPanel into PanelContentView and Workspace

**Files:**
- Modify: `Sources/Panels/PanelContentView.swift`
- Modify: `Sources/Workspace.swift`

- [ ] **Step 1: Update PanelContentView routing**

In `Sources/Panels/PanelContentView.swift`, replace the temporary `case .editor: EmptyView()` (added in Task 1) with:

```swift
        case .editor:
            if let editorPanel = panel as? EditorPanel {
                EditorPanelView(
                    panel: editorPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
```

- [ ] **Step 2: Add SurfaceKind.editor in Workspace.swift**

In the `SurfaceKind` private enum (around line 5586), ensure there is:

```swift
static let editor = "editor"
```

(This may already exist from Task 1 placeholder fixes.)

- [ ] **Step 3: Add newEditorSurface factory method**

Add this method to `Workspace.swift`, after `newMarkdownSurface`:

```swift
    // MARK: - Editor panel creation

    /// ID of the current preview (temporary) editor panel, if any.
    private(set) var previewEditorPanelId: UUID?

    @discardableResult
    func newEditorSurface(
        inPane paneId: PaneID,
        filePath: String,
        isPreview: Bool = false,
        focus: Bool? = nil
    ) -> EditorPanel? {
        // If this file is already open in a pinned editor tab, focus it instead.
        if let existingId = editorPanelId(for: filePath), !panels(existingId, isPreview: true) {
            if focus != false {
                focusPanel(existingId)
            }
            return panels[existingId] as? EditorPanel
        }

        // If opening as preview and a preview tab already exists, reuse it.
        if isPreview, let previewId = previewEditorPanelId,
           let existingPreview = panels[previewId] as? EditorPanel {
            existingPreview.replaceFile(filePath)
            // Update tab title in bonsplit.
            if let tabId = surfaceIdFromPanelId(previewId) {
                bonsplitController.updateTab(
                    tabId,
                    title: existingPreview.displayTitle,
                    icon: existingPreview.displayIcon
                )
                panelTitles[previewId] = existingPreview.displayTitle
            }
            if focus != false {
                focusPanel(previewId)
            }
            return existingPreview
        }

        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let editorPanel = EditorPanel(workspaceId: id, filePath: filePath, isPreview: isPreview)
        panels[editorPanel.id] = editorPanel
        panelTitles[editorPanel.id] = editorPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: editorPanel.displayTitle,
            icon: editorPanel.displayIcon,
            kind: SurfaceKind.editor,
            isDirty: editorPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: editorPanel.id)
            panelTitles.removeValue(forKey: editorPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = editorPanel.id

        if isPreview {
            previewEditorPanelId = editorPanel.id
        }

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: editorPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installEditorPanelSubscription(editorPanel)
        return editorPanel
    }

    /// Find an existing editor panel for the given file path.
    private func editorPanelId(for filePath: String) -> UUID? {
        for (id, panel) in panels {
            if let editor = panel as? EditorPanel, editor.filePath == filePath {
                return id
            }
        }
        return nil
    }

    /// Check if a panel is a preview editor panel.
    private func panels(_ panelId: UUID, isPreview: Bool) -> Bool {
        guard let editor = panels[panelId] as? EditorPanel else { return false }
        return editor.isPreview == isPreview
    }

    private func installEditorPanelSubscription(_ editorPanel: EditorPanel) {
        var subs = Set<AnyCancellable>()

        // Sync title changes to bonsplit tab.
        editorPanel.$displayTitle
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak editorPanel] newTitle in
                guard let self, let editorPanel,
                      let tabId = self.surfaceIdFromPanelId(editorPanel.id) else { return }
                if self.panelTitles[editorPanel.id] != newTitle {
                    self.panelTitles[editorPanel.id] = newTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: editorPanel.id, fallback: newTitle)
                self.bonsplitController.updateTab(tabId, title: resolvedTitle,
                    hasCustomTitle: self.panelCustomTitles[editorPanel.id] != nil)
            }
            .store(in: &subs)

        // Sync isDirty changes to bonsplit tab.
        editorPanel.$isDirty
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak editorPanel] isDirty in
                guard let self, let editorPanel,
                      let tabId = self.surfaceIdFromPanelId(editorPanel.id) else { return }
                self.bonsplitController.updateTab(tabId, isDirty: isDirty)
            }
            .store(in: &subs)

        // Track preview → pinned promotion.
        editorPanel.$isPreview
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak editorPanel] isPreview in
                guard let self, let editorPanel else { return }
                if !isPreview && self.previewEditorPanelId == editorPanel.id {
                    self.previewEditorPanelId = nil
                }
            }
            .store(in: &subs)

        panelSubscriptions[editorPanel.id] = subs
    }
```

Note: The `previewEditorPanelId` property needs to be declared at the class level. Find the appropriate section in `Workspace.swift` where properties are declared (near other panel-related state) and add:

```swift
/// ID of the current preview (temporary) editor panel in this workspace.
var previewEditorPanelId: UUID?
```

- [ ] **Step 4: Update surfaceKind for .editor**

Ensure the `surfaceKind(for:)` method includes `case .editor: return SurfaceKind.editor`.

- [ ] **Step 5: Clean up didCloseTab to clear previewEditorPanelId**

Find the bonsplit delegate callback `didCloseTab` (or equivalent close cleanup) in Workspace.swift. Add cleanup for the preview editor tracking:

```swift
// Inside the panel close cleanup path:
if panelId == previewEditorPanelId {
    previewEditorPanelId = nil
}
```

Search for where panel cleanup happens after bonsplit close:
```bash
grep -n "didCloseTab\|panels.removeValue" Sources/Workspace.swift | head -20
```

- [ ] **Step 6: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add Sources/Panels/PanelContentView.swift Sources/Workspace.swift
git commit -m "feat(editor): wire EditorPanel into PanelContentView and Workspace"
```

---

### Task 7: Add session persistence for editor panels

**Files:**
- Modify: `Sources/SessionPersistence.swift`
- Modify: `Sources/Workspace.swift`

- [ ] **Step 1: Define SessionEditorPanelSnapshot**

In `Sources/SessionPersistence.swift`, replace the empty/placeholder `SessionEditorPanelSnapshot` (from Task 1) with:

```swift
struct SessionEditorPanelSnapshot: Codable, Sendable {
    var filePath: String
    var isPreview: Bool
}
```

- [ ] **Step 2: Add editor field to SessionPanelSnapshot**

Ensure `SessionPanelSnapshot` has (may already exist from Task 1):

```swift
var editor: SessionEditorPanelSnapshot?
```

- [ ] **Step 3: Update sessionPanelSnapshot in Workspace.swift**

In the `sessionPanelSnapshot(panelId:includeScrollback:)` method, replace the temporary `case .editor: return nil` with:

```swift
        case .editor:
            guard let editorPanel = panel as? EditorPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = nil
            fileExplorerSnapshot = nil
            editorSnapshot = SessionEditorPanelSnapshot(
                filePath: editorPanel.filePath,
                isPreview: editorPanel.isPreview
            )
```

You will also need to:
1. Add `let editorSnapshot: SessionEditorPanelSnapshot?` variable declaration alongside the other snapshot variables at the top of the method.
2. Set `editorSnapshot = nil` in all other cases (.terminal, .browser, .markdown, .fileExplorer).
3. Add `editor: editorSnapshot` to the return `SessionPanelSnapshot(...)` constructor.

- [ ] **Step 4: Update createPanel for .editor restore**

In the `createPanel(from:inPane:)` method, replace the temporary `case .editor: return nil` with:

```swift
        case .editor:
            guard let filePath = snapshot.editor?.filePath,
                  FileManager.default.fileExists(atPath: filePath),
                  let editorPanel = newEditorSurface(
                    inPane: paneId,
                    filePath: filePath,
                    isPreview: snapshot.editor?.isPreview ?? false,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: editorPanel.id)
            return editorPanel.id
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Sources/SessionPersistence.swift Sources/Workspace.swift
git commit -m "feat(editor): add session persistence for editor panels"
```

---

### Task 8: Connect file explorer to editor panel

**Files:**
- Modify: `Sources/Panels/FileExplorerDataSource.swift`
- Modify: `Sources/Panels/FileExplorerOutlineView.swift`
- Modify: `Sources/Panels/FileExplorerPanelView.swift`

- [ ] **Step 1: Add single-click callback to FileExplorerDataSource**

In `Sources/Panels/FileExplorerDataSource.swift`, add a new callback property alongside `onFileDoubleClick`:

```swift
var onFileSingleClick: ((FileNode) -> Void)?
```

Add `outlineViewSelectionDidChange` delegate method (after the existing delegate methods around line 135):

```swift
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if !node.isDirectory {
            onFileSingleClick?(node)
        }
    }
```

- [ ] **Step 2: Wire single-click callback in FileExplorerOutlineView**

In `Sources/Panels/FileExplorerOutlineView.swift`, add the callback parameter to the struct:

```swift
struct FileExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var panel: FileExplorerPanel
    let onFileOpen: (FileNode) -> Void
    let onFilePreview: ((FileNode) -> Void)?
```

Update the `Coordinator` init to wire the callback:

```swift
init(panel: FileExplorerPanel, onFileOpen: @escaping (FileNode) -> Void, onFilePreview: ((FileNode) -> Void)?) {
    self.dataSource = FileExplorerDataSource()
    self.dataSource.panel = panel
    self.dataSource.onFileDoubleClick = onFileOpen
    self.dataSource.onFileSingleClick = onFilePreview
    self.dataSource.onNodeExpand = { [weak panel] node in
        panel?.refreshExpandedNode(node)
    }
}
```

Update `makeCoordinator`:

```swift
func makeCoordinator() -> Coordinator {
    Coordinator(panel: panel, onFileOpen: onFileOpen, onFilePreview: onFilePreview)
}
```

- [ ] **Step 3: Update FileExplorerPanelView to handle preview and open**

In `Sources/Panels/FileExplorerPanelView.swift`, replace the current `openFile` method and update the `FileExplorerOutlineView` call.

Add a workspace reference. The view needs access to the workspace to create editor panels. Add an environment object or callback. The cleanest approach is callbacks passed from the parent:

Add new callback properties to `FileExplorerPanelView`:

```swift
struct FileExplorerPanelView: View {
    @ObservedObject var panel: FileExplorerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void
    var onOpenFileInEditor: ((String, Bool) -> Void)?  // (filePath, isPreview)
```

Update the `FileExplorerOutlineView` usage in the body to pass both callbacks:

```swift
FileExplorerOutlineView(
    panel: panel,
    onFileOpen: { openFile($0) },
    onFilePreview: { previewFile($0) }
)
```

Update `openFile` and add `previewFile`:

```swift
    private func openFile(_ node: FileNode) {
        let path = node.url.path
        if EditorPanel.isBinaryFile(at: path) {
            NSWorkspace.shared.open(node.url)
        } else {
            onOpenFileInEditor?(path, false)
        }
    }

    private func previewFile(_ node: FileNode) {
        let path = node.url.path
        if EditorPanel.isBinaryFile(at: path) {
            return  // Don't preview binary files.
        }
        onOpenFileInEditor?(path, true)
    }
```

- [ ] **Step 4: Wire the callback from PanelContentView**

In `Sources/Panels/PanelContentView.swift`, update the `.fileExplorer` case to pass the editor callback. This requires adding an `onOpenFileInEditor` callback to `PanelContentView`:

```swift
struct PanelContentView: View {
    // ... existing properties ...
    var onOpenFileInEditor: ((String, Bool) -> Void)?
```

In the `.fileExplorer` case:

```swift
        case .fileExplorer:
            if let fileExplorerPanel = panel as? FileExplorerPanel {
                FileExplorerPanelView(
                    panel: fileExplorerPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestPanelFocus: onRequestPanelFocus,
                    onOpenFileInEditor: onOpenFileInEditor
                )
            }
```

- [ ] **Step 5: Wire the callback from WorkspaceContentView**

Find where `PanelContentView` is instantiated in the `BonsplitView` closure in `WorkspaceContentView` (or `ContentView.swift`). Pass a closure that calls workspace:

```swift
onOpenFileInEditor: { filePath, isPreview in
    let pane = workspace.bonsplitController.focusedPaneId ?? paneId
    workspace.newEditorSurface(
        inPane: pane,
        filePath: filePath,
        isPreview: isPreview,
        focus: true
    )
}
```

Search for the exact instantiation site:
```bash
grep -n "PanelContentView(" Sources/ContentView.swift Sources/WorkspaceContentView.swift 2>/dev/null | head -10
```

- [ ] **Step 6: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add Sources/Panels/FileExplorerDataSource.swift Sources/Panels/FileExplorerOutlineView.swift Sources/Panels/FileExplorerPanelView.swift Sources/Panels/PanelContentView.swift Sources/ContentView.swift
git commit -m "feat(editor): connect file explorer single-click/double-click to editor tabs"
```

---

### Task 9: Add editor.open socket command

**Files:**
- Modify: `Sources/TerminalController.swift`

- [ ] **Step 1: Register the command**

In `Sources/TerminalController.swift`, find the command dispatch switch (around line 2343 where `markdown.open` is registered). Add after the markdown case:

```swift
        // Editor
        case "editor.open":
            return v2Result(id: id, self.v2EditorOpen(params: params))
```

Also add `"editor.open"` to the allowed-commands list (around line 2486 where `markdown.open` appears):

```swift
            "editor.open",
```

- [ ] **Step 2: Implement v2EditorOpen**

Add the method near the `v2MarkdownOpen` method (around line 7134). Follow the same pattern:

```swift
    // MARK: - Editor

    private func v2EditorOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }

        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        guard filePath.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "Path must be absolute: \(filePath)", data: ["path": filePath])
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return .err(code: "not_found", message: "File not found: \(filePath)", data: ["path": filePath])
        }
        guard !isDir.boolValue else {
            return .err(code: "invalid_params", message: "Path is a directory: \(filePath)", data: ["path": filePath])
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return .err(code: "permission_denied", message: "File not readable: \(filePath)", data: ["path": filePath])
        }

        if EditorPanel.isBinaryFile(at: filePath) {
            return .err(code: "invalid_params", message: "File appears to be binary: \(filePath)", data: ["path": filePath])
        }

        let isPreview = v2Bool(params, "preview") ?? false
        let shouldFocus = v2Bool(params, "focus") ?? true

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create editor panel", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if shouldFocus {
                v2MaybeFocusWindow(for: tabManager)
                v2MaybeSelectWorkspace(tabManager, workspace: ws)
            }

            guard let focusedPaneId = ws.bonsplitController.focusedPaneId else {
                result = .err(code: "not_found", message: "No focused pane", data: nil)
                return
            }

            let createdPanel = ws.newEditorSurface(
                inPane: focusedPaneId,
                filePath: filePath,
                isPreview: isPreview,
                focus: shouldFocus ? true : false
            )

            guard let editorPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create editor panel", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "workspace_id": ws.id.uuidString,
                "surface_id": editorPanelId.uuidString,
                "path": filePath,
                "preview": isPreview
            ])
        }
        return result
    }
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/TerminalController.swift
git commit -m "feat(editor): add editor.open socket command"
```

---

### Task 10: Add editor to command palette and localization

**Files:**
- Modify: `Sources/ContentView.swift`
- Modify: `Resources/Localizable.xcstrings`

- [ ] **Step 1: Update command palette kind for editor**

In `Sources/ContentView.swift`, find the command palette kind switch (around line 5004). The `.editor` case should already have been added in Task 1. Verify it has proper display name and search keywords:

```swift
case .editor:
    return String(localized: "commandPalette.kind.editor", defaultValue: "Editor")
```

And for keywords:

```swift
case .editor:
    return ["editor", "text", "file", "edit", "notepad"]
```

- [ ] **Step 2: Add localization entries**

In `Resources/Localizable.xcstrings`, add entries for:
- `commandPalette.kind.editor` → EN: "Editor", JA: "エディタ"
- `editorPanel.fileUnavailable` → EN: "File not available", JA: "ファイルが見つかりません"

Open the file and add the entries following the existing format.

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-editor-tab build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/ContentView.swift Resources/Localizable.xcstrings
git commit -m "feat(editor): add editor to command palette and localization"
```

---

### Task 11: Manual verification build and test

- [ ] **Step 1: Full clean build**

```bash
./scripts/reload.sh --tag editor-tab
```

Expected: BUILD SUCCEEDED, app path printed.

- [ ] **Step 2: Verify file explorer → editor tab flow**

1. Open the built app.
2. Open a file explorer panel.
3. Single-click a `.json` file → verify a preview tab opens with syntax highlighting.
4. Single-click a different `.md` file → verify the preview tab is reused (content switches).
5. Double-click a `.swift` file → verify a pinned tab opens.
6. Edit text in the editor → verify isDirty dot appears on tab.
7. Press Cmd+S → verify the dot disappears and file is saved.
8. Edit the preview tab → verify it promotes to a pinned tab.

- [ ] **Step 3: Verify socket command**

```bash
echo '{"jsonrpc":"2.0","method":"editor.open","params":{"path":"'$HOME'/.zshrc"},"id":1}' | socat - UNIX-CONNECT:/tmp/cmux-debug-editor-tab.sock
```

Expected: JSON response with surface_id.

- [ ] **Step 4: Commit any fixes found during testing**

```bash
git add -A
git commit -m "fix(editor): address issues found during manual testing"
```

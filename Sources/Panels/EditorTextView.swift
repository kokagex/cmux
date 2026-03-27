import AppKit
import SwiftUI

// MARK: - NSTextView subclass

/// NSTextView subclass that intercepts key events (e.g. Cmd+S) before the
/// standard responder chain handles them.
final class EditorNSTextView: NSTextView {
    var keyDownHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - NSViewRepresentable

/// Wraps an NSTextView inside an NSScrollView for editing files.
///
/// **Architecture:** NSTextView is the source of truth for content.
/// `EditorPanel.fileContent` is only used for initial load and external file
/// reloads. The view notifies the panel of edits via `panel.markDirty()` --
/// it never copies the full string back on every keystroke.
struct EditorTextView: NSViewRepresentable {
    @ObservedObject var panel: EditorPanel

    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate {
        let panel: EditorPanel
        var textView: EditorNSTextView?
        var lastContentGeneration: Int
        private var isUpdatingFromModel = false
        private var highlightWorkItem: DispatchWorkItem?

        init(panel: EditorPanel) {
            self.panel = panel
            self.lastContentGeneration = panel.fileContentGeneration
            super.init()
        }

        func setIsUpdatingFromModel(_ value: Bool) {
            isUpdatingFromModel = value
        }

        // MARK: NSTextStorageDelegate

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range _: NSRange,
            changeInLength _: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isUpdatingFromModel else { return }
            panel.markDirty()
            scheduleHighlight()
        }

        // MARK: Debounced highlighting

        func scheduleHighlight() {
            highlightWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let textView = self.textView, let ts = textView.textStorage else { return }
                SyntaxHighlighter.highlight(ts, language: self.panel.language, font: EditorTextView.editorFont)
            }
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
        }

        // MARK: Cmd+S handler

        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "s" else { return false }
            if let text = textView?.string {
                panel.save(text: text)
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    // MARK: - makeNSView

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
        textView.usesFindBar = true
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

        // Layout: wrap to scroll view width
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        textView.keyDownHandler = context.coordinator.handleKeyDown
        scrollView.documentView = textView
        context.coordinator.textView = textView
        textView.textStorage?.delegate = context.coordinator

        // Set initial content
        context.coordinator.setIsUpdatingFromModel(true)
        textView.string = panel.fileContent
        context.coordinator.setIsUpdatingFromModel(false)

        // Initial highlight
        if let ts = textView.textStorage {
            SyntaxHighlighter.highlight(ts, language: panel.language, font: Self.editorFont)
        }

        return scrollView
    }

    // MARK: - updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Only update when fileContentGeneration changed (external reload)
        if context.coordinator.lastContentGeneration != panel.fileContentGeneration {
            context.coordinator.lastContentGeneration = panel.fileContentGeneration
            context.coordinator.setIsUpdatingFromModel(true)
            textView.string = panel.fileContent
            context.coordinator.setIsUpdatingFromModel(false)
            if let ts = textView.textStorage {
                SyntaxHighlighter.highlight(ts, language: panel.language, font: Self.editorFont)
            }
        }
    }
}

import AppKit
import SwiftUI

// MARK: - Line Number Ruler

/// Draws line numbers in the gutter alongside the text view.
///
/// Performance: total line count is cached and only recomputed when the text
/// changes (via `invalidateLineCount()`). Newline counting uses a fast byte
/// scan instead of NSString.lineRange iteration.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    private static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: gutterFont,
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    private static let minGutterWidth: CGFloat = 36
    private static let rightPadding: CGFloat = 8

    /// Cached total line count; invalidated on text change.
    private var cachedTotalLines: Int = 1
    private var cachedTextGeneration: Int = -1
    /// Cached digit count for gutter width calculation.
    private var cachedDigitCount: Int = 2
    private var cachedGutterWidth: CGFloat = 0

    init(textView: NSTextView) {
        self.textView = textView
        super.init(
            scrollView: textView.enclosingScrollView!,
            orientation: .verticalRuler
        )
        self.ruleThickness = Self.minGutterWidth
        self.clientView = textView
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Called by EditorNSTextView when text content changes.
    func invalidateLineCount() {
        cachedTextGeneration = -1
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in _: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? bounds

        // Compute glyph range visible in the scroll view
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil
        )

        // Update cached total line count only when text changed
        let content = textView.string
        let textGen = content.hashValue
        if textGen != cachedTextGeneration {
            cachedTotalLines = Self.countNewlines(in: content, upTo: content.utf16.count) + 1
            cachedTextGeneration = textGen
        }

        let digitCount = max(String(cachedTotalLines).count, 2)
        if digitCount != cachedDigitCount || cachedGutterWidth == 0 {
            cachedDigitCount = digitCount
            let sampleString = String(repeating: "8", count: digitCount) as NSString
            cachedGutterWidth = sampleString.size(withAttributes: Self.textAttributes).width + Self.rightPadding + 4
        }
        if abs(ruleThickness - cachedGutterWidth) > 1 {
            ruleThickness = cachedGutterWidth
            needsDisplay = true
        }

        // Draw background
        NSColor.textBackgroundColor.withAlphaComponent(0.5).setFill()
        bounds.fill()

        // Line number at the start of the visible range
        let nsContent = content as NSString
        var lineNumber = Self.countNewlines(in: content, upTo: visibleCharRange.location) + 1
        var charIndex = visibleCharRange.location

        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = nsContent.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            lineRect.origin.y += textView.textContainerInset.height

            let yInRuler = lineRect.origin.y - visibleRect.origin.y

            let numberString = "\(lineNumber)" as NSString
            let stringSize = numberString.size(withAttributes: Self.textAttributes)
            let drawPoint = NSPoint(
                x: ruleThickness - stringSize.width - Self.rightPadding,
                y: yInRuler + (lineRect.height - stringSize.height) / 2
            )
            numberString.draw(at: drawPoint, withAttributes: Self.textAttributes)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }

    /// Fast newline count using UTF-16 scan up to the given UTF-16 offset.
    private static func countNewlines(in string: String, upTo utf16Limit: Int) -> Int {
        var count = 0
        var offset = 0
        for char in string {
            if offset >= utf16Limit { break }
            if char == "\n" { count += 1 }
            offset += char.utf16.count
        }
        return count
    }
}

// MARK: - NSTextView subclass

/// NSTextView subclass that intercepts key events (e.g. Cmd+S) before the
/// standard responder chain handles them.
final class EditorNSTextView: NSTextView {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var onBecomeFirstResponder: (() -> Void)?
    weak var lineNumberRuler: LineNumberRulerView?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onBecomeFirstResponder?() }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        lineNumberRuler?.invalidateLineCount()
    }

    override var frame: NSRect {
        didSet { lineNumberRuler?.needsDisplay = true }
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
    var onBecomeFirstResponder: (() -> Void)?

    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate {
        let panel: EditorPanel
        var textView: EditorNSTextView?
        var lastContentGeneration: Int
        var boundsObserver: NSObjectProtocol?
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
        textView.onBecomeFirstResponder = onBecomeFirstResponder
        scrollView.documentView = textView
        context.coordinator.textView = textView
        panel.focusableTextView = textView
        textView.textStorage?.delegate = context.coordinator

        // Line number ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        textView.lineNumberRuler = ruler

        // Observe scroll/resize to update line numbers (store token for cleanup)
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { _ in ruler.needsDisplay = true }

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

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.boundsObserver = nil
        }
        coordinator.panel.focusableTextView = nil
    }

    // MARK: - updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorNSTextView else { return }
        textView.onBecomeFirstResponder = onBecomeFirstResponder

        // Only update when fileContentGeneration changed (external reload)
        if context.coordinator.lastContentGeneration != panel.fileContentGeneration {
            context.coordinator.lastContentGeneration = panel.fileContentGeneration
            context.coordinator.setIsUpdatingFromModel(true)
            textView.string = panel.fileContent
            context.coordinator.setIsUpdatingFromModel(false)
            if let ts = textView.textStorage {
                SyntaxHighlighter.highlight(ts, language: panel.language, font: Self.editorFont)
            }
            // Refresh line numbers after content change
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }
}

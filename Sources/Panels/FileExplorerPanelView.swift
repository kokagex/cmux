import AppKit
import SwiftUI

/// SwiftUI view that renders a FileExplorerPanel's directory tree.
struct FileExplorerPanelView: View {
    @ObservedObject var panel: FileExplorerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void
    var onOpenFileInEditor: ((String, Bool) -> Void)?
    var onOpenFileInBrowser: ((URL) -> Void)?

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0


    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            FileExplorerOutlineView(panel: panel, onFileOpen: { openFile($0) }, onFilePreview: { previewFile($0) }, onFileOpenInEditor: { onOpenFileInEditor?($0, false) }, onFileOpenInBrowser: onOpenFileInBrowser)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Root path button
            Button(action: changeRootPath) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(abbreviatedPath)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Filter field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField(
                    String(localized: "fileExplorer.toolbar.filter.placeholder", defaultValue: "Filter"),
                    text: $panel.filterText
                )
                .font(.system(size: 11))
                .textFieldStyle(.plain)
                .frame(maxWidth: 140)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
            )

            // Options menu
            Menu {
                Toggle(
                    String(localized: "fileExplorer.toolbar.showHiddenFiles", defaultValue: "Show Hidden Files"),
                    isOn: $panel.showHiddenFiles
                )
                Toggle(
                    String(localized: "fileExplorer.toolbar.showIgnoredFiles", defaultValue: "Show Ignored Files"),
                    isOn: $panel.showIgnoredFiles
                )

            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Helpers

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if panel.rootPath.hasPrefix(home) {
            return "~" + panel.rootPath.dropFirst(home.count)
        }
        return panel.rootPath
    }

    private var backgroundColor: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private func changeRootPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "fileExplorer.openPanel.message", defaultValue: "Choose a folder to explore")
        panel.prompt = String(localized: "fileExplorer.openPanel.prompt", defaultValue: "Open")
        if panel.runModal() == .OK, let url = panel.url {
            self.panel.rootPath = url.path
        }
    }

    private func openFile(_ node: FileNode) {
        if FileExplorerDataSource.isWebKitRenderable(node.url) {
            onOpenFileInBrowser?(node.url)
        } else if EditorPanel.isBinaryFile(at: node.url.path) {
            NSWorkspace.shared.open(node.url)
        } else {
            onOpenFileInEditor?(node.url.path, false)
        }
    }

    private func previewFile(_ node: FileNode) {
        if FileExplorerDataSource.isWebKitRenderable(node.url) {
            return
        }
        let path = node.url.path
        if EditorPanel.isBinaryFile(at: path) {
            return
        }
        onOpenFileInEditor?(path, true)
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
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

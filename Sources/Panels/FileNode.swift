import Foundation

// MARK: - GitFileStatus

enum GitFileStatus: Sendable {
    case unmodified
    case modified
    case added
    case deleted
    case untracked
    case conflicted
}

// MARK: - FileNode

@MainActor
final class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool

    /// nil = not yet loaded, [] = empty directory
    var children: [FileNode]?
    var isExpanded: Bool = false
    var gitStatus: GitFileStatus = .unmodified

    init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }

    /// Loads children from the filesystem.
    /// - Parameters:
    ///   - showHidden: Whether to include hidden files (names starting with `.`).
    ///   - ignoredPaths: Set of absolute path strings to exclude from results.
    func loadChildren(showHidden: Bool, ignoredPaths: Set<String> = []) {
        guard isDirectory else {
            children = nil
            return
        }

        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: []
            )
        } catch {
            children = []
            return
        }

        var nodes: [FileNode] = []
        for itemURL in contents {
            // Filter hidden files
            let itemName = itemURL.lastPathComponent
            if !showHidden && itemName.hasPrefix(".") {
                continue
            }

            // Filter ignored paths
            let absolutePath = itemURL.path
            if ignoredPaths.contains(absolutePath) {
                continue
            }

            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let node = FileNode(url: itemURL, name: itemName, isDirectory: isDir)
            nodes.append(node)
        }

        // Sort: directories first, then alphabetical (localizedStandardCompare)
        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        children = nodes
    }
}

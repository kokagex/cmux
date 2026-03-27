// FileIconMapper.swift
// Maps file extensions and filenames to SF Symbol icon names.
// All symbols are available on macOS 13+.

import Foundation

enum FileIconMapper {
    static let folderIcon = "folder.fill"
    static let fileIcon = "doc.fill"

    static let extensionMap: [String: String] = [
        // Swift / Apple
        "swift": "swift",
        "xcodeproj": "hammer.fill",
        "xcworkspace": "hammer.fill",
        "plist": "list.bullet.rectangle.fill",
        "xcconfig": "gearshape.fill",
        "xcstrings": "character.bubble.fill",

        // Web
        "html": "globe",
        "css": "paintbrush.fill",
        "js": "doc.text.fill",
        "jsx": "doc.text.fill",
        "ts": "doc.text.fill",
        "tsx": "doc.text.fill",

        // Data / Config
        "json": "curlybraces",
        "xml": "chevron.left.forwardslash.chevron.right",
        "svg": "photo.fill",
        "yaml": "list.dash",
        "yml": "list.dash",
        "toml": "list.dash",
        "ini": "gearshape",
        "cfg": "gearshape",
        "conf": "gearshape",
        "env": "lock.fill",

        // Languages
        "py": "terminal.fill",
        "rb": "terminal.fill",
        "go": "terminal.fill",
        "rs": "terminal.fill",
        "c": "c.square.fill",
        "cpp": "chevron.left.forwardslash.chevron.right",
        "h": "c.square",
        "m": "m.square.fill",
        "mm": "m.square.fill",
        "java": "j.square.fill",
        "zig": "terminal.fill",

        // Docs
        "md": "text.alignleft",
        "markdown": "text.alignleft",
        "txt": "doc.plaintext.fill",

        // Images
        "png": "photo.fill",
        "jpg": "photo.fill",
        "jpeg": "photo.fill",
        "gif": "photo.fill",
        "webp": "photo.fill",
        "ico": "photo.fill",
        "icns": "photo.fill",

        // Archives
        "zip": "archivebox.fill",
        "tar": "archivebox.fill",
        "gz": "archivebox.fill",
        "dmg": "externaldrive.fill",

        // Scripts
        "sh": "terminal",
        "bash": "terminal",
        "zsh": "terminal",
        "fish": "terminal",

        // Dotfiles / VCS
        "gitignore": "arrow.triangle.branch",
        "gitmodules": "arrow.triangle.branch",

        // Database
        "db": "cylinder.fill",
        "sqlite": "cylinder.fill",
        "sql": "cylinder.fill",
        "csv": "tablecells.fill",
    ]

    static let filenameMap: [String: String] = [
        "Makefile": "hammer",
        "Dockerfile": "shippingbox.fill",
        "LICENSE": "checkmark.seal.fill",
        "CHANGELOG.md": "clock.arrow.circlepath",
        "README.md": "info.circle.fill",
        "CLAUDE.md": "brain",
        "Package.swift": "swift",
        ".gitignore": "arrow.triangle.branch",
        ".env": "lock.fill",
    ]

    /// Returns the SF Symbol name for the given filename or path component.
    /// - Parameters:
    ///   - name: The filename (last path component).
    ///   - isDirectory: Whether the item is a directory.
    /// - Returns: An SF Symbol name string.
    static func icon(for name: String, isDirectory: Bool) -> String {
        if isDirectory {
            return folderIcon
        }

        if let symbol = filenameMap[name] {
            return symbol
        }

        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if !ext.isEmpty, let symbol = extensionMap[ext] {
            return symbol
        }

        // Some dotfiles have no extension; try the full name lowercased.
        let nameLower = name.lowercased()
        if let symbol = extensionMap[nameLower] {
            return symbol
        }

        return fileIcon
    }
}

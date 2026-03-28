import Foundation

/// Provides git status information for files in a repository.
actor GitStatusProvider {
    private let rootPath: String
    private let queue = DispatchQueue(label: "com.cmux.git-status", qos: .utility)

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// Fetches the git status for all files in the repository.
    ///
    /// Runs `git status --porcelain=v1 -z` and parses NUL-delimited output.
    /// Returns a dictionary mapping absolute file paths to their `GitFileStatus`.
    /// Returns an empty dictionary if not a git repo or the command fails.
    func fetchStatuses() async -> [String: GitFileStatus] {
        return await withCheckedContinuation { continuation in
            queue.async { [rootPath] in
                let result = Self.runGit(
                    args: ["status", "--porcelain=v1", "-z", "--ignored"],
                    rootPath: rootPath
                )
                guard let output = result else {
                    continuation.resume(returning: [:])
                    return
                }
                let statuses = Self.parsePortcelainV1(output: output, rootPath: rootPath)
                continuation.resume(returning: statuses)
            }
        }
    }

    /// Checks which of the given absolute paths are ignored by git.
    ///
    /// Runs `git check-ignore -z --stdin`, writes paths NUL-separated to stdin,
    /// and returns the set of absolute paths that are ignored.
    func fetchIgnoredPaths(_ paths: [String]) async -> Set<String> {
        guard !paths.isEmpty else { return [] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
            queue.async { [rootPath] in
                // Convert absolute paths to relative for git check-ignore
                let relativePaths = paths.map { path -> String in
                    if path.hasPrefix(rootPath + "/") {
                        return String(path.dropFirst(rootPath.count + 1))
                    }
                    return path
                }

                let stdinData = relativePaths
                    .joined(separator: "\0")
                    .appending("\0")
                    .data(using: .utf8) ?? Data()

                let result = Self.runGit(
                    args: ["check-ignore", "-z", "--stdin"],
                    rootPath: rootPath,
                    stdinData: stdinData
                )

                guard let output = result, !output.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }

                // output is already NUL-split by runGit, convert to absolute paths
                let ignoredArray: [String] = output.map { relativePath in
                    rootPath + "/" + String(relativePath)
                }
                let ignored = Set(ignoredArray)
                continuation.resume(returning: ignored)
            }
        }
    }

    // MARK: - Private helpers

    /// Runs a git command in rootPath, optionally writing stdinData to the process stdin.
    /// Returns the stdout as a Substring sequence split on NUL, or nil on failure.
    private static func runGit(
        args: [String],
        rootPath: String,
        stdinData: Data? = nil
    ) -> [Substring]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: rootPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let data = stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            do {
                try process.run()
            } catch {
                return nil
            }
            stdinPipe.fileHandleForWriting.write(data)
            stdinPipe.fileHandleForWriting.closeFile()
        } else {
            do {
                try process.run()
            } catch {
                return nil
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outputString = String(data: outputData, encoding: .utf8) else {
            return nil
        }

        return outputString.split(separator: "\0", omittingEmptySubsequences: false)
    }

    /// Parses `git status --porcelain=v1 -z` NUL-delimited output.
    ///
    /// Format: "XY PATH\0" for normal entries.
    /// Renames: "XY DEST\0ORIG\0" (dest is first field, orig is the next NUL-separated token).
    private static func parsePortcelainV1(
        output: [Substring],
        rootPath: String
    ) -> [String: GitFileStatus] {
        var result: [String: GitFileStatus] = [:]
        var index = output.startIndex

        while index < output.endIndex {
            let entry = output[index]
            index = output.index(after: index)

            // Each entry is at least "XY PATH" (5+ chars: 2 status + 1 space + 1+ path)
            guard entry.count >= 4 else { continue }

            let x = entry[entry.startIndex]  // index status
            let y = entry[entry.index(after: entry.startIndex)]  // working tree status
            // entry[2] should be a space
            let pathStart = entry.index(entry.startIndex, offsetBy: 3)
            let relativePath = String(entry[pathStart...])

            guard !relativePath.isEmpty else { continue }

            // Strip trailing slash from ignored directories
            let cleanedPath = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
            let absolutePath = rootPath + "/" + cleanedPath
            let status = gitFileStatus(x: x, y: y)
            result[absolutePath] = status

            // For renames (R or C in index), the next NUL-token is the original path
            if x == "R" || x == "C" {
                // Consume (and skip) the original path token
                if index < output.endIndex {
                    index = output.index(after: index)
                }
            }
        }

        return result
    }

    /// Maps XY status characters from `git status --porcelain=v1` to `GitFileStatus`.
    private static func gitFileStatus(x: Character, y: Character) -> GitFileStatus {
        // Ignored
        if x == "!" && y == "!" {
            return .ignored
        }

        // Conflict markers
        if x == "U" || y == "U" {
            return .conflicted
        }
        // Both added or both deleted (special conflict states)
        if (x == "A" && y == "A") || (x == "D" && y == "D") {
            return .conflicted
        }

        // Untracked
        if x == "?" && y == "?" {
            return .untracked
        }

        // Working tree status takes priority for display purposes
        switch y {
        case "M":
            return .modified
        case "D":
            return .deleted
        case "?":
            return .untracked
        default:
            break
        }

        // Index (staged) status
        switch x {
        case "A":
            return .added
        case "M":
            return .modified
        case "D":
            return .deleted
        case "R":
            // Rename counts as modified for display
            return .modified
        default:
            break
        }

        return .unmodified
    }
}

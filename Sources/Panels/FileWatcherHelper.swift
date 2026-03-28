import Foundation

/// Reusable file watcher using DispatchSource.
///
/// Monitors a file for changes (write, delete, rename, extend) and invokes
/// a callback on the main actor when events are detected. Handles automatic
/// reattach when the file is deleted or renamed (e.g., atomic saves).
@MainActor
final class FileWatcherHelper {

    /// Distinguishes content changes from file-level events.
    enum ChangeKind {
        /// File content was modified (.write or .extend).
        case contentChanged
        /// File was deleted or renamed (.delete or .rename).
        case deletedOrRenamed
    }

    /// Called on the main actor when a file event is detected.
    private let onChange: (ChangeKind) -> Void

    /// Called on the main actor when the watcher successfully reattaches
    /// after a delete/rename retry loop.
    private let onReattach: (() -> Void)?

    /// Absolute path of the file being watched.
    private(set) var filePath: String?

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isStopped: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.file-watch", qos: .utility)

    /// Maximum number of reattach attempts after a file delete/rename event.
    private static let maxReattachAttempts = 6
    /// Delay between reattach attempts (total window: attempts * delay = 3s).
    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    /// Creates a new file watcher.
    /// - Parameters:
    ///   - onChange: Called on the main actor when a file event occurs.
    ///   - onReattach: Called on the main actor when the watcher successfully
    ///     reattaches after a delete/rename retry loop.
    init(onChange: @escaping (ChangeKind) -> Void, onReattach: (() -> Void)? = nil) {
        self.onChange = onChange
        self.onReattach = onReattach
    }

    deinit {
        // DispatchSource cancel is safe from any thread.
        fileWatchSource?.cancel()
    }

    // MARK: - Public API

    /// Start watching the given file path. Stops any existing watch first.
    func start(filePath: String) {
        stop()
        self.filePath = filePath
        self.isStopped = false
        startFileWatcher()
        if fileWatchSource == nil {
            // File may not exist yet (e.g., session restore before recreation).
            // Retry briefly so atomic-rename recreations can reconnect.
            scheduleReattach(attempt: 1)
        }
    }

    /// Stop watching. Safe to call multiple times.
    func stop() {
        isStopped = true
        stopFileWatcher()
        filePath = nil
    }

    // MARK: - Internal watcher management

    private func startFileWatcher() {
        guard let filePath else { return }

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
                    self.onChange(.deletedOrRenamed)
                }
            } else {
                DispatchQueue.main.async {
                    self.onChange(.contentChanged)
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    /// Retry reattaching the file watcher up to `maxReattachAttempts` times.
    /// Each attempt checks if the file has reappeared. Bails out early if
    /// the watcher has been stopped.
    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isStopped, let filePath = self.filePath else { return }
                if FileManager.default.fileExists(atPath: filePath) {
                    self.startFileWatcher()
                    self.onReattach?()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    /// Reattach the watcher to the current file path (e.g., after an atomic save
    /// replaces the inode). If the file is not yet available, begins the
    /// reattach retry loop.
    func reattach() {
        guard !isStopped, let filePath else { return }
        startFileWatcher()
        if fileWatchSource == nil {
            scheduleReattach(attempt: 1)
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        // File descriptor is closed by the cancel handler.
        fileDescriptor = -1
    }
}

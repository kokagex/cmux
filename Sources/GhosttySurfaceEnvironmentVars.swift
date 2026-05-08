import Darwin

// Helpers to build the C-array of environment variables that
// `ghostty_surface_new` consumes. Pulled out of `TerminalSurface.createSurface`
// so the conversion can be regression-tested directly — the loop was once lost
// in a merge resolution (0.63.0) and silently broke shell-integration injection
// because nothing covered it.
enum GhosttySurfaceEnvironmentVars {
    typealias Storage = (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)

    /// Append `env` to `envVars`/`storage`, allocating C strings via `strdup`.
    /// Caller owns the freeing of the appended `Storage` entries (the existing
    /// `defer` block in `createSurface` does this for the whole vector).
    static func append(
        from env: [String: String],
        into envVars: inout [ghostty_env_var_s],
        storage: inout [Storage]
    ) {
        guard !env.isEmpty else { return }
        envVars.reserveCapacity(envVars.count + env.count)
        storage.reserveCapacity(storage.count + env.count)
        for (key, value) in env {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            storage.append((keyPtr, valuePtr))
            envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
        }
    }

    /// Free C strings allocated by `append(from:into:storage:)`.
    static func freeStorage(_ storage: [Storage]) {
        for (key, value) in storage {
            free(key)
            free(value)
        }
    }
}

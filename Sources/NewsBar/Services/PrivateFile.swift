import Darwin
import Foundation

#if DEBUG
/// Test-only fault injection. Compiled out of release builds.
enum PrivateFileFaults {
    private static let lock = NSLock()
    private static var _failBeforeRename = false

    static var failBeforeRename: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _failBeforeRename
        }
        set {
            lock.lock()
            _failBeforeRename = newValue
            lock.unlock()
        }
    }

    static func reset() {
        failBeforeRename = false
    }
}
#endif

enum PrivateFileError: Error, Equatable {
    case openFailed(Int32)
    case permissionMismatch
    case writeFailed(Int32)
    case syncFailed(Int32)
    case renameFailed(Int32)
    case invalidPath
}

/// Atomic, owner-only writes for files that hold personal data or secrets.
///
/// The file is created with mode 0600 in its final directory and only then
/// filled and renamed into place, so there is no window where secrets or
/// history are world-readable. This is deliberately not a process-wide umask
/// change: callers opt in file by file.
enum PrivateFile {
    static let temporaryPrefix = ".newsbar-private-tmp-"
    /// Leftovers written by the research-only precursor of this helper.
    static let legacyTemporaryPrefixes = [".newsbar-research-tmp-"]

    /// Creates `directory` (and parents) with 0700 and re-asserts the mode.
    static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    /// Writes `data` to `url` atomically. `durable` also fsyncs the file and
    /// its parent directory, which ledgers and key stores need to survive a
    /// crash; disposable caches can skip it. `fullSync` additionally asks the
    /// hardware to flush its cache (F_FULLFSYNC) before the regular fsync.
    static func write(
        _ data: Data,
        to url: URL,
        durable: Bool = true,
        fullSync: Bool = false
    ) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)

        let temporaryURL = directory.appendingPathComponent(
            temporaryPrefix + UUID().uuidString
        )
        var descriptor: Int32 = -1
        do {
            descriptor = try openExclusive(temporaryURL)
            try verifyOwnerOnly(descriptor)
            try writeAll(data, to: descriptor)
            #if DEBUG
            if PrivateFileFaults.failBeforeRename {
                throw PrivateFileError.renameFailed(EIO)
            }
            #endif
            if durable {
                if fullSync {
                    // Best effort: fsync below still provides the barrier
                    // when the filesystem does not implement F_FULLFSYNC.
                    _ = Darwin.fcntl(descriptor, F_FULLFSYNC)
                }
                try sync(descriptor)
            }
            let closeResult = Darwin.close(descriptor)
            descriptor = -1
            guard closeResult == 0 else {
                throw PrivateFileError.writeFailed(errno)
            }
            try rename(temporaryURL, to: url)
            if durable {
                try syncDirectory(directory)
            }
        } catch {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            _ = temporaryURL.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.unlink($0) }
            }
            throw error
        }
    }

    /// Best-effort tightening for files written before the atomic writer
    /// existed. Symlinks are refused rather than followed.
    @discardableResult
    static func tightenExistingFile(_ url: URL) -> Bool {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else {
            // Nothing to tighten when the file does not exist (yet).
            return errno == ENOENT
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        if (info.st_mode & 0o777) == 0o600 { return true }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.chmod(path, 0o600) == 0
        }
    }

    /// Removes leftovers from a crash during `write`. Only files carrying our
    /// recognisable prefix and older than `olderThan` are touched.
    @discardableResult
    static func removeStaleTemporaries(
        in directory: URL,
        olderThan: Date,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        // The temporary files are dot-files by design, so hidden entries must
        // be listed; the recognisable prefix is what scopes the cleanup.
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )) ?? []
        var removed = 0
        let cutoff = olderThan
        for url in urls {
            let name = url.lastPathComponent
            let isTemporary = name.hasPrefix(temporaryPrefix)
                || legacyTemporaryPrefixes.contains { name.hasPrefix($0) }
            guard isTemporary else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - POSIX

    private static func openExclusive(_ url: URL) throws -> Int32 {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw PrivateFileError.invalidPath }
            let descriptor = Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                throw PrivateFileError.openFailed(errno)
            }
            return descriptor
        }
    }

    private static func verifyOwnerOnly(_ descriptor: Int32) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw PrivateFileError.openFailed(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600 else {
            throw PrivateFileError.permissionMismatch
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PrivateFileError.writeFailed(errno)
                }
                if written == 0 {
                    throw PrivateFileError.writeFailed(EIO)
                }
                offset += written
            }
        }
    }

    private static func sync(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw PrivateFileError.syncFailed(errno)
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = try directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw PrivateFileError.invalidPath }
            let value = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard value >= 0 else {
                throw PrivateFileError.openFailed(errno)
            }
            return value
        }
        var result: Int32 = 0
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            result = -1
            break
        }
        let saved = errno
        _ = Darwin.close(descriptor)
        guard result == 0 else {
            throw PrivateFileError.syncFailed(saved)
        }
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw PrivateFileError.renameFailed(errno)
        }
    }
}

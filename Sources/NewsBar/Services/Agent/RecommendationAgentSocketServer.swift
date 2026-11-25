import Darwin
import Foundation
import NewsBarAgentProtocol

/// One-request-per-connection Unix socket for the fixed recommendation summary.
///
/// The socket node is the only filesystem artifact: its directory is 0700 and
/// the node 0600. Requests are read with a 3 second deadline, admitted on the
/// main actor, re-authorized immediately before the reply is written, and the
/// connection is closed. No payload is queued, logged or written to disk.
@MainActor
final class RecommendationAgentSocketServer {
    typealias ScopeProvider = @MainActor () -> RecommendationAgentAccess.Scope

    private let path: URL?
    private let access: RecommendationAgentAccess
    private let scope: ScopeProvider
    private let onAdmitted: (@MainActor () -> Void)?
    private let isAgentEnabled: @MainActor () -> Bool
    private let queue = DispatchQueue(label: "com.newsbar.app.recommendation-summary")
    private var source: DispatchSourceRead?

    init(
        path: URL? = RecommendationSummarySocket.defaultURL,
        access: RecommendationAgentAccess,
        scope: @escaping ScopeProvider,
        onAdmitted: (@MainActor () -> Void)? = nil,
        isAgentEnabled: @escaping @MainActor () -> Bool = { true }
    ) {
        self.path = path
        self.access = access
        self.scope = scope
        self.onAdmitted = onAdmitted
        self.isAgentEnabled = isAgentEnabled
    }

    func start() throws {
        guard source == nil, let path else { throw RecommendationSummarySocket.TransportError.unavailable }
        try PrivateFile.ensureDirectory(path.deletingLastPathComponent())

        var info = stat()
        let existing = path.withUnsafeFileSystemRepresentation { raw -> Int32 in
            guard let raw else { return -1 }
            return Darwin.lstat(raw, &info)
        }
        if existing == 0 {
            // Never delete a regular file or a symlink that happens to occupy
            // our fixed path.
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw RecommendationSummarySocket.TransportError.invalid
            }
            guard unlink(path) else { throw RecommendationSummarySocket.TransportError.unavailable }
        } else if errno != ENOENT {
            throw RecommendationSummarySocket.TransportError.unavailable
        }

        let fd = try RecommendationSummarySocket.makeDescriptor()
        do {
            let bound: Bool = try RecommendationSummarySocket.withAddress(for: path) { address, length in
                Darwin.bind(fd, address, length) == 0
            }
            guard bound, setOwnerOnly(path), Darwin.listen(fd, 8) == 0 else {
                throw RecommendationSummarySocket.TransportError.unavailable
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptPending(listenFD: fd)
            }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            self.source = source
        } catch {
            Darwin.close(fd)
            _ = unlink(path)
            throw error
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        // Let the accept queue drain and the cancel handler close the listener.
        queue.sync {}
        if let path {
            var info = stat()
            let result = path.withUnsafeFileSystemRepresentation { raw -> Int32 in
                guard let raw else { return -1 }
                return Darwin.lstat(raw, &info)
            }
            if result == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
                _ = unlink(path)
            }
        }
    }

    // MARK: - Transport

    nonisolated private func acceptPending(listenFD: Int32) {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.readConnection(client)
            }
        }
    }

    nonisolated private func readConnection(_ fd: Int32) {
        do {
            try RecommendationSummarySocket.configure(fd)
            guard RecommendationSummarySocket.peerIsOwner(fd) else {
                Darwin.close(fd)
                return
            }
            let data = try RecommendationSummarySocket.read(
                fd,
                max: RecommendationSummarySocket.maxRequestBytes,
                deadline: RecommendationSummarySocket.Deadline()
            )
            let window = RecommendationSummaryRequest.parse(data)
            Task { @MainActor [weak self] in
                guard let self else {
                    Darwin.close(fd)
                    return
                }
                self.respond(fd: fd, window: window)
            }
        } catch {
            Darwin.close(fd)
        }
    }

    // MARK: - Reply

    private func respond(fd: Int32, window: RecommendationSummaryWindow?) {
        let reply: RecommendationSummaryReply
        if let window {
            if !isAgentEnabled() {
                access.setAgentEnabled(false)
                reply = RecommendationSummaryReply(status: .notAuthorized, window: window)
            } else {
                let admission = access.begin(window, scope: scope())
                if let ticket = admission.ticket {
                    onAdmitted?()
                    // A switch turned off after admission must invalidate the
                    // ticket before any bytes are written.
                    if !isAgentEnabled() { access.setAgentEnabled(false) }
                    reply = access.deliver(ticket, scope: scope())
                } else {
                    reply = RecommendationSummaryReply(status: admission.status, window: window)
                }
            }
        } else {
            reply = RecommendationSummaryReply(status: .invalidRequest)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(reply),
           data.count <= RecommendationSummarySocket.maxReplyBytes {
            _ = RecommendationSummarySocket.sendOnce(data, to: fd)
        }
        Darwin.shutdown(fd, SHUT_WR)
        Darwin.close(fd)
    }

    // MARK: - Filesystem

    private func setOwnerOnly(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { raw in
            guard let raw else { return false }
            return Darwin.chmod(raw, 0o600) == 0
        }
    }

    private func unlink(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { raw in
            guard let raw else { return false }
            return Darwin.unlink(raw) == 0
        }
    }
}

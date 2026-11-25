import Darwin
import Foundation

/// Local, one-request socket transport. Never launches a process or uses an
/// AgentPaths directory. The socket node is the only filesystem artifact.
public enum RecommendationSummarySocket {
    public static let maxRequestBytes = 16
    public static let maxReplyBytes = 2_048

    public static var defaultURL: URL? {
        let key = _CS_DARWIN_USER_TEMP_DIR
        let length = confstr(key, nil, 0)
        guard length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(key, &buffer, length) == length else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent("nb-rd/s")
    }

    public enum TransportError: Error { case unavailable, invalid, timedOut }

    public struct Deadline: Sendable {
        private let end: UInt64
        public init(seconds: TimeInterval = 3) {
            let clamped = seconds.isFinite ? min(max(seconds, 0.001), 60) : 3
            end = DispatchTime.now().uptimeNanoseconds + UInt64(clamped * 1_000_000_000)
        }
        public var expired: Bool { DispatchTime.now().uptimeNanoseconds >= end }
        fileprivate var remaining: Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            return now < end ? Int32((end - now + 999_999) / 1_000_000) : 0
        }
    }

    public static func makeDescriptor() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.unavailable }
        do { try configure(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }

    public static func configure(_ fd: Int32) throws {
        var one: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw TransportError.unavailable
        }
    }

    public static func peerIsOwner(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    public static func withAddress<T>(for url: URL, _ use: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        let path = Array(url.path.utf8)
        guard !path.isEmpty, path.count < MemoryLayout.size(ofValue: address.sun_path),
              !path.contains(0) else { throw TransportError.invalid }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = MemoryLayout<sockaddr_un>.size
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: path)
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { use($0, socklen_t(length)) }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: Deadline) throws {
        while !deadline.expired {
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&entry, 1, deadline.remaining)
            if result == 0 { break }
            if result < 0 {
                if errno == EINTR { continue }
                throw TransportError.unavailable
            }
            guard entry.revents & Int16(POLLNVAL) == 0 else { throw TransportError.unavailable }
            return
        }
        throw TransportError.timedOut
    }

    public static func read(_ fd: Int32, max: Int, deadline: Deadline) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: min(512, max + 1))
        var data = Data()
        while !deadline.expired {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count == 0 { return data }
            if count > 0 {
                guard data.count + count <= max else { throw TransportError.invalid }
                data.append(contentsOf: bytes.prefix(count))
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try wait(fd, events: Int16(POLLIN), deadline: deadline)
            } else if errno != EINTR {
                throw TransportError.unavailable
            }
        }
        throw TransportError.timedOut
    }

    /// The caller orders authorization and this single nonblocking send on the
    /// same actor. Never schedule a retry containing the authorized payload.
    @discardableResult
    public static func sendOnce(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            return Darwin.send(fd, base, buffer.count, 0) == buffer.count
        }
    }

    public static func request(
        _ window: RecommendationSummaryWindow,
        socket url: URL? = defaultURL,
        deadline: Deadline = Deadline()
    ) -> RecommendationSummaryReply {
        guard let url else { return .init(status: .appUnavailable, window: window) }
        do {
            let fd = try makeDescriptor()
            defer { Darwin.close(fd) }
            let status = try withAddress(for: url) { Darwin.connect(fd, $0, $1) }
            if status != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw TransportError.unavailable }
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw TransportError.unavailable }
            }
            guard peerIsOwner(fd), sendOnce(Data("\(window.rawValue)\n".utf8), to: fd),
                  Darwin.shutdown(fd, SHUT_WR) == 0 else { throw TransportError.unavailable }
            let bytes = try read(fd, max: maxReplyBytes, deadline: deadline)
            let reply = try JSONDecoder().decode(RecommendationSummaryReply.self, from: bytes)
            guard reply.schemaVersion == 1, reply.metricDefinitionVersion == 1, reply.view == "overview",
                  reply.window == window else { throw TransportError.invalid }
            return reply
        } catch TransportError.timedOut {
            return .init(status: .requestTimedOut, window: window)
        } catch {
            return .init(status: .appUnavailable, window: window)
        }
    }
}

import Foundation
import os

/// One decision for both the first RSS request and every redirect. The DNS
/// check is defense in depth: URLSession may resolve the hostname again.
struct RSSDestinationPolicy: Sendable {
    let resolve: @Sendable (URL) async -> ReaderNavigationPolicy.DestinationResolution
    let allowsFakeIP: @Sendable () async -> Bool
    var timeoutNanoseconds: UInt64 = 3_000_000_000

    static var live: Self {
        Self(
            resolve: { url in
                guard let host = url.host else { return .unresolved }
                let addresses = await RSSDNSResolver.shared.resolve(host: host)
                return ReaderNavigationPolicy.classifyAddresses(addresses)
            },
            allowsFakeIP: { await ReaderProxyController.shared.allowsFakeIPDestination() }
        )
    }

    func allows(_ url: URL) async throws -> Bool {
        try Task.checkCancellation()
        guard SecurityPolicies.validatePublicHTTPURL(url.absoluteString).url != nil else { return false }
        let permitted = try await RSSDestinationDecision().run(timeoutNanoseconds: timeoutNanoseconds) {
            switch await resolve(url) {
            case .publicDestination:
                return true
            case .fakeIPDestination:
                return await allowsFakeIP()
            case .privateDestination, .unresolved:
                return false
            }
        }
        try Task.checkCancellation()
        return permitted
    }
}

/// Unlike a structured task-group race, this can return when the system DNS
/// resolver is still blocked. The unstructured work is cancelled but a
/// synchronous getaddrinfo call may finish later; it cannot resume the caller.
private final class RSSDestinationDecision: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Bool, Error>?
        var result: Result<Bool, Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func run(
        timeoutNanoseconds: UInt64,
        decide: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let finished = state.withLock { state -> Result<Bool, Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let finished {
                    continuation.resume(with: finished)
                    return
                }

                let worker = Task {
                    let decision = await decide()
                    self.finish(.success(decision))
                }
                let timer = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self.finish(.failure(URLError(.timedOut)))
                }
                let alreadyFinished = state.withLock { state in
                    guard state.result == nil else { return true }
                    state.tasks = [worker, timer]
                    return false
                }
                if alreadyFinished {
                    worker.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Bool, Error>) {
        let pending = state.withLock { state -> (CheckedContinuation<Bool, Error>?, [Task<Void, Never>])? in
            guard state.result == nil else { return nil }
            state.result = result
            let pending = (state.continuation, state.tasks)
            state.continuation = nil
            state.tasks = []
            return pending
        }
        guard let (continuation, tasks) = pending else { return }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}

import Foundation
import os

/// Invalidates work that began before a cache-clear request. The cache actors
/// check the token at the actual write boundary, not only before an `await`.
final class CacheWriteGeneration: Sendable {
    private let value = OSAllocatedUnfairLock<UUID>(initialState: UUID())

    func capture() -> CacheWriteToken {
        CacheWriteToken(generation: value.withLock { $0 }, owner: self)
    }

    func invalidate() {
        value.withLock { $0 = UUID() }
    }

    fileprivate func contains(_ generation: UUID) -> Bool {
        value.withLock { $0 == generation }
    }
}

struct CacheWriteToken: Sendable {
    fileprivate let generation: UUID
    fileprivate let owner: CacheWriteGeneration

    var isCurrent: Bool { owner.contains(generation) }
}

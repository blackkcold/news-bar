import Foundation
import Observation

/// Main-actor state machine for comment threads. The view model owns one and
/// the reader asks it to load the post that is actually open; no list row ever
/// triggers a comment request on its own.
@MainActor
@Observable
final class WeiboCommentController {
    private let fetcher: any WeiboCommentFetching
    private let cache: WeiboCommentCache
    private(set) var threads: [String: WeiboCommentThread] = [:]

    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var lastRequestAt: Date?
    @ObservationIgnored private var cooldownUntil: Date?

    let cacheFreshness: TimeInterval
    let minimumRequestInterval: TimeInterval

    init(
        fetcher: any WeiboCommentFetching,
        cache: WeiboCommentCache = WeiboCommentCache(),
        cacheFreshness: TimeInterval = 10 * 60,
        minimumRequestInterval: TimeInterval = 1.2
    ) {
        self.fetcher = fetcher
        self.cache = cache
        self.cacheFreshness = cacheFreshness
        self.minimumRequestInterval = minimumRequestInterval
    }

    func thread(for mid: String) -> WeiboCommentThread {
        threads[mid] ?? WeiboCommentThread(postID: mid)
    }

    /// Loads the first page automatically. A cached thread is shown first; a
    /// stale one refreshes underneath without replacing visible rows, and new
    /// top-of-thread comments wait behind `newComments` until the reader
    /// explicitly applies them, so the scroll position never jumps.
    func load(post: WeiboPost, credentials: WeiboCredentials, force: Bool = false) async {
        let mid = post.mid
        let generation = bump(mid)
        var thread = threads[mid] ?? WeiboCommentThread(postID: mid)

        if let cooldownUntil, cooldownUntil > Date() {
            thread.state = .rateLimited(until: cooldownUntil)
            thread.isRefreshing = false
            threads[mid] = thread
            return
        }

        if !force, threads[mid] == nil, let cached = await cache.load(mid: mid) {
            thread.comments = cached.page.comments
            thread.total = cached.page.total
            thread.nextCursor = cached.page.nextCursor
            thread.pagesLoaded = max(1, cached.pagesLoaded)
            thread.fetchedAt = cached.page.fetchedAt
            thread.tier = cached.page.tier
            thread.state = thread.comments.isEmpty ? .empty : .loaded
            threads[mid] = thread

            if Date().timeIntervalSince(cached.page.fetchedAt) < cacheFreshness {
                return
            }
        }

        if !force,
           let existing = threads[mid],
           let fetchedAt = existing.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < cacheFreshness {
            return
        }

        thread = threads[mid] ?? thread
        if thread.comments.isEmpty {
            thread.state = .loadingFirst
        } else {
            thread.isRefreshing = true
        }
        threads[mid] = thread

        await fetchFirstPage(post: post, credentials: credentials, generation: generation)
    }

    func loadMore(post: WeiboPost, credentials: WeiboCredentials) async {
        let mid = post.mid
        guard var thread = threads[mid],
              thread.state == .loaded,
              thread.canLoadMore,
              let cursor = thread.nextCursor else { return }
        let generation = generations[mid] ?? 0

        thread.state = .loadingMore
        thread.loadMoreError = nil
        threads[mid] = thread

        guard await waitForSlot() else {
            var current = threads[mid] ?? thread
            current.state = .loaded
            if let cooldownUntil {
                current.loadMoreError = .rateLimited(until: cooldownUntil)
            }
            threads[mid] = current
            return
        }

        let outcome = await fetcher.fetchComments(
            mid: mid,
            uid: post.uid,
            authorUID: post.uid,
            cursor: cursor,
            credentials: credentials,
            now: Date()
        )
        guard generations[mid] == generation else { return }

        var current = threads[mid] ?? thread
        switch outcome {
        case .success(let page, _):
            let existing = Set(current.comments.map(\.id))
            var merged = current.comments
            for comment in page.comments where !existing.contains(comment.id) {
                merged.append(comment)
            }
            current.comments = Array(merged.prefix(WeiboCommentLimits.maxComments))
            current.pagesLoaded += 1
            current.nextCursor = page.nextCursor
            current.total = page.total ?? current.total
            if let total = current.total, total < current.comments.count {
                current.total = current.comments.count
            }
            current.fetchedAt = page.fetchedAt
            current.tier = page.tier
            current.state = .loaded
            current.loadMoreError = nil
            threads[mid] = current
            await persist(mid: mid)
        case .failure(let failure):
            current.state = .loaded
            current.loadMoreError = issue(from: failure)
            if case .rateLimited(let retryAfter) = failure {
                let until = Date().addingTimeInterval(retryAfter ?? 15 * 60)
                cooldownUntil = until
                current.loadMoreError = .rateLimited(until: until)
            }
            threads[mid] = current
        }
    }

    func applyPending(mid: String) async {
        guard var thread = threads[mid], !thread.pendingComments.isEmpty else { return }
        var merged: [WeiboComment] = []
        var seen = Set<String>()
        for comment in thread.pendingComments + thread.comments where seen.insert(comment.id).inserted {
            merged.append(comment)
        }
        thread.comments = Array(merged.prefix(WeiboCommentLimits.maxComments))
        thread.pendingComments = []
        thread.newComments = 0
        threads[mid] = thread
        await persist(mid: mid)
    }

    func cancel(mid: String) {
        _ = bump(mid)
        guard var thread = threads[mid], thread.isRefreshing || thread.state == .loadingFirst else { return }
        thread.isRefreshing = false
        thread.state = thread.comments.isEmpty ? .idle : .loaded
        threads[mid] = thread
    }

    func clearCache() async {
        await cache.clear()
        threads = [:]
    }

    // MARK: - Requests

    private func fetchFirstPage(post: WeiboPost, credentials: WeiboCredentials, generation: Int) async {
        let mid = post.mid
        guard await waitForSlot() else {
            if let cooldownUntil, cooldownUntil > Date() {
                var thread = threads[mid] ?? WeiboCommentThread(postID: mid)
                thread.isRefreshing = false
                thread.state = .rateLimited(until: cooldownUntil)
                threads[mid] = thread
            }
            return
        }

        let outcome = await fetcher.fetchComments(
            mid: mid,
            uid: post.uid,
            authorUID: post.uid,
            cursor: nil,
            credentials: credentials,
            now: Date()
        )
        guard generations[mid] == generation else { return }

        var thread = threads[mid] ?? WeiboCommentThread(postID: mid)
        thread.isRefreshing = false
        switch outcome {
        case .success(let page, _):
            let oldIDs = Set(thread.comments.map(\.id))
            let fresh = page.comments.filter { !oldIDs.contains($0.id) }
            if thread.comments.isEmpty {
                thread.comments = Array(page.comments.prefix(WeiboCommentLimits.maxComments))
                thread.pendingComments = []
                thread.newComments = 0
            } else if !fresh.isEmpty {
                var pending = thread.pendingComments
                let pendingIDs = Set(pending.map(\.id))
                pending.append(contentsOf: fresh.filter { !pendingIDs.contains($0.id) })
                thread.pendingComments = Array(pending.prefix(WeiboCommentLimits.maxComments))
                thread.newComments = thread.pendingComments.count
            }

            thread.total = page.total ?? thread.total
            if let total = thread.total, total < thread.comments.count + thread.pendingComments.count {
                thread.total = thread.comments.count + thread.pendingComments.count
            }
            thread.nextCursor = page.nextCursor
            thread.pagesLoaded = max(1, thread.pagesLoaded)
            thread.fetchedAt = page.fetchedAt
            thread.tier = page.tier
            thread.loadMoreError = nil
            if thread.comments.isEmpty {
                if let total = page.total, total > 0 {
                    thread.state = .failed(.parseChanged, canRetry: true)
                } else {
                    thread.state = .empty
                }
            } else {
                thread.state = .loaded
            }
            threads[mid] = thread
            await persist(mid: mid)
        case .failure(let failure):
            apply(failure, to: &thread)
            threads[mid] = thread
        }
    }

    private func waitForSlot() async -> Bool {
        if let cooldownUntil, cooldownUntil > Date() { return false }
        if let lastRequestAt {
            let delay = lastRequestAt.addingTimeInterval(minimumRequestInterval).timeIntervalSince(Date())
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        guard !Task.isCancelled else { return false }
        lastRequestAt = Date()
        return true
    }

    private func apply(_ failure: WeiboCommentFailure, to thread: inout WeiboCommentThread) {
        thread.isRefreshing = false
        switch failure {
        case .authRequired:
            if thread.comments.isEmpty {
                thread.state = .authRequired
            } else {
                thread.state = .loaded
                thread.loadMoreError = .authRequired
            }
        case .rateLimited(let retryAfter):
            let until = Date().addingTimeInterval(retryAfter ?? 15 * 60)
            cooldownUntil = until
            if thread.comments.isEmpty {
                thread.state = .rateLimited(until: until)
            } else {
                thread.state = .loaded
                thread.loadMoreError = .rateLimited(until: until)
            }
        case .challenge:
            if thread.comments.isEmpty {
                thread.state = .failed(.challenge, canRetry: false)
            } else {
                thread.state = .loaded
                thread.loadMoreError = .challenge
            }
        case .network, .server, .parseChanged, .unknown:
            let issue = issue(from: failure)
            if thread.comments.isEmpty {
                thread.state = .failed(issue, canRetry: issue != .parseChanged)
            } else {
                thread.state = .loaded
                thread.loadMoreError = issue
            }
        }
    }

    private func issue(from failure: WeiboCommentFailure) -> WeiboCommentIssue {
        switch failure {
        case .authRequired: return .authRequired
        case .rateLimited(let retryAfter): return .rateLimited(until: Date().addingTimeInterval(retryAfter ?? 15 * 60))
        case .challenge: return .challenge
        case .network: return .network
        case .server: return .server
        case .parseChanged: return .parseChanged
        case .unknown: return .unknown
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func bump(_ mid: String) -> Int {
        let next = (generations[mid] ?? 0) + 1
        generations[mid] = next
        return next
    }

    private func persist(mid: String) async {
        guard let thread = threads[mid] else { return }
        var all: [WeiboComment] = []
        var seen = Set<String>()
        for comment in thread.pendingComments + thread.comments where seen.insert(comment.id).inserted {
            all.append(comment)
        }
        let page = WeiboCommentPage(
            comments: Array(all.prefix(WeiboCommentLimits.maxComments)),
            total: thread.total,
            nextCursor: thread.nextCursor,
            fetchedAt: thread.fetchedAt ?? Date(),
            tier: thread.tier
        )
        await cache.save(
            mid: mid,
            thread: CachedWeiboCommentThread(page: page, pagesLoaded: thread.pagesLoaded)
        )
    }
}

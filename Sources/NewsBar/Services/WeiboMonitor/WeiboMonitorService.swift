import Foundation
import os

enum WeiboMonitorAddError: Error, Equatable {
    case invalidInput
    case duplicate
}

/// The orchestration layer. It owns the in-memory account list, the seen-mid
/// baseline, the request budget, the risk state machine and the notification
/// aggregation window. It never touches AppKit, UserDefaults, WebKit or
/// UserNotifications directly, which is what makes the 24-hour simulation and
/// the baseline/dedupe tests possible.
actor WeiboMonitorService {
    private static let logger = Logger(subsystem: "com.newsbar.app", category: "weibo-monitor")
    private static let maxEvents = 20
    private static let notificationWindow: TimeInterval = 45
    private static let relevanceAIDailyCap = 100

    private let store: WeiboMonitorStore
    private let feed: any WeiboFeedFetching
    private let notifier: any WeiboAlertNotifying
    private let planner: WeiboPollPlanner
    private let alertPolicy: WeiboAlertPolicy
    private let relevanceModel: WeiboRelevanceModel
    private var relevanceDeciders: [any WeiboRelevanceDeciding]
    private let corpus: WeiboCorpusRecorder?
    private let sleeper: @Sendable (Duration) async -> Void
    private let autoFlushAlerts: Bool
    private let changeNotifier: @Sendable () async -> Void
    private let authAlertRecorder: @Sendable (Date) async -> Void

    private var rng: WeiboRNG
    private var config: WeiboMonitorConfig = .default
    private var credentials: WeiboCredentials = .none
    private var users: [WeiboMonitorUser] = []
    private var postsByUID: [String: [WeiboPost]] = [:]
    private var events: [WeiboMonitorEvent] = []
    private var budget: WeiboRequestBudget
    private var circuit = WeiboCircuitBreaker()
    private var delivered: [(date: Date, uid: String)] = []
    private var pendingAlerts: [String: [WeiboPost]] = [:]
    private var pendingAlertStartedAt: [String: Date] = [:]
    private var alertFlushTask: Task<Void, Never>?
    private var emptyStreak: [String: Int] = [:]
    private var consecutiveStoreFailures = 0
    private var lastDesktopCookieHeader: String?
    private var lastAuthAlertAt: Date?
    private var unloadedUIDs: Set<String> = []
    private var wasOnline = true
    private var lastRelevanceMode: WeiboRelevanceMode?
    private var lastRelevanceEnabled: Bool?
    private var relevanceCircuits: [String: WeiboRelevanceCircuitBreaker] = [:]
    private var relevanceAICalls = 0
    private var relevanceAIDay: Date?

    private var isStarted = false
    private var isTicking = false
    private var isFlushing = false
    private var isAuthProbe = false
    private var isLowPower = false
    private var isOnline = true
    private var authState: WeiboLoginState = .unknown
    private var authPausedUntil: Date?
    private var globalPausedUntil: Date?
    private var globalCooldownUntil: Date?
    private var lastTickAt: Date?
    private var storeError: String?
    private var monitorWritesBlocked = false
    private var persistentStoreWarningKey: String?

    init(
        store: WeiboMonitorStore = WeiboMonitorStore(),
        feed: any WeiboFeedFetching = WeiboUserFeedService(),
        notifier: any WeiboAlertNotifying = NoopWeiboAlertNotifier(),
        planner: WeiboPollPlanner = WeiboPollPlanner(),
        alertPolicy: WeiboAlertPolicy = WeiboAlertPolicy(),
        relevanceModel: WeiboRelevanceModel = WeiboRelevanceModel(),
        relevanceDeciders: [any WeiboRelevanceDeciding] = [],
        corpus: WeiboCorpusRecorder? = WeiboCorpusRecorder.fromEnvironment(),
        rng: WeiboRNG = WeiboRNG(),
        sleeper: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        autoFlushAlerts: Bool = true,
        changeNotifier: @escaping @Sendable () async -> Void = {
            await MainActor.run {
                NotificationCenter.default.post(name: .weiboMonitorChanged, object: nil)
            }
        },
        authAlertRecorder: @escaping @Sendable (Date) async -> Void = { _ in }
    ) {
        self.store = store
        self.feed = feed
        self.notifier = notifier
        self.planner = planner
        self.alertPolicy = alertPolicy
        self.relevanceModel = relevanceModel
        self.relevanceDeciders = relevanceDeciders
        self.corpus = corpus
        self.rng = rng
        self.sleeper = sleeper
        self.autoFlushAlerts = autoFlushAlerts
        self.changeNotifier = changeNotifier
        self.authAlertRecorder = authAlertRecorder
        self.budget = WeiboRequestBudget()
    }

    // MARK: - Lifecycle

    func start(now: Date, config: WeiboMonitorConfig) async {
        guard !isStarted else { return }
        isStarted = true
        self.config = config
        self.lastAuthAlertAt = config.lastAuthAlertAt

        let loaded = await store.load(now: now)
        users = loaded.users
        postsByUID = loaded.postsByUID
        unloadedUIDs = loaded.unloadedUIDs
        monitorWritesBlocked = loaded.monitorWriteBlocked
        if !loaded.issues.isEmpty {
            storeError = loaded.issues.joined(separator: ", ")
        }
        if loaded.issues.contains("monitor.unreadable") {
            // The original monitor.json was moved aside before this rebuilt
            // list is written, or writes are paused because it could not be.
            let warningKey = loaded.monitorWriteBlocked
                ? "weibo.events.monitorWriteBlocked"
                : "weibo.events.monitorUnreadable"
            persistentStoreWarningKey = warningKey
            addEvent(
                .warning,
                L10n.string(warningKey, language: config.language)
            )
        }

        for index in users.indices {
            if users[index].needsManualResume {
                // A restart is a fresh chance, per the design. The failure
                // count is kept only long enough to choose a gentle next due.
                users[index].needsManualResume = false
                users[index].consecutiveFailures = 0
            }
            if unloadedUIDs.contains(users[index].uid) {
                users[index].lastErrorKind = .disk
                users[index].needsManualResume = true
                users[index].pausedUntil = nil
            }
            if users[index].nextDueAt <= now {
                if planner.isNight(now, config: config) {
                    if users[index].priority == .p0 {
                        users[index].nextDueAt = planner.nextDue(
                            for: users[index],
                            now: now,
                            config: config,
                            isLowPower: false,
                            rng: &rng
                        )
                    } else {
                        users[index].nextDueAt = planner.nextMorningStart(after: now, config: config)
                    }
                } else {
                    users[index].nextDueAt = planner.initialDue(now: now, rng: &rng)
                }
            }
        }

        budget = WeiboRequestBudget(now: now)
        budget.startWarmup(now: now)
        // Old posts predate the filter. Decide them once at launch so the
        // feed opens in the same shape the user configured, instead of
        // showing a month of unfiltered history until the next poll.
        await redecideAllPosts(now: now)
        lastRelevanceMode = config.relevanceMode
        lastRelevanceEnabled = config.relevanceEnabled
        addEvent(.info, L10n.string("weibo.events.started", language: config.language))
        await persistUsers(now: now)
        await notifyChange()
    }

    func handleWake(now: Date) async {
        planner.spreadWakeUp(users: &users, now: now, config: config, rng: &rng)
        await persistUsers(now: now)
        await notifyChange()
    }

    func setOnline(_ online: Bool, now: Date) async {
        let wasOffline = !isOnline
        isOnline = online
        if online, wasOffline {
            planner.spreadWakeUp(users: &users, now: now, config: config, rng: &rng)
            await notifyChange()
        }
    }

    // MARK: - Tick

    func tick(
        now: Date,
        config: WeiboMonitorConfig,
        credentials: WeiboCredentials,
        isLowPower: Bool,
        isOnline: Bool,
        relevanceDeciders: [any WeiboRelevanceDeciding]? = nil
    ) async {
        if let relevanceDeciders {
            self.relevanceDeciders = relevanceDeciders
        }
        self.config = config
        self.credentials = credentials
        self.isLowPower = isLowPower
        self.isOnline = isOnline
        self.lastTickAt = now
        self.lastAuthAlertAt = maxDate(lastAuthAlertAt, config.lastAuthAlertAt)

        let previousRelevanceMode = lastRelevanceMode
        let previousRelevanceEnabled = lastRelevanceEnabled
        lastRelevanceMode = config.relevanceMode
        lastRelevanceEnabled = config.relevanceEnabled
        if let previousRelevanceMode, let previousRelevanceEnabled,
           previousRelevanceMode != config.relevanceMode
            || previousRelevanceEnabled != config.relevanceEnabled {
            await redecideAllPosts(now: now)
        }

        observeCookieChange(credentials: credentials, now: now)
        if isOnline && !wasOnline && authState != .expired {
            // The network came back after an outage. Spread the overdue
            // accounts instead of letting the budget release them all at once.
            // An expired-auth probe must not be delayed by this spread.
            planner.spreadWakeUp(users: &users, now: now, config: config, rng: &rng)
        }
        wasOnline = isOnline

        guard config.enabled else {
            await notifyChange()
            return
        }
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        pruneDelivered(now: now)
        await flushAlerts(now: now)

        if authState == .expired {
            guard credentials.hasDesktopLogin else {
                await notifyChange()
                return
            }
            guard let until = authPausedUntil, now >= until else {
                await notifyChange()
                return
            }
            // One request every fifteen minutes is enough to notice that the
            // user signed in again without hammering a dead session.
            authPausedUntil = now.addingTimeInterval(15 * 60)
            isAuthProbe = true
        }

        guard isOnline else {
            await notifyChange()
            return
        }
        guard !isGloballyPaused(now: now) else {
            await notifyChange()
            return
        }

        let due = dueUIDs(now: now)
        let circuitProbe = circuit.isAwaitingProbe && circuit.canRequest(now: now)
        let limitedDue = isAuthProbe
            ? Array(due.prefix(1))
            : (circuitProbe ? Array(due.prefix(1)) : due)
        if isAuthProbe && limitedDue.isEmpty {
            isAuthProbe = false
            authPausedUntil = now.addingTimeInterval(15 * 60)
            await notifyChange()
            return
        }
        var requestCount = 0
        var successCount = 0
        var failureCount = 0

        for uid in limitedDue {
            guard isOnline, !Task.isCancelled else { break }
            guard !isGloballyPaused(now: now), circuit.canRequest(now: now) else { break }
            guard let index = users.firstIndex(where: { $0.uid == uid }) else { continue }

            let user = users[index]
            guard !user.isMuted(now: now), !user.isPaused(now: now) else { continue }

            // Occasional idle rounds for P1/P2 only when the account was
            // checked recently; a cold or overdue account must not skip.
            if user.priority != .p0,
               user.lastCheckedAt != nil,
               planner.shouldSkipIdleRound(priority: user.priority, rng: &rng) {
                users[index].nextDueAt = planner.nextDue(
                    for: users[index], now: now, config: config, isLowPower: isLowPower, rng: &rng
                )
                continue
            }

            let decision = budget.acquire(now: now, priority: user.priority)
            switch decision {
            case .allowed:
                break
            case .deferred(let until):
                users[index].nextDueAt = max(until, now.addingTimeInterval(1))
                continue
            }

            requestCount += 1
            let outcome = await fetchAndProcess(
                uid: uid,
                now: now,
                isCircuitProbe: circuitProbe
            )
            switch outcome {
            case .success:
                successCount += 1
            case .failure:
                failureCount += 1
            }

            let spacing = WeiboRandom.int(in: 400...1200, rng: &rng)
            await sleeper(.milliseconds(spacing))
        }

        await flushAlerts(now: now)
        await persistUsers(now: now)
        if requestCount > 0 {
            Self.logger.notice(
                "tick users=\(self.users.count, privacy: .public) requests=\(requestCount, privacy: .public) ok=\(successCount, privacy: .public) fail=\(failureCount, privacy: .public) circuit=\(self.circuit.isOpen(now: now), privacy: .public)"
            )
        }
        await notifyChange()
    }

    // MARK: - Fetch and state machine

    private enum ProcessOutcome {
        case success
        case failure
    }

    private func fetchAndProcess(
        uid: String,
        now: Date,
        isCircuitProbe: Bool
    ) async -> ProcessOutcome {
        guard !unloadedUIDs.contains(uid) else { return .failure }
        guard var index = users.firstIndex(where: { $0.uid == uid }) else {
            return .failure
        }
        let user = users[index]
        let previousCheckedAt = user.lastCheckedAt
        // The new-post window and the page-2 gap must be anchored to the last
        // *successful* check. A failure advances lastCheckedAt; using it here
        // would silently drop every post produced during an outage longer than
        // ten minutes.
        let gapAnchor = user.lastSuccessAt
            ?? previousCheckedAt
            ?? now.addingTimeInterval(-10 * 60)
        let isBaseline = user.lastSuccessAt == nil

        let first = await fetchPage(
            uid: uid,
            screenName: user.screenName,
            page: 1,
            now: now
        )
        guard let refreshedAfterFirst = users.firstIndex(where: { $0.uid == uid }) else {
            return .failure
        }
        index = refreshedAfterFirst

        guard case .success(let firstPage, let tier, let latency) = first else {
            if case .failure(let kind, let message, let retryAfter) = first {
                await handleFailure(
                    uid: uid,
                    kind: kind,
                    message: message,
                    retryAfter: retryAfter,
                    now: now,
                    isCircuitProbe: isCircuitProbe
                )
            }
            return .failure
        }
        Self.logger.notice(
            "fetch uid=\(uid, privacy: .private) tier=\(tier.rawValue, privacy: .public) latencyMs=\(Int(latency * 1000), privacy: .public) posts=\(firstPage.posts.count, privacy: .public)"
        )

        if firstPage.rawCount == 0 && !isBaseline {
            await handleFailure(
                uid: uid,
                kind: .emptyList,
                message: "empty list",
                retryAfter: nil,
                now: now,
                isCircuitProbe: isCircuitProbe
            )
            return .failure
        }

        var allPosts = firstPage.posts
        var gapSuspected = false
        var pageTier = firstPage

        if !isBaseline,
           now.timeIntervalSince(gapAnchor) > 30 * 60,
           let lastSeenMid = user.lastSeenMid,
           !firstPage.posts.contains(where: { $0.mid == lastSeenMid }) {
            switch budget.acquire(now: now, priority: user.priority) {
            case .allowed:
                let second = await fetchPage(
                    uid: uid,
                    screenName: user.screenName,
                    page: 2,
                    now: now
                )
                guard let refreshedAfterSecond = users.firstIndex(where: { $0.uid == uid }) else {
                    return .failure
                }
                index = refreshedAfterSecond
                if case .success(let secondPage, _, _) = second {
                    allPosts.append(contentsOf: secondPage.posts)
                    pageTier = secondPage
                    if !secondPage.posts.contains(where: { $0.mid == lastSeenMid }) {
                        gapSuspected = true
                    }
                } else {
                    gapSuspected = true
                }
            case .deferred:
                gapSuspected = true
            }
        }

        var unique: [WeiboPost] = []
        var seen = Set<String>()
        for post in allPosts where seen.insert(post.mid).inserted {
            unique.append(post)
        }
        let newest = unique.max { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.mid < rhs.mid
        }
        var missingDateMids = firstPage.missingDateMids.union(pageTier.missingDateMids)
        if missingDateMids.isEmpty, firstPage.dateMissing || pageTier.dateMissing {
            // Older parsers only reported the page-level flag.
            missingDateMids = Set(unique.map(\.mid))
        }
        let missingDateCount = unique.reduce(0) {
            $0 + (missingDateMids.contains($1.mid) ? 1 : 0)
        }
        let missingDateRatio = unique.isEmpty
            ? 0
            : Double(missingDateCount) / Double(unique.count)

        users[index].screenName = pageTier.screenName ?? user.screenName
        users[index].avatarURL = pageTier.avatarURL ?? user.avatarURL
        users[index].lastCheckedAt = now
        users[index].lastSuccessAt = now
        users[index].lastErrorKind = nil
        users[index].consecutiveFailures = 0
        users[index].pausedUntil = nil
        users[index].needsManualResume = false
        emptyStreak[uid] = nil
        circuit.noteSuccess(now: now)

        if isBaseline {
            let relevance = await decideRelevance(
                posts: unique,
                user: users[index],
                now: now,
                updatesStats: false
            )
            // The decision may hit the network. The account can be removed or
            // reordered while we wait, so never keep using the old index.
            guard let refreshed = users.firstIndex(where: { $0.uid == uid }) else {
                return .failure
            }
            index = refreshed
            let baseline = unique.map { post -> WeiboPost in
                var copy = post
                copy.read = true
                copy.relevance = relevance[post.mid]
                return copy
            }
            postsByUID[uid] = trim(posts: baseline, now: now)
            users[index].seenMids = Array(unique.map(\.mid).prefix(100))
            users[index].lastSeenMid = newest?.mid
            users[index].lastSeenAt = newest?.createdAt
            users[index].stats = stats(for: unique, now: now)
            users[index].hotWindowUntil = nil
            users[index].gapSuspected = false
            users[index].nextDueAt = planner.nextDue(
                for: users[index], now: now, config: config, isLowPower: isLowPower, rng: &rng
            )

            // Optional backfill is P0-only and capped at two hours. The default
            // is zero, so a normal first add still never pushes old posts.
            if config.backfillHours > 0,
               users[index].priority == .p0,
               !pageTier.dateMissing {
                let cutoff = now.addingTimeInterval(-Double(config.backfillHours) * 3600)
                let backfill = unique.filter { $0.createdAt >= cutoff }
                if !backfill.isEmpty {
                    let backfillMids = Set(backfill.map(\.mid))
                    var merged = postsByUID[uid] ?? []
                    for postIndex in merged.indices where backfillMids.contains(merged[postIndex].mid) {
                        merged[postIndex].read = false
                    }
                    postsByUID[uid] = trim(posts: merged, now: now)
                    let decidedBackfill = backfill.map { post -> WeiboPost in
                        var copy = post
                        copy.relevance = relevance[post.mid]
                        return copy
                    }
                    queueAlerts(posts: decidedBackfill, user: users[index], now: now)
                }
            }

            await persistPosts(uid: uid, now: now)
            addEvent(
                .success,
                L10n.string(
                    "weibo.events.baseline",
                    language: config.language,
                    unique.count
                )
            )
            if isAuthProbe { finishAuthProbe(now: now) }
            return .success
        }

        // A date-format change must not turn every old post into a "new" post.
        // Update the feed and the baseline, but do not notify.
        // Only a page where most dates are unreadable is unsafe to push. A
        // single bad entry must not silence the other nine.
        if missingDateRatio > 0.5 {
            let relevance = await decideRelevance(
                posts: unique,
                user: users[index],
                now: now,
                updatesStats: false
            )
            guard let refreshed = users.firstIndex(where: { $0.uid == uid }) else {
                return .failure
            }
            index = refreshed
            var merged = postsByUID[uid] ?? []
            let existing = Set(merged.map(\.mid))
            let readPosts = unique.map { post -> WeiboPost in
                var copy = post
                copy.read = true
                copy.relevance = relevance[post.mid]
                return copy
            }
            merged.append(contentsOf: readPosts.filter { !existing.contains($0.mid) })
            postsByUID[uid] = trim(posts: merged, now: now)
            mergeSeenMids(uid: uid, posts: unique, newest: newest)
            users[index].stats = stats(for: postsByUID[uid] ?? [], now: now)
            users[index].nextDueAt = planner.nextDue(
                for: users[index], now: now, config: config, isLowPower: isLowPower, rng: &rng
            )
            await persistPosts(uid: uid, now: now)
            addEvent(
                .warning,
                "\(user.screenName) · \(L10n.string("weibo.events.dateMissing", language: config.language))"
            )
            if isAuthProbe { finishAuthProbe(now: now) }
            return .success
        }

        let windowStart = gapAnchor.addingTimeInterval(-10 * 60)
        var newPosts: [WeiboPost] = []
        for post in unique {
            guard !user.seenMids.contains(post.mid) else { continue }
            guard !missingDateMids.contains(post.mid) else { continue }
            guard post.createdAt > windowStart else { continue }
            guard !(post.isTop && post.createdAt < windowStart) else { continue }
            // `isRetweet` is only true for a pure repost (empty own text); it
            // must not create a notification.
            guard !post.isRetweet else { continue }
            newPosts.append(post)
        }

        if gapSuspected {
            users[index].gapSuspected = true
            addEvent(
                .warning,
                "\(user.screenName) · \(L10n.string("weibo.events.gap", language: config.language))"
            )
        }

        // Long-form posts are truncated in the timeline. Fetch the full text
        // once for P0 or keyword-mode accounts, capped to two per poll.
        if !newPosts.isEmpty {
            var fetches = 0
            for postIndex in newPosts.indices where newPosts[postIndex].isLongText {
                guard fetches < 2 else { break }
                guard users[index].priority == .p0
                    || users[index].notifyMode == .keywords else { continue }
                guard case .allowed = budget.acquire(now: now, priority: users[index].priority) else {
                    break
                }
                fetches += 1
                if let current = users.firstIndex(where: { $0.uid == uid }) {
                    users[current].lastRequestAt = now
                }
                let longText = await feed.fetchLongText(
                    mid: newPosts[postIndex].mid,
                    credentials: credentials
                )
                guard let refreshed = users.firstIndex(where: { $0.uid == uid }) else {
                    return .failure
                }
                index = refreshed
                if let longText, !longText.isEmpty {
                    newPosts[postIndex].text = longText
                }
            }
        }

        let degradedNewPosts = unique.filter {
            missingDateMids.contains($0.mid) && !user.seenMids.contains($0.mid)
        }
        var degradedReadPosts: [WeiboPost] = []
        if !newPosts.isEmpty || !degradedNewPosts.isEmpty {
            let relevance = await decideRelevance(
                posts: newPosts + degradedNewPosts,
                user: users[index],
                now: now
            )
            guard let refreshed = users.firstIndex(where: { $0.uid == uid }) else {
                return .failure
            }
            index = refreshed
            newPosts = newPosts.map { post -> WeiboPost in
                var copy = post
                copy.relevance = relevance[post.mid]
                return copy
            }
            // A post whose date could not be parsed still belongs in the feed;
            // it is read and never pushed.
            degradedReadPosts = degradedNewPosts.map { post -> WeiboPost in
                var copy = post
                copy.read = true
                copy.relevance = relevance[post.mid]
                return copy
            }
        }

        if newPosts.isEmpty && degradedReadPosts.isEmpty {
            mergeSeenMids(uid: uid, posts: unique, newest: newest)
            users[index].nextDueAt = planner.nextDue(
                for: users[index], now: now, config: config, isLowPower: isLowPower, rng: &rng
            )
            if isAuthProbe { finishAuthProbe(now: now) }
            return .success
        }

        var merged = postsByUID[uid] ?? []
        let existing = Set(merged.map(\.mid))
        merged.append(
            contentsOf: (newPosts + degradedReadPosts).filter { !existing.contains($0.mid) }
        )
        postsByUID[uid] = trim(posts: merged, now: now)

        mergeSeenMids(uid: uid, posts: unique, newest: newest)
        users[index].stats = stats(for: postsByUID[uid] ?? [], now: now)
        users[index].hotWindowUntil = now.addingTimeInterval(10 * 60)
        users[index].nextDueAt = planner.nextDue(
            for: users[index], now: now, config: config, isLowPower: isLowPower, rng: &rng
        )

        // A long sleep must not produce an eight-hour notification flood. All
        // posts go to the feed; only the newest one is eligible for a push.
        // If the baseline was lost, the spec says "do not backfill"; the posts
        // still land in the feed and the UI shows "possible gap".
        let longGap = now.timeIntervalSince(gapAnchor) > 2 * 3600
        let alertPosts: [WeiboPost]
        if gapSuspected {
            alertPosts = []
        } else if longGap {
            alertPosts = Array(newPosts.sorted { $0.createdAt > $1.createdAt }.prefix(1))
        } else {
            alertPosts = newPosts
        }
        queueAlerts(posts: alertPosts, user: users[index], now: now)
        let eventName = users[index].screenName
        if !degradedReadPosts.isEmpty {
            addEvent(
                .warning,
                "\(eventName) · \(L10n.string("weibo.events.dateSkipped", language: config.language, degradedReadPosts.count))"
            )
        }

        await persistPosts(uid: uid, now: now)
        addEvent(
            .success,
            "\(eventName) · \(L10n.string("weibo.events.newPosts", language: config.language, newPosts.count))"
        )
        if isAuthProbe { finishAuthProbe(now: now) }
        return .success
    }

    /// Advances the baseline over every fetched mid, including pure reposts and
    /// old pinned posts. Skipping them in `seenMids` would make the next poll
    /// see them as "unseen" again and trigger a pointless page-2 gap scan.
    private func mergeSeenMids(uid: String, posts: [WeiboPost], newest: WeiboPost?) {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        var seenMids = users[index].seenMids
        seenMids.insert(contentsOf: posts.map(\.mid), at: 0)
        var uniqueMids = Set<String>()
        users[index].seenMids = Array(
            seenMids.filter { uniqueMids.insert($0).inserted }.prefix(100)
        )
        if let newest, newest.createdAt > (users[index].lastSeenAt ?? .distantPast) {
            users[index].lastSeenMid = newest.mid
            users[index].lastSeenAt = newest.createdAt
        }
    }

    private func fetchPage(
        uid: String,
        screenName: String,
        page: Int,
        now: Date
    ) async -> WeiboFetchOutcome {
        if let index = users.firstIndex(where: { $0.uid == uid }) {
            users[index].lastRequestAt = now
        }
        return await feed.fetchPage(
            uid: uid,
            screenName: screenName,
            page: page,
            credentials: credentials,
            now: now
        )
    }

    private func handleFailure(
        uid: String,
        kind: WeiboRiskKind,
        message: String,
        retryAfter: TimeInterval?,
        now: Date,
        isCircuitProbe: Bool
    ) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        var user = users[index]
        user.lastCheckedAt = now
        user.consecutiveFailures += 1
        var preserveNextDue = false
        var shouldSendAuthAlert = false

        if isCircuitProbe {
            circuit.noteFailure(now: now)
            globalCooldownUntil = maxDate(globalCooldownUntil, circuit.openUntilDate)
        }

        switch kind {
        case .rateLimited:
            let pause = max(3600, retryAfter ?? 0)
            user.pausedUntil = now.addingTimeInterval(pause)
            user.lastErrorKind = .rateLimited
            globalCooldownUntil = maxDate(
                globalCooldownUntil,
                now.addingTimeInterval(15 * 60)
            )
            if !isCircuitProbe {
                let duration = WeiboRandom.double(in: 30 * 60...60 * 60, rng: &rng)
                if circuit.noteRateLimit(uid: uid, now: now, openDuration: duration) {
                    globalCooldownUntil = maxDate(globalCooldownUntil, circuit.openUntilDate)
                    addEvent(
                        .warning,
                        L10n.string("weibo.events.rateLimitGlobal", language: config.language)
                    )
                }
            }
        case .authExpired:
            user.lastErrorKind = .authExpired
            user.pausedUntil = now.addingTimeInterval(15 * 60)
            authState = .expired
            authPausedUntil = now.addingTimeInterval(15 * 60)
            isAuthProbe = false
            shouldSendAuthAlert = true
        case .challenge:
            user.pausedUntil = now.addingTimeInterval(30 * 60)
            user.lastErrorKind = .challenge
            globalCooldownUntil = maxDate(
                globalCooldownUntil,
                now.addingTimeInterval(30 * 60)
            )
        case .network, .server, .unknown:
            let base: TimeInterval = [120, 300, 900, 3600][min(max(user.consecutiveFailures - 1, 0), 3)]
            let delay = max(120, base * WeiboRandom.double(in: 0.8...1.2, rng: &rng))
            user.pausedUntil = now.addingTimeInterval(delay)
            user.lastErrorKind = kind == .network ? .network : (kind == .server ? .server : .unknown)
            if user.consecutiveFailures >= 5 {
                user.needsManualResume = true
            }
        case .parseChanged:
            user.pausedUntil = now.addingTimeInterval(30 * 60)
            user.lastErrorKind = .parseChanged
        case .emptyList:
            let streak = (emptyStreak[uid] ?? 0) + 1
            emptyStreak[uid] = streak
            user.lastErrorKind = .emptyList
            if streak >= 3 {
                // A slowdown, not a hard pause: the account may legitimately
                // have no posts. Keep this nextDue instead of letting the
                // generic planner overwrite it.
                user.nextDueAt = now.addingTimeInterval(
                    2 * config.interval(for: user.priority)
                )
                preserveNextDue = true
            }
        case .ok:
            return
        }

        if !preserveNextDue {
            user.nextDueAt = max(
                user.pausedUntil ?? now,
                planner.nextDue(
                    for: user, now: now, config: config, isLowPower: isLowPower, rng: &rng
                )
            )
        }
        users[index] = user

        let errorKey = user.lastErrorKind?.titleKey ?? "weibo.error.unknown"
        addEvent(
            .error,
            "\(user.screenName) · \(L10n.string(errorKey, language: config.language))"
        )
        if shouldSendAuthAlert {
            await sendAuthAlertIfNeeded(now: now)
        }
        Self.logger.notice(
            "failure uid=\(user.uid, privacy: .private) kind=\(kind.rawValue, privacy: .public) message=\(message, privacy: .public)"
        )
    }

    private func finishAuthProbe(now: Date) {
        guard isAuthProbe else { return }
        isAuthProbe = false
        authState = .loggedIn
        authPausedUntil = nil
        for index in users.indices where users[index].lastErrorKind == .authExpired {
            users[index].pausedUntil = nil
            users[index].lastErrorKind = nil
            users[index].consecutiveFailures = 0
            users[index].nextDueAt = now.addingTimeInterval(
                WeiboRandom.double(in: 5...20, rng: &rng)
            )
        }
        addEvent(
            .success,
            L10n.string("weibo.events.sessionRestored", language: config.language)
        )
    }

    private func observeCookieChange(credentials: WeiboCredentials, now: Date) {
        let current = credentials.desktopCookieHeader
        if let previous = lastDesktopCookieHeader, previous != current {
            if authState == .expired, credentials.hasDesktopLogin {
                // The user signed in again. Skip the remaining backoff for the
                // accounts that were paused by the auth failure, and probe on
                // this tick; the probe decides whether it really works.
                authPausedUntil = now
                for index in users.indices where users[index].lastErrorKind == .authExpired {
                    users[index].pausedUntil = nil
                }
            }
        }
        lastDesktopCookieHeader = current
    }

    // MARK: - Alerts

    private func queueAlerts(posts: [WeiboPost], user: WeiboMonitorUser, now: Date) {
        guard !posts.isEmpty else { return }
        var accepted: [WeiboPost] = []
        for post in posts {
            let decision = alertPolicy.decision(
                for: post,
                user: user,
                config: config,
                now: now,
                accountNotificationsLastHour: deliveredCount(uid: user.uid, now: now),
                globalNotificationsLastHour: delivered.count,
                verdict: post.relevance?.verdict
            )
            if decision.shouldNotify {
                accepted.append(post)
            }
        }
        guard !accepted.isEmpty else { return }

        pendingAlerts[user.uid, default: []].append(contentsOf: accepted)
        if pendingAlertStartedAt[user.uid] == nil {
            pendingAlertStartedAt[user.uid] = now
        }
        scheduleAlertFlush(now: now)
    }

    private func scheduleAlertFlush(now: Date) {
        guard autoFlushAlerts else { return }
        alertFlushTask?.cancel()
        alertFlushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(Self.notificationWindow))
            guard !Task.isCancelled else { return }
            await self.flushAlerts(now: Date())
        }
    }

    func flushAlerts(now: Date) async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let ready = pendingAlerts.keys.filter { uid in
            guard let started = pendingAlertStartedAt[uid] else { return true }
            return now.timeIntervalSince(started) >= Self.notificationWindow
        }
        guard !ready.isEmpty else {
            if !pendingAlerts.isEmpty { scheduleAlertFlush(now: now) }
            return
        }

        for uid in ready {
            guard let posts = pendingAlerts[uid], !posts.isEmpty,
                  let user = users.first(where: { $0.uid == uid }) else {
                pendingAlerts[uid] = nil
                pendingAlertStartedAt[uid] = nil
                continue
            }
            guard config.enabled, config.notifyEnabled, !user.isMuted(now: now) else {
                pendingAlerts[uid] = nil
                pendingAlertStartedAt[uid] = nil
                continue
            }
            let accountCount = deliveredCount(uid: uid, now: now)
            let globalCount = delivered.count
            guard accountCount < config.perAccountHourlyCap,
                  globalCount < config.globalHourlyCap else {
                addEvent(
                    .warning,
                    "\(user.screenName) · \(L10n.string("weibo.events.notifCap", language: config.language))"
                )
                pendingAlerts[uid] = nil
                pendingAlertStartedAt[uid] = nil
                continue
            }
            // Remove the batch before awaiting delivery. A new post can arrive
            // while the notifier is suspended; clearing at the end would
            // silently drop it and it would never be notified.
            let batch = pendingAlerts.removeValue(forKey: uid) ?? []
            pendingAlertStartedAt[uid] = nil
            if let notification = alertPolicy.notification(
                for: batch,
                user: user,
                language: config.language,
                now: now
            ) {
                await notifier.send(notification, language: config.language)
                delivered.append((now, uid))
            }
        }
        if !pendingAlerts.isEmpty {
            scheduleAlertFlush(now: now)
        }
        pruneDelivered(now: now)
    }

    private func sendAuthAlertIfNeeded(now: Date) async {
        if let last = lastAuthAlertAt, now.timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        lastAuthAlertAt = now
        await notifier.sendAuthExpired(language: config.language)
        await authAlertRecorder(now)
        addEvent(
            .warning,
            L10n.string("weibo.events.authAlert", language: config.language)
        )
    }

    private func deliveredCount(uid: String, now: Date) -> Int {
        delivered.filter {
            $0.uid == uid && now.timeIntervalSince($0.date) < 3600
        }.count
    }

    private func pruneDelivered(now: Date) {
        delivered.removeAll { now.timeIntervalSince($0.date) >= 3600 }
    }

    // MARK: - Relevance

    /// Scores a batch of posts against the account's beat. The local rules
    /// always answer; the optional model only re-decides the uncertain ones,
    /// and only when the user turned correction on.
    private func decideRelevance(
        posts: [WeiboPost],
        user: WeiboMonitorUser,
        now: Date,
        updatesStats: Bool = true
    ) async -> [String: WeiboPostRelevance] {
        guard !posts.isEmpty else { return [:] }
        let mode = config.effectiveRelevanceMode(for: user)
        guard mode != .off else { return [:] }

        let references = crossPostReferences(excludingUID: user.uid, now: now)
        let fingerprintIndex = WeiboCrossPostIndex(
            references: references,
            excludingUID: user.uid,
            now: now
        )
        let baseline = user.relevanceStats?.onTopicRatio ?? 0.5

        var results: [String: WeiboPostRelevance] = [:]
        var corrected = 0
        for post in posts {
            var relevance = relevanceModel.evaluate(
                text: post.displayText,
                imageCount: post.imageURLs.count,
                accountBaseline: baseline,
                userKeywords: config.keywordList,
                crossPostIndex: fingerprintIndex,
                mode: mode,
                now: now
            )
            // Only uncertain verdicts are worth a network round trip. A
            // definite ad or a definite on-topic post stays local.
            if config.relevanceAICorrection,
               corrected < 3,
               relevance.verdict == .lowConfidence || relevance.verdict == .offTopic,
               let fused = await correct(
                   relevance: relevance,
                   post: post,
                   user: user,
                   mode: mode,
                   now: now
               ) {
                relevance = fused
                corrected += 1
            }
            results[post.mid] = relevance
        }

        if updatesStats, let userIndex = users.firstIndex(where: { $0.uid == user.uid }) {
            var stats = users[userIndex].relevanceStats ?? WeiboRelevanceStats()
            for relevance in results.values {
                stats.record(relevance)
            }
            users[userIndex].relevanceStats = stats
        }
        if let corpus {
            let decided = posts.map { post -> WeiboPost in
                var copy = post
                copy.relevance = results[post.mid]
                return copy
            }
            await corpus.append(posts: decided, now: now)
        }
        return results
    }

    private func correct(
        relevance: WeiboPostRelevance,
        post: WeiboPost,
        user: WeiboMonitorUser,
        mode: WeiboRelevanceMode,
        now: Date
    ) async -> WeiboPostRelevance? {
        guard !relevanceDeciders.isEmpty else { return nil }
        let day = Calendar.current.startOfDay(for: now)
        if relevanceAIDay != day {
            relevanceAIDay = day
            relevanceAICalls = 0
        }
        // A free endpoint still deserves a ceiling: a polling bug must not
        // turn into thousands of requests a day.
        guard relevanceAICalls < Self.relevanceAIDailyCap else { return nil }
        let context = WeiboDecisionContext(
            screenName: user.screenName,
            recentTopics: recentTopics(for: user.uid),
            isLongText: post.isLongText
        )
        for decider in relevanceDeciders.prefix(2) {
            var circuit = relevanceCircuits[decider.providerID] ?? WeiboRelevanceCircuitBreaker()
            guard circuit.canRequest(now: now) else { continue }
            guard let reservation = AIQuotaStore.shared.reserveTracked(
                .weiboRelevance,
                policy: .unlimited,
                at: now
            ) else {
                // The ledger refuses every reservation when it is unreadable.
                // Falling back to the rules is the safe answer.
                return nil
            }
            relevanceAICalls += 1
            do {
                let result = try await decider.decide(
                    text: post.displayText,
                    context: context
                )
                circuit.noteSuccess()
                relevanceCircuits[decider.providerID] = circuit
                _ = AIQuotaStore.shared.settle(
                    reservation,
                    actualCostMicros: result.costMicros,
                    inputTokens: result.inputTokens,
                    outputTokens: result.outputTokens,
                    priced: result.costMicros > 0,
                    at: now
                )
                return fuse(
                    relevance,
                    with: result,
                    providerID: decider.providerID,
                    mode: mode,
                    now: now
                )
            } catch {
                circuit.noteFailure(now: now)
                relevanceCircuits[decider.providerID] = circuit
                Self.logger.warning(
                    "relevance decider \(decider.providerID, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return nil
    }

    /// Rules stay in charge: the model may lift a post back to relevance, but
    /// it can never lower an interest score the rules already computed.
    private func fuse(
        _ relevance: WeiboPostRelevance,
        with result: WeiboDecisionResult,
        providerID: String,
        mode: WeiboRelevanceMode,
        now: Date
    ) -> WeiboPostRelevance {
        let adScore = WeiboRelevanceModel.clamp01(
            0.6 * relevance.adScore + 0.4 * result.isAd
        )
        let interestScore = WeiboRelevanceModel.clamp01(
            max(relevance.interestScore, 1 - result.isOffTopic)
        )
        let verdict = relevanceModel.verdict(
            adScore: adScore,
            interestScore: interestScore,
            mode: mode
        )
        var reasons = Array(relevance.reasons.prefix(2))
        reasons.append("model")
        return WeiboPostRelevance(
            adScore: adScore,
            interestScore: interestScore,
            verdict: verdict,
            reasons: reasons,
            decider: "rules+\(providerID)",
            decidedAt: now,
            modelConfidence: result.topicConfidence
        )
    }

    private func crossPostReferences(
        excludingUID: String,
        now: Date
    ) -> [WeiboCrossPostReference] {
        let cutoff = now.addingTimeInterval(-72 * 60 * 60)
        var references: [WeiboCrossPostReference] = []
        for (uid, posts) in postsByUID where uid != excludingUID {
            for post in posts where post.createdAt >= cutoff {
                references.append(
                    WeiboCrossPostReference(
                        uid: uid,
                        text: post.displayText,
                        createdAt: post.createdAt
                    )
                )
            }
        }
        return references
    }

    /// Re-evaluates stored posts, e.g. after the user changes the filter mode.
    /// Only the local rules run here: this is a UI change, not a new poll.
    private func redecideAllPosts(now: Date) async {
        for uid in Array(postsByUID.keys) {
            await redecidePosts(uid: uid, now: now)
        }
    }

    private func redecidePosts(uid: String, now: Date) async {
        guard var posts = postsByUID[uid], !posts.isEmpty,
              let user = users.first(where: { $0.uid == uid }) else { return }
        let mode = config.effectiveRelevanceMode(for: user)
        if mode == .off {
            var changed = false
            for index in posts.indices where posts[index].relevance != nil {
                posts[index].relevance = nil
                changed = true
            }
            guard changed else { return }
        } else {
            let references = crossPostReferences(excludingUID: uid, now: now)
            let fingerprintIndex = WeiboCrossPostIndex(
                references: references,
                excludingUID: uid,
                now: now
            )
            let baseline = user.relevanceStats?.onTopicRatio ?? 0.5
            for index in posts.indices {
                posts[index].relevance = relevanceModel.evaluate(
                    text: posts[index].displayText,
                    imageCount: posts[index].imageURLs.count,
                    accountBaseline: baseline,
                    userKeywords: config.keywordList,
                    crossPostIndex: fingerprintIndex,
                    mode: mode,
                    now: now
                )
            }
        }
        postsByUID[uid] = posts
        await persistPosts(uid: uid, now: now)
    }

    private func recentTopics(for uid: String) -> [String] {
        Array(
            (postsByUID[uid] ?? [])
                .prefix(6)
                .compactMap { topicHint(for: $0.displayText) }
        )
    }

    private func topicHint(for text: String) -> String? {
        let lower = text.lowercased()
        if ["手机", "iphone", "华为", "小米", "荣耀", "oppo", "vivo", "屏幕", "影像", "电池", "充电", "平板", "耳机"]
            .contains(where: lower.contains) {
            return "phone"
        }
        if ["电脑", "笔记本", "显卡", "cpu", "gpu", "键盘", "显示器", "内存", "硬盘"]
            .contains(where: lower.contains) {
            return "pc"
        }
        if ["ai", "模型", "开源", "算法", "kimi", "deepseek", "gpt", "claude"]
            .contains(where: lower.contains) {
            return "ai"
        }
        if ["系统", "更新", "app", "软件", "鸿蒙", "安卓", "ios", "macos", "windows"]
            .contains(where: lower.contains) {
            return "software"
        }
        if ["汽车", "智驾", "试驾", "车主", "车机"].contains(where: lower.contains) {
            return "auto"
        }
        return nil
    }

    // MARK: - User actions

    func addUser(
        input: String,
        priority: WeiboMonitorPriority = .p1,
        notifyMode: WeiboNotifyMode? = nil,
        now: Date
    ) async throws -> WeiboMonitorUser {
        guard let uid = Self.parseUID(input) else {
            throw WeiboMonitorAddError.invalidInput
        }
        guard !users.contains(where: { $0.uid == uid }) else {
            throw WeiboMonitorAddError.duplicate
        }
        let user = WeiboMonitorUser(
            uid: uid,
            screenName: "UID \(uid)",
            priority: priority,
            notifyMode: notifyMode,
            addedAt: now,
            nextDueAt: now,
            stats: WeiboMonitorStats()
        )
        users.append(user)
        postsByUID[uid] = []
        addEvent(
            .info,
            "\(user.screenName) · \(L10n.string("weibo.events.added", language: config.language))"
        )
        await persistUsers(now: now)
        await notifyChange()
        return user
    }

    func removeUser(uid: String, now: Date) async {
        guard let user = users.first(where: { $0.uid == uid }) else { return }
        users.removeAll { $0.uid == uid }
        postsByUID[uid] = nil
        pendingAlerts[uid] = nil
        pendingAlertStartedAt[uid] = nil
        unloadedUIDs.remove(uid)
        await store.deletePosts(uid: uid)
        addEvent(
            .info,
            "\(user.screenName) · \(L10n.string("weibo.events.removed", language: config.language))"
        )
        await persistUsers(now: now)
        await notifyChange()
    }

    func setPriority(uid: String, priority: WeiboMonitorPriority, now: Date) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        let oldDefault = WeiboNotifyMode.defaultMode(for: users[index].priority)
        users[index].priority = priority
        if users[index].notifyMode == oldDefault {
            users[index].notifyMode = WeiboNotifyMode.defaultMode(for: priority)
        }
        await persistUsers(now: now)
        await notifyChange()
    }

    func setNotifyMode(uid: String, mode: WeiboNotifyMode, now: Date) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        users[index].notifyMode = mode
        await persistUsers(now: now)
        await notifyChange()
    }

    /// nil follows the global mode; `.off` means "always show this account".
    func setRelevanceMode(uid: String, mode: WeiboRelevanceMode?, now: Date) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        guard users[index].relevanceMode != mode else { return }
        users[index].relevanceMode = mode
        await persistUsers(now: now)
        await redecidePosts(uid: uid, now: now)
        await notifyChange()
    }

    func setEnabled(uid: String, enabled: Bool, now: Date) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        users[index].enabled = enabled
        if enabled, users[index].nextDueAt < now {
            users[index].nextDueAt = now
        }
        await persistUsers(now: now)
        await notifyChange()
    }

    func checkNow(uid: String, now: Date) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        let floor = users[index].lastRequestAt?.addingTimeInterval(60) ?? now
        users[index].nextDueAt = max(now, floor)
        await persistUsers(now: now)
        await notifyChange()
    }

    func checkAll(now: Date) async {
        for index in users.indices where users[index].enabled {
            let floor = users[index].lastRequestAt?.addingTimeInterval(60) ?? now
            users[index].nextDueAt = max(now, floor)
        }
        await persistUsers(now: now)
        await notifyChange()
    }

    func mute(uid: String, until: Date, now: Date) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        users[index].mutedUntil = until
        addEvent(
            .info,
            "\(users[index].screenName) · \(L10n.string("weibo.events.muted", language: config.language))"
        )
        await persistUsers(now: now)
        await notifyChange()
    }

    func resumeUser(uid: String, now: Date) async {
        guard let index = users.firstIndex(where: { $0.uid == uid }) else { return }
        if unloadedUIDs.contains(uid) {
            // The posts file could not be read. Resuming would overwrite it
            // with a partial array; keep the disk error until a restart can
            // retry the read.
            users[index].lastErrorKind = .disk
            users[index].needsManualResume = true
            users[index].pausedUntil = nil
            await persistUsers(now: now)
            await notifyChange()
            return
        }
        users[index].pausedUntil = nil
        users[index].mutedUntil = nil
        users[index].needsManualResume = false
        users[index].consecutiveFailures = 0
        users[index].lastErrorKind = nil
        users[index].nextDueAt = now
        emptyStreak[uid] = nil
        addEvent(
            .info,
            "\(users[index].screenName) · \(L10n.string("weibo.events.manualResume", language: config.language))"
        )
        await persistUsers(now: now)
        await notifyChange()
    }

    func pauseAll(until: Date, now: Date) async {
        globalPausedUntil = until
        addEvent(
            .info,
            L10n.string("weibo.events.paused", language: config.language)
        )
        await notifyChange()
    }

    func resumeAll(now: Date) async {
        globalPausedUntil = nil
        globalCooldownUntil = nil
        circuit.reset()
        await notifyChange()
    }

    func markRead(mid: String, now: Date) async {
        for uid in Array(postsByUID.keys) {
            guard var posts = postsByUID[uid],
                  let index = posts.firstIndex(where: { $0.mid == mid }) else { continue }
            posts[index].read = true
            postsByUID[uid] = posts
            await persistPosts(uid: uid, now: now)
            await notifyChange()
            return
        }
    }

    func markAllRead(now: Date) async {
        for uid in Array(postsByUID.keys) {
            guard var posts = postsByUID[uid], posts.contains(where: { !$0.read }) else { continue }
            for index in posts.indices { posts[index].read = true }
            postsByUID[uid] = posts
            await persistPosts(uid: uid, now: now)
        }
        await notifyChange()
    }

    func clearGap(uid: String? = nil, now: Date) async {
        if let uid, let index = users.firstIndex(where: { $0.uid == uid }) {
            users[index].gapSuspected = false
        } else {
            for index in users.indices { users[index].gapSuspected = false }
        }
        await persistUsers(now: now)
        await notifyChange()
    }

    func persistNow(now: Date) async {
        await persistUsers(now: now)
        for uid in Array(postsByUID.keys) {
            await persistPosts(uid: uid, now: now)
        }
        await notifyChange()
    }

    // MARK: - Snapshot

    func snapshot() -> WeiboMonitorSnapshot {
        let unread = postsByUID.values.reduce(0) { partial, posts in
            partial + posts.reduce(0) {
                $0 + (($1.read || $1.isCollapsedByRelevance) ? 0 : 1)
            }
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: lastTickAt ?? Date())
        let todayCount = postsByUID.values.reduce(0) { partial, posts in
            partial + posts.reduce(0) { $0 + ($1.createdAt >= dayStart ? 1 : 0) }
        }
        let next = users
            .filter { $0.enabled && !$0.isPaused(now: Date()) }
            .map(\.nextDueAt)
            .min()
        let pauseCandidates = [globalPausedUntil, globalCooldownUntil, authPausedUntil, circuit.openUntilDate]
            .compactMap { $0 }
        let pausedUntil = pauseCandidates.max()

        return WeiboMonitorSnapshot(
            users: users,
            postsByUID: postsByUID,
            unreadCount: unread,
            loginState: resolvedLoginState,
            isEnabled: config.enabled,
            isTicking: isTicking,
            isOnline: isOnline,
            pausedUntil: pausedUntil,
            authPausedUntil: authPausedUntil,
            lastTickAt: lastTickAt,
            nextCheckAt: next,
            events: Array(events.suffix(Self.maxEvents)),
            storeError: storeError,
            storeErrorKey: persistentStoreWarningKey,
            todayPostCount: todayCount,
            gapSuspectedCount: users.filter(\.gapSuspected).count
        )
    }

    private var resolvedLoginState: WeiboLoginState {
        if authState == .expired { return .expired }
        if credentials.hasDesktopLogin { return .loggedIn }
        if credentials.hasMobileLogin { return .mobileOnly }
        return credentials.loginState
    }

    // MARK: - Helpers

    private func dueUIDs(now: Date) -> [String] {
        var buckets: [Int: [String]] = [:]
        for user in users {
            guard user.enabled,
                  !user.isMuted(now: now),
                  !user.isPaused(now: now),
                  !unloadedUIDs.contains(user.uid),
                  user.nextDueAt <= now else { continue }
            buckets[user.priority.rank, default: []].append(user.uid)
        }
        var result: [String] = []
        for rank in 0...2 {
            var bucket = buckets[rank] ?? []
            bucket.shuffle(using: &rng)
            result.append(contentsOf: bucket)
        }
        return result
    }

    private func isGloballyPaused(now: Date) -> Bool {
        if let globalPausedUntil, globalPausedUntil > now { return true }
        if let globalCooldownUntil, globalCooldownUntil > now { return true }
        if let authPausedUntil, authPausedUntil > now, authState == .expired, !isAuthProbe {
            return true
        }
        if circuit.isOpen(now: now), !circuit.canRequest(now: now) { return true }
        return false
    }

    private func trim(posts: [WeiboPost], now: Date) -> [WeiboPost] {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let filtered = posts
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
        return Array(filtered.prefix(WeiboMonitorStore.maxPostsPerAccount))
    }

    private func stats(for posts: [WeiboPost], now: Date) -> WeiboMonitorStats {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = posts.filter { $0.createdAt >= cutoff }
        return WeiboMonitorStats(
            posts7d: recent.count,
            lastPostAt: posts.map(\.createdAt).max()
        )
    }

    private func persistUsers(now: Date) async {
        // A monitor file that could not be archived must not be replaced by a
        // rebuilt, settings-lossy account list.
        guard !monitorWritesBlocked else { return }
        do {
            try await store.save(users: users, now: now)
            storeError = persistentStoreWarningKey
            consecutiveStoreFailures = 0
        } catch {
            consecutiveStoreFailures += 1
            persistentStoreWarningKey = nil
            storeError = error.localizedDescription
            Self.logger.error("persist users failed: \(error.localizedDescription, privacy: .public)")
            if consecutiveStoreFailures == 3 {
                addEvent(
                    .error,
                    L10n.string("weibo.events.storeError", language: config.language)
                )
            }
        }
    }

    private func persistPosts(uid: String, now: Date) async {
        guard !unloadedUIDs.contains(uid) else { return }
        guard let posts = postsByUID[uid] else { return }
        do {
            try await store.savePosts(uid: uid, posts: posts, now: now)
        } catch {
            consecutiveStoreFailures += 1
            persistentStoreWarningKey = nil
            storeError = error.localizedDescription
            Self.logger.error("persist posts failed: \(error.localizedDescription, privacy: .public)")
            if consecutiveStoreFailures == 3 {
                addEvent(
                    .error,
                    L10n.string("weibo.events.storeError", language: config.language)
                )
            }
        }
    }

    private func addEvent(_ kind: WeiboMonitorEvent.Kind, _ message: String) {
        events.append(WeiboMonitorEvent(at: Date(), kind: kind, message: message))
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

    private func notifyChange() async {
        await changeNotifier()
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): return max(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    static func parseUID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.allSatisfy(\.isNumber), (5...20).contains(trimmed.count) {
            return trimmed
        }

        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              let host = url.host?.lowercased() else {
            return nil
        }
        let allowedHosts = ["weibo.com", "www.weibo.com", "m.weibo.cn"]
        guard allowedHosts.contains(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if let marker = parts.firstIndex(of: "u"), marker + 1 < parts.count {
            let candidate = parts[marker + 1]
            if candidate.allSatisfy(\.isNumber), (5...20).contains(candidate.count) {
                return candidate
            }
        }
        if parts.count == 1 {
            let candidate = parts[0]
            if candidate.allSatisfy(\.isNumber), (5...20).contains(candidate.count) {
                return candidate
            }
        }
        return nil
    }
}

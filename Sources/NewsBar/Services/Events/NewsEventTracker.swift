import Foundation

protocol NewsEventTracking: Sendable {
    func tick(now: Date, sources: [NewsSource]) async -> NewsEventTrackingResult
    func recover(now: Date, sources: [NewsSource]) async -> NewsEventTrackingResult
    func budgetSnapshot(now: Date) async throws -> NewsEventBudgetSnapshot
    /// One conditional feed check for the workspace RSS checker. It uses the
    /// same budget actor and single-flight slot as event tracking; it does not
    /// touch event records or the scheduler. The budget slot is held until the
    /// caller acknowledges the result.
    func checkFeed(_ source: NewsSource, now: Date) async -> NewsEventSharedFeedCheck
    func acknowledgeFeedCheck(sourceID: String, outcome: NewsEventFeedAck) async
}

enum NewsEventFeedAck: Sendable {
    case committed
    case failed
    case cancelled
}

/// Result of one shared conditional feed check. The caller must persist any
/// returned evidence before committing `cursor`; the tracker never commits a
/// success cursor itself.
enum NewsEventSharedFeedCheck: Sendable {
    case reused(cursor: NewsEventFeedCursor, budget: NewsEventBudgetSnapshot)
    case notModified(cursor: NewsEventFeedCursor, budget: NewsEventBudgetSnapshot)
    case modified(evidence: [NewsEventEvidence], cursor: NewsEventFeedCursor,
                  budget: NewsEventBudgetSnapshot)
    case pending(budget: NewsEventBudgetSnapshot, reason: String)
    case throttled(until: Date?, budget: NewsEventBudgetSnapshot, reason: String)
    case failed(message: String, retryAt: Date?, budget: NewsEventBudgetSnapshot)
}

actor NewsEventTracker: NewsEventTracking {
    private struct PendingFeedCheck {
        let sourceID: String
        let evidence: [NewsEventEvidence]
        let cursor: NewsEventFeedCursor
        let createdAt: Date
    }

    private let store: any NewsEventPersisting
    private let fetcher: any NewsEventRSSFetching
    private let budget: NewsEventTrackingBudget
    /// A successful fetch whose evidence/cursor has not been acknowledged by
    /// the controller yet. The budget slot stays held for this source, so no
    /// tick or second manual check can fetch it again before durability.
    private var pendingFeedChecks: [String: PendingFeedCheck] = [:]
    private let pendingLifetime: TimeInterval = 120

    init(
        store: any NewsEventPersisting = NewsEventStore.shared,
        fetcher: any NewsEventRSSFetching = NewsEventRSSFetcher(),
        budget: NewsEventTrackingBudget? = nil
    ) {
        self.store = store
        self.fetcher = fetcher
        self.budget = budget ?? NewsEventTrackingBudget(store: store)
    }

    func recover(now: Date, sources: [NewsSource]) async -> NewsEventTrackingResult {
        await tick(now: now, sources: sources)
    }

    func budgetSnapshot(now: Date) async throws -> NewsEventBudgetSnapshot {
        try await budget.snapshot(now: now)
    }

    func tick(now: Date, sources: [NewsSource]) async -> NewsEventTrackingResult {
        await purgeStalePending(now: now)
        do {
            let allEvents = try await store.events()
            let dueEvents = allEvents.filter {
                $0.lifecycle == .tracking && NewsEventScheduler.isDue($0, at: now)
            }
            let rssSources = Self.uniqueRSSSources(in: sources)
            let currentBudget = try await budget.snapshot(now: now)
            let activeEvents = allEvents.filter { $0.lifecycle == .tracking }
            if rssSources.isEmpty, !activeEvents.isEmpty {
                return Self.result(
                    state: .noFreshSource,
                    budget: Self.paused(currentBudget, reason: "没有已启用 RSS 来源；本轮无新鲜来源。"),
                    pendingEventIDs: activeEvents.map(\.id).sorted(),
                    message: "没有已启用 RSS 来源；未执行实时检查，不代表无更新或已核实。"
                )
            }
            guard !dueEvents.isEmpty else {
                let state: NewsEventTrackingState = allEvents.contains(where: { $0.lifecycle == .tracking })
                    ? .tracking : .idle
                return Self.result(state: state, budget: currentBudget)
            }

            var cursors: [String: NewsEventFeedCursor] = [:]
            for source in rssSources {
                if let cursor = try await store.feedCursor(for: source.id) {
                    cursors[source.id] = cursor
                }
            }

            // A successful normal RSS refresh after an event became due is a
            // shared fresh check; it satisfies that due without another request.
            let sharedCheckedIDs = dueEvents.filter { event in
                guard let dueAt = NewsEventScheduler.dueAt(for: event) else { return false }
                return cursors.values.contains { cursor in
                    guard let checkedAt = cursor.checkedAt else { return false }
                    return checkedAt >= dueAt && checkedAt <= now
                }
            }.map(\.id).sorted()
            let sharedSet = Set(sharedCheckedIDs)
            let remainingDue = dueEvents.filter { !sharedSet.contains($0.id) }
            guard !remainingDue.isEmpty else {
                return Self.result(
                    state: .tracking,
                    budget: currentBudget,
                    checkedEventIDs: sharedCheckedIDs,
                    message: "常规 RSS 检查已在 due 后完成；复用共享 cursor，未重复请求。"
                )
            }

            let linkedSourceIDs = Set(remainingDue.flatMap { $0.evidence.compactMap(\.sourceID) })
            let pendingSourceIDs = Set(pendingFeedChecks.keys)
            let candidates = rssSources
                .filter { !pendingSourceIDs.contains($0.id) }
                .filter { (cursors[$0.id]?.retryAfter ?? .distantPast) <= now }
                .sorted { lhs, rhs in
                    let lhsCursor = cursors[lhs.id]
                    let rhsCursor = cursors[rhs.id]
                    let lhsTouch = Self.latest(lhsCursor?.checkedAt, lhsCursor?.attemptedAt) ?? .distantPast
                    let rhsTouch = Self.latest(rhsCursor?.checkedAt, rhsCursor?.attemptedAt) ?? .distantPast
                    if lhsTouch != rhsTouch { return lhsTouch < rhsTouch }
                    let lhsLinked = linkedSourceIDs.contains(lhs.id)
                    let rhsLinked = linkedSourceIDs.contains(rhs.id)
                    if lhsLinked != rhsLinked { return lhsLinked }
                    return lhs.id < rhs.id
                }

            guard let source = candidates.first else {
                if !pendingSourceIDs.isEmpty {
                    let pendingBudget = (try? await budget.snapshot(now: now)) ?? currentBudget
                    return Self.result(
                        state: .budgetDeferred,
                        budget: pendingBudget,
                        checkedEventIDs: sharedCheckedIDs,
                        pendingEventIDs: remainingDue.map(\.id).sorted(),
                        message: "同一 RSS 源已有检查等待证据/cursor 落盘；本轮不重复请求。"
                    )
                }
                let retryAt = rssSources.compactMap { cursors[$0.id]?.retryAfter }.filter { $0 > now }.min()
                let message = retryAt.map {
                    "所有已启用 RSS 来源均处于失败退避期；事件 due 保留，最早重试时间为 \($0.formatted(date: .abbreviated, time: .shortened))。"
                } ?? "暂时没有可执行的 RSS 来源检查；事件 due 保留。"
                let failureBudget = Self.paused(currentBudget, reason: "RSS 来源失败退避中。")
                return Self.result(
                    state: .failed,
                    budget: failureBudget,
                    checkedEventIDs: sharedCheckedIDs,
                    pendingEventIDs: remainingDue.map(\.id).sorted(),
                    message: message
                )
            }

            let acquired: Bool
            do {
                acquired = try await budget.acquire(now: now)
            } catch {
                let failureBudget = Self.paused(currentBudget, reason: "追踪预算账本读取/写入失败：\(error.localizedDescription)")
                return Self.result(
                    state: .failed,
                    budget: failureBudget,
                    checkedEventIDs: sharedCheckedIDs,
                    pendingEventIDs: remainingDue.map(\.id).sorted(),
                    message: "追踪预算账本不可用；未发起 RSS 请求：\(error.localizedDescription)"
                )
            }
            guard acquired else {
                let deferredBudget = (try? await budget.snapshot(now: now))
                    ?? Self.paused(currentBudget, reason: "追踪预算暂不可用。")
                return Self.result(
                    state: .budgetDeferred,
                    budget: deferredBudget,
                    checkedEventIDs: sharedCheckedIDs,
                    pendingEventIDs: remainingDue.map(\.id).sorted(),
                    message: deferredBudget.reason ?? "事件 RSS 条件检查预算暂不可用；due 已保留。"
                )
            }

            let oldCursor = cursors[source.id] ?? NewsEventFeedCursor(sourceID: source.id)
            do {
                let refresh = try await fetcher.refresh(source, cursor: oldCursor, now: now)
                if Task.isCancelled {
                    await budget.release()
                    return Self.result(
                        state: .tracking,
                        budget: currentBudget,
                        checkedEventIDs: sharedCheckedIDs,
                        pendingEventIDs: remainingDue.map(\.id).sorted()
                    )
                }

                let evidence: [NewsEventEvidence]
                let cursor: NewsEventFeedCursor
                let cursorAfterIngest: NewsEventFeedCursor?
                switch refresh {
                case let .modified(incoming, newCursor):
                    evidence = incoming
                    if incoming.isEmpty {
                        // A 200 with no archivable evidence may advance check time,
                        // but must not publish its new validators to other readers.
                        cursor = NewsEventFeedCursor(
                            sourceID: newCursor.sourceID,
                            eTag: oldCursor.eTag,
                            lastModified: oldCursor.lastModified,
                            checkedAt: newCursor.checkedAt,
                            attemptedAt: newCursor.attemptedAt,
                            failureCount: 0
                        )
                    } else {
                        cursor = newCursor
                    }
                    cursorAfterIngest = cursor
                case let .notModified(newCursor):
                    evidence = []
                    cursor = newCursor
                    // The controller commits this immediately on the serialized
                    // mutation channel; no evidence is required for a 304.
                    cursorAfterIngest = cursor
                }

                pendingFeedChecks[source.id] = PendingFeedCheck(
                    sourceID: source.id,
                    evidence: evidence,
                    cursor: cursorAfterIngest ?? cursor,
                    createdAt: now
                )
                let snapshot = try await budget.snapshot(now: now)
                let message: String
                if case .notModified = refresh {
                    message = "RSS 条件检查返回 304；将在串行确认后更新检查时间/cursor，没有新增 evidence。"
                } else {
                    message = "RSS 条件检查完成；收到 \(evidence.count) 条候选 evidence，已交由 Core matcher 去重分发。"
                }
                return Self.result(
                    state: .tracking,
                    evidence: evidence,
                    budget: snapshot,
                    checkedEventIDs: (sharedCheckedIDs + remainingDue.map(\.id)).sorted(),
                    message: message,
                    cursorToCommitAfterIngest: cursorAfterIngest
                )
            } catch {
                await budget.release()
                if error is CancellationError || Task.isCancelled {
                    return Self.result(
                        state: .tracking,
                        budget: (try? await budget.snapshot(now: now)) ?? currentBudget,
                        checkedEventIDs: sharedCheckedIDs,
                        pendingEventIDs: remainingDue.map(\.id).sorted()
                    )
                }

                let failureCount = oldCursor.failureCount + 1
                let exponent = min(max(0, failureCount - 1), 4)
                let delay = min(300 * Double(1 << exponent), 3_600)
                let retryAfter = now.addingTimeInterval(delay)
                let errorType = String(describing: type(of: error))
                let failedCursor = NewsEventFeedCursor(
                    sourceID: source.id,
                    eTag: oldCursor.eTag,
                    lastModified: oldCursor.lastModified,
                    checkedAt: oldCursor.checkedAt,
                    attemptedAt: now,
                    retryAfter: retryAfter,
                    failureCount: failureCount,
                    lastError: String(errorType.prefix(80))
                )
                do {
                    try await store.saveFeedCursor(failedCursor)
                } catch {
                    let snapshot = (try? await budget.snapshot(now: now)) ?? currentBudget
                    return Self.result(
                        state: .failed,
                        budget: Self.paused(snapshot, reason: "RSS 失败状态无法持久化：\(error.localizedDescription)"),
                        checkedEventIDs: sharedCheckedIDs,
                        pendingEventIDs: remainingDue.map(\.id).sorted(),
                        message: "RSS 检查失败，且退避状态无法写盘：\(error.localizedDescription)"
                    )
                }
                let snapshot = (try? await budget.snapshot(now: now)) ?? currentBudget
                let minutes = Int(delay / 60)
                return Self.result(
                    state: .failed,
                    budget: Self.paused(snapshot, reason: "RSS 源检查失败，已退避。"),
                    checkedEventIDs: sharedCheckedIDs,
                    pendingEventIDs: remainingDue.map(\.id).sorted(),
                    message: "\(source.displayName) RSS 检查失败（\(errorType)）；\(minutes) 分钟后重试，事件 due 保留。"
                )
            }
        } catch {
            let fallback = NewsEventBudgetSnapshot(
                availability: .unknown,
                reason: "事件追踪状态读取失败：\(error.localizedDescription)",
                checksUsed: nil,
                checksLimit: NewsEventScheduler.defaults.maxRSSChecksPerRollingHour,
                resetsAt: nil
            )
            return Self.result(
                state: .failed,
                budget: fallback,
                pendingEventIDs: [],
                message: "无法读取事件或追踪 cursor：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Workspace shared feed checks

    /// Conditional check for one feed. The workspace calls this through
    /// `NewsEventController`; it shares this tracker's budget actor, so a
    /// manual check and an automatic tick cannot both pass the single-flight
    /// slot even though they share the same store.
    func checkFeed(_ source: NewsSource, now: Date) async -> NewsEventSharedFeedCheck {
        guard case .rss = source else {
            let snapshot = (try? await budget.snapshot(now: now)) ?? Self.paused(
                NewsEventBudgetSnapshot(),
                reason: "仅支持 RSS 来源。"
            )
            return .failed(message: "仅支持 RSS 来源。", retryAt: nil, budget: snapshot)
        }

        await purgeStalePending(now: now)
        if pendingFeedChecks[source.id] != nil {
            let snapshot = (try? await budget.snapshot(now: now))
                ?? Self.paused(NewsEventBudgetSnapshot(), reason: "同一 RSS 源正在落盘。")
            return .pending(
                budget: snapshot,
                reason: "同一 RSS 源的检查已完成，正在等待证据/cursor 落盘；不重复请求。"
            )
        }

        do {
            let oldCursor = try await store.feedCursor(for: source.id)
            let currentBudget = try await budget.snapshot(now: now)

            if let retryAfter = oldCursor?.retryAfter, retryAfter > now {
                return .throttled(
                    until: retryAfter,
                    budget: Self.paused(currentBudget, reason: "该 RSS 来源仍在失败退避期。"),
                    reason: "该 RSS 来源仍在失败退避期；不会绕过退避重试。"
                )
            }

            // A check completed moments ago is a valid shared check. Reusing it
            // avoids spending another rolling-hour slot for the same feed.
            if let cursor = oldCursor,
               let checkedAt = cursor.checkedAt,
               checkedAt <= now,
               now.timeIntervalSince(checkedAt) < 90 {
                return .reused(cursor: cursor, budget: currentBudget)
            }

            let acquired: Bool
            do {
                acquired = try await budget.acquire(now: now)
            } catch {
                return .failed(
                    message: "追踪预算账本不可用；未发起 RSS 请求：\(error.localizedDescription)",
                    retryAt: nil,
                    budget: Self.paused(currentBudget, reason: "追踪预算账本不可用。")
                )
            }
            guard acquired else {
                let deferred = (try? await budget.snapshot(now: now))
                    ?? Self.paused(currentBudget, reason: "已有 RSS 检查在进行或预算已用完。")
                let reason = deferred.reason ?? "RSS 预算暂不可用。"
                return .throttled(
                    until: deferred.resetsAt,
                    budget: deferred,
                    reason: reason
                )
            }

            let refresh: NewsEventFeedRefresh
            do {
                refresh = try await fetcher.refresh(source, cursor: oldCursor, now: now)
            } catch {
                await budget.release()
                if error is CancellationError || Task.isCancelled {
                    let snapshot = (try? await budget.snapshot(now: now)) ?? currentBudget
                    return .failed(message: "检查已取消。", retryAt: nil, budget: snapshot)
                }
                let retryAt = await recordFeedFailure(
                    source: source,
                    oldCursor: oldCursor,
                    now: now,
                    error: error
                )
                let snapshot = (try? await budget.snapshot(now: now)) ?? currentBudget
                let minutes = retryAt.map { max(1, Int($0.timeIntervalSince(now) / 60)) } ?? 5
                return .failed(
                    message: "\(source.displayName) RSS 检查失败；\(minutes) 分钟后重试。",
                    retryAt: retryAt,
                    budget: Self.paused(snapshot, reason: "RSS 源检查失败，已退避。")
                )
            }

            let snapshot = (try? await budget.snapshot(now: now)) ?? currentBudget
            switch refresh {
            case let .notModified(cursor):
                pendingFeedChecks[source.id] = PendingFeedCheck(
                    sourceID: source.id,
                    evidence: [],
                    cursor: cursor,
                    createdAt: now
                )
                return .notModified(cursor: cursor, budget: snapshot)
            case let .modified(evidence, newCursor):
                let finalCursor: NewsEventFeedCursor
                if evidence.isEmpty {
                    // A 200 with no archivable evidence may advance the check
                    // time but must not publish new validators.
                    finalCursor = NewsEventFeedCursor(
                        sourceID: newCursor.sourceID,
                        eTag: oldCursor?.eTag,
                        lastModified: oldCursor?.lastModified,
                        checkedAt: newCursor.checkedAt,
                        attemptedAt: newCursor.attemptedAt,
                        failureCount: 0
                    )
                } else {
                    finalCursor = newCursor
                }
                pendingFeedChecks[source.id] = PendingFeedCheck(
                    sourceID: source.id,
                    evidence: evidence,
                    cursor: finalCursor,
                    createdAt: now
                )
                return .modified(evidence: evidence, cursor: finalCursor, budget: snapshot)
            }
        } catch {
            let snapshot = (try? await budget.snapshot(now: now)) ?? NewsEventBudgetSnapshot()
            return .failed(
                message: "无法读取 RSS cursor：\(error.localizedDescription)",
                retryAt: nil,
                budget: Self.paused(snapshot, reason: "RSS cursor 不可用。")
            )
        }
    }

    func acknowledgeFeedCheck(sourceID: String, outcome: NewsEventFeedAck) async {
        guard pendingFeedChecks.removeValue(forKey: sourceID) != nil else { return }
        await budget.release()
    }

    private func purgeStalePending(now: Date) async {
        let stale = pendingFeedChecks.values
            .filter { now.timeIntervalSince($0.createdAt) > pendingLifetime }
            .map(\.sourceID)
        guard !stale.isEmpty else { return }
        for sourceID in stale {
            pendingFeedChecks.removeValue(forKey: sourceID)
        }
        // The single-flight slot belongs to the expired pending check.
        await budget.release()
    }

    private func recordFeedFailure(
        source: NewsSource,
        oldCursor: NewsEventFeedCursor?,
        now: Date,
        error: Error
    ) async -> Date? {
        let failureCount = (oldCursor?.failureCount ?? 0) + 1
        let exponent = min(max(0, failureCount - 1), 4)
        let delay = min(300 * Double(1 << exponent), 3_600)
        let retryAfter = now.addingTimeInterval(delay)
        let failedCursor = NewsEventFeedCursor(
            sourceID: source.id,
            eTag: oldCursor?.eTag,
            lastModified: oldCursor?.lastModified,
            checkedAt: oldCursor?.checkedAt,
            attemptedAt: now,
            retryAfter: retryAfter,
            failureCount: failureCount,
            lastError: String(String(describing: type(of: error)).prefix(80))
        )
        do {
            try await store.saveFeedCursor(failedCursor)
            return retryAfter
        } catch {
            NSLog(
                "[NewsEventTracker] could not persist feed backoff for %@: %@",
                source.id,
                error.localizedDescription
            )
            return nil
        }
    }

    private static func uniqueRSSSources(in sources: [NewsSource]) -> [NewsSource] {
        var seen = Set<String>()
        return sources.compactMap { source in
            guard case .rss = source, seen.insert(source.id).inserted else { return nil }
            return source
        }
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private static func paused(
        _ snapshot: NewsEventBudgetSnapshot,
        reason: String
    ) -> NewsEventBudgetSnapshot {
        NewsEventBudgetSnapshot(
            availability: .paused,
            reason: reason,
            checksUsed: snapshot.checksUsed,
            checksLimit: snapshot.checksLimit ?? NewsEventScheduler.defaults.maxRSSChecksPerRollingHour,
            resetsAt: snapshot.resetsAt
        )
    }

    private static func result(
        state: NewsEventTrackingState,
        evidence: [NewsEventEvidence] = [],
        budget: NewsEventBudgetSnapshot,
        checkedEventIDs: [String] = [],
        pendingEventIDs: [String] = [],
        message: String? = nil,
        cursorToCommitAfterIngest: NewsEventFeedCursor? = nil
    ) -> NewsEventTrackingResult {
        NewsEventTrackingResult(
            state: state,
            evidence: evidence,
            budgetSnapshot: budget,
            checkedEventIDs: checkedEventIDs,
            pendingEventIDs: pendingEventIDs,
            message: message,
            cursorToCommitAfterIngest: cursorToCommitAfterIngest
        )
    }
}

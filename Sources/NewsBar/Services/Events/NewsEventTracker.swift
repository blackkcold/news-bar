import Foundation

protocol NewsEventTracking: Sendable {
    func tick(now: Date, sources: [NewsSource]) async -> NewsEventTrackingResult
    func recover(now: Date, sources: [NewsSource]) async -> NewsEventTrackingResult
    func budgetSnapshot(now: Date) async throws -> NewsEventBudgetSnapshot
}

actor NewsEventTracker: NewsEventTracking {
    private let store: any NewsEventPersisting
    private let fetcher: any NewsEventRSSFetching
    private let budget: NewsEventTrackingBudget

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
            let candidates = rssSources
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

                await budget.release()
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

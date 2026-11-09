import Foundation
import Observation
import XCTest
@testable import NewsBar

final class RefreshPolicyTests: XCTestCase {
    func testHotIntervalsMatchVisibilityPolicy() {
        XCTAssertEqual(RefreshPolicy.hotInterval(for: .visible), 5 * 60)
        XCTAssertEqual(RefreshPolicy.hotInterval(for: .background), 30 * 60)
        XCTAssertEqual(RefreshPolicy.hotInterval(for: .lowPower), 60 * 60)
    }

    func testRSSIntervalBecomesQuietAfterSixUnchangedRefreshes() {
        XCTAssertEqual(
            RefreshPolicy.rssInterval(
                unchangedRefreshCount: 6,
                changedRecently: false,
                visibility: .background
            ),
            3 * 60 * 60
        )
    }

    func testRSSIntervalAcceleratesAfterRecentChange() {
        XCTAssertEqual(
            RefreshPolicy.rssInterval(
                unchangedRefreshCount: 0,
                changedRecently: true,
                visibility: .visible
            ),
            30 * 60
        )
    }

    func testJitterStaysWithinTenPercentAndIsDeterministic() {
        let base: TimeInterval = 1_000
        let first = RefreshPolicy.jittered(base, key: "source-A")
        let second = RefreshPolicy.jittered(base, key: "source-A")
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first, 900)
        XCTAssertLessThanOrEqual(first, 1_100)
    }

    func testRSSFailureRetryUsesBoundedExponentialBackoff() {
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 1), 15 * 60)
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 2), 30 * 60)
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 3), 60 * 60)
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 9), 3 * 60 * 60)
    }

    func testRSSRefreshBatchesBoundObservableCommits() {
        XCTAssertTrue(RSSRefreshPlanner.batches(count: 0).isEmpty)
        XCTAssertEqual(RSSRefreshPlanner.batches(count: 4), [0..<4])
        XCTAssertEqual(RSSRefreshPlanner.batches(count: 10), [0..<6, 6..<10])
        XCTAssertEqual(RSSRefreshPlanner.batches(count: 36).count, 6)

        for sourceCount in [1, 4, 6, 7, 10, 36] {
            let commits = RSSRefreshPlanner.batches(count: sourceCount).count
            XCTAssertLessThanOrEqual(
                commits,
                Int(ceil(Double(sourceCount) / Double(RSSRefreshPlanner.batchSize)))
            )
        }
    }
}

final class CacheFreshnessCompatibilityTests: XCTestCase {
    private struct LegacyCacheEntry: Codable {
        let items: [NewsItem]
        let timestamp: Date
        let contentHash: String
        let aiSummary: String?
        let aiSummaryHash: String?
    }

    func testOldCacheWithoutValidationFieldsStillDecodes() throws {
        let item = NewsItem(title: "旧缓存", url: "https://example.com/legacy", source: .weibo)
        let legacy = LegacyCacheEntry(
            items: [item],
            timestamp: Date(),
            contentHash: CacheEntry.contentIdentifier(for: [item]),
            aiSummary: nil,
            aiSummaryHash: nil
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(CacheEntry.self, from: data)

        XCTAssertEqual(decoded.items, [item])
        XCTAssertNil(decoded.lastValidatedAt)
        XCTAssertNil(decoded.eTag)
        XCTAssertNil(decoded.lastModified)
    }

    func testRecentValidationKeepsOldContentFresh() {
        let entry = CacheEntry(
            items: [],
            timestamp: Date().addingTimeInterval(-24 * 60 * 60),
            contentHash: "hash",
            lastValidatedAt: Date()
        )
        XCTAssertFalse(entry.isStale)
    }

    func testNewsItemIdentityIsStableForSameSourceAndURL() {
        let first = NewsItem(title: "标题一", url: "https://example.com/article", source: .weibo)
        let second = NewsItem(title: "标题二", url: "https://example.com/article", source: .weibo)
        XCTAssertEqual(first.id, second.id)
    }
}

final class RSSConditionalRequestTests: XCTestCase {
    func testConditionalHeadersIncludeAvailableValidators() {
        let headers = RSSService.conditionalHeaders(
            eTag: "\"feed-v2\"",
            lastModified: "Wed, 29 Jul 2026 08:00:00 GMT"
        )
        XCTAssertEqual(headers["If-None-Match"], "\"feed-v2\"")
        XCTAssertEqual(headers["If-Modified-Since"], "Wed, 29 Jul 2026 08:00:00 GMT")
    }

    func testConditionalHeadersIgnoreEmptyValues() {
        XCTAssertTrue(RSSService.conditionalHeaders(eTag: "", lastModified: nil).isEmpty)
    }
}

final class TrendHistoryStoreTests: XCTestCase {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    func testSameSnapshotUsesThirtyMinuteHeartbeat() async {
        let fileURL = temporaryURL("history.json")
        let store = TrendHistoryStore(fileURL: fileURL)
        let now = Date()
        let weibo = [NewsItem(title: "稳定热点", url: "https://example.com/w", source: .weibo, rank: 1)]
        let bilibili = [NewsItem(title: "视频热点", url: "https://example.com/b", source: .bilibili, rank: 1)]

        let first = await store.record(weibo: weibo, bilibili: bilibili, now: now)
        _ = await store.record(weibo: weibo, bilibili: bilibili, now: now.addingTimeInterval(60))
        let beforeHeartbeat = await store.recentSnapshots(hours: 24, now: now.addingTimeInterval(60))
        _ = await store.record(weibo: weibo, bilibili: bilibili, now: now.addingTimeInterval(31 * 60))
        let afterHeartbeat = await store.recentSnapshots(hours: 24, now: now.addingTimeInterval(31 * 60))

        XCTAssertTrue(first.isSignificant)
        XCTAssertEqual(beforeHeartbeat.count, 1)
        XCTAssertEqual(afterHeartbeat.count, 2)
        await store.clear()
    }

    func testNewTopTopicProducesSignificantChange() async {
        let fileURL = temporaryURL("history.json")
        let store = TrendHistoryStore(fileURL: fileURL)
        let now = Date()
        let old = [NewsItem(title: "旧热点", url: "https://example.com/old", source: .weibo, rank: 1)]
        let new = [NewsItem(title: "新热点", url: "https://example.com/new", source: .weibo, rank: 1)]

        _ = await store.record(weibo: old, bilibili: [], now: now)
        let change = await store.record(weibo: new, bilibili: [], now: now.addingTimeInterval(5 * 60))

        XCTAssertTrue(change.isSignificant)
        XCTAssertTrue(change.context.contains("新热点"))
        XCTAssertFalse(change.historyHash.isEmpty)
        await store.clear()
    }
}

private actor SummaryCacheReadGate {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

final class AISummaryPersistenceAndTriggerTests: XCTestCase {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    func testDisabledBriefingDoesNotScheduleAutomaticGenerationOrAllowRetry() {
        XCTAssertFalse(AISummaryPresentationPolicy.needsAutomaticGeneration(state: .idle, enabled: false))
        XCTAssertFalse(AISummaryPresentationPolicy.needsAutomaticGeneration(state: .error("fictional"), enabled: false))
        XCTAssertFalse(AISummaryPresentationPolicy.canRegenerate(enabled: false, isRefreshing: false, isCoolingDown: false))
    }

    func testReenabledBriefingSchedulesRecoveryButDoesNotAutomaticallyRepeatTruncation() {
        XCTAssertTrue(AISummaryPresentationPolicy.needsAutomaticGeneration(state: .idle, enabled: true))
        XCTAssertTrue(AISummaryPresentationPolicy.needsAutomaticGeneration(state: .error("fictional"), enabled: true))
        XCTAssertFalse(AISummaryPresentationPolicy.needsAutomaticGeneration(state: .truncated("fictional"), enabled: true))
    }

    func testBriefingRetryRespectsActiveGenerationAndCooldown() {
        XCTAssertTrue(AISummaryPresentationPolicy.canRegenerate(enabled: true, isRefreshing: false, isCoolingDown: false))
        XCTAssertFalse(AISummaryPresentationPolicy.canRegenerate(enabled: true, isRefreshing: true, isCoolingDown: false))
        XCTAssertFalse(AISummaryPresentationPolicy.canRegenerate(enabled: true, isRefreshing: false, isCoolingDown: true))
    }

    @MainActor
    func testLateCooldownRecordNotifiesBothBriefingViews() async {
        let cooldown = AISummaryRegenerationCooldown()
        let now = Date(timeIntervalSince1970: 1_000)
        let menuUpdated = expectation(description: "Menu bar observes the recorded cooldown")
        let dashboardUpdated = expectation(description: "Dashboard observes the recorded cooldown")

        withObservationTracking {
            _ = cooldown.lastRegeneration
        } onChange: {
            menuUpdated.fulfill()
        }
        withObservationTracking {
            _ = cooldown.lastRegeneration
        } onChange: {
            dashboardUpdated.fulfill()
        }
        XCTAssertEqual(cooldown.remaining(at: now), 0)

        // A result can be visible before its cache write and cooldown record finish.
        cooldown.record(at: now)
        await fulfillment(of: [menuUpdated, dashboardUpdated], timeout: 1)
        XCTAssertEqual(cooldown.remaining(at: now), 60)
        XCTAssertEqual(cooldown.remaining(at: now.addingTimeInterval(30)), 30)
        XCTAssertEqual(cooldown.remaining(at: now.addingTimeInterval(60)), 0)
    }

    @MainActor
    func testCancelledCooldownTickerStopsWithoutResettingTheDisplay() async {
        var reads = 0
        var displayed: [TimeInterval] = []
        let ticker = Task { @MainActor in
            await AISummaryCooldownTicker.run(
                remaining: {
                    reads += 1
                    return reads < 4 ? 60 : 0
                },
                update: { displayed.append($0) },
                sleep: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                }
            )
        }
        await ticker.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(displayed, [60])
    }

    @MainActor
    func testCooldownTickerPublishesExpiry() async {
        var readings: [TimeInterval] = [10, 1, 0]
        var displayed: [TimeInterval] = []
        var sleeps = 0
        await AISummaryCooldownTicker.run(
            remaining: { readings.removeFirst() },
            update: { displayed.append($0) },
            sleep: { sleeps += 1 }
        )
        XCTAssertEqual(displayed, [10, 1, 0])
        XCTAssertEqual(sleeps, 2)
    }

    func testDisablingAndReenablingInvalidatesAnEarlierSummaryRun() {
        var revision = AISummaryEnablementRevision()
        let started = revision.value
        XCTAssertTrue(revision.isCurrent(started, enabled: true))
        revision.noteChange(from: true, to: false)
        XCTAssertFalse(revision.isCurrent(started, enabled: false))
        revision.noteChange(from: false, to: true)
        XCTAssertFalse(revision.isCurrent(started, enabled: true))
        XCTAssertTrue(revision.isCurrent(revision.value, enabled: true))
    }

    func testAssigningTheSameSummarySwitchValueDoesNotInvalidateTheRun() {
        var revision = AISummaryEnablementRevision()
        let started = revision.value
        revision.noteChange(from: true, to: true)
        XCTAssertTrue(revision.isCurrent(started, enabled: true))
    }

    @MainActor
    func testCacheReadDoesNotRestoreAfterNewSummaryStarts() async {
        let gate = SummaryCacheReadGate()
        let entry = AISummaryCacheEntry(
            summary: "fictional old summary", items: [], contentHash: "old",
            trendHistoryHash: "history", generatedAt: Date(timeIntervalSince1970: 0), trendItemCount: 0
        )
        var state: AISummaryState = .idle
        let loading = Task { @MainActor in
            await AISummaryCacheRestore.loadIfEligible(
                isEligible: { state == .idle },
                load: {
                    await gate.pause()
                    return entry
                }
            )
        }
        await gate.waitUntilEntered()
        state = .summarizing
        await gate.release()
        let restored = await loading.value
        XCTAssertNil(restored)
    }

    @MainActor
    func testCacheReadDoesNotRestoreAfterBriefingIsDisabled() async {
        let gate = SummaryCacheReadGate()
        let entry = AISummaryCacheEntry(
            summary: "fictional old summary", items: [], contentHash: "old",
            trendHistoryHash: "history", generatedAt: Date(timeIntervalSince1970: 0), trendItemCount: 0
        )
        var enabled = true
        let loading = Task { @MainActor in
            await AISummaryCacheRestore.loadIfEligible(
                isEligible: { enabled },
                load: {
                    await gate.pause()
                    return entry
                }
            )
        }
        await gate.waitUntilEntered()
        enabled = false
        await gate.release()
        let restored = await loading.value
        XCTAssertNil(restored)
    }

    @MainActor
    func testCacheReadReturnsEntryWhenEligibilityDoesNotChange() async {
        let entry = AISummaryCacheEntry(
            summary: "fictional summary", items: [], contentHash: "current",
            trendHistoryHash: "history", generatedAt: Date(timeIntervalSince1970: 0), trendItemCount: 0
        )
        let restored = await AISummaryCacheRestore.loadIfEligible(isEligible: { true }, load: { entry })
        XCTAssertEqual(restored?.contentHash, "current")
    }

    func testSummaryCacheRoundTripPreservesCitationSnapshot() async {
        let fileURL = temporaryURL("summary.json")
        let store = AISummaryCacheStore(fileURL: fileURL)
        let items = [NewsItem(title: "热点", url: "https://example.com/hot", source: .weibo, rank: 1)]
        let entry = AISummaryCacheEntry(
            summary: "【趋势概览】\n【热点】内容。\n引用：[#0]",
            items: items,
            contentHash: CacheEntry.contentIdentifier(for: items),
            trendHistoryHash: "history",
            generatedAt: Date(),
            trendItemCount: 1
        )

        await store.save(entry)
        let loaded = await store.load()

        XCTAssertEqual(loaded?.summary, entry.summary)
        XCTAssertEqual(loaded?.items, items)
        XCTAssertEqual(loaded?.trendItemCount, 1)
        await store.clear()
    }

    @MainActor
    func testAutomaticSummaryRespectsTrendAndRSSMinimumIntervals() {
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 10 * 60,
            shouldRecover: false
        ))
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 30 * 60,
            shouldRecover: false
        ))
        XCTAssertTrue(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 60 * 60,
            shouldRecover: false
        ))
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: false,
            rssChanged: true,
            trendIsSignificant: false,
            elapsedSinceSummary: 30 * 60,
            shouldRecover: false
        ))
        XCTAssertTrue(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: false,
            rssChanged: true,
            trendIsSignificant: false,
            elapsedSinceSummary: 60 * 60,
            shouldRecover: false
        ))
    }

    @MainActor
    func testBurstWeiboTriggersImmediatelyButThrottled() {
        // A burst Weibo topic bypasses the 1h baseline even when it just changed.
        XCTAssertTrue(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 10 * 60,
            shouldRecover: false,
            hasBurstWeibo: true,
            elapsedSinceBurstSummary: .infinity
        ))
        // Repeated burst trigger is suppressed within the 15-minute cooldown.
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 30 * 60,
            shouldRecover: false,
            hasBurstWeibo: true,
            elapsedSinceBurstSummary: 5 * 60
        ))
        // After the burst cooldown elapses, the burst trigger fires again.
        XCTAssertTrue(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 30 * 60,
            shouldRecover: false,
            hasBurstWeibo: true,
            elapsedSinceBurstSummary: 15 * 60
        ))
    }

    @MainActor
    func testGlobalManualRefreshDoesNotRepeatIdenticalSummary() {
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: false,
            isManualRefresh: true,
            hotChanged: false,
            rssChanged: false,
            trendIsSignificant: false,
            elapsedSinceSummary: 24 * 60 * 60,
            shouldRecover: false
        ))
    }

    @MainActor
    func testAutomaticRefreshDoesNotRepeatTheSameTruncatedContent() {
        for isBurst in [false, true] {
            XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
                hasCachedSummary: false,
                hasNewContent: false,
                isManualRefresh: false,
                hotChanged: true,
                rssChanged: false,
                trendIsSignificant: true,
                elapsedSinceSummary: .infinity,
                shouldRecover: false,
                hasBurstWeibo: isBurst,
                elapsedSinceBurstSummary: .infinity,
                isRepeatedTruncation: true
            ))
        }
    }

    @MainActor
    func testSummaryRecoveryDoesNotRepeatTheSameTruncatedContent() {
        for state: AISummaryState in [.idle, .error("fictional"), .truncated("fictional")] {
            XCTAssertFalse(NewsOrchestrator.shouldRecoverSharedSummary(
                hasNewContent: false, isRepeatedTruncation: true, state: state
            ))
        }
        XCTAssertTrue(NewsOrchestrator.shouldRecoverSharedSummary(
            hasNewContent: true, isRepeatedTruncation: false, state: .idle
        ))
        XCTAssertTrue(NewsOrchestrator.shouldRecoverSharedSummary(
            hasNewContent: false, isRepeatedTruncation: false, state: .error("fictional")
        ))
    }

    @MainActor
    func testTruncationLimitAllowsExplicitManualRecoveryOnly() {
        XCTAssertTrue(NewsOrchestrator.canAttemptSummary(
            consecutiveTruncations: 2, limit: 3, isManualRegeneration: false
        ))
        XCTAssertFalse(NewsOrchestrator.canAttemptSummary(
            consecutiveTruncations: 3, limit: 3, isManualRegeneration: false
        ))
        XCTAssertTrue(NewsOrchestrator.canAttemptSummary(
            consecutiveTruncations: 3, limit: 3, isManualRegeneration: true
        ))
    }

    func testTruncationFlagSurvivesCacheRoundTripAndLegacyEntriesRemainComplete() throws {
        let entry = AISummaryCacheEntry(
            summary: "fictional partial summary", items: [], contentHash: "fixture",
            trendHistoryHash: "history", generatedAt: Date(timeIntervalSince1970: 0),
            trendItemCount: 0, wasTruncated: true
        )
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AISummaryCacheEntry.self, from: encoded)
        XCTAssertTrue(decoded.wasTruncated)
        XCTAssertEqual(decoded.presentationState, .truncated("fictional partial summary"))
        XCTAssertNil(decoded.completedContentHash)
        XCTAssertEqual(decoded.truncatedContentHash, "fixture")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "wasTruncated")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let oldEntry = try JSONDecoder().decode(AISummaryCacheEntry.self, from: legacyData)
        XCTAssertFalse(oldEntry.wasTruncated)
        XCTAssertEqual(oldEntry.presentationState, .done("fictional partial summary"))
        XCTAssertEqual(oldEntry.completedContentHash, "fixture")
        XCTAssertNil(oldEntry.truncatedContentHash)
    }
}

final class BurstSummaryIdentityTests: XCTestCase {
    private func item(_ title: String, _ url: String) -> NewsItem {
        NewsItem(
            title: title,
            url: url,
            source: .weibo,
            hotLabel: "爆"
        )
    }

    func testBurstIdentityIsOrderIndependent() {
        let first = [item("A", "https://example.com/a"), item("B", "https://example.com/b")]
        let second = [item("B", "https://example.com/b"), item("A", "https://example.com/a")]
        XCTAssertEqual(
            NewsOrchestrator.burstIdentity(items: first),
            NewsOrchestrator.burstIdentity(items: second)
        )
    }

    func testBurstIdentityChangesWhenTheTopicChanges() {
        let old = [item("A", "https://example.com/a")]
        let new = [item("A", "https://example.com/a"), item("C", "https://example.com/c")]
        XCTAssertNotEqual(
            NewsOrchestrator.burstIdentity(items: old),
            NewsOrchestrator.burstIdentity(items: new)
        )
    }

    func testBurstIdentityIsNilWithoutABurstLabel() {
        let items = [NewsItem(title: "A", url: "https://example.com/a", source: .weibo)]
        XCTAssertNil(NewsOrchestrator.burstIdentity(items: items))
    }
}

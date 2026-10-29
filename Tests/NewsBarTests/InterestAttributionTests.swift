import XCTest
@testable import NewsBar

/// Isolated regression coverage for Task A: exposure gating, event/profile
/// separation, scoped explicit rules, consent-independent rules, and reset
/// recovery. Every test uses a fresh temporary store; none reads the real
/// application database.
final class InterestAttributionTests: XCTestCase {
    private func item(
        _ url: String = "https://example.com/story",
        title: String = "AI 模型发布",
        source: NewsSource = .rss(name: "Example", url: "https://example.com/feed")
    ) -> NewsItem {
        NewsItem(title: title, url: url, source: source)
    }

    private func temporaryStore() -> (LocalInterestStore, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("interest.sqlite")
        return (LocalInterestStore(fileURL: path), path)
    }

    @MainActor
    func testUndoRepeatedFeedbackRestoresThePreviousRule() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()
        let originalID = try XCTUnwrap(controller.feedback(article, kind: .lessLikeSource))
        let replacementID = try XCTUnwrap(controller.feedback(article, kind: .lessLikeSource))

        controller.undo(replacementID)

        XCTAssertEqual(controller.state.feedbacks.filter { $0.kind == .lessLikeSource }.map(\.id), [originalID])
        let flushed = await controller.flush()
        XCTAssertTrue(flushed)
        let persisted = try await store.load()
        XCTAssertEqual(persisted.feedbacks.filter { $0.kind == .lessLikeSource }.map(\.id), [originalID])
    }

    @MainActor
    func testRemovingRepeatedFeedbackDoesNotRestoreThePreviousRule() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()
        _ = try XCTUnwrap(controller.feedback(article, kind: .lessLikeSource))
        let replacementID = try XCTUnwrap(controller.feedback(article, kind: .lessLikeSource))

        controller.undo(replacementID, restorePrevious: false)

        XCTAssertFalse(controller.state.feedbacks.contains { $0.kind == .lessLikeSource })
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    // MARK: - Exposure continuity

    func testInactiveIntervalBreaksContinuousImpressionWindow() {
        var exposure = QualifiedExposure()
        XCTAssertFalse(exposure.update(visibleFraction: 1, active: true, now: 10))
        XCTAssertTrue(exposure.update(visibleFraction: 1, active: true, now: 11.1))

        var interrupted = QualifiedExposure()
        XCTAssertFalse(interrupted.update(visibleFraction: 1, active: true, now: 20))
        // App inactive / list covered: the interval must reset, not merely pause.
        XCTAssertFalse(interrupted.update(visibleFraction: 0, active: false, now: 20.5))
        XCTAssertFalse(interrupted.update(visibleFraction: 1, active: true, now: 20.8))
        XCTAssertTrue(interrupted.update(visibleFraction: 1, active: true, now: 21.9))
    }

    func testFreshExposureLatchIsRequiredAfterConsentEpochChange() {
        // A consent epoch change must recreate the row latch; reusing the old
        // one would keep suppressing impressions for the same list session.
        var oldEpoch = QualifiedExposure()
        XCTAssertFalse(oldEpoch.update(visibleFraction: 1, active: true, now: 10))
        XCTAssertTrue(oldEpoch.update(visibleFraction: 1, active: true, now: 11.1))
        XCTAssertFalse(oldEpoch.update(visibleFraction: 1, active: true, now: 12))

        var newEpoch = QualifiedExposure()
        XCTAssertFalse(newEpoch.update(visibleFraction: 1, active: true, now: 12.1))
        XCTAssertTrue(newEpoch.update(visibleFraction: 1, active: true, now: 13.2))
    }

    // MARK: - Event funnel vs strongest profile signal

    func testRawEventsAreRetainedWhileProfileKeepsStrongestSameDaySignal() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let article = item()
        let epoch = state.consentEpoch
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(state.record(item: article, kind: .opened, epoch: epoch, now: now))
        XCTAssertTrue(state.record(item: article, kind: .qualifiedRead, epoch: epoch, now: now.addingTimeInterval(60)))
        XCTAssertTrue(state.record(item: article, kind: .deepRead, epoch: epoch, now: now.addingTimeInterval(120)))

        XCTAssertEqual(state.events.map(\.kind), [.opened, .qualifiedRead, .deepRead])
        XCTAssertEqual(state.profileSignals.values.first?.strength, 1.5)
        let versionAfterPeak = state.profileVersion

        // A later weaker funnel event stays in the raw stream but cannot weaken
        // or re-version the strongest same-day profile signal.
        XCTAssertTrue(state.record(item: article, kind: .opened, epoch: epoch, now: now.addingTimeInterval(180)))
        XCTAssertEqual(state.events.count, 4)
        XCTAssertEqual(state.profileSignals.values.first?.strength, 1.5)
        XCTAssertEqual(state.profileVersion, versionAfterPeak)
        XCTAssertEqual(state.evidence(for: ContentIdentity.id(for: article.url)), 1.5)
    }

    func testFailedOpenNeverBecomesPositiveProfileEvidence() {
        var state = LocalInterestState()
        state.learningEnabled = true
        XCTAssertTrue(state.record(item: item(), kind: .failed, epoch: state.consentEpoch))
        XCTAssertEqual(state.events.map(\.kind), [.failed])
        XCTAssertTrue(state.profileSignals.isEmpty)
    }

    // MARK: - Scoped explicit rule idempotence

    func testSourceMuteIsIdempotentAcrossDifferentArticles() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let source = NewsSource.rss(name: "Example", url: "https://example.com/feed")
        let first = item("https://example.com/a", source: source)
        let second = item("https://example.com/b", source: source)

        _ = state.feedback(item: first, kind: .muteSource)
        _ = state.feedback(item: second, kind: .muteSource)

        XCTAssertEqual(state.feedbacks.filter { $0.kind == .muteSource }.count, 1)
        XCTAssertTrue(state.isBlocked(first))
        XCTAssertTrue(state.isBlocked(second))
    }

    func testTopicReductionIsIdempotentAndDistinctTopicsStayDistinct() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let article = item()

        _ = state.feedback(item: article, kind: .reduceTopic, topic: "AI")
        _ = state.feedback(item: article, kind: .reduceTopic, topic: "AI")
        _ = state.feedback(item: article, kind: .reduceTopic, topic: "ai")
        _ = state.feedback(item: article, kind: .reduceTopic, topic: "sports")

        XCTAssertEqual(state.feedbacks.filter { $0.kind == .reduceTopic }.count, 2)
    }

    func testLiteralKeywordReductionKeepsCaseWhileScopeDedupesCaseInsensitively() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["PC2545"]
        let article = item(title: "PC2545 新品发布")

        _ = state.feedback(item: article, kind: .reduceTopic, topic: "followed:PC2545")
        _ = state.feedback(item: article, kind: .reduceTopic, topic: "followed:pc2545")

        let rules = state.feedbacks.filter { $0.kind == .reduceTopic }
        XCTAssertEqual(rules.count, 1)
        // Deduplication is case-insensitive, but the persisted label must keep
        // the literal keyword spelling so `followed:PC2545` still matches tags.
        XCTAssertEqual(rules.first?.topic, "followed:PC2545")
        // Follow adds +4 under the same literal key; the reduction is a separate
        // signed term under that same key. A lowercased stored key would create
        // a second, unused "followed:pc2545" penalty.
        let profile = InterestProfile.build(state: state)
        XCTAssertEqual(profile.topics["followed:PC2545"], 4)
        XCTAssertEqual(profile.negativeTopics["followed:PC2545"] ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertNil(profile.negativeTopics["followed:pc2545"])
    }

    // MARK: - Explicit rules without behavioral learning

    func testExplicitBookmarkAndBlockPersistWhileLearningIsOffWithoutBuildingProfile() {
        var state = LocalInterestState()
        let article = item()
        let blocked = item("https://example.com/other", title: "足球新闻")

        _ = state.feedback(item: article, kind: .bookmark)
        _ = state.feedback(item: blocked, kind: .muteSource)

        XCTAssertEqual(state.feedbacks.count, 2)
        XCTAssertFalse(state.feedbacks.first { $0.kind == .bookmark }?.participatesInProfile ?? true)
        XCTAssertTrue(state.isBlocked(blocked))
        XCTAssertTrue(InterestProfile.build(state: state).topics.isEmpty)
        XCTAssertTrue(state.events.isEmpty)
    }

    func testExplicitRulesWhilePausedDoNotBecomeTrainingDataWhenResumed() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.learningPaused = true
        let article = item()

        _ = state.feedback(item: article, kind: .bookmark)
        state.learningPaused = false

        XCTAssertEqual(state.feedbacks.count, 1)
        XCTAssertFalse(state.feedbacks[0].participatesInProfile)
        XCTAssertTrue(InterestProfile.build(state: state).topics.isEmpty)
    }

    // MARK: - Clearing

    func testClearingStopsLearningDropsPublicCacheAndKeepsBookmarksUnconsented() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let article = item()
        state.ingest([article], now: Date(timeIntervalSince1970: 1_800_000_000))
        _ = state.record(item: article, kind: .qualifiedRead, epoch: state.consentEpoch)
        _ = state.feedback(item: article, kind: .bookmark)

        state.clearPersonalData(keepBookmarks: true)

        XCTAssertFalse(state.learningEnabled)
        XCTAssertFalse(state.learningPaused)
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertTrue(state.profileSignals.isEmpty)
        XCTAssertTrue(state.readingSessions.isEmpty)
        XCTAssertTrue(state.contents.isEmpty)
        XCTAssertNil(state.archiveStartedAt)
        XCTAssertNil(state.archiveUpdatedAt)
        XCTAssertEqual(state.feedbacks.filter { $0.kind == .bookmark }.count, 1)
        XCTAssertFalse(state.feedbacks[0].participatesInProfile)
        XCTAssertTrue(InterestProfile.build(state: state).topics.isEmpty)
    }

    // MARK: - Attribution and open gating

    func testAttributionRoundtripAndLegacyEventStillDecodes() throws {
        let event = InterestEvent(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            epoch: UUID(),
            item: item(),
            contentID: ContentIdentity.id(for: item().url),
            kind: .opened,
            sessionID: UUID(),
            surface: "recommendation",
            contextID: "batch-1",
            position: 3,
            readerSessionID: UUID(),
            policyVersion: "ranking-v9",
            profileVersion: 7
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(InterestEvent.self, from: encoded)
        XCTAssertEqual(decoded.surface, "recommendation")
        XCTAssertEqual(decoded.contextID, "batch-1")
        XCTAssertEqual(decoded.position, 3)
        XCTAssertEqual(decoded.readerSessionID, event.readerSessionID)
        XCTAssertEqual(decoded.policyVersion, "ranking-v9")
        XCTAssertEqual(decoded.profileVersion, 7)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["surface", "contextID", "position", "readerSessionID", "policyVersion", "profileVersion"] {
            legacyObject.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(InterestEvent.self, from: legacyData)
        XCTAssertEqual(legacy.kind, .opened)
        XCTAssertNil(legacy.surface)
        XCTAssertNil(legacy.contextID)
        XCTAssertNil(legacy.position)
        XCTAssertNil(legacy.readerSessionID)
        XCTAssertNil(legacy.policyVersion)
        XCTAssertNil(legacy.profileVersion)
    }

    @MainActor
    func testEventCapturesRealRankingPolicyAndFrozenProfileVersion() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()

        controller.record(
            article,
            kind: .impression,
            epoch: controller.state.consentEpoch,
            sessionID: controller.feedSessionID,
            surface: "recommendation",
            contextID: "batch-42",
            position: 7,
            policyVersion: "ranking-v9",
            profileVersion: 11
        )
        await controller.flush()

        let event = try XCTUnwrap(controller.state.events.first { $0.kind == .impression })
        XCTAssertEqual(event.surface, "recommendation")
        XCTAssertEqual(event.contextID, "batch-42")
        XCTAssertEqual(event.position, 7)
        XCTAssertEqual(event.policyVersion, "ranking-v9")
        XCTAssertEqual(event.profileVersion, 11)
        XCTAssertEqual(event.readerSessionID, nil)
    }

    func testReaderRequestCarriesBatchProvenanceWithoutChangingLegacyInit() {
        let epoch = UUID()
        let request = NewsReaderRequest(
            url: "https://example.com/story",
            title: "Story",
            item: item(),
            surface: "recommendation",
            contextID: "batch-7",
            consentEpoch: epoch,
            privateSession: false,
            policyVersion: "ranking-v3",
            profileVersion: 5,
            position: 2
        )
        XCTAssertEqual(request.policyVersion, "ranking-v3")
        XCTAssertEqual(request.profileVersion, 5)
        XCTAssertEqual(request.position, 2)

        let legacy = NewsReaderRequest(
            url: "https://example.com/story",
            title: "Story",
            item: nil,
            surface: "researchSource",
            contextID: nil,
            consentEpoch: epoch,
            privateSession: true
        )
        XCTAssertNil(legacy.policyVersion)
        XCTAssertNil(legacy.profileVersion)
        XCTAssertNil(legacy.position)
    }

    func testOpenAttributionRequiresOneSuccessfulAttributedLoad() {
        var gate = OpenAttribution()
        gate.beginNavigation()
        XCTAssertFalse(gate.shouldRecordLoaded(attributed: false, privateSession: false))
        XCTAssertFalse(gate.shouldRecordLoaded(attributed: true, privateSession: true))
        XCTAssertTrue(gate.shouldRecordLoaded(attributed: true, privateSession: false))
        XCTAssertFalse(gate.shouldRecordLoaded(attributed: true, privateSession: false))

        gate.beginNavigation()
        XCTAssertTrue(gate.shouldRecordLoaded(attributed: true, privateSession: false))
    }

    func testShortLinkServerRedirectStillAttributesTheOpenedItem() {
        var attribution = DocumentAttribution()
        attribution.noteServerRedirect()
        XCTAssertTrue(attribution.evaluate(
            finalURL: "https://www.bilibili.com/video/BV1xx",
            itemURL: "https://b23.tv/BV1xx"
        ))
    }

    func testCrossSiteRedirectDropsAttribution() {
        var attribution = DocumentAttribution()
        attribution.noteServerRedirect()
        XCTAssertFalse(attribution.evaluate(
            finalURL: "https://www.example.com/watch",
            itemURL: "https://b23.tv/BV1xx"
        ))
    }

    func testRedirectAfterTheFirstDocumentDoesNotWidenAttribution() {
        var attribution = DocumentAttribution()
        attribution.noteServerRedirect()
        XCTAssertTrue(attribution.evaluate(
            finalURL: "https://www.bilibili.com/video/BV1xx",
            itemURL: "https://b23.tv/BV1xx"
        ))
        attribution.noteServerRedirect()
        XCTAssertFalse(attribution.evaluate(
            finalURL: "https://www.bilibili.com/video/BV1yy",
            itemURL: "https://b23.tv/BV1xx"
        ))
    }

    func testUserNavigationDropsAttributionEvenOnTheSameSite() {
        var attribution = DocumentAttribution()
        attribution.noteServerRedirect()
        attribution.noteUserNavigation()
        XCTAssertFalse(attribution.evaluate(
            finalURL: "https://www.bilibili.com/video/BV1yy",
            itemURL: "https://b23.tv/BV1xx"
        ))
    }

    func testExactURLAttributesWithoutAnyRedirect() {
        var attribution = DocumentAttribution()
        XCTAssertTrue(attribution.evaluate(
            finalURL: "https://www.example.com/story",
            itemURL: "https://www.example.com/story"
        ))
    }

    // MARK: - Store recovery

    @MainActor
    func testUnknownSchemaRecoversOnlyThroughExplicitClear() async throws {
        let (store, path) = temporaryStore()
        var unknown = try await store.load()
        unknown.schemaVersion = 2
        unknown.revision = 1
        try await store.reset(unknown)

        let failingStore = LocalInterestStore(fileURL: path)
        do {
            _ = try await failingStore.load()
            XCTFail("Unknown schema must not silently load")
        } catch {
            // expected
        }

        let controller = InterestController(store: LocalInterestStore(fileURL: path))
        await controller.prepare()
        XCTAssertFalse(controller.isReady)
        XCTAssertNotNil(controller.storageError)

        // Clear is the explicit recovery path; it must succeed and leave a
        // readable v1 document with learning off.
        await controller.clear(keepBookmarks: false)
        XCTAssertNil(controller.storageError)
        XCTAssertTrue(controller.isReady)
        XCTAssertFalse(controller.state.learningEnabled)

        let recovered = try await LocalInterestStore(fileURL: path).load()
        XCTAssertEqual(recovered.schemaVersion, 1)
        XCTAssertFalse(recovered.learningEnabled)
        XCTAssertTrue(recovered.events.isEmpty)
    }

    @MainActor
    func testControllerClearStopsLearningAndPersistsTheReset() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()
        controller.record(article, kind: .qualifiedRead, epoch: controller.state.consentEpoch, sessionID: UUID())
        _ = controller.feedback(article, kind: .bookmark)
        await controller.flush()

        let cleared = await controller.clear(keepBookmarks: true)
        await controller.flush()

        XCTAssertTrue(cleared)
        XCTAssertFalse(controller.state.learningEnabled)
        XCTAssertTrue(controller.state.events.isEmpty)
        XCTAssertEqual(controller.state.feedbacks.filter { $0.kind == .bookmark }.count, 1)

        let persisted = try await store.load()
        XCTAssertFalse(persisted.learningEnabled)
        XCTAssertTrue(persisted.events.isEmpty)
        XCTAssertEqual(persisted.feedbacks.filter { $0.kind == .bookmark }.count, 1)
    }

    @MainActor
    func testExplicitBookmarkWorksThroughControllerWhileLearningIsOff() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        controller.setLearningEnabled(false)

        let id = controller.feedback(item(), kind: .bookmark)
        XCTAssertNotNil(id)
        await controller.flush()

        let persisted = try await store.load()
        XCTAssertEqual(persisted.feedbacks.filter { $0.kind == .bookmark }.count, 1)
        XCTAssertFalse(persisted.feedbacks[0].participatesInProfile)
        XCTAssertTrue(InterestProfile.build(state: persisted).topics.isEmpty)
        XCTAssertTrue(persisted.events.isEmpty)
    }

    @MainActor
    func testPausedExplicitRulesPersistWithoutRebuildingProfile() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        controller.setPaused(true)

        let article = item()
        XCTAssertNotNil(controller.feedback(article, kind: .bookmark))
        XCTAssertNotNil(controller.feedback(article, kind: .notInterested))
        XCTAssertTrue(controller.state.isBlocked(article))
        await controller.flush()

        let persisted = try await store.load()
        XCTAssertEqual(persisted.feedbacks.count, 2)
        XCTAssertFalse(persisted.feedbacks.contains { $0.participatesInProfile })
        XCTAssertTrue(persisted.events.isEmpty)
        XCTAssertTrue(InterestProfile.build(state: persisted).topics.isEmpty)
    }

    @MainActor
    func testRankCandidatesDuringResetIsIgnored() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        let before = item("https://example.com/before")
        let during = item("https://example.com/during")
        controller.rankCandidates([before])
        let beforeID = ContentIdentity.id(for: before.url)
        let rankedBefore = try await waitUntil { controller.recommendations?.items.map(\.contentID) == [beforeID] }
        XCTAssertTrue(rankedBefore)

        let reset = Task { await controller.clear(keepBookmarks: false) }
        // Queued after the reset task: the reset is suspended on the store
        // actor, so this runs inside the isResetting window.
        let intruder = Task { @MainActor in
            XCTAssertTrue(controller.isResetting)
            controller.rankCandidates([during])
        }
        let cleared = await reset.value
        await intruder.value
        XCTAssertTrue(cleared)

        // The reset's own rebuild ranks the pre-reset candidate set; a call
        // made during the reset must not swap in its candidates.
        let rankedOldSet = try await waitUntil { controller.recommendations?.items.map(\.contentID) == [beforeID] }
        XCTAssertTrue(rankedOldSet)
    }

    @MainActor
    func testFeedSessionIdentityIsStableUntilListSessionEnds() async {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        let first = controller.feedSessionID
        controller.rankCandidates([])
        XCTAssertEqual(controller.feedSessionID, first)
        controller.endListSession()
        XCTAssertNotEqual(controller.feedSessionID, first)
    }

    @MainActor
    func testSoftPreferencesAreRejectedWhileLearningIsOffPausedOrPrivate() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()

        controller.setPaused(true)
        XCTAssertNil(controller.feedback(article, kind: .reduceTopic, topic: "ai"))
        XCTAssertNil(controller.feedback(article, kind: .moreLikeThis))
        controller.setPaused(false)

        controller.privateReading = true
        XCTAssertNil(controller.feedback(article, kind: .reduceTopic, topic: "ai"))
        XCTAssertNil(controller.feedback(article, kind: .moreLikeThis))
        controller.privateReading = false

        controller.setLearningEnabled(false)
        XCTAssertNil(controller.feedback(article, kind: .reduceTopic, topic: "ai"))
        XCTAssertNil(controller.feedback(article, kind: .moreLikeThis))
        await controller.flush()

        let persisted = try await store.load()
        XCTAssertTrue(persisted.feedbacks.isEmpty)
        XCTAssertTrue(controller.sessionFeedback.isEmpty)

        controller.setLearningEnabled(true)
        XCTAssertNotNil(controller.feedback(article, kind: .reduceTopic, topic: "ai"))
        XCTAssertNotNil(controller.feedback(article, kind: .moreLikeThis))
        XCTAssertEqual(controller.sessionFeedback.count, 1)
    }

    @MainActor
    func testImpressionDedupesAcrossFlushWithinTheSameStableSession() async {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()
        let epoch = controller.state.consentEpoch

        controller.record(article, kind: .impression, epoch: epoch, sessionID: controller.feedSessionID, position: 0)
        await controller.flush()
        controller.record(article, kind: .impression, epoch: epoch, sessionID: controller.feedSessionID, position: 0)
        await controller.flush()

        XCTAssertEqual(controller.state.events.filter { $0.kind == .impression }.count, 1)

        // Disabling and re-enabling learning is a new consent epoch; the same
        // list session may legitimately see the article again.
        controller.setLearningEnabled(false)
        controller.setLearningEnabled(true)
        controller.record(article, kind: .impression, epoch: controller.state.consentEpoch, sessionID: controller.feedSessionID, position: 0)
        await controller.flush()
        XCTAssertEqual(controller.state.events.filter { $0.kind == .impression }.count, 2)
    }

    @MainActor
    func testGarbageSQLiteFileIsRecreatedByExplicitRecovery() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("interest.sqlite")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a sqlite database".utf8).write(to: path)

        let controller = InterestController(store: LocalInterestStore(fileURL: path))
        await controller.prepare()
        XCTAssertNotNil(controller.storageError)

        let recovered = await controller.clear(keepBookmarks: false)
        XCTAssertTrue(recovered)
        let restored = try await LocalInterestStore(fileURL: path).load()
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertTrue(restored.events.isEmpty)
    }

    @MainActor
    func testOrdinaryStoreFailureDoesNotDeleteTheExistingPath() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let store = LocalInterestStore(fileURL: path)
        var state = LocalInterestState()
        state.revision = 1

        do {
            try await store.recover(state)
            XCTFail("A non-database, non-writable path must not be silently recreated")
        } catch {
            // expected
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testClearReportsFailureInsteadOfSuccessWhenStoreCannotOpen() async {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? Data("not a directory".utf8).write(to: blocker)
        let controller = InterestController(store: LocalInterestStore(fileURL: blocker.appendingPathComponent("interest.sqlite")))
        await controller.prepare()
        XCTAssertNotNil(controller.storageError)

        let cleared = await controller.clear(keepBookmarks: false)
        XCTAssertFalse(cleared)
        XCTAssertNotNil(controller.storageError)
        XCTAssertTrue(controller.storageError?.contains("本地数据状态未确认") == true)
        XCTAssertTrue(controller.storageError?.contains("state is unconfirmed") == true)
        XCTAssertFalse(controller.isReady)
    }

    @MainActor
    func testPrepareClearsAStaleStorageErrorAfterASuccessfulRetry() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("interest.sqlite")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: path)

        let controller = InterestController(store: LocalInterestStore(fileURL: path))
        await controller.prepare()
        XCTAssertNotNil(controller.storageError)
        XCTAssertFalse(controller.isReady)

        // Remove only the synthetic damaged file, then retry the same load.
        try FileManager.default.removeItem(at: path)
        await controller.prepare()
        XCTAssertNil(controller.storageError, "a successful load must clear the previous error")
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.canManagePreferences)
    }

    @MainActor
    func testConsentTogglesAreRejectedWhileStorageIsUnavailable() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("interest.sqlite")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not sqlite".utf8).write(to: path)
        let controller = InterestController(store: LocalInterestStore(fileURL: path))
        await controller.prepare()
        XCTAssertNotNil(controller.storageError)
        XCTAssertFalse(controller.canManagePreferences)

        controller.setLearningEnabled(true)
        controller.setPaused(true)
        XCTAssertFalse(controller.state.learningEnabled)
        XCTAssertFalse(controller.state.learningPaused)
    }

    @MainActor
    func testSessionMoreLikeThisIsIdempotentPerContentAndUndoRemovesIt() async throws {
        let (store, _) = temporaryStore()
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)

        let article = item()
        let first = controller.feedback(article, kind: .moreLikeThis)
        let second = controller.feedback(article, kind: .moreLikeThis)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(controller.sessionFeedback.filter { $0.kind == .moreLikeThis }.count, 1,
                       "clicking more-like-this twice on one item must not double the session weight")

        let other = item("https://example.com/other", title: "另一篇")
        XCTAssertNotNil(controller.feedback(other, kind: .moreLikeThis))
        XCTAssertEqual(controller.sessionFeedback.count, 2)

        if let second { controller.undo(second) }
        XCTAssertEqual(controller.sessionFeedback.count, 1)
        XCTAssertEqual(controller.sessionFeedback.first?.item.url, other.url)
    }

    func testSoftFeedbackCopyIsAssertableInBothLanguages() {
        let zhSoft = InterestFeedbackCopy.softFeedbackUnavailable(.zh)
        XCTAssertTrue(zhSoft.contains("本地学习"))
        XCTAssertTrue(zhSoft.contains("收藏"))
        XCTAssertTrue(zhSoft.contains("屏蔽"))
        XCTAssertTrue(zhSoft.contains("隐藏"))
        let enSoft = InterestFeedbackCopy.softFeedbackUnavailable(.en)
        XCTAssertTrue(enSoft.lowercased().contains("learning"))
        XCTAssertTrue(enSoft.lowercased().contains("bookmark"))
        XCTAssertTrue(enSoft.lowercased().contains("mute"))
        XCTAssertTrue(enSoft.lowercased().contains("hide"))

        let zhFollow = InterestFeedbackCopy.followRequiresLearning(.zh)
        XCTAssertTrue(zhFollow.contains("关注"))
        XCTAssertTrue(zhFollow.contains("学习"))
        XCTAssertTrue(zhFollow.contains("收藏"))
        let enFollow = InterestFeedbackCopy.followRequiresLearning(.en)
        XCTAssertTrue(enFollow.lowercased().contains("following"))
        XCTAssertTrue(enFollow.lowercased().contains("learning"))
    }
}

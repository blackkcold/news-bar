import XCTest
@testable import NewsBar

final class LocalInterestTests: XCTestCase {
    private func item(_ url: String = "https://example.com/story?id=2", title: String = "AI 模型发布") -> NewsItem {
        NewsItem(title: title, url: url, source: .rss(name: "Example", url: "https://example.com/feed"))
    }

    func testCanonicalAliasesPreserveBusinessQueriesAndSourceIdentity() {
        let a = item("https://example.com/story?id=2&utm_source=x#top")
        let b = item("https://example.com/story?id=2")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(ContentIdentity.id(for: a.url), ContentIdentity.id(for: b.url))
        XCTAssertNotEqual(ContentIdentity.id(for: b.url), ContentIdentity.id(for: "https://example.com/story?id=3"))
        XCTAssertEqual(ContentIdentity.canonicalURL("https://example.com/a?b=2&a=1&utm_medium=r"), "https://example.com/a?b=2&a=1")
    }

    func testArchivePreservesFirstSeenAndUnknownPublicationDate() {
        var state = LocalInterestState()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        state.ingest([item()], now: start)
        state.ingest([item()], now: start.addingTimeInterval(3600))
        let record = state.contents.values.first
        XCTAssertEqual(record?.firstSeen, start)
        XCTAssertEqual(record?.lastSeen, start.addingTimeInterval(3600))
        XCTAssertNil(record?.item.publishedAt)
    }

    func testLoadingCachedMetadataCannotAdvanceLastSeen() {
        var state = LocalInterestState()
        let article = item()
        let future = article.timestamp.addingTimeInterval(86400)
        state.ingest([article], now: future, usingFetchTimestamps: true)
        XCTAssertEqual(state.contents.values.first?.lastSeen, article.timestamp)
        state.ingest([article], now: future.addingTimeInterval(86400), usingFetchTimestamps: true)
        XCTAssertEqual(state.contents.values.first?.lastSeen, article.timestamp)
    }

    func testPublisherDateIsParsedWithoutSubstitutingFetchTime() throws {
        let xml = """
        <rss version="2.0"><channel><item><title>dated</title><link>https://example.com/a</link><pubDate>Wed, 21 Oct 2026 10:00:00 +0000</pubDate></item><item><title>unknown</title><link>https://example.com/b</link></item></channel></rss>
        """
        let items = try RSSService.parseRSSFeed(data: Data(xml.utf8), sourceName: "Test", sourceURL: "https://example.com/feed")
        XCTAssertEqual(items[0].publishedAt?.timeIntervalSince1970, 1_792_576_800)
        XCTAssertNil(items[1].publishedAt)
    }

    func testNoConsentPauseAndOldEpochCannotWriteEvidence() {
        var state = LocalInterestState()
        let article = item()
        let oldEpoch = state.consentEpoch
        XCTAssertFalse(state.record(item: article, kind: .opened, epoch: oldEpoch))
        state.learningEnabled = true
        XCTAssertTrue(state.record(item: article, kind: .opened, epoch: oldEpoch))
        state.learningPaused = true
        XCTAssertFalse(state.record(item: article, kind: .qualifiedRead, epoch: oldEpoch))
        state.clearPersonalData(keepBookmarks: false)
        state.learningPaused = false
        XCTAssertFalse(state.record(item: article, kind: .qualifiedRead, epoch: oldEpoch))
        XCTAssertTrue(state.events.isEmpty)
    }

    func testEvidenceUpgradeReplacesWeakSignalAndUndoRemovesFeedback() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let article = item()
        let epoch = state.consentEpoch
        _ = state.record(item: article, kind: .opened, epoch: epoch)
        _ = state.record(item: article, kind: .qualifiedRead, epoch: epoch)
        _ = state.record(item: article, kind: .opened, epoch: epoch)
        XCTAssertEqual(state.evidence(for: ContentIdentity.id(for: article.url)), 1)
        let feedbackID = state.feedback(item: article, kind: .notInterested)
        XCTAssertTrue(state.isBlocked(article))
        state.undoFeedback(feedbackID)
        XCTAssertFalse(state.isBlocked(article))
    }

    func testExplicitSourceBlockIsIndependentOfLearningToggle() {
        var state = LocalInterestState()
        state.learningEnabled = true
        _ = state.feedback(item: item(), kind: .muteSource)
        state.learningEnabled = false
        XCTAssertTrue(state.isBlocked(item()))
    }

    func testExplicitBookmarkLearnsWithoutRequiringAnEarlierClick() {
        var state = LocalInterestState()
        state.learningEnabled = true
        _ = state.feedback(item: item(), kind: .bookmark)
        XCTAssertGreaterThan(InterestProfile.build(state: state).topics["ai"] ?? 0, 0)
        state.clearPersonalData(keepBookmarks: true)
        XCTAssertTrue(InterestProfile.build(state: state).topics.isEmpty)
    }

    func testReadingSessionsRetainTerminalStateAndRespectConsentEpoch() {
        var state = LocalInterestState()
        let session = ReadingSessionRecord(id: UUID(), epoch: state.consentEpoch, newsItemID: item().id,
                                           contentID: ContentIdentity.id(for: item().url), surface: "dashboardRSS", contextID: nil,
                                           endedAt: Date(), activeSeconds: 17, scrollCoverage: 0.3, articleAdapted: true, terminalState: .engaged)
        XCTAssertFalse(state.recordSession(session))
        state.learningEnabled = true
        XCTAssertTrue(state.recordSession(session))
        XCTAssertEqual(state.readingSessions.first?.activeSeconds, 17)
        XCTAssertEqual(state.readingSessions.first?.terminalState, .engaged)
        state.clearPersonalData(keepBookmarks: false)
        XCTAssertFalse(state.recordSession(session))
        XCTAssertTrue(state.readingSessions.isEmpty)
    }

    func testExplicitTopicReductionAffectsRankingBeforeAnyQualifiedRead() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let ai = item(title: "人工智能新模型")
        let sports = item("https://example.com/sports", title: "足球新闻")
        _ = state.feedback(item: ai, kind: .reduceTopic, topic: "ai")
        let ranked = RecommendationEngine.rank(items: [ai, sports], state: state)
        XCTAssertEqual(ranked.items.first?.item.id, sports.id)
    }

    func testSQLiteRestartAndEpochTombstoneRejectStaleSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("interest.sqlite")
        let store = LocalInterestStore(fileURL: path)
        var state = try await store.load()
        state.learningEnabled = true
        state.revision = 1
        _ = state.record(item: item(), kind: .opened, epoch: state.consentEpoch)
        try await store.save(state)
        let restored = try await LocalInterestStore(fileURL: path).load()
        XCTAssertEqual(restored.events.count, 1)
        let stale = state
        state.clearPersonalData(keepBookmarks: false)
        state.revision = 2
        try await store.reset(state)
        try await store.save(stale)
        let cleared = try await store.load()
        XCTAssertTrue(cleared.events.isEmpty)
        XCTAssertNotEqual(cleared.consentEpoch, stale.consentEpoch)
    }

    func testRetentionBoundsEventsAndMetadataWithoutDeletingBookmarks() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        state.ingest([item()], now: old)
        _ = state.record(item: item(), kind: .opened, epoch: state.consentEpoch, now: old)
        _ = state.feedback(item: item(), kind: .bookmark, now: old)
        state.prune(now: old.addingTimeInterval(200 * 86400))
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertEqual(state.feedbacks.filter { $0.kind == .bookmark }.count, 1)
        XCTAssertLessThanOrEqual(state.contents.count, 1)
    }

    @MainActor
    func testImpressionsAreBufferedUntilFlushAndPersistOnce() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let store = LocalInterestStore(fileURL: path)
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()
        let session = UUID()
        controller.record(article, kind: .impression, epoch: controller.state.consentEpoch, sessionID: session)
        // The render path must not mutate the observed document.
        XCTAssertTrue(controller.state.events.isEmpty)

        await controller.flush()
        XCTAssertEqual(controller.state.events.count, 1)
        XCTAssertEqual(controller.state.events.first?.kind, .impression)

        let persisted = try await store.load()
        XCTAssertEqual(persisted.events.count, 1)
    }

    @MainActor
    func testBufferedImpressionsDedupeWithinTheSameListSession() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let store = LocalInterestStore(fileURL: path)
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let article = item()
        let session = UUID()
        controller.record(article, kind: .impression, epoch: controller.state.consentEpoch, sessionID: session)
        controller.record(article, kind: .impression, epoch: controller.state.consentEpoch, sessionID: session)

        await controller.flush()
        XCTAssertEqual(controller.state.events.count, 1)
    }

    @MainActor
    func testControllerSerializesClearAndRejectsLateRead() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let store = LocalInterestStore(fileURL: path)
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        let epoch = controller.state.consentEpoch
        controller.record(item(), kind: .opened, epoch: epoch, sessionID: UUID())
        await controller.clear(keepBookmarks: false)
        controller.record(item(), kind: .qualifiedRead, epoch: epoch, sessionID: UUID())
        await controller.flush()
        let persisted = try await store.load()
        XCTAssertTrue(persisted.events.isEmpty)
        XCTAssertTrue(controller.state.events.isEmpty)
        controller.privateReading = true
        controller.record(item(), kind: .opened, epoch: controller.state.consentEpoch, sessionID: UUID())
        XCTAssertTrue(controller.state.events.isEmpty)
    }

    @MainActor
    func testPausedAndDisabledLearningStillAllowRemovingExplicitRules() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let controller = InterestController(store: LocalInterestStore(fileURL: path))
        await controller.prepare()
        controller.setLearningEnabled(true)
        let muted = controller.feedback(item(), kind: .muteSource)
        controller.setPaused(true)
        if let muted { controller.undo(muted) }
        XCTAssertFalse(controller.state.isBlocked(item()))
        controller.setPaused(false)
        controller.follow("人工智能")
        controller.setLearningEnabled(false)
        controller.unfollow("人工智能")
        XCTAssertTrue(controller.state.followedTopics.isEmpty)
        XCTAssertTrue(controller.state.events.isEmpty)
    }

    @MainActor
    func testLearningStatusDoesNotClaimActiveLearningWhenPausedOrPrivate() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let controller = InterestController(store: LocalInterestStore(fileURL: path))
        await controller.prepare()
        XCTAssertEqual(controller.learningStatus, .off)
        controller.setLearningEnabled(true)
        XCTAssertEqual(controller.learningStatus, .active)
        controller.setPaused(true)
        XCTAssertEqual(controller.learningStatus, .paused)
        controller.privateReading = true
        XCTAssertEqual(controller.learningStatus, .privateReading)
    }

    @MainActor
    func testSessionMoreLikeThisIsNeverPersistedAndClearedBookmarksDoNotRebuildProfile() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let store = LocalInterestStore(fileURL: path)
        let controller = InterestController(store: store)
        await controller.prepare()
        controller.setLearningEnabled(true)
        _ = controller.feedback(item(), kind: .moreLikeThis)
        XCTAssertEqual(controller.sessionFeedback.count, 1)
        await controller.flush()
        let saved = try await store.load()
        XCTAssertFalse(saved.feedbacks.contains { $0.kind == .moreLikeThis })
        controller.endListSession()
        XCTAssertTrue(controller.sessionFeedback.isEmpty)
        controller.record(item(), kind: .qualifiedRead, epoch: controller.state.consentEpoch, sessionID: UUID())
        _ = controller.feedback(item(), kind: .bookmark)
        await controller.clear(keepBookmarks: true)
        XCTAssertEqual(controller.state.feedbacks.count, 1)
        XCTAssertTrue(InterestProfile.build(state: controller.state).topics.isEmpty)
    }
}

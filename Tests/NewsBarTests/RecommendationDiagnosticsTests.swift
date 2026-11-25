import XCTest
@testable import NewsBar

final class RecommendationDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstExposureAndRerankAttributionKeepDifferentRanks() throws {
        var capture = RecommendationDiagnosticCapture()
        let first = UUID(), second = UUID(), attempt = UUID(), repeatAttempt = UUID()
        let exposure = try XCTUnwrap(capture.expose("synthetic", snapshot: first, rank: 2, confidence: .low, match: .matched, at: now))
        XCTAssertNil(capture.expose("synthetic", snapshot: second, rank: 6, confidence: .high, match: .matched, at: now))
        let click = try XCTUnwrap(capture.click("synthetic", snapshot: second, rank: 6, id: attempt, at: now.addingTimeInterval(1_800)))
        XCTAssertEqual(click.attributionKind, .afterRerank)
        XCTAssertEqual(click.exposureID, exposure.exposureID)
        XCTAssertEqual(exposure.algorithmRank, 2)
        XCTAssertEqual(click.algorithmRank, 6)
        XCTAssertNil(capture.click("synthetic", snapshot: second, rank: 6, id: attempt, at: now.addingTimeInterval(1_800)))
        let late = try XCTUnwrap(capture.click("synthetic", snapshot: first, rank: 2, id: repeatAttempt, at: now.addingTimeInterval(1_801)))
        XCTAssertEqual(late.attributionKind, .unattributed)
        XCTAssertNil(late.exposureID)
        let encoded = try JSONEncoder().encode(click)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["schemaVersion", "kind", "occurredAt", "diagnosticSessionID", "snapshotID",
                                         "contentKey", "exposureID", "attemptID", "attributionKind", "algorithmRank", "rankingVariant"])
        XCTAssertEqual(fields["kind"] as? String, "click_intent")
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic"))
    }

    func testResultAndMilestonesAreIdempotentAndRequireAnOpenedAttempt() throws {
        var capture = RecommendationDiagnosticCapture()
        let id = UUID()
        _ = capture.click("a", snapshot: UUID(), rank: 1, id: id, at: now)
        XCTAssertTrue(capture.read(id, activeSeconds: 15, adapted: false, at: now).isEmpty)
        XCTAssertNotNil(capture.finish(id, result: .opened, at: now.addingTimeInterval(1)))
        XCTAssertNil(capture.finish(id, result: .failed, at: now.addingTimeInterval(2)))
        XCTAssertTrue(capture.read(id, activeSeconds: 14.99, adapted: false, at: now.addingTimeInterval(16)).isEmpty)
        XCTAssertEqual(capture.read(id, activeSeconds: 15, adapted: false, at: now.addingTimeInterval(16)).map(\.milestone), [.engaged])
        XCTAssertEqual(capture.read(id, activeSeconds: 60, adapted: true, level: .deep, at: now.addingTimeInterval(61)).map(\.milestone), [.deep])
        XCTAssertTrue(capture.read(id, activeSeconds: 100, adapted: true, level: .deep, at: now.addingTimeInterval(101)).isEmpty)
        capture.invalidate()
        XCTAssertTrue(capture.read(id, activeSeconds: 150, adapted: true, level: .qualified, at: now.addingTimeInterval(151)).isEmpty)
    }

    func testLocalDayAndTimeZoneEndExposureSession() throws {
        var capture = RecommendationDiagnosticCapture()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let midnight = utc.startOfDay(for: now).addingTimeInterval(86_400)
        let snapshot = UUID()
        let old = try XCTUnwrap(capture.expose("a", snapshot: snapshot, rank: 1, confidence: .zero, match: .untagged,
                                               at: midnight.addingTimeInterval(-1), calendar: utc))
        let click = try XCTUnwrap(capture.click("a", snapshot: snapshot, rank: 1, id: UUID(), at: midnight, calendar: utc))
        XCTAssertNil(click.exposureID)
        XCTAssertNotEqual(click.diagnosticSessionID, old.diagnosticSessionID)
        var other = utc
        other.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -3_600))
        let exposure = try XCTUnwrap(capture.expose("a", snapshot: snapshot, rank: 1, confidence: .zero, match: .untagged,
                                                    at: midnight, calendar: other))
        XCTAssertNotEqual(exposure.diagnosticSessionID, click.diagnosticSessionID)
    }

    func testRetentionAndOwnerOnlyFile() async throws {
        let directory = TestIsolation.directory("rd-\(UUID())")
        let store = RecommendationDiagnosticStore(directory: directory)
        var capture = RecommendationDiagnosticCapture()
        let stale = now.addingTimeInterval(-31 * 86_400)
        let first = try XCTUnwrap(capture.expose("stale", snapshot: UUID(), rank: 1, confidence: .zero, match: .untagged, at: stale))
        let fresh = try XCTUnwrap(capture.expose("fresh", snapshot: UUID(), rank: 1, confidence: .zero, match: .untagged, at: now))
        try await store.append([first, fresh], now: now)
        let prunedByDate = try await store.load(now: now)
        XCTAssertEqual(prunedByDate.events.map(\.exposureID), [fresh.exposureID])
        try await store.append(Array(repeating: fresh, count: 10_000), now: now)
        let prunedBySize = try await store.load(now: now)
        XCTAssertEqual(prunedBySize.events.count, 10_000)
        XCTAssertNotNil(prunedBySize.truncatedThrough)
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        let file = try XCTUnwrap(manager.contentsOfDirectory(atPath: directory.path).first)
        XCTAssertEqual(try manager.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[.posixPermissions] as? Int, 0o600)
        try await store.clear()
        let cleared = try await store.load(now: now)
        XCTAssertTrue(cleared.events.isEmpty)
    }

    func testSummaryCountsTwoAttemptsButOnlyOneConvertedExposure() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = utc.startOfDay(for: now)
        let yesterday = day.addingTimeInterval(-600)
        var capture = RecommendationDiagnosticCapture()
        let snapshot = UUID()
        let exposure = try XCTUnwrap(capture.expose("content", snapshot: snapshot, rank: 3, confidence: .high,
                                                   match: .taggedNoMatch, at: yesterday, calendar: utc))
        var document = RecommendationDiagnosticDocument(coverageSince: day.addingTimeInterval(-86_400))
        document.events = [exposure]
        for i in [1.0, 2.0] {
            let id = UUID(), date = yesterday.addingTimeInterval(i)
            let click = try XCTUnwrap(capture.click("content", snapshot: snapshot, rank: 3, id: id, at: date, calendar: utc))
            document.events.append(click)
            document.events.append(try XCTUnwrap(capture.finish(id, result: .opened, at: date)))
            document.events += capture.read(id, activeSeconds: 15, adapted: false, at: date.addingTimeInterval(15))
        }
        let summary = try XCTUnwrap(RecommendationDiagnosticSummary.make(document: document, window: .week,
                                                                         now: day.addingTimeInterval(3_601), calendar: utc))
        XCTAssertEqual(summary.exposures, 1)
        XCTAssertEqual(summary.clickedExposures, 1)
        XCTAssertEqual(summary.engagedExposures, 1)
        XCTAssertEqual(summary.engaged, 2)
        XCTAssertEqual(summary.sameSnapshot, 2)
        XCTAssertEqual(summary.rank[0]?.engaged, 1)
        XCTAssertEqual(summary.match[.taggedNoMatch]?.exposures, 1)
        XCTAssertEqual(summary.missingDays, 6)
        XCTAssertEqual(summary.availableFrom, day.addingTimeInterval(-86_400))
    }

    @MainActor
    func testTurningDiagnosticsOnDoesNotChangeLearningOrRanking() async throws {
        let candidates = [
            NewsItem(title: "人工智能新进展", url: "https://example.invalid/a", source: .weibo, rank: 4, publishedAt: now),
            NewsItem(title: "足球赛事", url: "https://example.invalid/b", source: .weibo, rank: 8, publishedAt: now)
        ]
        let behaviorAt = Date().addingTimeInterval(60)
        let evaluateAt = behaviorAt.addingTimeInterval(30)
        func run(enabled: Bool) async throws -> (LocalInterestState, RecommendationSnapshot, RecommendationDiagnosticDocument) {
            let directory = TestIsolation.directory("rd-\(UUID())")
            let store = RecommendationDiagnosticStore(directory: directory.appendingPathComponent("diagnostic"))
            let diagnostics = RecommendationDiagnostics(store: store)
            XCTAssertFalse(diagnostics.enabled)
            let controller = InterestController(store: LocalInterestStore(fileURL: directory.appendingPathComponent("interest.sqlite")),
                                                diagnostics: diagnostics)
            await controller.prepare()
            controller.setLearningEnabled(true)
            diagnostics.setEnabled(enabled)
            let seed = RecommendationEngine.rank(items: candidates, state: controller.state, now: now)
            let row = try XCTUnwrap(seed.items.first)
            let date = Date().addingTimeInterval(-1)
            diagnostics.expose(row: row, snapshot: seed.id, rank: 1, confidence: seed.profileConfidence, now: date)
            let request = NewsReaderRequest(url: row.item.url, title: row.item.title, item: row.item,
                                            surface: "recommendation", contextID: seed.id.uuidString,
                                            consentEpoch: controller.consentEpoch, privateSession: false, position: 0)
            diagnostics.click(request, current: seed)
            for kind in [InterestEventKind.impression, .opened, .qualifiedRead] {
                controller.record(row.item, kind: kind, epoch: controller.consentEpoch,
                                  sessionID: request.id, surface: "recommendation",
                                  readerSessionID: kind == .impression ? nil : request.id, occurredAt: behaviorAt)
            }
            let flushed = await controller.flush()
            XCTAssertTrue(flushed)
            await diagnostics.flush()
            let document = try await store.load(now: Date())
            let state = controller.state
            return (state, RecommendationEngine.rank(items: candidates, state: state, now: evaluateAt), document)
        }
        let (off, offRank, offDocument) = try await run(enabled: false)
        let (on, onRank, onDocument) = try await run(enabled: true)
        XCTAssertTrue(offDocument.events.isEmpty)
        XCTAssertEqual(onDocument.events.map(\.kind), [.exposure, .click, .result, .milestone, .milestone])
        XCTAssertEqual(off.schemaVersion, on.schemaVersion)
        XCTAssertEqual(off.revision, on.revision)
        XCTAssertEqual(off.profileVersion, on.profileVersion)
        XCTAssertEqual(off.events.map(\.kind), on.events.map(\.kind))
        let profileOff = InterestProfile.build(state: off, now: evaluateAt)
        let profileOn = InterestProfile.build(state: on, now: evaluateAt)
        XCTAssertEqual(profileOff.topics, profileOn.topics)
        XCTAssertEqual(profileOff.shortTermTopics, profileOn.shortTermTopics)
        XCTAssertEqual(profileOff.sources, profileOn.sources)
        XCTAssertEqual(profileOff.confidence, profileOn.confidence)
        XCTAssertEqual(offRank.policyVersion, onRank.policyVersion)
        XCTAssertEqual(offRank.items.map(\.contentID), onRank.items.map(\.contentID))
        XCTAssertEqual(offRank.items.map(\.trace), onRank.items.map(\.trace))
    }

    @MainActor
    func testRevokedGenerationDropsPendingRecordsAcrossPausePrivateAndClear() async throws {
        let store = RecommendationDiagnosticStore(directory: TestIsolation.directory("rd-\(UUID())"))
        let diagnostics = RecommendationDiagnostics(store: store)
        diagnostics.setEnabled(true)
        diagnostics.setLearningAllowed(true)
        let item = NewsItem(title: "News", url: "https://example.invalid/a", source: .weibo)
        let rank = RecommendationEngine.rank(items: [item], state: LocalInterestState(), now: now)
        let row = try XCTUnwrap(rank.items.first)
        diagnostics.expose(row: row, snapshot: rank.id, rank: 1, confidence: 0, now: Date())
        diagnostics.setLearningAllowed(false)
        diagnostics.setLearningAllowed(true)
        await diagnostics.flush()
        let pruned = try await store.load(now: Date())
        XCTAssertTrue(pruned.events.isEmpty)
        diagnostics.expose(row: row, snapshot: rank.id, rank: 1, confidence: 0, now: Date())
        diagnostics.setEnabled(false)
        diagnostics.setEnabled(true)
        await diagnostics.flush()
        let afterToggle = try await store.load(now: Date())
        XCTAssertTrue(afterToggle.events.isEmpty)
        diagnostics.expose(row: row, snapshot: rank.id, rank: 1, confidence: 0, now: Date())
        let cleared = await diagnostics.clear()
        XCTAssertTrue(cleared)
        await diagnostics.flush()
        let afterClear = try await store.load(now: Date())
        XCTAssertTrue(afterClear.events.isEmpty)
    }
}

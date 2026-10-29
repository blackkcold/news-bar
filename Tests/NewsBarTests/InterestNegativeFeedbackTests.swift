import XCTest
@testable import NewsBar

final class InterestNegativeFeedbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sourceA = NewsSource.rss(name: "A", url: "https://a.example/rss")
    private let sourceB = NewsSource.rss(name: "B", url: "https://b.example/rss")

    private func item(_ title: String, _ id: Int, source: NewsSource? = nil) -> NewsItem {
        NewsItem(
            title: title,
            url: "https://example.com/negative/\(id)",
            source: source ?? sourceA,
            publishedAt: now
        )
    }

    private func state(learning: Bool = true) -> LocalInterestState {
        var state = LocalInterestState()
        state.learningEnabled = learning
        return state
    }

    private func trace(_ item: NewsItem, state: LocalInterestState, at date: Date? = nil) throws -> RecommendationTrace {
        let ranked = RecommendationEngine.rank(items: [item], state: state, now: date ?? now, limit: 5)
        return try XCTUnwrap(ranked.items.first?.trace)
    }

    func testLessLikeContentStaysVisibleAndDecays() throws {
        var state = state()
        let article = item("人工智能模型发布", 1)
        state.ingest([article], now: now)
        _ = state.feedback(item: article, kind: .lessLikeContent, now: now)

        let freshTrace = try trace(article, state: state)
        XCTAssertEqual(freshTrace.negativeContentPenalty, 0.25, accuracy: 1e-9)
        XCTAssertEqual(freshTrace.negativePenalty, 0.25, accuracy: 1e-9)

        let laterTrace = try trace(article, state: state, at: now.addingTimeInterval(14 * 86_400))
        XCTAssertEqual(laterTrace.negativeContentPenalty, 0.125, accuracy: 1e-9)

        // Soft means downweight, never hide: the item is still ranked.
        let ranked = RecommendationEngine.rank(items: [article], state: state, now: now, limit: 5)
        XCTAssertEqual(ranked.items.count, 1)
    }

    func testLessLikeSourceAppliesToEveryItemFromThatSource() throws {
        var state = state()
        let first = item("甲新闻", 2, source: sourceA)
        let second = item("乙新闻", 3, source: sourceA)
        state.ingest([first, second], now: now)
        _ = state.feedback(item: first, kind: .lessLikeSource, now: now)

        let ranked = RecommendationEngine.rank(items: [first, second], state: state, now: now, limit: 5)
        XCTAssertEqual(ranked.items.count, 2)
        for row in ranked.items {
            let trace = try XCTUnwrap(row.trace)
            XCTAssertEqual(trace.negativeSourcePenalty, 0.15, accuracy: 1e-9)
        }
    }

    func testCombinedSoftPenaltiesAreCappedAtForty() throws {
        var state = state()
        let article = item("人工智能模型发布", 4, source: sourceA)
        state.ingest([article], now: now)
        _ = state.feedback(item: article, kind: .lessLikeContent, now: now)
        _ = state.feedback(item: article, kind: .lessLikeSource, now: now)
        _ = state.feedback(item: article, kind: .reduceTopic, topic: "ai", now: now)

        let trace = try trace(article, state: state)
        XCTAssertEqual(trace.negativeContentPenalty, 0.25, accuracy: 1e-9)
        XCTAssertEqual(trace.negativeTopicPenalty, 0.16, accuracy: 1e-9)
        XCTAssertEqual(trace.negativeSourcePenalty, 0.15, accuracy: 1e-9)
        XCTAssertEqual(trace.negativePenalty, 0.40, accuracy: 1e-9)
    }

    func testSoftNegativeDoesNotApplyWhileLearningIsOff() throws {
        var state = state(learning: false)
        let article = item("人工智能模型发布", 5)
        state.ingest([article], now: now)
        _ = state.feedback(item: article, kind: .lessLikeContent, now: now, participatesInProfile: false)

        state.learningEnabled = true
        let trace = try trace(article, state: state)
        XCTAssertEqual(trace.negativePenalty, 0, accuracy: 1e-12)
    }

    func testUndoRemovesTheSoftRule() throws {
        var state = state()
        let article = item("人工智能模型发布", 6)
        state.ingest([article], now: now)
        let id = state.feedback(item: article, kind: .lessLikeContent, now: now)
        XCTAssertEqual(try trace(article, state: state).negativePenalty, 0.25, accuracy: 1e-9)

        state.undoFeedback(id)

        XCTAssertEqual(try trace(article, state: state).negativePenalty, 0, accuracy: 1e-12)
    }

    func testOldPayloadWithoutParticipatesInProfileDecodesAsTrue() throws {
        var state = state()
        let article = item("旧数据", 7)
        _ = state.feedback(item: article, kind: .lessLikeContent, now: now)
        let feedback = try XCTUnwrap(state.feedbacks.first)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(feedback)) as? [String: Any]
        )
        json.removeValue(forKey: "participatesInProfile")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(InterestFeedback.self, from: data)
        XCTAssertTrue(decoded.participatesInProfile)
        XCTAssertEqual(decoded.kind, .lessLikeContent)
    }

    func testUnknownFeedbackKindDoesNotStopDecoding() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"futureKind","occurredAt":\(now.timeIntervalSince1970),
         "item":{"id":"x","title":"新类型","url":"https://example.com/future","source":{"type":"weibo"},
                 "timestamp":\(now.timeIntervalSince1970)}}
        """
        let feedback = try JSONDecoder().decode(InterestFeedback.self, from: Data(json.utf8))
        XCTAssertEqual(feedback.kind, .unknown)
        XCTAssertFalse(LocalInterestState().isBlocked(feedback.item))
        let encoded = try JSONEncoder().encode(feedback)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "futureKind")
    }
}

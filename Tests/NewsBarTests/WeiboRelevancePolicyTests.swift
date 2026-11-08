import XCTest
@testable import NewsBar

final class WeiboRelevancePolicyTests: XCTestCase {
    private let calendar = WeiboMonitorTestSupport.calendar
    private var policy: WeiboAlertPolicy { WeiboAlertPolicy(calendar: calendar) }
    private let noon = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
    private let config = WeiboMonitorConfig(
        enabled: true,
        notifyEnabled: true,
        perAccountHourlyCap: 6,
        globalHourlyCap: 20,
        keywordNotifyEnabled: true,
        keywordList: ["Ultra"]
    )

    private func decision(
        text: String = "新的爆料",
        verdict: WeiboRelevanceVerdict?,
        priority: WeiboMonitorPriority = .p1
    ) -> WeiboAlertDecision {
        let user = WeiboMonitorTestSupport.user(priority: priority, now: noon)
        let post = WeiboMonitorTestSupport.post(text: text, createdAt: noon)
        return policy.decision(
            for: post,
            user: user,
            config: config,
            now: noon,
            accountNotificationsLastHour: 0,
            globalNotificationsLastHour: 0,
            verdict: verdict
        )
    }

    func testFilteredVerdictSuppressesNotification() {
        XCTAssertEqual(
            decision(verdict: .filtered),
            .feedOnly(.filteredByRelevance(.filtered))
        )
    }

    func testOffTopicVerdictSuppressesNotification() {
        XCTAssertEqual(
            decision(verdict: .offTopic),
            .feedOnly(.filteredByRelevance(.offTopic))
        )
    }

    func testLowConfidenceVerdictSuppressesNotification() {
        XCTAssertEqual(
            decision(verdict: .lowConfidence),
            .feedOnly(.filteredByRelevance(.lowConfidence))
        )
    }

    func testRelevantVerdictBypassesTheKeywordGate() {
        // P1 with a keyword list would normally stay in the feed, but the
        // relevance model already answered the question the list asks.
        XCTAssertEqual(
            decision(text: "普通的一句话", verdict: .relevant),
            .notify
        )
    }

    func testNilVerdictKeepsTheOldKeywordBehaviour() {
        XCTAssertEqual(
            decision(text: "普通的一句话", verdict: nil),
            .feedOnly(.keywordsMissed)
        )
    }

    func testMuteStillWinsOverARelevantVerdict() {
        var user = WeiboMonitorTestSupport.user(priority: .p1, now: noon)
        user.mutedUntil = noon.addingTimeInterval(3600)
        let post = WeiboMonitorTestSupport.post(text: "新的爆料", createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0,
                verdict: .relevant
            ),
            .feedOnly(.muted)
        )
    }

    func testQuietHoursStillWinOverARelevantVerdict() {
        let night = WeiboMonitorTestSupport.date(2026, 11, 7, 23, 45)
        let user = WeiboMonitorTestSupport.user(priority: .p1, now: night)
        let post = WeiboMonitorTestSupport.post(text: "新的爆料", createdAt: night)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: night,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0,
                verdict: .relevant
            ),
            .feedOnly(.quietHours)
        )
    }

    func testSuppressionTitleKeysExistForEveryVerdict() {
        let keys = WeiboRelevanceVerdict.allCases.map {
            WeiboAlertSuppression.filteredByRelevance($0).titleKey
        }
        for key in keys {
            XCTAssertNotEqual(L10n.string(key), key, "missing localization: \(key)")
        }
    }
}

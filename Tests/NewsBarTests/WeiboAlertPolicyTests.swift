import XCTest
@testable import NewsBar

final class WeiboAlertPolicyTests: XCTestCase {
    private let calendar = WeiboMonitorTestSupport.calendar
    private var policy: WeiboAlertPolicy { WeiboAlertPolicy(calendar: calendar) }
    private let noon = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
    private let config = WeiboMonitorConfig(
        enabled: true,
        notifyEnabled: true,
        perAccountHourlyCap: 6,
        globalHourlyCap: 20,
        keywordNotifyEnabled: true,
        keywordList: ["Ultra", "芯片"]
    )

    func testP0NotifiesByDefault() {
        let user = WeiboMonitorTestSupport.user(priority: .p0, now: noon)
        let post = WeiboMonitorTestSupport.post(createdAt: noon)
        let decision = policy.decision(
            for: post,
            user: user,
            config: config,
            now: noon,
            accountNotificationsLastHour: 0,
            globalNotificationsLastHour: 0
        )
        XCTAssertEqual(decision, .notify)
    }

    func testP1KeywordHitNotifies() {
        let user = WeiboMonitorTestSupport.user(priority: .p1, now: noon)
        let post = WeiboMonitorTestSupport.post(text: "这次真的有 Ultra 版本", createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .notify
        )
    }

    func testP1KeywordMissStaysInFeed() {
        let user = WeiboMonitorTestSupport.user(priority: .p1, now: noon)
        let post = WeiboMonitorTestSupport.post(text: "今天天气不错", createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .feedOnly(.keywordsMissed)
        )
    }

    func testP1KeywordMatchIsCaseInsensitive() {
        let user = WeiboMonitorTestSupport.user(priority: .p1, now: noon)
        let post = WeiboMonitorTestSupport.post(text: "ultra 版本来了", createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .notify
        )
    }

    func testP1QuietHoursSuppressNotification() {
        let quiet = WeiboMonitorTestSupport.date(2026, 11, 7, 23, 45)
        let user = WeiboMonitorTestSupport.user(priority: .p1, now: quiet)
        let post = WeiboMonitorTestSupport.post(text: "Ultra 深夜爆料", createdAt: quiet)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: quiet,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .feedOnly(.quietHours)
        )
    }

    func testP2DefaultStaysInFeed() {
        let user = WeiboMonitorTestSupport.user(priority: .p2, now: noon)
        let post = WeiboMonitorTestSupport.post(createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .feedOnly(.notifyModeFeedOnly)
        )
    }

    func testP2ExplicitAllNotifies() {
        let user = WeiboMonitorTestSupport.user(
            priority: .p2,
            notifyMode: .all,
            now: noon
        )
        let post = WeiboMonitorTestSupport.post(createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .notify
        )
    }

    func testMutedAccountStaysInFeed() {
        var user = WeiboMonitorTestSupport.user(now: noon)
        user.mutedUntil = noon.addingTimeInterval(3600)
        let post = WeiboMonitorTestSupport.post(createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .feedOnly(.muted)
        )
    }

    func testAccountAndGlobalCaps() {
        let user = WeiboMonitorTestSupport.user(now: noon)
        let post = WeiboMonitorTestSupport.post(createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 6,
                globalNotificationsLastHour: 0
            ),
            .feedOnly(.accountCap)
        )
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: config,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 20
            ),
            .feedOnly(.globalCap)
        )
    }

    func testNotifyDisabled() {
        var disabled = config
        disabled.notifyEnabled = false
        let user = WeiboMonitorTestSupport.user(now: noon)
        let post = WeiboMonitorTestSupport.post(createdAt: noon)
        XCTAssertEqual(
            policy.decision(
                for: post,
                user: user,
                config: disabled,
                now: noon,
                accountNotificationsLastHour: 0,
                globalNotificationsLastHour: 0
            ),
            .feedOnly(.notifyDisabled)
        )
    }

    func testSingleNotificationContent() {
        let user = WeiboMonitorTestSupport.user(now: noon)
        let post = WeiboMonitorTestSupport.post(
            mid: "3001",
            text: "一条很长的爆料内容",
            createdAt: WeiboMonitorTestSupport.date(2026, 11, 7, 11, 50)
        )
        let notification = policy.notification(
            for: [post],
            user: user,
            language: .zh,
            now: noon
        )
        XCTAssertEqual(notification?.title, user.screenName)
        XCTAssertTrue(notification?.subtitle.contains("新微博") == true)
        XCTAssertEqual(notification?.body, "一条很长的爆料内容")
        XCTAssertEqual(notification?.requestID, "weibo-3001")
        XCTAssertEqual(notification?.threadID, "weibo.\(user.uid)")
    }

    func testAggregatedNotificationContent() {
        let user = WeiboMonitorTestSupport.user(now: noon)
        let posts = [
            WeiboMonitorTestSupport.post(
                mid: "3001",
                text: "第一条",
                createdAt: WeiboMonitorTestSupport.date(2026, 11, 7, 11, 50)
            ),
            WeiboMonitorTestSupport.post(
                mid: "3002",
                text: "第二条",
                createdAt: WeiboMonitorTestSupport.date(2026, 11, 7, 11, 51)
            ),
            WeiboMonitorTestSupport.post(
                mid: "3003",
                text: "第三条",
                createdAt: WeiboMonitorTestSupport.date(2026, 11, 7, 11, 52)
            ),
        ]
        let notification = policy.notification(
            for: posts,
            user: user,
            language: .zh,
            now: noon
        )
        XCTAssertEqual(notification?.postCount, 3)
        XCTAssertTrue(notification?.title.contains("3") == true)
        XCTAssertTrue(notification?.body.contains("第三条") == true)
        XCTAssertEqual(notification?.requestID, "weibo-\(user.uid)-3003")
    }
}

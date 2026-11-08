import UserNotifications
import XCTest
@testable import NewsBar

final class WeiboMonitorRouterTests: XCTestCase {
    func testWeiboOpenRoute() {
        XCTAssertEqual(
            NotificationClickRouter.route(
                userInfo: [
                    "type": "weibo",
                    "mid": "123",
                    "uid": "42",
                    "url": "https://weibo.com/42/B",
                ],
                actionIdentifier: UNNotificationDefaultActionIdentifier
            ),
            .weibo(mid: "123", uid: "42", url: "https://weibo.com/42/B")
        )
    }

    func testWeiboMuteRoute() {
        XCTAssertEqual(
            NotificationClickRouter.route(
                userInfo: ["type": "weibo", "mid": "123", "uid": "42"],
                actionIdentifier: NotificationIdentifier.muteWeiboAction
            ),
            .muteWeibo(uid: "42")
        )
    }

    func testWeiboMarkReadRoute() {
        XCTAssertEqual(
            NotificationClickRouter.route(
                userInfo: ["type": "weibo", "mid": "123", "uid": "42"],
                actionIdentifier: NotificationIdentifier.markWeiboReadAction
            ),
            .markWeiboRead(mid: "123", uid: "42")
        )
    }

    func testWeiboMissingURLIsNil() {
        XCTAssertEqual(
            NotificationClickRouter.route(
                userInfo: ["type": "weibo", "mid": "123", "uid": "42"],
                actionIdentifier: UNNotificationDefaultActionIdentifier
            ),
            .weibo(mid: "123", uid: "42", url: nil)
        )
    }

    func testWeiboAuthAlertRoutesToDashboardOnly() {
        XCTAssertEqual(
            NotificationClickRouter.route(
                userInfo: ["type": "weibo", "mid": "", "uid": ""],
                actionIdentifier: UNNotificationDefaultActionIdentifier
            ),
            .weibo(mid: "", uid: "", url: nil)
        )
    }
}

import UserNotifications
import XCTest
@testable import NewsBar

final class NotificationSchedulingTests: XCTestCase {
    private func item(_ title: String) -> NewsItem {
        NewsItem(
            title: title,
            url: "https://example.com/\(title)",
            source: .rss(name: "Example", url: "https://example.com/feed")
        )
    }

    func testDailyRequestCarriesADigestAndRepeatsEveryDay() throws {
        let request = try XCTUnwrap(
            NotificationService.makeDailyRequest(
                items: [item("one"), item("two")],
                count: 3,
                hour: 9,
                minute: 30
            )
        )
        XCTAssertEqual(request.identifier, NotificationIdentifier.dailyRequest)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 9)
        XCTAssertEqual(trigger.dateComponents.minute, 30)
        let digest = request.content.userInfo["digest"] as? String
        XCTAssertNotNil(digest)
    }

    func testDailyRequestStillRepeatsWhenThereIsNoDigestContent() throws {
        let request = try XCTUnwrap(
            NotificationService.makeDailyRequest(items: [], count: 3, hour: 8, minute: 0)
        )
        XCTAssertEqual(request.identifier, NotificationIdentifier.dailyRequest)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 8)
        XCTAssertEqual(request.content.userInfo["type"] as? String, "daily")
    }
}

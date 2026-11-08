import Foundation
@testable import NewsBar

enum WeiboMonitorTestSupport {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }

    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = calendar.timeZone
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    static func user(
        uid: String = "1001",
        name: String = "数码闲聊站",
        priority: WeiboMonitorPriority = .p0,
        notifyMode: WeiboNotifyMode? = nil,
        now: Date = date(2026, 11, 7, 12, 0),
        lastPostAt: Date? = nil,
        hotWindowUntil: Date? = nil
    ) -> WeiboMonitorUser {
        var stats = WeiboMonitorStats()
        stats.lastPostAt = lastPostAt
        return WeiboMonitorUser(
            uid: uid,
            screenName: name,
            priority: priority,
            notifyMode: notifyMode,
            addedAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
            nextDueAt: now,
            lastSuccessAt: now.addingTimeInterval(-60),
            hotWindowUntil: hotWindowUntil,
            stats: stats
        )
    }

    static func post(
        mid: String = "1002",
        uid: String = "1001",
        name: String = "数码闲聊站",
        text: String = "新的爆料",
        createdAt: Date = date(2026, 11, 7, 11, 58),
        read: Bool = false
    ) -> WeiboPost {
        WeiboPost(
            mid: mid,
            bid: "B\(mid)",
            uid: uid,
            screenName: name,
            text: text,
            createdAt: createdAt,
            fetchedAt: createdAt.addingTimeInterval(60),
            url: WeiboPost.makeURL(uid: uid, bid: "B\(mid)", mid: mid),
            read: read
        )
    }

    static func t0Fixture() -> Data {
        let json: [String: Any] = [
            "ok": 1,
            "data": [
                "list": [
                    [
                        "idstr": "1002",
                        "bid": "B2",
                        "text_raw": "第二条 <a href=\"https://weibo.com\">链接</a> &amp; 内容 &#39;quoted&#39;",
                        "created_at": "Fri Nov 07 09:58:00 +0800 2026",
                        "isTop": 0,
                        "isLongText": true,
                        "pics": [
                            ["large": ["url": "https://wx1.sinaimg.cn/large/one.jpg"]]
                        ],
                        "user": [
                            "screen_name": "数码闲聊站",
                            "profile_image_url": "https://tvax1.sinaimg.cn/avatar.jpg",
                        ],
                    ],
                    [
                        "idstr": "1001",
                        "bid": "B1",
                        "text_raw": "",
                        "created_at": "Thu Nov 06 09:00:00 +0800 2026",
                        "isTop": 1,
                        "retweeted_status": [
                            "text_raw": "被转发的原文"
                        ],
                    ],
                ]
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    static func t1Fixture() -> Data {
        let json: [String: Any] = [
            "ok": 1,
            "data": [
                "cards": [
                    [
                        "card_type": 9,
                        "mblog": [
                            "id": "2001",
                            "text": "T1 <b>内容</b> &amp; 更多",
                            "created_at": "11-07",
                            "isLongText": false,
                            "pics": [],
                            "user": ["screen_name": "T1用户"],
                        ],
                    ],
                    [
                        "card_type": 11,
                        "card_group": [
                            [
                                "mblog": [
                                    "id": "2000",
                                    "text": "嵌套卡片",
                                    "created_at": "11-06",
                                    "user": ["screen_name": "T1用户"],
                                ]
                            ]
                        ],
                    ],
                ],
                "cardlistInfo": ["since_id": "2001"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}

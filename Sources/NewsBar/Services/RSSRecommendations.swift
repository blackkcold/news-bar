import Foundation

struct RSSRecommendation: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let category: Category

    enum Category: String, CaseIterable {
        case tech = "科技"
        case general = "综合"
    }
}

enum RSSRecommendations {

    static let all: [RSSRecommendation] = [
        RSSRecommendation(name: "36氪", url: "https://36kr.com/feed", category: .tech),
        RSSRecommendation(name: "少数派", url: "https://sspai.com/feed", category: .tech),
        RSSRecommendation(name: "V2EX 创意", url: "https://www.v2ex.com/feed/tab/creative.xml", category: .tech),
        RSSRecommendation(name: "OSCHINA", url: "https://www.oschina.net/news/rss", category: .tech),
        RSSRecommendation(name: "Hacker News", url: "https://hnrss.org/frontpage", category: .tech),
        RSSRecommendation(name: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", category: .general),
        RSSRecommendation(name: "FT 中文", url: "https://www.ftchinese.com/rss/news", category: .general),
    ]
}

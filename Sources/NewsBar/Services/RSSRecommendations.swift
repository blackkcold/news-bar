import Foundation

struct RSSRecommendation: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let category: Category

    enum Category: String, CaseIterable {
        case tech = "科技"
        case general = "综合"
        case finance = "财经"
        case design = "设计"
        case international = "国际"
        case lifestyle = "生活"
    }
}

enum RSSRecommendations {

    // Strict direct-only policy: publisher-hosted, HTTPS RSS/Atom feeds only.
    // No public proxy, aggregator, third-party bridge, or unreachable feeds.
    static let all: [RSSRecommendation] = [
        // 科技
        RSSRecommendation(name: "36氪", url: "https://www.36kr.com/feed", category: .tech),
        RSSRecommendation(name: "少数派", url: "https://sspai.com/feed", category: .tech),
        RSSRecommendation(name: "V2EX 创意", url: "https://www.v2ex.com/feed/tab/creative.xml", category: .tech),
        RSSRecommendation(name: "OSCHINA", url: "https://www.oschina.net/news/rss", category: .tech),
        RSSRecommendation(name: "虎嗅", url: "https://rss.huxiu.com/", category: .tech),
        RSSRecommendation(name: "爱范儿", url: "https://www.ifanr.com/feed", category: .tech),
        RSSRecommendation(name: "IT之家", url: "https://www.ithome.com/rss/", category: .tech),
        // 综合
        RSSRecommendation(name: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", category: .general),
        // 财经
        RSSRecommendation(name: "华尔街见闻", url: "https://dedicated.wallstreetcn.com/rss.xml", category: .finance),
        // 国际
        RSSRecommendation(name: "NYT 中文", url: "https://cn.nytimes.com/rss/news.xml", category: .international),
    ]
}
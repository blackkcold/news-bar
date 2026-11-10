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
    //
    // Verified 2026-11-10: every URL below answered with a valid RSS/Atom root
    // and at least one item. Re-run the in-app recommendation validation after
    // changing this list.
    static let all: [RSSRecommendation] = [
        // 科技
        RSSRecommendation(name: "36氪", url: "https://www.36kr.com/feed", category: .tech),
        RSSRecommendation(name: "少数派", url: "https://sspai.com/feed", category: .tech),
        RSSRecommendation(name: "V2EX 创意", url: "https://www.v2ex.com/feed/tab/creative.xml", category: .tech),
        RSSRecommendation(name: "OSCHINA", url: "https://www.oschina.net/news/rss", category: .tech),
        RSSRecommendation(name: "虎嗅", url: "https://rss.huxiu.com/", category: .tech),
        RSSRecommendation(name: "爱范儿", url: "https://www.ifanr.com/feed", category: .tech),
        RSSRecommendation(name: "IT之家", url: "https://www.ithome.com/rss/", category: .tech),
        RSSRecommendation(name: "量子位", url: "https://www.qbitai.com/feed", category: .tech),
        RSSRecommendation(name: "InfoQ 中文", url: "https://www.infoq.cn/feed", category: .tech),
        RSSRecommendation(name: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml", category: .tech),
        RSSRecommendation(name: "掘金", url: "https://juejin.cn/rss", category: .tech),
        // 综合
        // BBC's simplified-Chinese feed redirects to the traditional feed; the
        // name says so instead of pretending it is 简体.
        RSSRecommendation(name: "BBC 中文（繁体）", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", category: .general),
        RSSRecommendation(name: "中国新闻网", url: "https://www.chinanews.com.cn/rss/scroll-news.xml", category: .general),
        // 财经
        RSSRecommendation(name: "华尔街见闻", url: "https://dedicated.wallstreetcn.com/rss.xml", category: .finance),
        RSSRecommendation(name: "FT 中文网", url: "https://www.ftchinese.com/rss/news", category: .finance),
        // 国际
        RSSRecommendation(name: "NYT 中文", url: "https://cn.nytimes.com/rss/news.xml", category: .international),
        RSSRecommendation(name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml", category: .international),
        RSSRecommendation(name: "The Guardian World", url: "https://www.theguardian.com/world/rss", category: .international),
        // 设计
        RSSRecommendation(name: "A List Apart", url: "https://alistapart.com/main/feed/", category: .design),
        RSSRecommendation(name: "CSS-Tricks", url: "https://css-tricks.com/feed/", category: .design),
        // 生活
        RSSRecommendation(name: "机核", url: "https://www.gcores.com/rss", category: .lifestyle),
        RSSRecommendation(name: "什么值得买", url: "https://post.smzdm.com/feed/", category: .lifestyle),
    ]
}

/// The three sources shown when a person has never subscribed to anything.
/// Kept as names so the catalog stays the single source of truth; the test
/// target asserts every name resolves and the set covers three categories.
enum RSSStarterPicks {
    static let names = ["中国新闻网", "量子位", "FT 中文网"]

    static var recommendations: [RSSRecommendation] {
        names.compactMap { name in
            RSSRecommendations.all.first { $0.name == name }
        }
    }
}

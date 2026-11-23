import Foundation

/// Built-in invariants for the comment surface. This is the part an agent can
/// run with one command and no fixture file: it exercises the production
/// parser and fails loudly if a rule regresses.
enum AgentChecks {
    struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run() -> [Check] {
        [
            whitespaceAroundAnchor(),
            mentionAndTopicKeepHref(),
            sinaURLUnwrapsOnce(),
            nonHTTPSDowngrades(),
            dataHrefIsNotALink(),
            uppercaseAnchorParses(),
        ]
    }

    private static func whitespaceAroundAnchor() -> Check {
        let raw = "Nice shot <a href='https://example.com/a'>this one</a> is great"
        guard let runs = WeiboCommentParser.parseRuns(raw) else {
            return Check(name: "whitespace-around-anchor", passed: false, detail: "parseRuns returned nil")
        }
        let joined = runs.map(\.text).joined()
        let link = runs.first { $0.kind == .link }?.url
        let passed = joined == "Nice shot this one is great" && link == "https://example.com/a"
        return Check(
            name: "whitespace-around-anchor",
            passed: passed,
            detail: passed ? joined : "joined=\(joined) link=\(link ?? "nil")"
        )
    }

    private static func mentionAndTopicKeepHref() -> Check {
        let raw = "回复<a href='https://m.weibo.cn/n/%E6%9F%90%E4%BA%BA'>@某人</a>:"
            + "<a href='https://s.weibo.com/weibo?q=%23%E8%AF%9D%E9%A2%98%23'>#话题#</a>"
        guard let runs = WeiboCommentParser.parseRuns(raw) else {
            return Check(name: "mention-topic-href", passed: false, detail: "parseRuns returned nil")
        }
        let mention = runs.first { $0.kind == .mention }
        let topic = runs.first { $0.kind == .topic }
        let passed = mention?.url != nil && topic?.url != nil
        return Check(
            name: "mention-topic-href",
            passed: passed,
            detail: passed ? "mention and topic carry Weibo hrefs" : "mention=\(mention?.url ?? "nil") topic=\(topic?.url ?? "nil")"
        )
    }

    private static func sinaURLUnwrapsOnce() -> Check {
        let raw = "<a href='https://weibo.cn/sinaurl?u=https%3A%2F%2Fexample.com%2Fa'>故事</a>"
        guard let runs = WeiboCommentParser.parseRuns(raw) else {
            return Check(name: "sinaurl-unwrap", passed: false, detail: "parseRuns returned nil")
        }
        let passed = runs.count == 1 && runs[0].kind == .link && runs[0].url == "https://example.com/a"
        return Check(
            name: "sinaurl-unwrap",
            passed: passed,
            detail: passed ? "unwrapped one layer" : "url=\(runs.first?.url ?? "nil")"
        )
    }

    private static func nonHTTPSDowngrades() -> Check {
        let raw = "<a href='http://example.com/x'>明文</a>"
        guard let runs = WeiboCommentParser.parseRuns(raw) else {
            return Check(name: "https-only", passed: false, detail: "parseRuns returned nil")
        }
        let passed = runs.count == 1 && runs[0].kind == .text && runs[0].url == nil
        return Check(
            name: "https-only",
            passed: passed,
            detail: passed ? "http anchor stayed plain text" : "kind=\(runs.first?.kind.rawValue ?? "nil")"
        )
    }

    private static func dataHrefIsNotALink() -> Check {
        let raw = "看图<a data-href='https://example.com/a' name='x'>说明</a>"
        let passed = WeiboCommentParser.parseRuns(raw) == nil
        return Check(
            name: "data-href-not-a-link",
            passed: passed,
            detail: passed ? "data-href ignored" : "data-href became a link"
        )
    }

    private static func uppercaseAnchorParses() -> Check {
        let raw = "看<A HREF='https://example.com/A'>大写</A>"
        guard let runs = WeiboCommentParser.parseRuns(raw) else {
            return Check(name: "uppercase-anchor", passed: false, detail: "parseRuns returned nil")
        }
        let passed = runs.first { $0.kind == .link }?.url == "https://example.com/A"
        return Check(
            name: "uppercase-anchor",
            passed: passed,
            detail: passed ? "uppercase anchor parsed" : "link missing"
        )
    }
}

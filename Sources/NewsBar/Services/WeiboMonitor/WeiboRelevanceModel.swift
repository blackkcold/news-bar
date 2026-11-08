import Foundation

/// Pre-computed 4-gram sets for the cross-account repost signal. Building the
/// index once per poll batch keeps the rule pass cheap even when the feed holds
/// several hundred posts.
struct WeiboCrossPostIndex: Sendable {
    struct Entry: Sendable {
        var uid: String
        var grams: Set<String>
        var createdAt: Date
    }

    private let entries: [Entry]

    init(
        references: [WeiboCrossPostReference],
        excludingUID: String? = nil,
        now: Date,
        window: TimeInterval = 72 * 60 * 60
    ) {
        let cutoff = now.addingTimeInterval(-window)
        var result: [Entry] = []
        result.reserveCapacity(references.count)
        for reference in references {
            guard reference.createdAt >= cutoff else { continue }
            if let excludingUID, reference.uid == excludingUID { continue }
            let grams = WeiboTextFingerprint.grams(reference.text)
            guard grams.count >= WeiboTextFingerprint.minimumComparableGrams else { continue }
            result.append(Entry(uid: reference.uid, grams: grams, createdAt: reference.createdAt))
        }
        entries = result
    }

    var isEmpty: Bool { entries.isEmpty }

    /// The highest containment against any *other* account's post. The
    /// reference set is already scoped to the window and the account.
    func bestContainment(for text: String) -> Double {
        guard !entries.isEmpty else { return 0 }
        let target = WeiboTextFingerprint.grams(text)
        guard target.count >= WeiboTextFingerprint.minimumComparableGrams else { return 0 }
        var best = 0.0
        for entry in entries {
            let value = WeiboTextFingerprint.containment(target, entry.grams)
            if value > best {
                best = value
                if best >= 0.95 { break }
            }
        }
        return best
    }
}

enum WeiboTextFingerprint {
    static let gramSize = 4
    /// Below this, a post is too short for containment to mean anything: two
    /// one-line news flashes share a phrase by coincidence, not by copying.
    static let minimumComparableGrams = 32

    static func normalize(_ text: String) -> String {
        var value = text.lowercased()
        value = value.replacingOccurrences(
            of: "https?://\\S+",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "@[a-z0-9_\\-]+",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "#", with: "")
        var result = ""
        for scalar in value.unicodeScalars {
            let isCJK = (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
            if isCJK || CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func grams(_ text: String, size: Int = gramSize) -> Set<String> {
        let characters = Array(normalize(text))
        guard characters.count >= size else { return [] }
        var result = Set<String>()
        result.reserveCapacity(characters.count - size + 1)
        for index in 0...(characters.count - size) {
            result.insert(String(characters[index..<(index + size)]))
        }
        return result
    }

    /// Asymmetric on purpose: a short PR blurb copied from a long article still
    /// matches, while a long article quoting one sentence does not. The
    /// denominator is the shorter set.
    static func containment(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let denominator = min(lhs.count, rhs.count)
        guard denominator > 0 else { return 0 }
        let shared = lhs.intersection(rhs).count
        return Double(shared) / Double(denominator)
    }
}

/// Pure, local, explainable relevance scoring. It never performs I/O and never
/// decides anything irreversible: the service turns the verdict into "collapse"
/// and "do not notify", and every rule leaves a reason code behind.
struct WeiboRelevanceModel: Sendable {
    static let crossPostThreshold = 0.30

    // MARK: - Vocabulary

    private static let lotteryPlatformTerms = ["微博抽奖平台"]
    private static let lotteryPlatformLinkTerms = ["公示链接"]

    private static let disclosureTerms: [(String, Double)] = [
        ("#广告#", 0.75),
        ("广告合作", 0.60),
        ("商业推广", 0.60),
        ("商单", 0.60),
        ("赞助内容", 0.60),
        ("品牌合作", 0.60),
        ("#推广#", 0.60),
        ("赞助", 0.45),
        ("广告", 0.30),
    ]

    private static let transactionTerms = [
        "券后", "到手价", "领券", "直降", "满减", "预售", "抢购", "优惠券", "折扣", "下单立减",
    ]

    private static let funnelTerms = [
        "taobao.com", "tmall.com", "jd.com", "pinduoduo", "小黄车", "橱窗", "购买链接", "下单链接",
    ]

    private static let brandVoiceTerms = ["现已开售", "首发", "官方"]

    private static let weakReverseTerms = [
        "汽车", "试驾", "车主", "影视", "追剧", "明星", "综艺", "体育", "足球", "篮球", "马拉松",
        "比亚迪", "特斯拉", "蔚来", "小鹏", "问界", "极氪", "智界", "天气",
        // Film and game coverage is only weakly off-topic: a product review
        // can legitimately quote a movie or a game.
        "电影", "电视剧", "海报", "上映", "预告片", "游戏", "开黑", "抽卡", "卡池", "定档",
        "漫威", "美队", "复仇者", "宣传行程",
    ]

    private static let strongReverseTerms = [
        "美食", "餐厅", "晚餐", "午餐", "早餐", "做饭", "探店", "好吃", "吃了", "这家店", "点餐",
        "外卖", "风景", "旅游", "旅行", "海边", "夕阳", "酒店", "度假", "猫", "狗", "宠物",
        "假期", "日历", "招聘", "求职", "简历", "房价", "星座", "央视新闻", "国务院",
        "朝代", "历史", "广电总局", "印发", "十五五", "规划", "问驾",
    ]

    private static let techTopicTerms = [
        // Products and parts
        "手机", "平板", "电脑", "笔记本", "芯片", "处理器", "soc", "显卡", "gpu", "cpu",
        "内存", "存储", "屏幕", "显示", "相机", "影像", "镜头", "电池", "充电", "续航",
        "散热", "系统", "更新", "软件", "app", "ai", "大模型", "模型", "开源", "算法",
        "评测", "对比", "参数", "跑分", "性能", "信号", "卫星通信", "鸿蒙", "安卓", "ios",
        "windows", "macos", "linux", "ar", "vr", "智能", "机器人", "自动驾驶", "智驾",
        "车机", "耳机", "手表", "手环", "电视", "投影", "路由器", "nas", "键鼠", "显示器",
        "imac", "macbook", "ipad", "iphone", "mac", "airpods", "watch", "pixel",
        // Leaks and launch language
        "爆料", "独家", "首发", "旗舰", "新机", "折叠", "超大杯", "大杯", "发布会", "预热",
        "供应链", "量产", "专利", "项目暂停", "变动", "前瞻", "开模", "中端机", "次旗舰",
        "产品策略", "配置", "三证", "认证", "排期",
        // Brands that are unambiguous enough to stand alone
        "华为", "小米", "荣耀", "oppo", "vivo", "iphone", "三星", "一加", "realme", "红米",
        "联想", "戴尔", "惠普", "华硕", "魅族", "努比亚", "索尼", "大疆", "特斯拉", "比亚迪",
        "问界", "极氪", "智界", "小鹏", "蔚来",
        // AI models
        "kimi", "deepseek", "chatgpt", "gpt", "claude", "gemini", "llama", "qwen", "通义",
        "文心", "豆包", "混元", "智谱", "openai", "anthropic",
    ]

    private static let dealEntityTerms = [
        // Product entity words. A transaction word alone is never enough.
        "华为", "小米", "荣耀", "oppo", "vivo", "苹果", "iphone", "三星", "一加", "realme",
        "红米", "联想", "戴尔", "惠普", "华硕", "魅族", "大疆", "索尼", "耳机", "手表",
        "平板", "手机", "电脑", "显示器", "路由器", "充电宝", "键盘", "鼠标",
    ]

    private static let specPattern = try? NSRegularExpression(
        pattern: "(?i)(\\d+(?:\\.\\d+)?\\s*(?:mah|毫安时?|英寸|寸|mp|万像素|nm|ghz|hz|gb|tb|mm|nit|fps|w))"
    )

    private static let modelPattern = try? NSRegularExpression(
        pattern: "(?i)((?:iphone|ipad|macbook|mate|pura|nova|redmi|galaxy|pixel|find|reno|magic|mix|fold)\\s?\\d{0,4}[a-z]*|[a-z]{2,10}\\s?\\d{2,4}\\s?(?:pro|max|ultra|plus|mini|air)?|(?:小米|华为|荣耀|红米|真我|一加|三星|魅族)\\s?[a-z]{0,6}\\s?\\d{1,4})"
    )

    // MARK: - Entry point

    func evaluate(
        text: String,
        imageCount: Int,
        accountBaseline: Double,
        userKeywords: [String],
        crossPostIndex: WeiboCrossPostIndex?,
        mode: WeiboRelevanceMode,
        now: Date
    ) -> WeiboPostRelevance {
        if mode == .off {
            return WeiboPostRelevance(
                adScore: 0,
                interestScore: 1,
                verdict: .relevant,
                reasons: ["filterOff"],
                decidedAt: now
            )
        }

        let normalized = text.lowercased()
        let (adScore, adReasons) = advertiseScore(
            normalized: normalized,
            original: text,
            userKeywords: userKeywords,
            crossPostIndex: crossPostIndex
        )
        let (interestScore, interestReasons) = interestScore(
            normalized: normalized,
            original: text,
            imageCount: imageCount,
            accountBaseline: accountBaseline,
            userKeywords: userKeywords
        )
        let verdict = decide(adScore: adScore, interestScore: interestScore, mode: mode)

        var reasons = adReasons
        if verdict != .filtered {
            reasons.append(contentsOf: interestReasons)
        }
        if reasons.isEmpty {
            reasons = ["neutral"]
        }

        return WeiboPostRelevance(
            adScore: Self.clamp01(adScore),
            interestScore: Self.clamp01(interestScore),
            verdict: verdict,
            reasons: Array(reasons.prefix(4)),
            decidedAt: now
        )
    }

    /// Re-runs only the verdict from fused scores. Used after a decision model
    /// answers so the stored relevance keeps one decision shape.
    func verdict(
        adScore: Double,
        interestScore: Double,
        mode: WeiboRelevanceMode
    ) -> WeiboRelevanceVerdict {
        decide(adScore: adScore, interestScore: interestScore, mode: mode)
    }

    // MARK: - Advertising

    private func advertiseScore(
        normalized: String,
        original: String,
        userKeywords: [String],
        crossPostIndex: WeiboCrossPostIndex?
    ) -> (Double, [String]) {
        var score = 0.0
        var reasons: [String] = []

        if Self.lotteryPlatformTerms.allSatisfy({ normalized.contains($0) }),
           Self.lotteryPlatformLinkTerms.allSatisfy({ normalized.contains($0) }) {
            score += 1.0
            reasons.append("lotteryPlatform")
        } else if Self.lotteryPlatformTerms.allSatisfy({ normalized.contains($0) }) {
            // @微博抽奖平台 is the official draw tool: its presence alone is
            // enough to treat the post as a giveaway.
            score += 0.65
            reasons.append("lotteryPlatform")
        }

        // "抽 N 位" alone means little; the call to action is what makes it an
        // ad. This two-part shape is what the naive keyword matching got wrong.
        // The count can be an emoji digit (1️⃣0️⃣), so the gap allows any
        // non-sentence characters.
        let hasDrawCount = Self.matches(
            normalized,
            pattern: "抽[^，。！？\\n]{0,10}(?:位|个|名|台|部|铁粉)"
        )
        let hasCallToAction = ["转发", "评论", "关注", "点赞", "留言", "转评赞"].contains {
            normalized.contains($0)
        }
        if hasDrawCount && hasCallToAction {
            score += 0.70
            reasons.append("lottery")
        } else if hasDrawCount {
            score += 0.45
            reasons.append("lotteryWeak")
        }

        let hasGiveaway = normalized.contains("送出")
        let hasGiveawayCue = ["🎁", "抽", "留言", "评论", "转发"].contains {
            normalized.contains($0)
        }
        if hasGiveaway && hasGiveawayCue {
            score += 0.55
            reasons.append("gift")
        }
        if normalized.contains("已送完") || normalized.contains("已开奖") {
            score += 0.25
            reasons.append("giftClosed")
        }

        // A brand co-run is a promotion even when no ad word appears. This is
        // the shape that a keyword-only model misses.
        let hasJointBrand = ["联合", "携手", "共同发起"].contains { normalized.contains($0) }
        let hasBrandEntity = Self.dealEntityTerms.contains { normalized.contains($0) }
        if hasJointBrand && hasBrandEntity &&
            (normalized.contains("发起") || normalized.contains("活动") || normalized.contains("合作")) {
            score += 0.45
            reasons.append("brandJoint")
        }
        if normalized.contains("做了本书") || normalized.contains("新书") {
            score += 0.45
            reasons.append("ownContent")
        }

        // Manufacturer copy-paste: the phrases a brand sends to a reviewer.
        // They are not proof of an ad on their own, but they are enough to
        // collapse the post without notifying.
        let marketingPhrases = ["官方数据显示", "满血体验", "跨代之作", "巅峰性能", "定位是"]
        if marketingPhrases.contains(where: { normalized.contains($0) }) {
            score += 0.35
            reasons.append("marketing")
        }

        var disclosure = 0.0
        for (term, weight) in Self.disclosureTerms where normalized.contains(term) {
            disclosure = max(disclosure, weight)
        }
        if disclosure > 0 {
            score += disclosure
            reasons.append("disclosure")
        }

        let hasTransaction = Self.transactionTerms.contains { normalized.contains($0) }
        let hasModelInText = Self.modelPattern.map { Self.hasMatch($0, in: original) } ?? false
        let hasDealEntity = Self.dealEntityTerms.contains { normalized.contains($0) }
            || hasModelInText
        if hasTransaction && hasDealEntity {
            score += 0.50
            reasons.append("transaction")
        } else if hasTransaction {
            // A transaction word in a news post ("购物 App 点外卖") is common.
            // Keep a little evidence but never enough to filter on its own.
            score += 0.10
            reasons.append("transactionWeak")
        }

        if Self.funnelTerms.contains(where: { normalized.contains($0) }) {
            score += 0.45
            reasons.append("funnel")
        }

        if Self.brandVoiceTerms.allSatisfy({ normalized.contains($0) }) {
            score += 0.25
            reasons.append("brandVoice")
        }

        if let crossPostIndex {
            let containment = crossPostIndex.bestContainment(for: original)
            if containment >= Self.crossPostThreshold {
                score += 0.35
                reasons.append(String(format: "crossPost:%.2f", containment))
            }
        }

        let specCount = Self.specDensity(original)
        if specCount >= 3 && score < 0.6 {
            // A dense spec sheet is the signature of a review, not a sales
            // post. It must not cancel evidence that is already strong: a
            // giveaway that lists iPhone models is still a giveaway.
            score -= 0.30
            reasons.append("specDensity")
        }

        // An explicit interest keyword is also the user's allowlist. It never
        // lifts a definite ad, but it stops a keyword coincidence from being
        // the only evidence.
        if userKeywords.contains(where: {
            let needle = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !needle.isEmpty && normalized.contains(needle)
        }) {
            score -= 0.10
            reasons.append("allowlist")
        }

        return (Self.clamp01(score), reasons)
    }

    // MARK: - Interest

    private func interestScore(
        normalized: String,
        original: String,
        imageCount: Int,
        accountBaseline: Double,
        userKeywords: [String]
    ) -> (Double, [String]) {
        var reasons: [String] = []

        let userHits = Self.uniqueHits(
            in: normalized,
            terms: userKeywords.map { $0.lowercased() }
        ).filter { !$0.isEmpty }
        let techHits = Self.uniqueHits(in: normalized, terms: Self.techTopicTerms)

        let topicStrength: Double
        if !userHits.isEmpty {
            topicStrength = 1.0
            reasons.append("userTopic")
        } else if !techHits.isEmpty {
            // On a tech account a single product or brand word is a stronger
            // signal than two words on a general account. Without this floor a
            // one-line leak reads as low confidence forever.
            topicStrength = max(0.7, min(1.0, Double(techHits.count) * 0.22))
            reasons.append("topicHit")
        } else {
            topicStrength = 0
        }

        let specCount = Self.specDensity(original)
        let contentCharacters = Self.contentCharacterCount(normalized)
        let detail = min(1.0, Double(specCount) / 3.0) * 0.6
            + min(1.0, Double(contentCharacters) / 120.0) * 0.4
        if detail >= 0.5 { reasons.append("infoDensity") }

        let structure: Double
        let distinctModels = Self.modelCount(original)
        if distinctModels >= 2 {
            structure = 1.0
            reasons.append("modelComparison")
        } else if imageCount > 0 {
            structure = 0.6
            reasons.append("mediaStructure")
        } else {
            structure = 0
        }

        let strongReverse = Self.uniqueHits(in: normalized, terms: Self.strongReverseTerms)
        let weakReverse = Self.uniqueHits(in: normalized, terms: Self.weakReverseTerms)
        let reverseHit = min(1.0, Double(strongReverse.count) * 0.6 + Double(weakReverse.count) * 0.25)
        if reverseHit > 0 { reasons.append("reverseTopic") }

        let raw = 0.55 * topicStrength
            + 0.20 * detail
            // The account baseline may only lift, never lower. A few old
            // off-topic posts must not make every new leak look irrelevant.
            + 0.15 * max(0.5, Self.clamp01(accountBaseline))
            + 0.10 * structure
            - 0.35 * reverseHit

        return (Self.clamp01(raw), reasons)
    }

    // MARK: - Decision

    private func decide(
        adScore: Double,
        interestScore: Double,
        mode: WeiboRelevanceMode
    ) -> WeiboRelevanceVerdict {
        if adScore >= mode.adFilterThreshold { return .filtered }
        if adScore >= mode.adReviewThreshold { return .lowConfidence }
        if interestScore >= mode.relevantThreshold { return .relevant }
        if interestScore >= mode.offTopicThreshold { return .lowConfidence }
        return .offTopic
    }

    // MARK: - Text helpers

    static func clamp01(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private static func uniqueHits(in text: String, terms: [String]) -> [String] {
        var hits: [String] = []
        for term in terms {
            let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, !hits.contains(needle) else { continue }
            guard containsTerm(text, needle) else { continue }
            // A longer already-matched term subsumes its shorter suffix
            // ("超大杯" over "大杯"). Order the vocabulary longest-first.
            if hits.contains(where: { $0.contains(needle) && $0 != needle }) { continue }
            hits.append(needle)
        }
        return hits
    }

    /// Short ASCII terms ("ai", "pc", "ios") must match as words, not as
    /// substrings: "said" and "bios" are not technology signals.
    private static func containsTerm(_ text: String, _ term: String) -> Bool {
        let isShortASCII = term.count <= 3
            && term.unicodeScalars.allSatisfy { $0.isASCII }
        guard isShortASCII else { return text.contains(term) }

        var searchStart = text.startIndex
        while let range = text.range(of: term, range: searchStart..<text.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == text.startIndex {
                beforeOK = true
            } else {
                let before = text[text.index(before: range.lowerBound)]
                beforeOK = !(before.isASCII && before.isLetter)
            }
            let afterOK: Bool
            if range.upperBound == text.endIndex {
                afterOK = true
            } else {
                let after = text[range.upperBound]
                afterOK = !(after.isASCII && after.isLetter)
            }
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func hasMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        !regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).isEmpty
    }

    private static func specDensity(_ text: String) -> Int {
        var count = 0
        if let specPattern {
            count += specPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).count
        }
        count += modelCount(text)
        return count
    }

    private static func modelCount(_ text: String) -> Int {
        guard let modelPattern else { return 0 }
        let matches = modelPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var seen = Set<String>()
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            seen.insert(text[range].lowercased())
        }
        return seen.count
    }

    private static func contentCharacterCount(_ text: String) -> Int {
        text.reduce(into: 0) { partial, character in
            if !character.isWhitespace && !character.isPunctuation { partial += 1 }
        }
    }
}

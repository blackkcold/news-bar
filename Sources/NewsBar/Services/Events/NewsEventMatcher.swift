import Foundation

struct NewsEventMatcher: NewsEventMatching {
    func decide(_ evidence: NewsEventEvidence, against event: NewsEvent) -> NewsEventMatchDecision {
        let incomingSubjects = Self.unique(evidence.subjectAliases + Self.inferredSubjects(in: evidence.title))
        let eventSubjects = Self.unique(event.subjectAliases + Self.inferredSubjects(in: event.title))
        guard Self.subjectsOverlap(incomingSubjects, eventSubjects) else {
            return .insufficient(reasons: ["主体别名未命中"])
        }

        let incomingText = [evidence.eventDescription, evidence.title, evidence.excerpt].joined(separator: " ")
        let existingText = [event.eventDescription, event.title].joined(separator: " ")
        let incomingTokens = Self.semanticTokens(incomingText, removing: incomingSubjects)
        let existingTokens = Self.semanticTokens(existingText, removing: eventSubjects)
        let overlap = Self.overlap(incomingTokens, existingTokens)
        let incomingAction = Self.normalized(evidence.action ?? Self.action(in: incomingText) ?? "")
        let existingAction = Self.normalized(event.action ?? Self.action(in: existingText) ?? "")
        let sameAction = !incomingAction.isEmpty && incomingAction == existingAction

        if let lhs = Self.normalizedOptional(event.location),
           let rhs = Self.normalizedOptional(evidence.location), lhs != rhs, overlap < 0.60 {
            return .separate(reasons: ["已知地点冲突", "描述重合不足以解释地点差异"])
        }
        if let lhs = event.eventTime, let rhs = evidence.eventTime,
           abs(lhs.timeIntervalSince(rhs)) > 48 * 3600, overlap < 0.60 {
            return .separate(reasons: ["已知事件时间相差超过 48 小时", "描述重合不足"])
        }

        let existingDate = event.evidence.compactMap { $0.publishedAt ?? $0.fetchedAt }.max()
        let incomingDate = evidence.publishedAt ?? evidence.fetchedAt
        if let existingDate,
           !Calendar.current.isDate(existingDate, inSameDayAs: incomingDate),
           overlap < 0.48 {
            return .separate(reasons: ["跨日期的普通报道且事件描述重合不足"])
        }

        if !incomingAction.isEmpty, !existingAction.isEmpty, !sameAction, overlap < 0.52 {
            return .separate(reasons: ["主体相同但动作不同", "事件描述重合不足"])
        }
        if overlap >= 0.22 {
            var reasons = ["主体别名命中"]
            if sameAction { reasons.append("动作一致：\(evidence.action ?? Self.action(in: incomingText) ?? "")") }
            if overlap >= 0.22 { reasons.append("事件语义描述重合") }
            return .sameEvent(reasons: reasons)
        }
        return .insufficient(reasons: ["主体命中但动作/事件描述重合不足"])
    }

    static func inferredSubjects(in text: String) -> [String] {
        let normalizedText = text.lowercased()
        let knownAliases: [[String]] = [
            ["苹果公司", "Apple"], ["特斯拉", "Tesla"], ["华为", "Huawei"],
            ["小米", "Xiaomi"], ["微软", "Microsoft"], ["谷歌", "Google"],
            ["OpenAI"], ["DeepSeek"], ["英伟达", "NVIDIA"], ["字节跳动", "ByteDance"],
            ["特朗普", "Trump"], ["拜登", "Biden"], ["马斯克", "Elon Musk"],
            ["联合国", "United Nations"], ["NASA"], ["vivo"], ["OPPO"], ["三星", "Samsung"],
        ]
        let matches = knownAliases.filter { group in
            group.contains { alias in containsAlias(alias, in: normalizedText) }
        }.flatMap { $0 }
        if !matches.isEmpty { return Self.unique(matches) }

        let lower = text.lowercased()
        let earliestAction = actionAliases
            .flatMap { canonical, aliases in aliases.map { ($0.lowercased(), canonical) } }
            .compactMap { alias, _ -> (String.Index, String)? in
                guard containsAlias(alias, in: lower), let range = lower.range(of: alias) else { return nil }
                return (range.lowerBound, alias)
            }
            .min { $0.0 < $1.0 }
        if let earliestAction {
            let prefix = String(text[..<earliestAction.0])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r:：,，。！!？?、-—"))
            if prefix.count >= 2, prefix.count <= 24 { return [prefix] }
        }
        let firstPhrase = text
            .components(separatedBy: CharacterSet(charactersIn: "：:,，。！!？?\n|"))
            .first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstPhrase.isEmpty ? [] : [firstPhrase]
    }

    static func action(in text: String) -> String? {
        let lower = text.lowercased()
        return actionAliases
            .flatMap { canonical, aliases in aliases.map { ($0.lowercased(), canonical) } }
            .compactMap { alias, canonical in containsAlias(alias, in: lower) ? (alias, canonical) : nil }
            .sorted { lhs, rhs in lhs.0.count > rhs.0.count }
            .first?.1
    }

    static func isOfficialURL(_ rawURL: String) -> Bool {
        guard let rawHost = URL(string: rawURL)?.host?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return false }

        let institutionNamespaces = [
            "gov", "gov.cn", "gov.uk", "gov.au", "govt.nz", "gov.sg", "gov.in", "go.jp", "gc.ca",
            "mil", "mil.cn", "mod.uk", "edu", "edu.cn", "edu.au", "ac.uk", "ac.jp",
        ]
        let firstPartyCompanyDomains = [
            "openai.com", "microsoft.com", "apple.com", "google.com", "tesla.com", "nvidia.com",
            "deepseek.com", "huawei.com", "xiaomi.com", "mi.com", "bytedance.com", "samsung.com",
            "vivo.com", "oppo.com", "meta.com", "amazon.com",
        ]
        return (institutionNamespaces + firstPartyCompanyDomains).contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    static func publisherKey(url rawURL: String, sourceID: String?, sourceName: String) -> String? {
        if let host = URL(string: rawURL)?.host, !host.isEmpty {
            return SourceTierCatalog.registrableDomain(host)
        }
        if let sourceID, !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? nil : "name:\(name)"
    }

    private static let actionAliases: [(String, [String])] = [
        ("发布", ["发布", "公布", "推出", "上线", "launch", "release"]),
        ("宣布", ["宣布", "官宣", "宣布将", "announce", "announced"]),
        ("回应", ["回应", "回复", "表态", "respond", "response"]),
        ("发生", ["发生", "爆发", "爆炸", "坍塌", "起火", "occurred", "explosion"]),
        ("事故", ["事故", "撞击", "坠毁", "crash", "accident"]),
        ("收购", ["收购", "并购", "acquire", "acquisition"]),
        ("起诉", ["起诉", "控告", "诉讼", "sue", "lawsuit"]),
        ("调查", ["调查", "调查组", "立案", "investigate", "probe"]),
        ("更正", ["更正", "撤回", "修正", "correct", "correction"]),
        ("离任", ["辞职", "离职", "卸任", "resign", "resignation"]),
        ("签约", ["签约", "签署", "达成协议", "sign", "agreement"]),
        ("批准", ["批准", "通过", "否决", "approve", "approved"]),
        ("故障", ["故障", "宕机", "宕掉", "停机", "服务中断", "服务异常", "系统中断", "瘫痪", "不可用", "无法访问", "outage", "downtime", "failure", "malfunction", "unavailable", "offline", "not working", "service down", "service disruption", "service outage"]),
        ("恢复", ["恢复", "恢复服务", "恢复运行", "修复", "重启", "resumed", "restored", "recovered", "service restored", "back online"]),
        ("停运", ["停运", "停摆", "停止运营", "停工", "暂停运营", "shutdown", "halted", "suspended", "shut down"]),
    ]

    private static func containsAlias(_ alias: String, in lowerText: String) -> Bool {
        guard !alias.isEmpty else { return false }
        if alias.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            let pattern = "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: alias))(?![A-Za-z0-9])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return lowerText.contains(alias)
            }
            let range = NSRange(lowerText.startIndex..<lowerText.endIndex, in: lowerText)
            return regex.firstMatch(in: lowerText, options: [], range: range) != nil
        }
        return lowerText.contains(alias)
    }

    private static func subjectsOverlap(_ lhs: [String], _ rhs: [String]) -> Bool {
        for a in lhs {
            let left = normalized(a)
            guard left.count >= 2 else { continue }
            for b in rhs {
                let right = normalized(b)
                guard right.count >= 2 else { continue }
                if left == right || left.contains(right) || right.contains(left) { return true }
            }
        }
        return false
    }

    private static func semanticTokens(_ text: String, removing aliases: [String]) -> Set<String> {
        var value = text.lowercased()
        for alias in aliases where alias.count >= 2 {
            value = value.replacingOccurrences(of: alias.lowercased(), with: " ")
        }
        let stopwords: Set<String> = [
            "报道", "消息", "最新", "相关", "多个", "一名", "表示", "记者", "今天", "目前",
            "发布", "宣布", "回应", "发生", "事故", "推出", "media", "report", "news", "launch", "release", "announce", "respond",
        ]
        return Set(tokens(value).filter { !stopwords.contains($0) })
    }

    private static func tokens(_ text: String) -> [String] {
        var latin = ""
        var chinese = ""
        var result: [String] = []
        func flushLatin() {
            if latin.count > 1 { result.append(latin) }
            latin = ""
        }
        func flushChinese() {
            let chars = Array(chinese)
            if chars.count == 1 { result.append(chinese) }
            if chars.count > 1 {
                for index in 0..<(chars.count - 1) {
                    result.append(String(chars[index]) + String(chars[index + 1]))
                }
                if chars.count > 3 {
                    for index in 0..<(chars.count - 2) {
                        result.append(String(chars[index]) + String(chars[index + 1]) + String(chars[index + 2]))
                    }
                }
            }
            chinese = ""
        }
        for character in text {
            if character.unicodeScalars.allSatisfy({ isCJK($0.value) }) {
                flushLatin()
                chinese.append(character)
            } else if character.isLetter || character.isNumber {
                flushChinese()
                latin.append(character)
            } else {
                flushLatin()
                flushChinese()
            }
        }
        flushLatin()
        flushChinese()
        return result
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    private static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let common = lhs.intersection(rhs).count
        return Double(common) / Double(min(lhs.count, rhs.count))
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = normalized(value)
        return result.isEmpty ? nil : result
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

import Foundation

struct NewsEventInputAdapter: NewsEventInputAdapting {
    func from(items: [NewsItem], kind: NewsEventInputKind, now: Date) -> [NewsEventEvidence] {
        items.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !item.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let inputKind: NewsEventInputKind = item.source.isBuiltIn ? .trend : kind
            let publisherKind: NewsEventPublisherKind
            if inputKind == .trend { publisherKind = .unknown }
            else { publisherKind = NewsEventMatcher.isOfficialURL(item.url) ? .official : .unknown }
            let fetchedAt = min(item.timestamp, now)
            let publisherKey = inputKind == .trend ? nil : NewsEventMatcher.publisherKey(
                url: item.url,
                sourceID: item.source.id,
                sourceName: item.source.displayName
            )
            let risk = NewsEventRiskClassifier.risk(in: title)
            let claim = NewsEventClaim(
                id: "item-claim:\(item.id)",
                text: title,
                risk: risk,
                status: .unverified,
                evidenceIDs: [item.id],
                scope: .core
            )
            let signal: Int?
            if inputKind == .trend, let rank = item.rank, rank > 0 {
                signal = max(1, 100 - min(99, rank) + (item.hotLabel == "爆" ? 10 : 0))
            } else {
                signal = nil
            }
            return NewsEventEvidence(
                id: item.id,
                title: title,
                url: item.url,
                excerpt: title,
                inputKind: inputKind,
                publisherKind: publisherKind,
                sourceID: item.source.id,
                sourceName: item.source.displayName,
                publisherKey: publisherKey,
                independence: .unknown,
                publishedAt: item.publishedAt,
                fetchedAt: fetchedAt,
                subjectAliases: NewsEventMatcher.inferredSubjects(in: title),
                action: NewsEventMatcher.action(in: title),
                eventDescription: title,
                claims: [claim],
                publicSignal: signal
            )
        }
    }

    func fromResearchRecord(_ record: ResearchRecord, now: Date) -> [NewsEventEvidence] {
        guard let report = record.report, !report.evidence.isEmpty else { return [] }
        let idMap = Dictionary(uniqueKeysWithValues: report.evidence.map { item in
            (item.id, Self.researchEvidenceID(recordID: record.id, item: item))
        })
        let coreText = "\(record.topic) \(record.seed.title)"
        let claims = (report.verification?.claims ?? []).map { claim in
            NewsEventClaim(
                id: "research:\(record.id):claim:\(ContentIdentity.digest(claim.claim))",
                text: claim.claim,
                risk: NewsEventRiskClassifier.risk(in: claim.claim),
                status: Self.claimStatus(claim.status),
                evidenceIDs: claim.evidenceIDs.compactMap { idMap[$0] },
                scope: Self.claimScope(claim.claim)
            )
        }
        let timeline = report.timeline.map { node in
            NewsEventTimelineNode(
                id: "research:\(record.id):timeline:\(node.id)",
                occurredAt: node.sortDate,
                text: [node.title, node.detail].filter { !$0.isEmpty }.joined(separator: " — "),
                evidenceIDs: node.evidenceIDs.compactMap { idMap[$0] }
            )
        }
        let conflicts = report.verification?.conflicts ?? []
        let coreConflicts = conflicts.filter { !Self.isDetailConflict($0) }
        let detailConflicts = conflicts.filter(Self.isDetailConflict)
        let evidenceItems = report.evidence.sorted {
            if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt < $1.fetchedAt }
            return $0.id < $1.id
        }

        return evidenceItems.enumerated().map { index, item in
            let evidenceID = Self.researchEvidenceID(recordID: record.id, item: item)
            let primaryTimeline = index == 0 ? timeline : []
            let primaryConflicts = index == 0 ? conflicts : []
            let primaryClaims = index == 0 ? claims : []
            let reportEventTime = index == 0 ? timeline.compactMap(\.occurredAt).min() : nil
            let publisherKind: NewsEventPublisherKind = NewsEventMatcher.isOfficialURL(item.url)
                ? .official : .unknown
            let syndicationGroup = item.syndicationGroup?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identity: String?
            if let syndicationGroup, !syndicationGroup.isEmpty {
                identity = "syndication:\(record.id):\(syndicationGroup)"
            } else if item.domain.isEmpty {
                identity = NewsEventMatcher.publisherKey(
                    url: item.url,
                    sourceID: record.seed.source.id,
                    sourceName: record.seed.source.displayName
                )
            } else {
                identity = SourceTierCatalog.registrableDomain(item.domain)
            }
            let fetchedAt = min(item.fetchedAt, now)
            let description = [record.topic, record.aliases.joined(separator: " "), report.overview, item.title, item.quote]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let aliases = NewsEventMatcher.inferredSubjects(in: coreText) + record.aliases + [record.topic]
            return NewsEventEvidence(
                id: evidenceID,
                title: item.title,
                url: item.url,
                excerpt: item.quote,
                inputKind: .research,
                publisherKind: publisherKind,
                sourceID: record.seed.source.id,
                sourceName: item.domain.isEmpty ? record.seed.source.displayName : item.domain,
                publisherKey: identity,
                independence: syndicationGroup?.isEmpty == false ? .syndicated : .unknown,
                publishedAt: item.publishedAt,
                fetchedAt: fetchedAt,
                subjectAliases: Array(Set(aliases)).sorted(),
                action: NewsEventMatcher.action(in: description),
                eventDescription: description,
                eventTime: reportEventTime,
                claims: primaryClaims,
                conflicts: primaryConflicts,
                coreConflicts: index == 0 ? coreConflicts : [],
                detailConflicts: index == 0 ? detailConflicts : [],
                timeline: primaryTimeline
            )
        }
    }

    private static func researchEvidenceID(recordID: String, item: EvidenceItem) -> String {
        let rawURL = item.canonicalURL.isEmpty ? item.url : item.canonicalURL
        let canonicalURL = ContentIdentity.canonicalURL(rawURL)
        let identity = canonicalURL.isEmpty ? item.id : canonicalURL
        return "research:\(recordID):\(ContentIdentity.digest(identity))"
    }

    private static func claimStatus(_ status: EvidenceStance?) -> NewsEventClaimStatus {
        switch status {
        case .some(.supports): return .supported
        case .some(.refutes): return .contested
        case .some(.unclear), .none: return .unverified
        }
    }

    private static func claimScope(_ text: String) -> NewsEventClaimScope {
        isDetailConflict(text) ? .detail : .core
    }

    /// Research conflicts are plain strings, not typed claims. Explicitly
    /// quantitative or descriptive disagreements are kept as detail conflicts;
    /// unclassified conflicts conservatively remain core conflicts.
    static func isDetailConflict(_ text: String) -> Bool {
        let lower = text.lowercased()
        let chineseDetailTerms = [
            "人数", "伤亡数字", "伤亡人数", "死亡人数", "数量", "具体数字", "数字", "金额", "价格", "成本",
            "损失", "销量", "产量", "比例", "百分比", "规格", "型号", "容量", "重量", "尺寸",
        ]
        let englishDetailTerms = [
            "casualty count", "number of", "specific figure", "amount", "price", "cost", "sales volume",
            "percentage", "model number", "capacity", "size", "quantity", "count",
        ]
        return chineseDetailTerms.contains(where: lower.contains)
            || englishDetailTerms.contains(where: { containsEnglishTerm($0, in: lower) })
            || NewsEventRiskClassifier.hasContextualRiskNumber(text)
    }

    private static func containsEnglishTerm(_ term: String, in lowerText: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: term))(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return lowerText.contains(term)
        }
        let range = NSRange(lowerText.startIndex..<lowerText.endIndex, in: lowerText)
        return regex.firstMatch(in: lowerText, options: [], range: range) != nil
    }
}

enum NewsEventRiskClassifier {
    private static let chineseHighRiskTerms = [
        "伤亡", "死亡", "遇难", "身亡", "受伤", "失踪", "失联", "伤者", "死者", "责任",
        "归责", "肇事", "凶手", "罪名", "涉嫌", "指控", "事故原因",
    ]

    private static let englishHighRiskPatterns = [
        #"\bcasualt(?:y|ies)\b"#,
        #"\bkilled\b"#,
        #"\bdead(?:ly)?\b"#,
        #"\binjur(?:ed|y|ies)\b"#,
        #"\bmissing\b"#,
        #"\bwounded\b"#,
        #"\bfatalit(?:y|ies)\b"#,
        #"\bdeath toll\b"#,
        #"\bblam(?:e|ed|es)\b"#,
        #"\bresponsib(?:ility|le|ly)\b"#,
        #"\balleg(?:ed|ation|ations)\b"#,
        #"\bsuspect(?:ed|s)?\b"#,
    ]

    private static let numericOutcomePatterns = [
        #"(?:\d+(?:,\d{3})*(?:\.\d+)?|[零〇一二两三四五六七八九十百千万亿]+)\s*(?:人|名|位)?\s*(?:死亡|遇难|身亡|受伤|伤亡|失踪|失联|被困)|(?:死亡|遇难|身亡|受伤|伤亡|失踪|失联|被困)[^。！？.!?\n]{0,10}(?:\d+(?:,\d{3})*(?:\.\d+)?|[零〇一二两三四五六七八九十百千万亿]+)"#,
        #"\b\d+(?:,\d{3})*(?:\.\d+)?\s*(?:people|persons|passengers|workers|residents)?\s*(?:were\s+|was\s+)?(?:killed|dead|injured|missing|wounded|casualties|fatalities)\b|\b(?:killed|dead|injured|missing|wounded|casualties|fatalities|death toll)\b[^.!?\n]{0,12}\b\d+(?:,\d{3})*(?:\.\d+)?\b"#,
    ]

    static func risk(in text: String) -> NewsEventClaimRisk {
        isHighRisk(text) ? .highRisk : .ordinary
    }

    static func isHighRisk(_ text: String) -> Bool {
        let lower = text.lowercased()
        if chineseHighRiskTerms.contains(where: lower.contains) { return true }
        return englishHighRiskPatterns.contains(where: { matches($0, in: text) })
            || hasContextualRiskNumber(text)
    }

    static func hasContextualRiskNumber(_ text: String) -> Bool {
        numericOutcomePatterns.contains { matches($0, in: text) }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}

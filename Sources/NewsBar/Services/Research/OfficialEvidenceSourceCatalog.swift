import Foundation

/// A fact that can be stated from a fresh, first-party source field without
/// extending it into an impact claim or relying on an AI-generated summary.
struct ResearchQuickFinding: Sendable, Equatable {
    let id: String
    let eventKey: String
    let claim: String
    let sourceID: String
    let sourceName: String
    let sourceURL: String
    let sourceTitle: String
    let sourceExcerpt: String
    let publishedAt: Date
    let checkedAt: Date
    let eventTime: Date?
    let location: String?
    let verificationBasis: NewsEventVerificationBasis

    func eventEvidence() -> NewsEventEvidence {
        let claimEvidence = NewsEventClaim(
            id: "quick-claim:\(id)",
            text: claim,
            risk: NewsEventRiskClassifier.risk(in: claim),
            status: .supported,
            evidenceIDs: [id],
            scope: .core
        )
        return NewsEventEvidence(
            id: id,
            title: sourceTitle,
            url: sourceURL,
            excerpt: sourceExcerpt,
            inputKind: .research,
            publisherKind: .official,
            sourceID: sourceID,
            sourceName: sourceName,
            publisherKey: NewsEventMatcher.publisherKey(
                url: sourceURL,
                sourceID: sourceID,
                sourceName: sourceName
            ),
            independence: .unknown,
            publishedAt: publishedAt,
            fetchedAt: checkedAt,
            subjectAliases: NewsEventMatcher.inferredSubjects(in: sourceTitle),
            action: NewsEventMatcher.action(in: sourceTitle),
            eventDescription: claim,
            eventTime: eventTime,
            location: location,
            claims: [claimEvidence],
            verificationBasis: verificationBasis
        )
    }
}

/// Conditional, on-demand cache for a small set of public first-party feeds.
/// It never changes the user's RSS subscriptions and never promotes a source
/// merely because its domain looks official.
actor OfficialEvidenceSourceCatalog {
    static let shared = OfficialEvidenceSourceCatalog()

    private struct FeedDefinition: Sendable {
        var id: String
        var name: String
        var url: String
        var allowedHosts: Set<String>
        var topicTerms: [String]
    }

    private struct FeedCache: Codable {
        var eTag: String?
        var lastModified: String?
        var checkedAt: Date
        var items: [NewsItem]
    }

    private struct FileState: Codable {
        var version: Int
        var feeds: [String: FeedCache]
        var feedAttemptedAt: [String: Date]
        var usgsAttemptedAt: Date?
        var usgsCheckedAt: Date?
        var usgsFeatures: [USGSFeature]
    }

    private struct USGSFeatureCollection: Decodable {
        var features: [USGSFeature]
    }

    private struct USGSFeature: Codable, Sendable, Equatable {
        var id: String
        var properties: Properties

        struct Properties: Codable, Sendable, Equatable {
            var magnitude: Double?
            var place: String?
            var timeMilliseconds: Int64?
            var updatedMilliseconds: Int64?
            var status: String?
            var url: String?
            var title: String?

            enum CodingKeys: String, CodingKey {
                case magnitude = "mag"
                case place, status, url, title
                case timeMilliseconds = "time"
                case updatedMilliseconds = "updated"
            }
        }
    }

    private static let feeds: [FeedDefinition] = [
        FeedDefinition(
            id: "nbs.latest",
            name: "国家统计局",
            url: "https://www.stats.gov.cn/sj/zxfb/rss.xml",
            allowedHosts: ["stats.gov.cn", "www.stats.gov.cn"],
            topicTerms: ["统计", "经济", "gdp", "cpi", "ppi", "物价", "人口", "制造业", "投资", "贸易", "工业", "服务业"]
        ),
        FeedDefinition(
            id: "hk.isd.general.zh",
            name: "香港政府新闻处",
            url: "https://www.info.gov.hk/gia/rss/general_zh.xml",
            allowedHosts: ["info.gov.hk", "www.info.gov.hk"],
            topicTerms: ["香港", "港府", "特区", "香港政府", "香港特别行政区"]
        ),
    ]

    private static let usgsURL = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson"
    private static let feedRefreshInterval: TimeInterval = 60 * 60
    private static let usgsRefreshInterval: TimeInterval = 15 * 60
    private static let evidenceFreshness: TimeInterval = 24 * 60 * 60

    private var state: FileState?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func findings(
        for candidates: [ResearchCandidateItem],
        now moment: Date? = nil
    ) async -> [ResearchQuickFinding] {
        loadIfNeeded()
        let current = moment ?? now()
        let relevantFeeds = Set(candidates.flatMap { candidate in
            Self.feeds.filter { Self.matchesTopic(candidate.item.title, terms: $0.topicTerms) }.map(\.id)
        })
        for feed in Self.feeds where relevantFeeds.contains(feed.id) {
            await refresh(feed, now: current)
        }

        let needsUSGS = candidates.contains { Self.isEarthquakeTopic($0.item.title) }
        if needsUSGS { await refreshUSGS(now: current) }

        var findings: [ResearchQuickFinding] = []
        for candidate in candidates {
            for feed in Self.feeds
                where relevantFeeds.contains(feed.id)
                    && Self.matchesTopic(candidate.item.title, terms: feed.topicTerms) {
                guard let cache = state?.feeds[feed.id],
                      let item = cache.items.first(where: { Self.exactMatch(candidate.item, officialItem: $0) }),
                      let finding = Self.rssFinding(item, sourceID: feed.id, sourceName: feed.name, allowedHosts: feed.allowedHosts, now: current) else {
                    continue
                }
                findings.append(finding)
            }
            if needsUSGS, Self.isEarthquakeTopic(candidate.item.title),
               let feature = state?.usgsFeatures.first(where: { Self.matchesUSGS(candidate.item.title, feature: $0) }),
               let finding = Self.usgsFinding(feature, now: current) {
                findings.append(finding)
            }
        }

        var seen: Set<String> = []
        return findings.filter { seen.insert($0.eventKey).inserted }
    }

    private func refresh(_ feed: FeedDefinition, now current: Date) async {
        let previous = state?.feeds[feed.id]
        if let checkedAt = previous?.checkedAt,
           current.timeIntervalSince(checkedAt) < Self.feedRefreshInterval { return }
        if let attemptedAt = state?.feedAttemptedAt[feed.id],
           current.timeIntervalSince(attemptedAt) < Self.feedRefreshInterval { return }
        state?.feedAttemptedAt[feed.id] = current
        persist()
        do {
            let result = try await RSSService.fetchConditional(
                url: feed.url,
                sourceName: feed.name,
                eTag: previous?.eTag,
                lastModified: previous?.lastModified,
                allowEmpty: true
            )
            switch result {
            case let .modified(items, eTag, lastModified):
                state?.feeds[feed.id] = FeedCache(
                    eTag: eTag,
                    lastModified: lastModified,
                    checkedAt: current,
                    items: Array(items.prefix(100))
                )
            case let .notModified(eTag, lastModified):
                guard var previous else { return }
                previous.eTag = eTag
                previous.lastModified = lastModified
                previous.checkedAt = current
                state?.feeds[feed.id] = previous
            }
            persist()
        } catch is CancellationError {
            return
        } catch {
            // A failed or stale feed does not become evidence. Keep only its
            // previous cache and allow the cooldown to expire before retry.
            return
        }
    }

    private func refreshUSGS(now current: Date) async {
        if let checkedAt = state?.usgsCheckedAt,
           current.timeIntervalSince(checkedAt) < Self.usgsRefreshInterval { return }
        if let attemptedAt = state?.usgsAttemptedAt,
           current.timeIntervalSince(attemptedAt) < Self.usgsRefreshInterval { return }
        state?.usgsAttemptedAt = current
        persist()
        guard let url = SecurityPolicies.validatePublicHTTPURL(Self.usgsURL).url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        do {
            let (data, response) = try await PrivateHTTP.data(
                for: request,
                maxBytes: 1_500_000,
                allowedContentTypes: ["application/geo+json", "application/json"],
                timeout: 12,
                redirectPolicy: .deny
            )
            guard (200...299).contains(response.statusCode) else { return }
            let collection = try JSONDecoder().decode(USGSFeatureCollection.self, from: data)
            state?.usgsFeatures = Array(collection.features.prefix(500))
            state?.usgsCheckedAt = current
            persist()
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func loadIfNeeded() {
        guard state == nil else { return }
        if let data = try? Data(contentsOf: ResearchPaths.officialSourceCatalogFile),
           let decoded = try? JSONDecoder().decode(FileState.self, from: data),
           decoded.version == 1 {
            state = decoded
        } else {
            state = FileState(
                version: 1,
                feeds: [:],
                feedAttemptedAt: [:],
                usgsAttemptedAt: nil,
                usgsCheckedAt: nil,
                usgsFeatures: []
            )
        }
    }

    private func persist() {
        guard let state,
              let data = try? JSONEncoder().encode(state) else { return }
        try? PrivateFile.write(data, to: ResearchPaths.officialSourceCatalogFile, durable: false)
    }

    private static func matchesTopic(_ title: String, terms: [String]) -> Bool {
        let text = title.lowercased()
        return terms.contains { text.contains($0.lowercased()) }
    }

    private static func isEarthquakeTopic(_ title: String) -> Bool {
        let text = title.lowercased()
        return ["地震", "earthquake", "seismic", "magnitude", "震级"].contains(where: text.contains)
    }

    private static func exactMatch(_ candidate: NewsItem, officialItem: NewsItem) -> Bool {
        let sameURL = !candidate.url.isEmpty
            && ContentIdentity.canonicalURL(candidate.url) == ContentIdentity.canonicalURL(officialItem.url)
        let sameHeadline = TopicFingerprint.normalized(candidate.title)
            == TopicFingerprint.normalized(officialItem.title)
        return sameURL || sameHeadline
    }

    private static func rssFinding(
        _ item: NewsItem,
        sourceID: String,
        sourceName: String,
        allowedHosts: Set<String>,
        now current: Date
    ) -> ResearchQuickFinding? {
        let sourceURL = item.readerURL ?? item.url
        guard let publishedAt = item.publishedAt,
              current.timeIntervalSince(publishedAt) >= -300,
              current.timeIntervalSince(publishedAt) <= evidenceFreshness,
              let host = URL(string: sourceURL)?.host?.lowercased(),
              allowedHosts.contains(host),
              SecurityPolicies.validatePublicHTTPURL(sourceURL).url != nil else { return nil }
        let evidenceID = "quick:official:\(ContentIdentity.digest("\(sourceID)\n\(ContentIdentity.canonicalURL(sourceURL))\n\(publishedAt.timeIntervalSince1970)"))"
        let headline = SecurityPolicies.sanitizeHTMLContent(item.title)
        guard !headline.isEmpty else { return nil }
        let claim = "\(sourceName)发布：\(headline)"
        return ResearchQuickFinding(
            id: evidenceID,
            eventKey: ContentIdentity.digest("official\n\(sourceID)\n\(TopicFingerprint.normalized(headline))"),
            claim: claim,
            sourceID: sourceID,
            sourceName: sourceName,
            sourceURL: sourceURL,
            sourceTitle: headline,
            sourceExcerpt: String((item.excerpt ?? headline).prefix(1_200)),
            publishedAt: publishedAt,
            checkedAt: current,
            eventTime: nil,
            location: nil,
            verificationBasis: .officialOriginalFields
        )
    }

    private static func matchesUSGS(_ candidateTitle: String, feature: USGSFeature) -> Bool {
        let properties = feature.properties
        guard let magnitude = properties.magnitude,
              let place = properties.place,
              let title = properties.title,
              !title.isEmpty else { return false }
        let candidate = TopicFingerprint.normalized(candidateTitle).lowercased()
        let officialTitle = TopicFingerprint.normalized(title).lowercased()
        if candidate == officialTitle || candidate.contains(officialTitle) { return true }
        let normalizedPlace = TopicFingerprint.normalized(place).lowercased()
        guard normalizedPlace.count >= 6, candidate.contains(normalizedPlace) else { return false }
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\bM\\s*([0-9]+(?:\\.[0-9]+)?)") else { return false }
        let range = NSRange(candidateTitle.startIndex..<candidateTitle.endIndex, in: candidateTitle)
        guard let match = regex.firstMatch(in: candidateTitle, range: range),
              let valueRange = Range(match.range(at: 1), in: candidateTitle),
              let candidateMagnitude = Double(candidateTitle[valueRange]) else { return false }
        return abs(candidateMagnitude - magnitude) < 0.0001
    }

    private static func usgsFinding(_ feature: USGSFeature, now current: Date) -> ResearchQuickFinding? {
        let properties = feature.properties
        guard let magnitude = properties.magnitude,
              let place = properties.place,
              let title = properties.title,
              let url = properties.url,
              let eventMilliseconds = properties.timeMilliseconds,
              let updatedMilliseconds = properties.updatedMilliseconds,
              SecurityPolicies.validatePublicHTTPURL(url).url != nil,
              URL(string: url)?.host?.lowercased() == "earthquake.usgs.gov" else { return nil }
        let eventTime = Date(timeIntervalSince1970: TimeInterval(eventMilliseconds) / 1_000)
        let publishedAt = Date(timeIntervalSince1970: TimeInterval(updatedMilliseconds) / 1_000)
        guard current.timeIntervalSince(publishedAt) >= -300,
              current.timeIntervalSince(publishedAt) <= evidenceFreshness,
              current.timeIntervalSince(eventTime) >= -300,
              current.timeIntervalSince(eventTime) <= evidenceFreshness else { return nil }
        let sourceID = "usgs.earthquake.\(feature.id)"
        let titleText = SecurityPolicies.sanitizeHTMLContent(title)
        let fields = [
            "event_id=\(feature.id)",
            "magnitude=\(magnitude)",
            "place=\(place)",
            "time=\(ISO8601DateFormatter().string(from: eventTime))",
            properties.status.map { "status=\($0)" },
        ].compactMap { $0 }
        let claim = "USGS 地震记录字段：\(fields.joined(separator: "；"))"
        let evidenceID = "quick:usgs:\(ContentIdentity.digest("\(feature.id)\n\(updatedMilliseconds)"))"
        return ResearchQuickFinding(
            id: evidenceID,
            eventKey: "usgs:\(feature.id)",
            claim: claim,
            sourceID: sourceID,
            sourceName: "USGS",
            sourceURL: url,
            sourceTitle: titleText,
            sourceExcerpt: String(fields.joined(separator: "\n").prefix(1_200)),
            publishedAt: publishedAt,
            checkedAt: current,
            eventTime: eventTime,
            location: place,
            verificationBasis: .officialOriginalFields
        )
    }
}

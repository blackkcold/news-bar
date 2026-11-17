import Foundation

enum WorkspaceSourceMetricsBuilder {
    static func metrics(event: NewsEvent?, research: ResearchRecord?) -> WorkspaceSourceMetrics {
        let reportEvidence = research?.report?.evidence ?? []

        // Canonical URL first, then syndication group, then registrable domain.
        var byURL: [String: EvidenceItem] = [:]
        for item in reportEvidence where byURL[item.canonicalURL] == nil {
            byURL[item.canonicalURL] = item
        }
        var groupRepresentative: [String: EvidenceItem] = [:]
        var ungrouped: [EvidenceItem] = []
        for item in byURL.values {
            if let group = item.syndicationGroup, !group.isEmpty {
                if groupRepresentative[group] == nil {
                    groupRepresentative[group] = item
                }
            } else {
                ungrouped.append(item)
            }
        }
        let deduped = ungrouped + Array(groupRepresentative.values)
        let domains = Set(deduped.map { item in
            item.domain.isEmpty ? item.canonicalURL : item.domain
        })

        // The validator is the authority. Recomputing a different number here
        // is what makes the metric disagree with the report itself.
        let independent: Int
        if let verification = research?.report?.verification {
            independent = verification.independentSources
        } else {
            independent = domains.count
        }

        let publishers = NewsEventSourceResolver().countablePublisherCount(
            in: event?.evidence ?? []
        )
        let eligible = event?.notificationEligibility == .eligible

        return WorkspaceSourceMetrics(
            researchIndependentSourceCount: independent,
            researchUniqueDomainCount: domains.count,
            notificationPublisherCount: publishers,
            notificationEligible: eligible,
            basis: "research: \(independent) independent / \(domains.count) domains; notification: \(publishers) publishers"
        )
    }
}

struct WorkspaceDetailBuilder: Sendable {
    init() {}

    func build(
        subject: WorkspaceSubject,
        event: NewsEvent?,
        research: ResearchRecord?,
        versions: [WorkspaceReportVersion],
        updates: [WorkspaceUpdateCandidate]
    ) -> WorkspaceDetail {
        let evidence = mergedEvidence(event: event, research: research)
        let timeline = mergedTimeline(event: event, research: research)
        let metrics = WorkspaceSourceMetricsBuilder.metrics(event: event, research: research)
        let sortedVersions = versions.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
            return lhs.id < rhs.id
        }
        let sortedUpdates = updates.sorted { lhs, rhs in
            if lhs.discoveredAt != rhs.discoveredAt {
                return lhs.discoveredAt > rhs.discoveredAt
            }
            return lhs.id < rhs.id
        }
        return WorkspaceDetail(
            subject: subject,
            event: event,
            research: research,
            versions: sortedVersions,
            evidence: evidence,
            timeline: timeline,
            metrics: metrics,
            updates: sortedUpdates
        )
    }

    // MARK: - Evidence

    private func mergedEvidence(
        event: NewsEvent?,
        research: ResearchRecord?
    ) -> [WorkspaceEvidence] {
        let eventEvidence = event?.evidence ?? []
        var eventKeys: Set<String> = []
        for item in eventEvidence {
            let key = Self.evidenceKey(
                canonicalURL: ContentIdentity.canonicalURL(item.url),
                quote: item.excerpt
            )
            eventKeys.insert(key)
        }

        var rows: [WorkspaceEvidence] = []
        var emittedKeys: Set<String> = []

        for item in research?.report?.evidence ?? [] {
            let key = Self.evidenceKey(canonicalURL: item.canonicalURL, quote: item.quote)
            let shared = eventKeys.contains(key)
            rows.append(
                WorkspaceEvidence(
                    id: ContentIdentity.digest(
                        "workspace-evidence-research\n\(item.canonicalURL)\n\(QuoteVerifier.normalize(item.quote))"
                    ),
                    title: item.title,
                    url: item.url,
                    canonicalURL: item.canonicalURL,
                    quote: item.quote,
                    publishedAt: item.publishedAt,
                    sourceName: item.domain,
                    origin: .research,
                    verification: item.quoteVerified ? .verifiedQuote : .unverifiedQuote,
                    tier: item.tier,
                    independence: nil,
                    sharedWithEvent: shared
                )
            )
            emittedKeys.insert(key)
        }

        for item in eventEvidence {
            let canonical = ContentIdentity.canonicalURL(item.url)
            let key = Self.evidenceKey(canonicalURL: canonical, quote: item.excerpt)
            if emittedKeys.contains(key) { continue }
            rows.append(
                WorkspaceEvidence(
                    id: ContentIdentity.digest(
                        "workspace-evidence-event\n\(canonical)\n\(QuoteVerifier.normalize(item.excerpt))"
                    ),
                    title: item.title,
                    url: item.url,
                    canonicalURL: canonical,
                    quote: item.excerpt,
                    publishedAt: item.publishedAt,
                    sourceName: item.sourceName,
                    origin: .event,
                    verification: .snippetOnly,
                    tier: nil,
                    independence: item.independence,
                    sharedWithEvent: false
                )
            )
            emittedKeys.insert(key)
        }

        return rows.sorted { lhs, rhs in
            if lhs.origin != rhs.origin { return lhs.origin == .research }
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (left?, right?):
                if left != right { return left > right }
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): break
            }
            return lhs.id < rhs.id
        }
    }

    private static func evidenceKey(canonicalURL: String, quote: String) -> String {
        canonicalURL + "\u{1F}" + QuoteVerifier.normalize(quote)
    }

    // MARK: - Timeline

    private func mergedTimeline(
        event: NewsEvent?,
        research: ResearchRecord?
    ) -> [WorkspaceTimelineEntry] {
        var entries: [WorkspaceTimelineEntry] = []

        for node in event?.timeline ?? [] {
            entries.append(
                WorkspaceTimelineEntry(
                    id: "event:\(node.id)",
                    occurredAt: node.occurredAt,
                    text: node.text,
                    origin: .event,
                    evidenceIDs: node.evidenceIDs,
                    confidence: nil
                )
            )
        }

        for node in research?.report?.timeline ?? [] {
            let text = [node.title, node.detail]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            entries.append(
                WorkspaceTimelineEntry(
                    id: "research:\(node.id)",
                    occurredAt: node.sortDate,
                    text: text,
                    origin: .research,
                    evidenceIDs: node.evidenceIDs,
                    confidence: node.confidence
                )
            )
        }

        return entries.sorted { lhs, rhs in
            switch (lhs.occurredAt, rhs.occurredAt) {
            case let (left?, right?):
                if left != right { return left > right }
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): break
            }
            return lhs.id < rhs.id
        }
    }
}

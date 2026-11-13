import Foundation

struct NewsEventSourceResolver: NewsEventSourceResolving {
    func groups(for evidence: [NewsEventEvidence]) -> [NewsEventSourceGroup] {
        var grouped: [String: [NewsEventEvidence]] = [:]
        var groupKeys: [String: (displayName: String, key: String?, kind: NewsEventPublisherKind, syndicated: Bool)] = [:]

        for item in evidence {
            let classifiedKind = Self.classifiedKind(for: item)
            let attributedWire = Self.attributedWireKey(in: item)
            let rawKey = attributedWire ?? item.publisherKey
            let groupKey: String
            if item.inputKind == .trend {
                groupKey = "trend:\(item.sourceID ?? item.sourceName.lowercased())"
            } else if let rawKey, !rawKey.isEmpty {
                groupKey = rawKey
            } else if let sourceID = item.sourceID, !sourceID.isEmpty {
                groupKey = "unknown-source:\(sourceID.lowercased())"
            } else {
                let name = item.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                groupKey = name.isEmpty ? "unidentified:\(item.id)" : "unknown-name:\(name)"
            }
            grouped[groupKey, default: []].append(item)
            let existing = groupKeys[groupKey]
            let hasIdentity = rawKey != nil
                || !(item.sourceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !item.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isExplicitlySyndicated = rawKey?.hasPrefix("syndication:") == true
            let groupPublisherKey = item.inputKind == .trend ? nil : (rawKey ?? (hasIdentity ? groupKey : nil))
            groupKeys[groupKey] = (
                existing?.displayName ?? (attributedWire == nil ? item.sourceName : Self.wireDisplayName(attributedWire!)),
                groupPublisherKey,
                Self.preferredKind(existing?.kind, classifiedKind),
                existing?.syndicated == true || attributedWire != nil || isExplicitlySyndicated
            )
        }

        return grouped.keys.sorted().compactMap { key in
            guard let items = grouped[key], let metadata = groupKeys[key] else { return nil }
            let kind: NewsEventPublisherKind = items.allSatisfy { $0.inputKind == .trend }
                ? .unknown : metadata.kind
            let independence: NewsEventIndependence
            if metadata.syndicated { independence = .syndicated }
            else if items.count > 1 { independence = .samePublisher }
            else { independence = items.first?.independence ?? .unknown }
            return NewsEventSourceGroup(
                id: key,
                displayName: metadata.displayName,
                publisherKey: metadata.key,
                publisherKind: kind,
                independence: independence,
                evidenceIDs: items.map(\.id).sorted()
            )
        }
    }

    func countablePublisherCount(in evidence: [NewsEventEvidence]) -> Int {
        Set(groups(for: evidence).filter { group in
            guard group.publisherKind != .official else { return false }
            return group.evidenceIDs.contains { id in
                evidence.first(where: { $0.id == id })?.inputKind != .trend
            }
        }.compactMap(\.publisherKey)).count
    }

    private static func preferredKind(
        _ lhs: NewsEventPublisherKind?,
        _ rhs: NewsEventPublisherKind
    ) -> NewsEventPublisherKind {
        if lhs == .official || rhs == .official { return .official }
        if lhs == .newsPublisher || rhs == .newsPublisher { return .newsPublisher }
        return .unknown
    }

    private static func classifiedKind(for evidence: NewsEventEvidence) -> NewsEventPublisherKind {
        guard evidence.inputKind != .trend else { return .unknown }
        if NewsEventMatcher.isOfficialURL(evidence.url) { return .official }
        // Do not let a free-form or legacy `.official` label override URL attribution.
        return evidence.publisherKind == .official ? .unknown : evidence.publisherKind
    }

    private static func attributedWireKey(in evidence: NewsEventEvidence) -> String? {
        let text = "\(evidence.sourceName)\n\(evidence.title)\n\(evidence.excerpt)".lowercased()
        let matches: [(String, [String])] = [
            ("wire:xinhua", ["据新华社", "新华社电", "新华社报道", "来源：新华社", "来源:新华社"]),
            ("wire:reuters", ["据路透社", "路透社报道", "路透社消息", "reuters reports"]),
            ("wire:ap", ["据美联社", "美联社报道", "associated press"]),
            ("wire:afp", ["据法新社", "法新社报道", "afp reports"]),
        ]
        return matches.first { _, aliases in aliases.contains(where: text.contains) }?.0
    }

    private static func wireDisplayName(_ key: String) -> String {
        switch key {
        case "wire:xinhua": return "新华社稿"
        case "wire:reuters": return "路透社稿"
        case "wire:ap": return "美联社稿"
        case "wire:afp": return "法新社稿"
        default: return "同一通讯社稿"
        }
    }
}

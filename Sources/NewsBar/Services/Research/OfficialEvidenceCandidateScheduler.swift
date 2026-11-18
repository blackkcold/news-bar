import Foundation

/// Selects a small, durable set of automatic research candidates for the
/// optional official-source lookup. Manual research never calls this scheduler.
actor OfficialEvidenceCandidateScheduler {
    static let shared = OfficialEvidenceCandidateScheduler()
    static let maximumCandidatesPerRollingHour = 2
    private static let deduplicationWindow: TimeInterval = 60 * 60

    private struct State: Codable {
        var version = 1
        var selectedAtByEventKey: [String: Date] = [:]
    }

    private var state = State()
    private var didLoad = false
    private var readOnly = false

    private var fileURL: URL {
        ResearchPaths.applicationSupportRoot
            .appendingPathComponent("Notifications", isDirectory: true)
            .appendingPathComponent("official-evidence-candidate-schedule-v1.json")
    }

    /// Reserves up to two distinct public-impact candidates before any source
    /// request begins. A failed source lookup still consumes its short window,
    /// so repeated feed refreshes cannot repeatedly fetch the same event.
    func select(
        from candidates: [ResearchCandidateItem],
        now: Date = Date()
    ) -> [ResearchCandidateItem] {
        guard loadIfNeeded() else { return [] }
        let retentionCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let beforePruneCount = state.selectedAtByEventKey.count
        state.selectedAtByEventKey = state.selectedAtByEventKey.filter { $0.value >= retentionCutoff }
        var didPrune = beforePruneCount != state.selectedAtByEventKey.count

        let recentKeys = Set(state.selectedAtByEventKey.compactMap { key, selectedAt in
            let age = now.timeIntervalSince(selectedAt)
            return age >= 0 && age < Self.deduplicationWindow ? key : nil
        })
        let availableSlots = max(0, Self.maximumCandidatesPerRollingHour - recentKeys.count)
        var seenKeys = recentKeys
        var selected: [ResearchCandidateItem] = []
        for candidate in candidates.sorted(by: Self.preferredCandidate) {
            guard selected.count < availableSlots else { break }
            let key = Self.eventKey(for: candidate)
            guard seenKeys.insert(key).inserted else { continue }
            selected.append(candidate)
        }

        for candidate in selected {
            state.selectedAtByEventKey[Self.eventKey(for: candidate)] = now
        }
        if state.selectedAtByEventKey.count > 2_000 {
            didPrune = true
            let retainedKeys = Set(state.selectedAtByEventKey
                .sorted { $0.value > $1.value }
                .prefix(2_000)
                .map(\.key))
            state.selectedAtByEventKey = state.selectedAtByEventKey.filter {
                retainedKeys.contains($0.key)
            }
        }

        if selected.isEmpty && !didPrune { return [] }
        guard persist() else { return [] }
        return selected
    }

    private func loadIfNeeded() -> Bool {
        guard !didLoad else { return !readOnly }
        didLoad = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(State.self, from: data),
              decoded.version == 1 else {
            readOnly = true
            NSLog("[OfficialEvidenceCandidateScheduler] Existing schedule could not be decoded; automatic source lookup is paused.")
            return false
        }
        state = decoded
        return true
    }

    private func persist() -> Bool {
        guard !readOnly else { return false }
        do {
            try PrivateFile.write(try JSONEncoder().encode(state), to: fileURL, durable: true)
            return true
        } catch {
            readOnly = true
            NSLog("[OfficialEvidenceCandidateScheduler] Could not persist candidate slots: %@", error.localizedDescription)
            return false
        }
    }

    private static func eventKey(for candidate: ResearchCandidateItem) -> String {
        if let eventID = candidate.eventID, !eventID.isEmpty { return "event:\(eventID)" }
        let topicKey = candidate.topicKey
        if !topicKey.isEmpty { return "topic:\(topicKey)" }
        let url = ContentIdentity.canonicalURL(candidate.item.url)
        if !url.isEmpty { return "url:\(url)" }
        return "item:\(candidate.item.id)"
    }

    private static func preferredCandidate(
        _ lhs: ResearchCandidateItem,
        _ rhs: ResearchCandidateItem
    ) -> Bool {
        let lhsPublicImpact = lhs.kind == .publicImpact
        let rhsPublicImpact = rhs.kind == .publicImpact
        if lhsPublicImpact != rhsPublicImpact { return lhsPublicImpact }
        if lhs.isUrgent != rhs.isUrgent { return lhs.isUrgent }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.item.publishedAt != rhs.item.publishedAt {
            return (lhs.item.publishedAt ?? .distantPast) > (rhs.item.publishedAt ?? .distantPast)
        }
        let lhsKey = eventKey(for: lhs)
        let rhsKey = eventKey(for: rhs)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhs.item.id < rhs.item.id
    }
}

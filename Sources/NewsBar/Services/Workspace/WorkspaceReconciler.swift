import Foundation

/// Builds/updates subjects from the authoritative research index and event
/// store. It never writes a research record or event, never follows a subject
/// and never merges two event-backed subjects by URL/title alone.
struct WorkspaceReconciler: Sendable {
    init() {}

    func reconcile(
        research: [ResearchIndexEntry],
        events: [NewsEvent],
        existing: [WorkspaceSubject],
        now: Date,
        /// Optional report-evidence URLs keyed by record. Stage 4 can supply
        /// them from full records; the index alone only carries the seed URL.
        evidenceURLsByRecordID: [String: Set<String>] = [:]
    ) -> WorkspaceReconcileResult {
        var subjects = existing
        let initialByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var retiredIDs: Set<String> = []
        var changedIDs: Set<String> = []
        var createdIDs: Set<String> = []

        let usableResearch = research
            .filter { $0.issue == nil && !$0.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.id < $1.id }
        let orderedEvents = events.sorted { $0.id < $1.id }

        var researchSeedURLs: [String: String] = [:]   // canonical -> subject id
        var researchLatest: [String: Date] = [:]
        var eventLatest: [String: Date] = [:]
        var hadLinksAtStart: Set<String> = []

        for subject in subjects where !subject.researchRecordIDs.isEmpty || !subject.eventIDs.isEmpty {
            hadLinksAtStart.insert(subject.id)
        }

        func subjectIndex(id: String) -> Int? {
            subjects.firstIndex { $0.id == id && !retiredIDs.contains($0.id) }
        }

        func subject(containingKey key: String) -> Int? {
            subjects.firstIndex {
                !retiredIDs.contains($0.id) && $0.lookupKeys.contains(key)
            }
        }

        func subject(containingResearch id: String) -> Int? {
            subjects.firstIndex {
                !retiredIDs.contains($0.id)
                    && ($0.researchRecordIDs.contains(id)
                        || $0.lookupKeys.contains("research:\(id)"))
            }
        }

        func subject(containingEvent id: String) -> Int? {
            subjects.firstIndex {
                !retiredIDs.contains($0.id)
                    && ($0.eventIDs.contains(id)
                        || $0.lookupKeys.contains("event:\(id)"))
            }
        }

        func subjectMatchingExactTitle(_ title: String, allowEventBacked: Bool) -> Int? {
            let key = TopicFingerprint.normalized(title)
            guard !key.isEmpty else { return nil }
            let candidates = subjects.indices.filter { index in
                let subject = subjects[index]
                guard !retiredIDs.contains(subject.id) else { return false }
                guard allowEventBacked || subject.eventIDs.isEmpty else { return false }
                if TopicFingerprint.normalized(subject.title) == key { return true }
                return subject.aliases.contains {
                    TopicFingerprint.normalized($0) == key
                }
            }
            guard !candidates.isEmpty else { return nil }
            let topicCandidates = candidates.filter { subjects[$0].eventIDs.isEmpty }
            if let best = topicCandidates.min(by: { lhs, rhs in
                if subjects[lhs].createdAt != subjects[rhs].createdAt {
                    return subjects[lhs].createdAt < subjects[rhs].createdAt
                }
                return subjects[lhs].id < subjects[rhs].id
            }) {
                return best
            }
            if allowEventBacked, candidates.count == 1 {
                return candidates[0]
            }
            return nil
        }

        func createSubject(title: String, kind: WorkspaceSubjectKind) -> Int {
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = WorkspaceSubject(
                title: cleaned.isEmpty ? "未命名主题" : cleaned,
                aliases: [],
                kind: kind,
                createdAt: now,
                updatedAt: now,
                lastActivityAt: now,
                isFollowed: false,
                isArchived: false,
                archivedAt: nil,
                updateState: .current,
                lastCheckedAt: nil,
                lastCheckOutcome: .notConfigured,
                pendingUpdateIDs: [],
                researchRecordIDs: [],
                eventIDs: [],
                lookupKeys: [],
                schemaVersion: WorkspaceSubject.currentSchemaVersion
            )
            subjects.append(subject)
            createdIDs.insert(subject.id)
            return subjects.count - 1
        }

        func merge(_ sourceID: String, into targetID: String) {
            guard sourceID != targetID,
                  let sourceIndex = subjectIndex(id: sourceID),
                  let targetIndex = subjectIndex(id: targetID) else { return }
            let source = subjects[sourceIndex]
            var target = subjects[targetIndex]

            target.researchRecordIDs = Self.orderedUnion(
                target.researchRecordIDs,
                source.researchRecordIDs
            )
            target.eventIDs = Self.orderedUnion(target.eventIDs, source.eventIDs)
            target.lookupKeys = Self.orderedUnion(target.lookupKeys, source.lookupKeys)
            target.lookupKeys = Self.orderedUnion(
                target.lookupKeys,
                ["subject:\(source.id)"]
            )
            target.aliases = Self.mergedAliases(
                target.aliases,
                title: target.title,
                adding: [source.title] + source.aliases
            )
            target.isFollowed = target.isFollowed || source.isFollowed
            if source.isArchived {
                target.isArchived = true
                if target.archivedAt == nil {
                    target.archivedAt = source.archivedAt ?? now
                }
            }
            target.seedURL = target.seedURL ?? source.seedURL
            target.userRevision = max(target.userRevision, source.userRevision)
            target.pendingUpdateIDs = Self.orderedUnion(
                target.pendingUpdateIDs,
                source.pendingUpdateIDs
            )
            target.updateState = Self.strongest(target.updateState, source.updateState)
            if (source.lastCheckedAt ?? .distantPast) > (target.lastCheckedAt ?? .distantPast) {
                target.lastCheckedAt = source.lastCheckedAt
                target.lastCheckOutcome = source.lastCheckOutcome
            }
            if (source.lastNotifiedAt ?? .distantPast) > (target.lastNotifiedAt ?? .distantPast) {
                target.lastNotifiedAt = source.lastNotifiedAt
                target.lastNotificationKind = source.lastNotificationKind
                target.lastNotifiedReference = source.lastNotifiedReference
            }
            target.createdAt = min(target.createdAt, source.createdAt)
            target.lastActivityAt = max(target.lastActivityAt, source.lastActivityAt)
            target.updatedAt = max(target.updatedAt, source.updatedAt)
            if target.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                target.title = source.title
            }
            target.kind = target.recomputedKind
            subjects[targetIndex] = target

            retiredIDs.insert(source.id)
            changedIDs.insert(target.id)
            if hadLinksAtStart.contains(source.id) {
                hadLinksAtStart.insert(target.id)
            }
            researchLatest[target.id] = max(
                researchLatest[target.id] ?? .distantPast,
                researchLatest[source.id] ?? .distantPast
            )
            eventLatest[target.id] = max(
                eventLatest[target.id] ?? .distantPast,
                eventLatest[source.id] ?? .distantPast
            )
            for (url, subjectID) in researchSeedURLs where subjectID == source.id {
                researchSeedURLs[url] = target.id
            }
            // A canonical subject that was itself created during this pass is
            // no longer "new" if it absorbed an existing one.
            createdIDs.remove(target.id)
            if initialByID[target.id] == nil {
                createdIDs.insert(target.id)
            }
        }

        // 1. Research entries. Explicit record/topic key wins, then exact title.
        for entry in usableResearch {
            let index = subject(containingResearch: entry.id)
                ?? subject(containingKey: "topic:\(entry.topicKey)")
                ?? subjectMatchingExactTitle(entry.topic, allowEventBacked: true)
                ?? createSubject(title: entry.topic, kind: .topic)

            subjects[index].link(
                researchID: entry.id,
                title: entry.topic,
                aliases: []
            )
            subjects[index].markActivity(at: entry.lastSeenAt)
            subjects[index].markActivity(at: entry.updatedAt)
            researchLatest[subjects[index].id] = max(
                researchLatest[subjects[index].id] ?? .distantPast,
                max(entry.lastSeenAt, entry.updatedAt)
            )
            if let seedURL = entry.seedURL, !seedURL.isEmpty {
                researchSeedURLs[ContentIdentity.canonicalURL(seedURL)] = subjects[index].id
            }
        }

        for (recordID, urls) in evidenceURLsByRecordID {
            guard let subjectID = subject(containingResearch: recordID).map({ subjects[$0].id }) else {
                continue
            }
            for url in urls {
                researchSeedURLs[ContentIdentity.canonicalURL(url)] = subjectID
            }
        }

        // 2. Events. Explicit event ID + explicit `research:<recordID>:` evidence
        // provenance wins. URL/title fallbacks never merge event-backed subjects.
        for event in orderedEvents {
            let explicitRecordIDs = event.evidence.compactMap {
                Self.researchRecordID(from: $0.id)
            }
            let explicitIndexes = Self.orderedUnique(
                explicitRecordIDs.compactMap(subject(containingResearch:))
            )

            var targetIndex = subject(containingEvent: event.id)
            if let existing = targetIndex {
                let targetID = subjects[existing].id
                for sourceIndex in explicitIndexes {
                    let sourceID = subjects[sourceIndex].id
                    if sourceID != targetID {
                        merge(sourceID, into: targetID)
                    }
                }
                targetIndex = subjectIndex(id: targetID) ?? targetIndex
            } else if let primary = explicitIndexes.min(by: { lhs, rhs in
                if subjects[lhs].createdAt != subjects[rhs].createdAt {
                    return subjects[lhs].createdAt < subjects[rhs].createdAt
                }
                return subjects[lhs].id < subjects[rhs].id
            }) {
                let targetID = subjects[primary].id
                for sourceIndex in explicitIndexes {
                    let sourceID = subjects[sourceIndex].id
                    if sourceID != targetID {
                        merge(sourceID, into: targetID)
                    }
                }
                targetIndex = subjectIndex(id: targetID) ?? primary
            } else {
                // A seed/report URL may attach an event to a research-only
                // subject. Never use it against an event-backed subject: two
                // events sharing one article are still two events.
                for evidence in event.evidence {
                    let canonical = ContentIdentity.canonicalURL(evidence.url)
                    guard let subjectID = researchSeedURLs[canonical],
                          let found = subjectIndex(id: subjectID),
                          subjects[found].eventIDs.isEmpty else { continue }
                    targetIndex = found
                    break
                }
                if targetIndex == nil {
                    targetIndex = subjectMatchingExactTitle(event.title, allowEventBacked: false)
                }
                if targetIndex == nil {
                    targetIndex = createSubject(title: event.title, kind: .event)
                }
            }
            guard let index = targetIndex else { continue }
            let targetID = subjects[index].id
            subjects[index].link(
                eventID: event.id,
                title: event.title,
                aliases: event.subjectAliases
            )
            subjects[index].markActivity(at: event.lastEvidenceAt)
            subjects[index].markActivity(at: event.firstSeenAt)
            eventLatest[targetID] = max(
                eventLatest[targetID] ?? .distantPast,
                event.lastEvidenceAt
            )
            if event.hasConflict, !subjects[index].isArchived {
                subjects[index].updateState = .needsReview
            }

            // The same event evidence carries the record ID. If another subject
            // already owns that record, fold it into the event's canonical
            // subject without deleting any record/event/version.
            for recordID in explicitRecordIDs {
                guard let recordIndex = subject(containingResearch: recordID) else { continue }
                let recordSubjectID = subjects[recordIndex].id
                if recordSubjectID != targetID {
                    merge(recordSubjectID, into: targetID)
                }
            }
        }

        // 3. Drop retired rows and finalize canonical metadata.
        subjects.removeAll { retiredIDs.contains($0.id) }
        for index in subjects.indices {
            let id = subjects[index].id
            let before = subjects[index]
            subjects[index].kind = subjects[index].recomputedKind
            subjects[index].schemaVersion = max(
                subjects[index].schemaVersion,
                WorkspaceSubject.currentSchemaVersion
            )

            if hadLinksAtStart.contains(id) {
                let latestResearch = researchLatest[id] ?? .distantPast
                let latestEvent = eventLatest[id] ?? .distantPast
                if latestEvent > latestResearch,
                   let event = orderedEvents
                       .filter({ subjects[index].eventIDs.contains($0.id) })
                       .max(by: { $0.lastEvidenceAt < $1.lastEvidenceAt }),
                   !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    subjects[index].title = event.title
                } else if latestResearch > latestEvent,
                          let entry = usableResearch
                              .filter({ subjects[index].researchRecordIDs.contains($0.id) })
                              .max(by: { $0.lastSeenAt < $1.lastSeenAt }),
                          !entry.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    subjects[index].title = entry.topic
                }
            }

            if subjects[index] != before {
                subjects[index].updatedAt = max(subjects[index].updatedAt, now)
            } else if let old = initialByID[id], old != subjects[index] {
                // Links/conflict state changed earlier in the pass even when
                // title/kind are stable.
                subjects[index].updatedAt = max(subjects[index].updatedAt, now)
            }
        }

        // Compare against the initial snapshot, not a post-link snapshot: this
        // is the only reliable way to report newly linked IDs and conflict state.
        for subject in subjects {
            if let old = initialByID[subject.id] {
                if old != subject {
                    changedIDs.insert(subject.id)
                }
            } else {
                changedIDs.insert(subject.id)
                createdIDs.insert(subject.id)
            }
        }
        changedIDs.formUnion(retiredIDs)
        createdIDs.subtract(retiredIDs)

        subjects.sort { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }

        return WorkspaceReconcileResult(
            subjects: subjects,
            changedIDs: changedIDs,
            createdIDs: createdIDs
        )
    }

    /// `research:<recordID>:<digest>` (also claim/timeline variants). Only the
    /// record ID is authoritative; the trailing digest is not parsed.
    static func researchRecordID(from evidenceID: String) -> String? {
        guard evidenceID.hasPrefix("research:") else { return nil }
        let rest = evidenceID.dropFirst("research:".count)
        guard let separator = rest.firstIndex(of: ":") else { return nil }
        let recordID = String(rest[..<separator])
        return recordID.isEmpty ? nil : recordID
    }

    private static func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set(lhs)
        var output = lhs
        for value in rhs where seen.insert(value).inserted {
            output.append(value)
        }
        return output
    }

    private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func strongest(
        _ lhs: WorkspaceUpdateState,
        _ rhs: WorkspaceUpdateState
    ) -> WorkspaceUpdateState {
        func rank(_ value: WorkspaceUpdateState) -> Int {
            switch value {
            case .current: return 0
            case .hasUpdates: return 1
            case .needsReview: return 2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func mergedAliases(
        _ aliases: [String],
        title: String,
        adding incoming: [String]
    ) -> [String] {
        let titleKey = TopicFingerprint.normalized(title)
        var seen = Set(aliases.map(TopicFingerprint.normalized))
        var output = aliases
        for alias in incoming {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TopicFingerprint.normalized(trimmed)
            guard !trimmed.isEmpty, !key.isEmpty, key != titleKey,
                  seen.insert(key).inserted else { continue }
            output.append(trimmed)
        }
        if output.count > 12 {
            output.removeFirst(output.count - 12)
        }
        return output
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class NewsEventController: NewsEventControlling {
    private static var singleton: NewsEventController?

    static var shared: NewsEventController {
        if let singleton { return singleton }
        let controller = NewsEventController(settings: AppSettings())
        singleton = controller
        return controller
    }

    /// Rebinds the process-wide controller to the app's live settings instance.
    /// Call this from NewsOrchestrator or the event UI instead of constructing a second store.
    static func shared(settings: AppSettings) -> NewsEventController {
        if let singleton {
            singleton.settings = settings
            return singleton
        }
        let controller = NewsEventController(settings: settings)
        singleton = controller
        return controller
    }

    private(set) var events: [NewsEvent] = []
    private(set) var state: NewsEventControllerState = .idle
    private(set) var trackingState: NewsEventTrackingState = .idle
    private(set) var budgetSnapshot = NewsEventBudgetSnapshot()

    @ObservationIgnored private var settings: AppSettings
    @ObservationIgnored private let store: any NewsEventPersisting
    @ObservationIgnored private let matcher: any NewsEventMatching
    @ObservationIgnored private let sourceResolver: any NewsEventSourceResolving
    @ObservationIgnored private let inputAdapter: any NewsEventInputAdapting
    @ObservationIgnored private let notificationPolicy: any NewsEventNotificationPolicing
    @ObservationIgnored private let summaryBuilder: any NewsEventSummaryBuilding
    @ObservationIgnored private let tracker: any NewsEventTracking
    @ObservationIgnored private var mutationInProgress = false
    @ObservationIgnored private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        settings: AppSettings,
        store: any NewsEventPersisting = NewsEventStore.shared,
        matcher: any NewsEventMatching = NewsEventMatcher(),
        sourceResolver: any NewsEventSourceResolving = NewsEventSourceResolver(),
        inputAdapter: any NewsEventInputAdapting = NewsEventInputAdapter(),
        notificationPolicy: any NewsEventNotificationPolicing = NewsEventNotificationPolicy(),
        summaryBuilder: any NewsEventSummaryBuilding = NewsEventSummaryBuilder(),
        tracker: (any NewsEventTracking)? = nil
    ) {
        self.settings = settings
        self.store = store
        self.matcher = matcher
        self.sourceResolver = sourceResolver
        self.inputAdapter = inputAdapter
        self.notificationPolicy = notificationPolicy
        self.summaryBuilder = summaryBuilder
        self.tracker = tracker ?? NewsEventTracker(store: store)
    }

    func reload(now: Date) async {
        await withSerializedMutation {
            await reloadSerialized(now: now)
        }
    }

    private func reloadSerialized(now: Date) async {
        state = .loading(hasCachedEvents: !events.isEmpty)
        do {
            var restored = try await store.events()
            for index in restored.indices {
                let previous = restored[index]
                Self.normalizeConflictScopes(&restored[index])
                Self.normalizeRisk(&restored[index])
                Self.boundHistory(&restored[index])
                restored[index].sourceGroups = sourceResolver.groups(for: restored[index].evidence)
                restored[index].countablePublisherCount = sourceResolver.countablePublisherCount(in: restored[index].evidence)
                restored[index].coreConsistency = Self.consistency(for: restored[index])
                Self.scoreAndExplain(&restored[index], settings: settings, now: now)
                if restored[index].lastNotifiedAt != nil && restored[index].lastNotifiedFingerprint == nil {
                    restored[index].lastNotifiedFingerprint = NewsEventSemanticFingerprint.make(for: restored[index])
                }
                restored[index].notificationEligibility = notificationPolicy.eligibility(for: restored[index])
                if restored[index].lastNotifiedAt == nil && restored[index].notificationKeys.isEmpty {
                    restored[index].notificationMessage = notificationPolicy.explanation(for: restored[index], now: now)
                }
                if restored[index] != previous { try await store.upsert(restored[index]) }
            }
            events = Self.ordered(restored)
            trackingState = try await store.trackingState()
            budgetSnapshot = try await store.budgetSnapshot()
            state = .loaded(updatedAt: now, isStale: false)
        } catch {
            state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
        }
    }

    @discardableResult
    func ingest(items: [NewsItem], kind: NewsEventInputKind, now: Date) async -> Bool {
        let evidence = inputAdapter.from(items: items, kind: kind, now: now)
        guard items.isEmpty || !evidence.isEmpty else { return false }
        return await ingest(evidence, now: now)
    }

    @discardableResult
    func ingest(researchRecord: ResearchRecord, now: Date) async -> Bool {
        await ingest(inputAdapter.fromResearchRecord(researchRecord, now: now), now: now)
    }

    @discardableResult
    func ingest(_ incoming: [NewsEventEvidence], now: Date) async -> Bool {
        await withSerializedMutation {
            await ingestSerialized(incoming, now: now)
        }
    }

    private func ingestSerialized(_ incoming: [NewsEventEvidence], now: Date) async -> Bool {
        state = .loading(hasCachedEvents: !events.isEmpty)
        guard !incoming.isEmpty else {
            if stateHasCachedEvents {
                state = .loaded(updatedAt: now, isStale: false)
            } else {
                await reloadSerialized(now: now)
            }
            return true
        }

        do {
            var working = Dictionary(uniqueKeysWithValues: try await store.events().map { ($0.id, $0) })
            for id in Array(working.keys) {
                guard var event = working[id] else { continue }
                let previous = event
                Self.normalizeConflictScopes(&event)
                Self.normalizeRisk(&event)
                event.sourceGroups = sourceResolver.groups(for: event.evidence)
                event.countablePublisherCount = sourceResolver.countablePublisherCount(in: event.evidence)
                event.coreConsistency = Self.consistency(for: event)
                _ = NewsEventScheduler.expireIfSilent(&event, at: now)
                event.notificationEligibility = notificationPolicy.eligibility(for: event)
                if event.lastNotifiedAt == nil && event.notificationKeys.isEmpty {
                    event.notificationMessage = notificationPolicy.explanation(for: event, now: now)
                }
                if event != previous { try await store.upsert(event) }
                working[id] = event
            }
            var seenEvidence = Set(working.values.flatMap { $0.evidence.map(\.id) })
            var changedIDs: Set<String> = []
            var changeHints: [String: NewsEventChangeKind] = [:]
            var allIncomingPersisted = true
            var capacityDeletedCount = 0
            var capacityPressureDeletedCount = 0
            var capacityDeletedCandidateCount = 0
            var protectedCapacityCount = 0
            var capacityLimitedSeen = trackingState == .capacityLimited
            let configuredAliases = settings.newsEventInterestSettings.aliases
            let orderedEvidence = incoming.map { Self.addConfiguredAliases(to: $0, aliases: configuredAliases) }.sorted {
                if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt < $1.fetchedAt }
                return $0.id < $1.id
            }

            for evidence in orderedEvidence {
                guard !evidence.id.isEmpty, !evidence.title.isEmpty,
                      !evidence.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    allIncomingPersisted = false
                    continue
                }
                guard seenEvidence.insert(evidence.id).inserted else { continue }

                var matchedID: String?
                var decisionNotes: [String] = []
                let candidates = working.values.sorted {
                    if $0.lastEvidenceAt != $1.lastEvidenceAt { return $0.lastEvidenceAt > $1.lastEvidenceAt }
                    return $0.id < $1.id
                }
                for event in candidates where event.lifecycle != .expired || Self.canReevaluateCandidate(event) {
                    var matchingEvent = event
                    matchingEvent.subjectAliases = Self.unique(
                        matchingEvent.subjectAliases
                            + Self.configuredAliases(in: "\(event.title) \(event.eventDescription)", aliases: configuredAliases)
                    )
                    switch matcher.decide(evidence, against: matchingEvent) {
                    case .sameEvent(let reasons):
                        matchedID = event.id
                        decisionNotes = reasons
                        break
                    case .separate(let reasons), .insufficient(let reasons):
                        decisionNotes.append(contentsOf: reasons)
                    }
                    if matchedID != nil { break }
                }

                let eventID: String
                let changeHint: NewsEventChangeKind
                if let matchedID, var event = working[matchedID] {
                    let previousEvent = event
                    let reactivatingCandidate = event.lifecycle == .expired
                        && Self.isSubstantiveReevaluation(evidence, for: event, now: now, sourceResolver: sourceResolver)
                    eventID = matchedID
                    event.evidence.append(evidence)
                    event.lastEvidenceAt = max(event.lastEvidenceAt, evidence.fetchedAt)
                    if evidence.fetchedAt >= event.lastEvidenceAt {
                        event.title = evidence.title
                        event.action = evidence.action ?? event.action
                        event.eventDescription = evidence.eventDescription
                    }
                    event.subjectAliases = Self.unique(event.subjectAliases + evidence.subjectAliases)
                    event.eventTime = evidence.eventTime ?? event.eventTime
                    event.location = evidence.location ?? event.location
                    event.mergeReasons = Self.unique(event.mergeReasons + decisionNotes)
                    event.claims = Self.mergeClaims(event.claims + evidence.claims)
                    event.timeline = Self.mergeTimeline(event.timeline + evidence.timeline)
                    let existingCoreConflicts = event.coreConflictDetails
                    let existingDetailConflicts = event.detailConflictDetails
                    event.conflicts = Self.unique(event.conflicts + evidence.conflicts)
                    event.coreConflicts = Self.unique(existingCoreConflicts + Self.coreConflicts(in: evidence))
                    event.detailConflicts = Self.unique(existingDetailConflicts + (evidence.detailConflicts ?? []))
                    event.sourceGroups = sourceResolver.groups(for: event.evidence)
                    event.countablePublisherCount = sourceResolver.countablePublisherCount(in: event.evidence)
                    event.coreConsistency = Self.consistency(for: event)
                    if event.lifecycle != .expired {
                        event.lifecycle = settings.newsEventMonitoringEnabled ? .tracking : .queued
                    } else if reactivatingCandidate {
                        event.lifecycle = settings.newsEventMonitoringEnabled ? .tracking : .queued
                        event.provisionalCandidateExpiredAt = nil
                        event.expiresAt = nil
                        event.followupIndex = 0
                        event.lastCheckedAt = nil
                        event.nextCheckAt = evidence.fetchedAt.addingTimeInterval(5 * 60)
                        event.trackingStatus = .scheduled
                        event.trackingMessage = "收到新发布主体或实质进展证据；候选已重新评估并恢复。"
                    }
                    let detectedChange = Self.changeKind(for: evidence, previousEvent: previousEvent, updatedEvent: event)
                    if detectedChange == .majorProgress {
                        event.lastMajorProgressAt = max(event.lastMajorProgressAt ?? .distantPast, evidence.fetchedAt)
                    }
                    changeHint = reactivatingCandidate ? .initial : detectedChange
                    working[eventID] = event
                } else {
                    let persistedEvents = try await store.events()
                    let persistedIDs = Set(persistedEvents.map(\.id))
                    let reservedSlots = working.keys.filter { !persistedIDs.contains($0) }.count
                    let effectiveCapacity = max(1, NewsEventStore.maximumEvents - reservedSlots)
                    let capacity = try await store.prune(
                        now: now,
                        maximumEvents: effectiveCapacity,
                        terminalRetention: 30 * 86_400
                    )
                    capacityDeletedCount += capacity.deletedEventIDs.count
                    capacityPressureDeletedCount += capacity.capacityPressureDeletedCount
                    capacityDeletedCandidateCount += capacity.deletedCandidateCount
                    protectedCapacityCount = max(protectedCapacityCount, capacity.protectedEventCount + reservedSlots)
                    if capacity.capacityLimited {
                        capacityLimitedSeen = true
                    } else if working.count - capacity.deletedEventIDs.count < NewsEventStore.maximumEvents {
                        capacityLimitedSeen = false
                    }
                    for deletedID in capacity.deletedEventIDs { working.removeValue(forKey: deletedID) }
                    guard !capacity.capacityLimited, working.count < NewsEventStore.maximumEvents else {
                        trackingState = .capacityLimited
                        capacityLimitedSeen = true
                        allIncomingPersisted = false
                        budgetSnapshot = NewsEventBudgetSnapshot(
                            availability: .paused,
                            reason: "事件容量达到硬上限。",
                            capacityReason: Self.capacityReason(
                                deletedCount: capacityDeletedCount,
                                pressureDeletedCount: capacityPressureDeletedCount,
                                candidateDeletedCount: capacityDeletedCandidateCount,
                                protectedCount: capacity.protectedEventCount + reservedSlots,
                                capacityLimited: true
                            ),
                            checksUsed: nil,
                            checksLimit: nil,
                            resetsAt: nil
                        )
                        continue
                    }
                    eventID = UUID().uuidString
                    let firstSeenAt = evidence.fetchedAt
                    var event = NewsEvent(
                        id: eventID,
                        title: evidence.title,
                        action: evidence.action,
                        eventDescription: evidence.eventDescription,
                        subjectAliases: evidence.subjectAliases,
                        eventTime: evidence.eventTime,
                        location: evidence.location,
                        lifecycle: settings.newsEventMonitoringEnabled ? .tracking : .queued,
                        firstSeenAt: firstSeenAt,
                        lastEvidenceAt: evidence.fetchedAt,
                        nextCheckAt: firstSeenAt.addingTimeInterval(5 * 60),
                        evidence: [evidence],
                        claims: evidence.claims,
                        timeline: evidence.timeline,
                        conflicts: evidence.conflicts,
                        coreConflicts: Self.coreConflicts(in: evidence),
                        detailConflicts: evidence.detailConflicts ?? [],
                        mergeReasons: Self.unique(decisionNotes + ["未发现满足主体+动作/描述规则的已有事件，创建独立事件。"]),
                        sourceGroups: sourceResolver.groups(for: [evidence]),
                        countablePublisherCount: sourceResolver.countablePublisherCount(in: [evidence])
                    )
                    event.coreConsistency = Self.consistency(for: event)
                    working[eventID] = event
                    changeHint = .initial
                }

                if var event = working[eventID] {
                    Self.boundHistory(&event)
                    event.sourceGroups = sourceResolver.groups(for: event.evidence)
                    event.countablePublisherCount = sourceResolver.countablePublisherCount(in: event.evidence)
                    Self.normalizeRisk(&event)
                    Self.scoreAndExplain(&event, settings: settings, now: now)
                    event.notificationEligibility = notificationPolicy.eligibility(for: event)
                    if event.lastNotifiedAt == nil && event.notificationKeys.isEmpty {
                        event.notificationMessage = notificationPolicy.explanation(for: event, now: now)
                    }
                    working[eventID] = event
                    changedIDs.insert(eventID)
                    if let existing = changeHints[eventID] {
                        changeHints[eventID] = Self.moreSignificant(existing, changeHint)
                    } else {
                        changeHints[eventID] = changeHint
                    }
                }
            }

            for id in changedIDs.sorted() {
                guard var event = working[id] else { continue }
                do {
                    try await store.upsert(event)
                } catch NewsEventStoreError.capacityLimited {
                    trackingState = .capacityLimited
                    capacityLimitedSeen = true
                    allIncomingPersisted = false
                    protectedCapacityCount = max(protectedCapacityCount, working.count)
                    working.removeValue(forKey: id)
                    changedIDs.remove(id)
                    continue
                }

                if settings.newsEventNotificationsEnabled {
                    let change = event.lastNotifiedAt == nil ? NewsEventChangeKind.initial : (changeHints[id] ?? .routine)
                    await sendIfAllowed(event: &event, change: change, now: now)
                    working[id] = event
                }
            }

            events = Self.ordered(Array(working.values))
            if capacityLimitedSeen { trackingState = .capacityLimited }
            else {
                let hasActiveEvents = events.contains { $0.lifecycle != .expired }
                if trackingState == .capacityLimited {
                    trackingState = settings.newsEventMonitoringEnabled && hasActiveEvents ? .tracking : .idle
                } else if !settings.newsEventMonitoringEnabled {
                    trackingState = .idle
                } else if hasActiveEvents && trackingState == .idle {
                    trackingState = .tracking
                }
                budgetSnapshot = try await store.budgetSnapshot()
            }
            if capacityLimitedSeen || capacityDeletedCount > 0 {
                budgetSnapshot.capacityReason = Self.capacityReason(
                    deletedCount: capacityDeletedCount,
                    pressureDeletedCount: capacityPressureDeletedCount,
                    candidateDeletedCount: capacityDeletedCandidateCount,
                    protectedCount: protectedCapacityCount,
                    capacityLimited: capacityLimitedSeen
                )
            } else if trackingState != .capacityLimited {
                budgetSnapshot.capacityReason = nil
            }
            try await store.saveTrackingState(trackingState)
            try await store.saveBudgetSnapshot(budgetSnapshot)
            if case .failed = state {
                // A notification persistence failure remains visible after the ingest pass.
            } else {
                state = .loaded(updatedAt: now, isStale: false)
            }
            return allIncomingPersisted
        } catch {
            state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
            if trackingState != .capacityLimited { trackingState = .failed }
            return false
        }
    }

    func event(id: String) -> NewsEvent? {
        events.first(where: { $0.id == id })
    }

    /// Records a successful ordinary RSS conditional request as a shared check.
    /// It does not consume the event-tracking budget; no second request is needed
    /// when this fresh check already happened after an event's due time.
    func recordSharedRSSCheck(
        sourceID: String,
        eTag: String?,
        lastModified: String?,
        checkedAt: Date,
        advanceValidators: Bool = true
    ) async {
        await withSerializedMutation {
            do {
                let old = try await store.feedCursor(for: sourceID)
                let cursor = NewsEventFeedCursor(
                    sourceID: sourceID,
                    eTag: advanceValidators ? (eTag ?? old?.eTag) : old?.eTag,
                    lastModified: advanceValidators ? (lastModified ?? old?.lastModified) : old?.lastModified,
                    checkedAt: checkedAt,
                    attemptedAt: checkedAt,
                    failureCount: 0
                )
                try await store.saveFeedCursor(cursor)

                if settings.newsEventMonitoringEnabled {
                    var restored = try await store.events()
                    for index in restored.indices where restored[index].lifecycle != .expired {
                        let previous = restored[index]
                        restored[index].lifecycle = .tracking
                        if NewsEventScheduler.isDue(restored[index], at: checkedAt) {
                            NewsEventScheduler.markChecked(
                                &restored[index],
                                at: checkedAt,
                                message: "常规 RSS 条件检查已满足本次 due；未重复请求。"
                            )
                        }
                        if restored[index] != previous {
                            try await store.upsert(restored[index])
                        }
                    }
                    events = Self.ordered(restored)
                    if trackingState != .capacityLimited {
                        trackingState = restored.count >= NewsEventStore.maximumEvents
                            ? .capacityLimited
                            : (restored.contains(where: { $0.lifecycle != .expired }) ? .tracking : .idle)
                    }
                    try await store.saveTrackingState(trackingState)
                }

                budgetSnapshot = try await store.budgetSnapshot()
                try await store.saveBudgetSnapshot(budgetSnapshot)
            } catch {
                trackingState = .failed
                state = .failed(message: "常规 RSS 共享 cursor 无法持久化：\(error.localizedDescription)", hasCachedEvents: !events.isEmpty)
                NSLog("[NewsEventController] Failed to persist shared RSS cursor: %@", error.localizedDescription)
            }
        }
    }

    /// Confirms a tracker HTTP 200 cursor only after the caller has durably ingested its evidence.
    @discardableResult
    func commitTrackingCursorAfterIngest(_ cursor: NewsEventFeedCursor) async -> Bool {
        await withSerializedMutation {
            do {
                try await store.saveFeedCursor(cursor)
                return true
            } catch {
                trackingState = .failed
                state = .failed(
                    message: "证据已保存，但 RSS cursor 确认失败；保留旧 cursor，允许重抓：\(error.localizedDescription)",
                    hasCachedEvents: !events.isEmpty
                )
                NSLog("[NewsEventController] Failed to confirm tracking cursor: %@", error.localizedDescription)
                return false
            }
        }
    }

    private func applyTrackingResult(_ result: NewsEventTrackingResult, now: Date) async {
        let hadControllerFailure: Bool
        if case .failed = state { hadControllerFailure = true } else { hadControllerFailure = false }
        do {
            var restored = try await store.events()
            let checkedIDs = Set(result.checkedEventIDs)
            let pendingIDs = Set(result.pendingEventIDs)
            for index in restored.indices {
                guard restored[index].lifecycle != .expired else { continue }
                let id = restored[index].id
                if checkedIDs.contains(id), settings.newsEventMonitoringEnabled,
                   NewsEventScheduler.isDue(restored[index], at: now) {
                    NewsEventScheduler.markChecked(
                        &restored[index],
                        at: now,
                        message: String((result.message ?? "RSS 条件检查完成。").prefix(300))
                    )
                    try await store.upsert(restored[index])
                } else if pendingIDs.contains(id), settings.newsEventMonitoringEnabled {
                    switch result.state {
                    case .budgetDeferred:
                        NewsEventScheduler.markBudgetDeferred(&restored[index], resetsAt: result.budgetSnapshot.resetsAt)
                    case .noFreshSource:
                        NewsEventScheduler.markNoFreshSource(&restored[index])
                    case .failed:
                        NewsEventScheduler.markFailed(
                            &restored[index],
                            message: String((result.message ?? "RSS 检查失败；due 保留。").prefix(300))
                        )
                    case .idle, .tracking, .capacityLimited:
                        continue
                    }
                    try await store.upsert(restored[index])
                }
            }

            restored = try await store.events()
            events = Self.ordered(restored)
            if trackingState == .capacityLimited {
                trackingState = .capacityLimited
            } else if hadControllerFailure {
                trackingState = .failed
            } else {
                trackingState = result.state
            }
            let previousCapacityReason = try await store.budgetSnapshot().capacityReason
            budgetSnapshot = result.budgetSnapshot
            budgetSnapshot.capacityReason = budgetSnapshot.capacityReason ?? previousCapacityReason
            try await store.saveTrackingState(trackingState)
            try await store.saveBudgetSnapshot(budgetSnapshot)
            if hadControllerFailure {
                // Keep an ingest/notification persistence error visible.
            } else if result.state == .failed {
                state = .failed(
                    message: result.message ?? "事件追踪失败。",
                    hasCachedEvents: !events.isEmpty
                )
            } else {
                state = .loaded(updatedAt: now, isStale: false)
            }
        } catch {
            trackingState = .failed
            budgetSnapshot = NewsEventBudgetSnapshot(
                availability: .paused,
                reason: "追踪状态持久化失败：\(error.localizedDescription)",
                checksUsed: result.budgetSnapshot.checksUsed,
                checksLimit: result.budgetSnapshot.checksLimit,
                resetsAt: result.budgetSnapshot.resetsAt
            )
            state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
            NSLog("[NewsEventController] Failed to apply tracking result: %@", error.localizedDescription)
        }
    }

    /// Recovery/expiry runs before due work. The tracker is awaited only after
    /// `withSerializedMutation` releases its slot, so evidence re-enters via the
    /// normal serialized `ingest` path without recursive queue acquisition.
    func recoverAndTick(now: Date, sources: [NewsSource]) async {
        await withSerializedMutation {
            await recoverAndTickSerialized(now: now)
        }
        guard !Task.isCancelled else { return }
        if case .failed = state { return }
        guard settings.newsEventMonitoringEnabled else {
            do {
                var snapshot = try await tracker.budgetSnapshot(now: now)
                snapshot.capacityReason = budgetSnapshot.capacityReason
                await withSerializedMutation {
                    do {
                        budgetSnapshot = snapshot
                        if trackingState != .capacityLimited { trackingState = .idle }
                        try await store.saveBudgetSnapshot(snapshot)
                        try await store.saveTrackingState(trackingState)
                    } catch {
                        trackingState = .failed
                        state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
                    }
                }
            } catch {
                await withSerializedMutation {
                    trackingState = .failed
                    state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
                }
            }
            return
        }

        // The mutation slot is deliberately free while the tracker awaits the
        // network. Its result is then applied through the same serialized path.
        let result = await tracker.recover(now: now, sources: sources)
        guard !Task.isCancelled else { return }
        if !result.evidence.isEmpty {
            let durable = await ingest(result.evidence, now: now)
            guard durable else {
                let failure = trackingResultAfterPersistenceFailure(
                    result,
                    message: "RSS 返回的 evidence 未能全部持久化；cursor 未推进，due 保留以便安全重抓。"
                )
                await withSerializedMutation { await applyTrackingResult(failure, now: now) }
                return
            }
        }
        if let cursor = result.cursorToCommitAfterIngest {
            let committed = await commitTrackingCursorAfterIngest(cursor)
            guard committed else {
                let failure = trackingResultAfterPersistenceFailure(
                    result,
                    message: "evidence 已保存，但 cursor 确认失败；due 保留以便重抓。"
                )
                await withSerializedMutation { await applyTrackingResult(failure, now: now) }
                return
            }
        }
        await withSerializedMutation {
            await applyTrackingResult(result, now: now)
        }
    }

    private func trackingResultAfterPersistenceFailure(
        _ result: NewsEventTrackingResult,
        message: String
    ) -> NewsEventTrackingResult {
        NewsEventTrackingResult(
            state: .failed,
            evidence: [],
            budgetSnapshot: NewsEventBudgetSnapshot(
                availability: .paused,
                reason: message,
                capacityReason: result.budgetSnapshot.capacityReason,
                checksUsed: result.budgetSnapshot.checksUsed,
                checksLimit: result.budgetSnapshot.checksLimit,
                resetsAt: result.budgetSnapshot.resetsAt
            ),
            checkedEventIDs: [],
            pendingEventIDs: Array(Set(result.checkedEventIDs + result.pendingEventIDs)).sorted(),
            message: message
        )
    }

    private func recoverAndTickSerialized(now: Date) async {
        state = .loading(hasCachedEvents: !events.isEmpty)
        do {
            var restored = try await store.events()
            for index in restored.indices {
                let previous = restored[index]
                Self.normalizeConflictScopes(&restored[index])
                Self.normalizeRisk(&restored[index])
                Self.boundHistory(&restored[index])
                restored[index].sourceGroups = sourceResolver.groups(for: restored[index].evidence)
                restored[index].countablePublisherCount = sourceResolver.countablePublisherCount(in: restored[index].evidence)
                restored[index].coreConsistency = Self.consistency(for: restored[index])
                restored[index].notificationEligibility = notificationPolicy.eligibility(for: restored[index])
                if restored[index].lastNotifiedAt == nil && restored[index].notificationKeys.isEmpty {
                    restored[index].notificationMessage = notificationPolicy.explanation(for: restored[index], now: now)
                }
                if restored[index].lastNotifiedAt != nil && restored[index].lastNotifiedFingerprint == nil {
                    restored[index].lastNotifiedFingerprint = NewsEventSemanticFingerprint.make(for: restored[index])
                }
                if !NewsEventScheduler.expireIfSilent(&restored[index], at: now),
                   restored[index].lifecycle != .expired {
                    if settings.newsEventMonitoringEnabled {
                        restored[index].lifecycle = .tracking
                        if restored[index].nextCheckAt == nil {
                            restored[index].nextCheckAt = NewsEventScheduler.dueAt(for: restored[index])
                        }
                        if restored[index].trackingMessage?.hasPrefix("Core 阶段") == true {
                            restored[index].trackingMessage = nil
                        }
                    } else {
                        restored[index].lifecycle = .queued
                        restored[index].trackingStatus = .scheduled
                        restored[index].trackingMessage = "事件监控已关闭；不会额外检查。"
                    }
                }
                if restored[index] != previous {
                    try await store.upsert(restored[index])
                }
            }

            let pruned = try await store.prune(
                now: now,
                maximumEvents: NewsEventStore.maximumEvents,
                terminalRetention: 30 * 86_400
            )
            restored.removeAll { pruned.deletedEventIDs.contains($0.id) }
            let hasActive = restored.contains { $0.lifecycle != .expired }
            trackingState = pruned.capacityLimited
                ? .capacityLimited
                : (hasActive && settings.newsEventMonitoringEnabled ? .tracking : .idle)
            budgetSnapshot = try await store.budgetSnapshot()
            if pruned.capacityLimited || !pruned.deletedEventIDs.isEmpty {
                budgetSnapshot.capacityReason = Self.capacityReason(
                    deletedCount: pruned.deletedEventIDs.count,
                    pressureDeletedCount: pruned.capacityPressureDeletedCount,
                    candidateDeletedCount: pruned.deletedCandidateCount,
                    protectedCount: pruned.protectedEventCount,
                    capacityLimited: pruned.capacityLimited
                )
            } else {
                budgetSnapshot.capacityReason = nil
            }
            try await store.saveTrackingState(trackingState)
            try await store.saveBudgetSnapshot(budgetSnapshot)
            events = Self.ordered(restored)
            state = .loaded(updatedAt: now, isStale: false)
        } catch {
            state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
            trackingState = .failed
        }
    }

    /// Collapses the incoming article list with the persisted evidence→event mapping.
    /// Keeps unmapped items visible while preventing screened event evidence from flowing back in.
    func foldedRecommendationItems(from items: [NewsItem]) -> [NewsItem] {
        let itemByEvidenceID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localInterest = InterestController.shared.state
        let eventPreferences = settings.newsEventInterestSettings
        var result: [NewsItem] = []
        var representedEvidenceIDs: Set<String> = []
        var blockedEvidenceIDs: Set<String> = []
        var resultIDs: Set<String> = []
        let directSuppressionTerms = eventPreferences.hardBlocks + eventPreferences.excludes
        func contains(_ term: String, in text: String) -> Bool {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !clean.isEmpty
                && text.range(of: clean, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        func matchesSuppressionRule(_ text: String, item: NewsItem? = nil) -> Bool {
            let lower = text.lowercased()
            if directSuppressionTerms.contains(where: { contains($0, in: lower) }) { return true }
            return eventPreferences.scopedExcludes.contains { rule in
                switch rule.scope {
                case .topic, .entity:
                    return contains(rule.value, in: lower)
                case .region:
                    return false // A standalone article has no structured event location.
                case .source:
                    guard let item else { return false }
                    return contains(rule.value, in: item.source.displayName)
                        || contains(rule.value, in: item.source.id)
                }
            }
        }
        for event in events {
            let eventText = ([event.title, event.action ?? "", event.eventDescription]
                + event.subjectAliases + event.evidence.map(\.title)).joined(separator: " ")
            blockedEvidenceIDs.formUnion(event.evidence.compactMap { evidence in
                guard let item = itemByEvidenceID[evidence.id], localInterest.isBlocked(item) else { return nil }
                return evidence.id
            })
            if event.interestDisposition == .hardBlocked || event.interestDisposition == .excluded
                || matchesSuppressionRule(eventText) {
                blockedEvidenceIDs.formUnion(event.evidence.map(\.id))
                continue
            }
            guard event.lifecycle != .expired else { continue }
            representedEvidenceIDs.formUnion(event.evidence.map(\.id))
            let representative = event.evidence
                .sorted { $0.fetchedAt > $1.fetchedAt }
                .filter { !blockedEvidenceIDs.contains($0.id) }
                .compactMap { itemByEvidenceID[$0.id] }
                .first
            if let representative, resultIDs.insert(representative.id).inserted {
                result.append(representative)
            }
        }

        for item in items {
            guard !representedEvidenceIDs.contains(item.id), !blockedEvidenceIDs.contains(item.id),
                  !resultIDs.contains(item.id), !localInterest.isBlocked(item),
                  !matchesSuppressionRule(item.title, item: item) else { continue }
            resultIDs.insert(item.id)
            result.append(item)
        }
        return result
    }

    private var stateHasCachedEvents: Bool { !events.isEmpty }

    private func withSerializedMutation<Value>(_ operation: () async -> Value) async -> Value {
        await acquireMutationSlot()
        defer { releaseMutationSlot() }
        return await operation()
    }

    private func acquireMutationSlot() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationSlot() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    private func sendIfAllowed(event: inout NewsEvent, change: NewsEventChangeKind, now: Date) async {
        if event.interestDisposition == .hardBlocked || event.interestDisposition == .excluded {
            event.notificationEligibility = notificationPolicy.eligibility(for: event)
            event.notificationMessage = event.interestDisposition == .hardBlocked
                ? "硬屏蔽规则优先；已抑制事件通知。"
                : "排除规则优先；已抑制事件通知。"
            do {
                try await store.upsert(event)
            } catch {
                state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
            }
            return
        }

        switch notificationPolicy.decide(event: event, change: change) {
        case .suppress(let reason):
            event.notificationEligibility = notificationPolicy.eligibility(for: event)
            if event.notificationMessage == nil { event.notificationMessage = reason }
            do {
                try await store.upsert(event)
            } catch {
                event.notificationMessage = "通知决策已完成，但事件状态未能持久化：\(error.localizedDescription)"
                state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
            }
        case .notify(let alert):
            do {
                guard try await store.claimNotification(eventID: event.id, key: alert.notificationID, at: now) else {
                    event.notificationMessage = "通知去重键已存在；为避免重复未重发。"
                    return
                }
                event.notificationKeys.insert(alert.notificationID)
                event.notificationMessage = "通知去重键已持久化，系统投递结果待确认。"
                do {
                    try await NotificationService.sendNewsEventAlert(alert)
                    event.lastNotifiedAt = now
                    event.lastNotifiedFingerprint = alert.semanticFingerprint
                    event.notificationEligibility = notificationPolicy.eligibility(for: event)
                    event.notificationMessage = "macOS 已接受通知请求；是否实际显示仍由系统通知策略决定。"
                } catch {
                    event.notificationMessage = "系统未确认通知投递；去重键已保存，本事件不会自动重发。\(error.localizedDescription)"
                }
            } catch {
                event.notificationMessage = "无法持久化通知去重键，未发送通知：\(error.localizedDescription)"
                state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
                return
            }
            do {
                try await store.upsert(event)
            } catch {
                event.notificationMessage = event.lastNotifiedAt == nil
                    ? "通知未确认；去重状态已保存，但通知结果无法回写：\(error.localizedDescription)"
                    : "macOS 已接受通知请求，但投递状态无法回写：\(error.localizedDescription)"
                state = .failed(message: error.localizedDescription, hasCachedEvents: !events.isEmpty)
            }
        }
    }

    private static func consistency(for event: NewsEvent) -> NewsEventCoreConsistency {
        if !event.coreConflictDetails.isEmpty || event.claims.contains(where: {
            $0.scope != .detail && $0.status == .contested
        }) {
            return .contested
        }
        let publisherKeys = Set(event.sourceGroups.filter { $0.publisherKind != .official }.compactMap(\.publisherKey))
        if event.evidence.count >= 2 && publisherKeys.count >= 2 { return .consistent }
        if event.claims.contains(where: { $0.scope != .detail && $0.status == .supported }) { return .consistent }
        return .unknown
    }

    private static func scoreAndExplain(_ event: inout NewsEvent, settings: AppSettings, now: Date) {
        let newsGroups = event.sourceGroups.filter { group in
            guard group.publisherKind != .official, group.publisherKey != nil else { return false }
            return event.evidence.contains { $0.inputKind != .trend && group.evidenceIDs.contains($0.id) }
        }
        let officialCount = event.evidence.filter { $0.publisherKind == .official }.count
        let trends = event.evidence.filter { $0.inputKind == .trend }
        let maxTrendSignal = trends.compactMap(\.publicSignal).max() ?? 0
        let recentBoost = now.timeIntervalSince(event.lastEvidenceAt) <= 24 * 3600 ? 10 : 0
        let content = ([event.title, event.action ?? "", event.eventDescription]
            + event.evidence.map(\.title)
            + event.claims.filter { $0.scope != .detail }.map(\.text)).joined(separator: " ").lowercased()
        let contentSignals: [(terms: [String], score: Int, reason: String)] = [
            (["地震", "洪水", "台风", "火灾", "爆炸", "坍塌", "事故", "earthquake", "flood", "typhoon", "wildfire", "explosion", "crash"], 18, "公共安全/应急内容信号"),
            (["服务中断", "大面积停电", "召回", "停运", "outage", "service disruption", "recall", "shutdown"], 14, "公共服务/安全处置内容信号"),
            (["法规", "立法", "判决", "禁令", "制裁", "起诉", "regulation", "legislation", "court ruling", "sanction", "lawsuit"], 11, "政策/法律行动内容信号"),
            (["收购", "并购", "罢工", "裁员", "破产", "acquisition", "merger", "strike", "layoff", "bankruptcy"], 9, "机构/经营变化内容信号"),
            (["签署", "生效", "批准", "正式发布", "投入运营", "signed", "took effect", "approved", "entered service"], 6, "实质里程碑内容信号"),
        ]
        let contentSignal = contentSignals.first { signal in signal.terms.contains(where: content.contains) }
        event.publicImportanceScore = min(
            100,
            newsGroups.count * 12 + min(24, maxTrendSignal / 4) + min(12, officialCount * 4)
                + min(12, trends.count * 4) + recentBoost + (contentSignal?.score ?? 0)
        )
        var publicReasons: [String] = []
        if !newsGroups.isEmpty { publicReasons.append("\(newsGroups.count) 个可区分新闻发布主体") }
        if officialCount > 0 { publicReasons.append("包含官方来源证据（不计发布主体）") }
        if !trends.isEmpty { publicReasons.append("\(trends.count) 条趋势发现信号") }
        if recentBoost > 0 { publicReasons.append("最近 24 小时有新证据") }
        if let contentSignal { publicReasons.append(contentSignal.reason) }
        event.publicImportanceReason = publicReasons.isEmpty ? "公开来源信号尚少" : publicReasons.joined(separator: "；")

        let preferences = settings.newsEventInterestSettings
        let topicFields = [event.title, event.action ?? "", event.eventDescription]
            + event.evidence.map(\.title) + event.claims.map(\.text)
        let entityText = topicFields.joined(separator: " ")
        let configuredEntityAliases = preferences.aliases.keys.sorted().flatMap { canonical -> [String] in
            let group = [canonical] + (preferences.aliases[canonical] ?? [])
            guard group.contains(where: { containsConfiguredAlias($0, in: entityText) }) else { return [] }
            return group
        }
        let entityFields = event.subjectAliases + event.evidence.flatMap(\.subjectAliases) + configuredEntityAliases
        let regionFields = [event.location].compactMap { $0 }
            + event.evidence.compactMap(\.location)
        let sourceFields = event.sourceGroups.flatMap { [$0.displayName, $0.publisherKey ?? ""] }
            + event.evidence.flatMap { [$0.sourceName, $0.sourceID ?? "", $0.publisherKey ?? "", $0.author ?? ""] }
        let legacyFields = [event.title, event.action ?? "", event.eventDescription]
            + event.subjectAliases + event.evidence.map(\.title)
        let searchable = legacyFields.joined(separator: " ")
        func contains(_ term: String, in fields: [String]) -> Bool {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty else { return false }
            return fields.contains {
                $0.range(of: clean, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        func matches(_ term: String) -> Bool {
            contains(term, in: legacyFields)
        }
        func matches(_ rule: NewsEventInterestRule) -> Bool {
            switch rule.scope {
            case .topic: return contains(rule.value, in: topicFields)
            case .entity: return contains(rule.value, in: entityFields)
            case .region: return contains(rule.value, in: regionFields)
            case .source: return contains(rule.value, in: sourceFields)
            }
        }
        if let blocked = preferences.hardBlocks.first(where: matches) {
            event.interestDisposition = .hardBlocked
            event.personalInterestScore = -10_000
            event.interestReasons = ["硬屏蔽：\(blocked)"]
            return
        }
        if let excluded = preferences.excludes.first(where: matches) {
            event.interestDisposition = .excluded
            event.personalInterestScore = -1_000
            event.interestReasons = ["排除规则：\(excluded)"]
            return
        }
        if let excluded = preferences.scopedExcludes.first(where: matches) {
            event.interestDisposition = .excluded
            event.personalInterestScore = -1_000
            event.interestReasons = ["分类排除：\(excluded.value)"]
            return
        }

        let keywordTerms = preferences.keywords.flatMap { keyword in
            [keyword] + (preferences.aliases[keyword] ?? [])
        }
        let entityTerms = preferences.aliases.keys.sorted().flatMap { canonical in
            [canonical] + (preferences.aliases[canonical] ?? [])
        }
        let includeTerms = preferences.includes
        let matchedKeywords = keywordTerms.filter { contains($0, in: legacyFields) }
        let matchedEntities = entityTerms.filter { contains($0, in: legacyFields) }
        let matchedIncludes = includeTerms.filter(matches)
        let matchedScopedIncludes = preferences.scopedIncludes.filter(matches)
        if keywordTerms.isEmpty && entityTerms.isEmpty && includeTerms.isEmpty
            && preferences.scopedIncludes.isEmpty {
            event.interestDisposition = .open
            event.personalInterestScore = 0
            event.interestReasons = ["关键词为空，开放发现"]
        } else if !matchedKeywords.isEmpty || !matchedEntities.isEmpty
            || !matchedIncludes.isEmpty || !matchedScopedIncludes.isEmpty {
            event.interestDisposition = .matched
            event.personalInterestScore = min(
                100,
                (matchedKeywords.count + matchedEntities.count) * 12
                    + (matchedIncludes.count + matchedScopedIncludes.count) * 24
            )
            event.interestReasons = matchedKeywords.map { "关键词：\($0)" }
                + matchedEntities.map { "实体别名：\($0)" }
                + matchedIncludes.map { "包含：\($0)" }
                + matchedScopedIncludes.map { "分类关注：\($0.value)" }
        } else {
            event.interestDisposition = .unmatched
            event.personalInterestScore = 0
            event.interestReasons = ["未匹配个人偏好；公开重要性仍独立排序"]
        }

        // Do not touch InterestController.state when the event-learning switch is off.
        if preferences.learningEnabled && InterestController.shared.learningEnabled {
            let profile = InterestProfile.build(state: InterestController.shared.state, now: now)
            let tags = TitleFeatures.tags(searchable)
            let learned = tags.compactMap { profile.topics[$0] }.max() ?? 0
            if learned > 0 {
                event.personalInterestScore = min(100, event.personalInterestScore + Int((learned * 8).rounded()))
                event.interestReasons.append("本地学习画像提供兴趣加权")
                if event.interestDisposition == .unmatched || event.interestDisposition == .open {
                    event.interestDisposition = .matched
                }
            }
        }
    }

    private static func changeKind(
        for evidence: NewsEventEvidence,
        previousEvent: NewsEvent,
        updatedEvent: NewsEvent
    ) -> NewsEventChangeKind {
        if !coreConflicts(in: evidence).isEmpty || evidence.claims.contains(where: {
            $0.status == .corrected || ($0.scope != .detail && $0.status == .contested)
        }) {
            return .correction
        }
        return NewsEventSemanticFingerprint.hasMeaningfulProgress(
            evidence: evidence,
            previousEvent: previousEvent,
            updatedEvent: updatedEvent
        ) ? .majorProgress : .routine
    }

    private static func moreSignificant(_ lhs: NewsEventChangeKind, _ rhs: NewsEventChangeKind) -> NewsEventChangeKind {
        func priority(_ value: NewsEventChangeKind) -> Int {
            switch value {
            case .initial: return 0
            case .routine: return 1
            case .majorProgress: return 2
            case .correction: return 3
            }
        }
        return priority(lhs) >= priority(rhs) ? lhs : rhs
    }

    private static func boundHistory(_ event: inout NewsEvent) {
        let maximumEvidence = 120
        let maximumClaims = 128
        let maximumTimeline = 128
        let maximumConflicts = 64
        let maximumMergeReasons = 48
        let maximumNestedRecords = 32

        for index in event.evidence.indices {
            event.evidence[index].claims = Array(event.evidence[index].claims.suffix(maximumNestedRecords)).map { claim in
                var bounded = claim
                bounded.evidenceIDs = Array(unique(claim.evidenceIDs).suffix(maximumNestedRecords))
                return bounded
            }
            event.evidence[index].timeline = Array(event.evidence[index].timeline.suffix(maximumNestedRecords)).map { node in
                var bounded = node
                bounded.evidenceIDs = Array(unique(node.evidenceIDs).suffix(maximumNestedRecords))
                return bounded
            }
            event.evidence[index].conflicts = Array(unique(event.evidence[index].conflicts).suffix(maximumNestedRecords))
            if let core = event.evidence[index].coreConflicts {
                event.evidence[index].coreConflicts = Array(unique(core).suffix(maximumNestedRecords))
            }
            if let detail = event.evidence[index].detailConflicts {
                event.evidence[index].detailConflicts = Array(unique(detail).suffix(maximumNestedRecords))
            }
        }

        if event.evidence.count > maximumEvidence {
            let bySource = Dictionary(grouping: event.evidence) { evidence -> String in
                if let sourceID = evidence.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
                    return "source:\(sourceID.lowercased())"
                }
                if let publisherKey = evidence.publisherKey?.trimmingCharacters(in: .whitespacesAndNewlines), !publisherKey.isEmpty {
                    return "publisher:\(publisherKey.lowercased())"
                }
                return "name:\(evidence.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            }
            let newestPerSource = bySource.values.compactMap { group in
                group.max {
                    if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt < $1.fetchedAt }
                    return $0.id > $1.id
                }
            }.sorted {
                if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt > $1.fetchedAt }
                return $0.id < $1.id
            }
            let preferred = Array(newestPerSource.prefix(maximumEvidence))
            let preferredIDs = Set(preferred.map(\.id))
            let fillers = event.evidence
                .filter { !preferredIDs.contains($0.id) }
                .sorted {
                    if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt > $1.fetchedAt }
                    return $0.id < $1.id
                }
                .prefix(max(0, maximumEvidence - preferred.count))
            event.evidence = (preferred + Array(fillers)).sorted {
                if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt < $1.fetchedAt }
                return $0.id < $1.id
            }
        }

        let retainedEvidenceDates = Dictionary(
            event.evidence.map { ($0.id, $0.fetchedAt) },
            uniquingKeysWith: { max($0, $1) }
        )
        event.claims = event.claims.map { claim in
            var bounded = claim
            bounded.evidenceIDs = Array(unique(claim.evidenceIDs).suffix(maximumNestedRecords))
            return bounded
        }
        event.timeline = event.timeline.map { node in
            var bounded = node
            bounded.evidenceIDs = Array(unique(node.evidenceIDs).suffix(maximumNestedRecords))
            return bounded
        }
        event.claims = Array(event.claims.sorted { lhs, rhs in
            let lhsDate = lhs.evidenceIDs.compactMap { retainedEvidenceDates[$0] }.max() ?? .distantPast
            let rhsDate = rhs.evidenceIDs.compactMap { retainedEvidenceDates[$0] }.max() ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }.prefix(maximumClaims)).sorted { $0.id < $1.id }
        event.timeline = Array(event.timeline.sorted { lhs, rhs in
            let lhsDate = lhs.occurredAt ?? lhs.evidenceIDs.compactMap { retainedEvidenceDates[$0] }.max() ?? .distantPast
            let rhsDate = rhs.occurredAt ?? rhs.evidenceIDs.compactMap { retainedEvidenceDates[$0] }.max() ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }.prefix(maximumTimeline)).sorted {
            switch ($0.occurredAt, $1.occurredAt) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
        event.conflicts = Array(unique(event.conflicts).suffix(maximumConflicts))
        event.coreConflicts = event.coreConflicts.map { Array(unique($0).suffix(maximumConflicts)) }
        event.detailConflicts = event.detailConflicts.map { Array(unique($0).suffix(maximumConflicts)) }
        event.mergeReasons = Array(unique(event.mergeReasons).suffix(maximumMergeReasons))
    }

    private static func mergeClaims(_ claims: [NewsEventClaim]) -> [NewsEventClaim] {
        var result: [String: NewsEventClaim] = [:]
        for claim in claims {
            if var existing = result[claim.id] {
                existing.evidenceIDs = unique(existing.evidenceIDs + claim.evidenceIDs)
                if claim.status == .contested || claim.status == .corrected { existing.status = claim.status }
                if claim.scope == .core || existing.scope == nil { existing.scope = claim.scope }
                result[claim.id] = existing
            } else {
                result[claim.id] = claim
            }
        }
        return result.values.sorted { $0.id < $1.id }
    }

    private static func mergeTimeline(_ nodes: [NewsEventTimelineNode]) -> [NewsEventTimelineNode] {
        var result: [String: NewsEventTimelineNode] = [:]
        for node in nodes {
            if var existing = result[node.id] {
                existing.evidenceIDs = unique(existing.evidenceIDs + node.evidenceIDs)
                result[node.id] = existing
            } else {
                result[node.id] = node
            }
        }
        return result.values.sorted {
            switch ($0.occurredAt, $1.occurredAt) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
    }

    private static func normalizeRisk(_ event: inout NewsEvent) {
        event.claims = event.claims.map { claim in
            var updated = claim
            updated.risk = NewsEventRiskClassifier.risk(in: claim.text)
            return updated
        }
        for index in event.evidence.indices {
            event.evidence[index].claims = event.evidence[index].claims.map { claim in
                var updated = claim
                updated.risk = NewsEventRiskClassifier.risk(in: claim.text)
                return updated
            }
        }
    }

    private static func normalizeConflictScopes(_ event: inout NewsEvent) {
        let eventDetails = event.detailConflicts ?? event.conflicts.filter(NewsEventInputAdapter.isDetailConflict)
        let eventDetailSet = Set(eventDetails)
        event.detailConflicts = eventDetails
        event.coreConflicts = event.coreConflicts
            ?? event.conflicts.filter { !eventDetailSet.contains($0) }
        for index in event.claims.indices where event.claims[index].scope == nil {
            event.claims[index].scope = NewsEventInputAdapter.isDetailConflict(event.claims[index].text) ? .detail : .core
        }
        for index in event.evidence.indices {
            let evidenceDetails = event.evidence[index].detailConflicts
                ?? event.evidence[index].conflicts.filter(NewsEventInputAdapter.isDetailConflict)
            let detailSet = Set(evidenceDetails)
            event.evidence[index].detailConflicts = evidenceDetails
            event.evidence[index].coreConflicts = event.evidence[index].coreConflicts
                ?? event.evidence[index].conflicts.filter { !detailSet.contains($0) }
            for claimIndex in event.evidence[index].claims.indices
                where event.evidence[index].claims[claimIndex].scope == nil {
                event.evidence[index].claims[claimIndex].scope = NewsEventInputAdapter.isDetailConflict(
                    event.evidence[index].claims[claimIndex].text
                ) ? .detail : .core
            }
        }
    }

    private static func addConfiguredAliases(
        to evidence: NewsEventEvidence,
        aliases: [String: [String]]
    ) -> NewsEventEvidence {
        var enriched = evidence
        enriched.subjectAliases = unique(
            enriched.subjectAliases + configuredAliases(
                in: "\(evidence.title) \(evidence.eventDescription) \(evidence.excerpt)",
                aliases: aliases
            )
        )
        return enriched
    }

    private static func configuredAliases(in text: String, aliases: [String: [String]]) -> [String] {
        aliases.keys.sorted().flatMap { canonical -> [String] in
            let group = [canonical] + (aliases[canonical] ?? [])
            guard group.contains(where: { containsConfiguredAlias($0, in: text) }) else { return [] }
            return group
        }
    }

    private static func containsConfiguredAlias(_ alias: String, in text: String) -> Bool {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if clean.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            let pattern = "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: clean))(?![A-Za-z0-9])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return text.range(of: clean, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
        return text.range(of: clean, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func coreConflicts(in evidence: NewsEventEvidence) -> [String] {
        if let coreConflicts = evidence.coreConflicts { return coreConflicts }
        guard let detailConflicts = evidence.detailConflicts else { return evidence.conflicts }
        let details = Set(detailConflicts)
        return evidence.conflicts.filter { !details.contains($0) }
    }

    private static func canReevaluateCandidate(_ event: NewsEvent) -> Bool {
        event.lifecycle == .expired
            && event.countablePublisherCount < 3
            && event.lastNotifiedAt == nil
            && event.notificationKeys.isEmpty
    }

    private static func isSubstantiveReevaluation(
        _ evidence: NewsEventEvidence,
        for event: NewsEvent,
        now: Date,
        sourceResolver: any NewsEventSourceResolving
    ) -> Bool {
        guard canReevaluateCandidate(event) else { return false }
        let effectiveDate = evidence.publishedAt ?? evidence.fetchedAt
        guard effectiveDate <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(effectiveDate) <= 24 * 3600 else { return false }

        let updatedPublisherCount = sourceResolver.countablePublisherCount(in: event.evidence + [evidence])
        if updatedPublisherCount > event.countablePublisherCount { return true }
        if evidence.claims.contains(where: { $0.status == .supported || $0.status == .corrected }) { return true }
        let progressText = [evidence.title, evidence.excerpt, evidence.eventDescription].joined(separator: " ")
        if NewsEventSemanticFingerprint.containsProgressSignal(in: progressText) { return true }
        let knownTimelineIDs = Set(event.timeline.map(\.id))
        return evidence.timeline.contains {
            !knownTimelineIDs.contains($0.id) && NewsEventSemanticFingerprint.containsProgressSignal(in: $0.text)
        }
    }

    private static func capacityReason(
        deletedCount: Int,
        pressureDeletedCount: Int,
        candidateDeletedCount: Int,
        protectedCount: Int,
        capacityLimited: Bool
    ) -> String {
        let cleanup = "本次清理 \(deletedCount) 条过期未通知记录（容量压力提前回收 \(pressureDeletedCount) 条，其中未达三源候选 \(candidateDeletedCount) 条）。"
        if capacityLimited {
            return "事件存储达到 500 条上限；\(cleanup)仍有 \(protectedCount) 条活跃、已通知或带去重键的记录受保护，新事件暂未接纳。"
        }
        return "容量维护完成；\(cleanup)已通知与活跃事件未被淘汰。"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func ordered(_ events: [NewsEvent]) -> [NewsEvent] {
        events.sorted {
            let lhsSuppressed = $0.interestDisposition == .hardBlocked || $0.interestDisposition == .excluded
            let rhsSuppressed = $1.interestDisposition == .hardBlocked || $1.interestDisposition == .excluded
            if lhsSuppressed != rhsSuppressed { return !lhsSuppressed }
            if $0.publicImportanceScore != $1.publicImportanceScore {
                return $0.publicImportanceScore > $1.publicImportanceScore
            }
            if $0.personalInterestScore != $1.personalInterestScore {
                return $0.personalInterestScore > $1.personalInterestScore
            }
            if $0.lastEvidenceAt != $1.lastEvidenceAt { return $0.lastEvidenceAt > $1.lastEvidenceAt }
            return $0.id < $1.id
        }
    }
}

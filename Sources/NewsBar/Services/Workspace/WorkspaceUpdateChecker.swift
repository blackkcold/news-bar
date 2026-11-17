import Foundation

/// RSS-only update check for one workspace subject.
///
/// This type deliberately does **not** own a fetcher or a budget. It goes
/// through `NewsEventController`, whose tracker owns the single
/// `NewsEventTrackingBudget`. A second budget instance against the same store
/// would let a manual check and an event tick pass the single-flight slot at
/// the same time and overdraw the rolling-hour quota.
@MainActor
final class WorkspaceUpdateChecker: WorkspaceUpdateChecking {
    static let shared = WorkspaceUpdateChecker()

    private let controllerProvider: @MainActor () -> NewsEventController
    private let store: any WorkspacePersisting
    private let researchStore: any ResearchPersisting
    private let eventStore: any NewsEventPersisting
    private let matcher: WorkspaceLeadMatcher
    private let maxFeedsPerCheck: Int
    private let throttle: TimeInterval
    private let now: @Sendable () -> Date

    init(
        controllerProvider: @escaping @MainActor () -> NewsEventController = {
            NewsEventController.shared
        },
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        researchStore: any ResearchPersisting = ResearchStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared,
        matcher: WorkspaceLeadMatcher = WorkspaceLeadMatcher(),
        /// Eight is the design ceiling, not a target. The default is one feed
        /// so a single click cannot consume the whole rolling-hour budget.
        maxFeedsPerCheck: Int = 1,
        throttle: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.controllerProvider = controllerProvider
        self.store = store
        self.researchStore = researchStore
        self.eventStore = eventStore
        self.matcher = matcher
        self.maxFeedsPerCheck = max(1, min(8, maxFeedsPerCheck))
        self.throttle = max(0, throttle)
        self.now = now
    }

    func check(
        subjectID: String,
        sources: [NewsSource],
        now checkNow: Date
    ) async -> WorkspaceUpdateCheckResult {
        guard var subject = await store.subject(id: subjectID) else {
            return failure(
                subject: placeholderSubject(id: subjectID, now: checkNow),
                message: L10n.string("workspace.check.subjectMissing"),
                at: checkNow
            )
        }

        guard !subject.isArchived else {
            return failure(
                subject: subject,
                message: L10n.string("workspace.check.archived"),
                at: checkNow
            )
        }

        if let last = subject.lastCheckedAt,
           checkNow.timeIntervalSince(last) < throttle {
            let until = last.addingTimeInterval(throttle)
            _ = try? await store.updateSubject(id: subject.id) { latest in
                latest.lastCheckOutcome = .throttled(until: until)
            }
            var coverage = WorkspaceCheckCoverage()
            coverage.nextEligibleAt = until
            subject.lastCheckOutcome = .throttled(until: until)
            return WorkspaceUpdateCheckResult(
                subject: subject,
                added: [],
                outcome: .throttled(until: until),
                coverage: coverage
            )
        }

        let eligible = eligibleSources(from: sources)
        guard !eligible.isEmpty else {
            _ = try? await store.updateSubject(id: subject.id) { latest in
                latest.lastCheckOutcome = .notConfigured
            }
            subject.lastCheckOutcome = .notConfigured
            return WorkspaceUpdateCheckResult(
                subject: subject,
                added: [],
                outcome: .notConfigured,
                coverage: WorkspaceCheckCoverage()
            )
        }

        let plan = await planFeed(from: eligible, now: checkNow)
        switch plan {
        case let .source(source, budget):
            return await check(
                source: source,
                subject: subject,
                eligibleCount: eligible.count,
                budget: budget,
                now: checkNow
            )
        case let .allBackingOff(retryAt, budget):
            var coverage = WorkspaceCheckCoverage()
            coverage.eligibleSourceCount = eligible.count
            coverage.deferredSourceCount = eligible.count
            coverage.budgetUsed = budget?.checksUsed
            coverage.budgetLimit = budget?.checksLimit
            coverage.budgetResetsAt = budget?.resetsAt
            coverage.retryAt = retryAt
            _ = try? await store.updateSubject(id: subject.id) { latest in
                latest.lastCheckOutcome = .throttled(until: retryAt)
            }
            subject.lastCheckOutcome = .throttled(until: retryAt)
            return WorkspaceUpdateCheckResult(
                subject: subject,
                added: [],
                outcome: .throttled(until: retryAt),
                coverage: coverage
            )
        }
    }

    // MARK: - Check one feed

    private func check(
        source: NewsSource,
        subject: WorkspaceSubject,
        eligibleCount: Int,
        budget: NewsEventBudgetSnapshot?,
        now checkNow: Date
    ) async -> WorkspaceUpdateCheckResult {
        let controller = controllerProvider()
        let refresh = await controller.checkSharedFeed(source, now: checkNow)
        var coverage = WorkspaceCheckCoverage()
        coverage.eligibleSourceCount = eligibleCount
        coverage.deferredSourceCount = max(0, eligibleCount - 1)
        coverage.nextEligibleAt = checkNow.addingTimeInterval(throttle)
        coverage.budgetUsed = budget?.checksUsed
        coverage.budgetLimit = budget?.checksLimit
        coverage.budgetResetsAt = budget?.resetsAt

        switch refresh {
        case let .reused(cursor, snapshot):
            coverage.reusedSharedCheck = true
            coverage.budgetUsed = snapshot.checksUsed
            coverage.budgetLimit = snapshot.checksLimit
            coverage.budgetResetsAt = snapshot.resetsAt
            coverage.nextEligibleAt = max(
                checkNow.addingTimeInterval(throttle),
                (cursor.checkedAt ?? checkNow).addingTimeInterval(throttle)
            )
            let evidence = await reusableEvidence(
                source: source,
                cursor: cursor,
                now: checkNow
            )
            let candidates = candidates(
                from: evidence,
                subject: subject,
                now: checkNow
            )
            let newCandidates = await unseenCandidates(
                candidates,
                subjectID: subject.id
            )
            if !candidates.isEmpty {
                do {
                    try await store.saveUpdates(candidates, for: subject.id)
                } catch {
                    return failure(
                        subject: subject,
                        message: L10n.string("workspace.check.leadSaveFailed"),
                        at: checkNow,
                        coverage: coverage
                    )
                }
            }
            return await finishSuccess(
                subject: subject,
                added: newCandidates,
                reviewCandidates: candidates,
                coverage: coverage,
                at: checkNow
            )

        case let .notModified(cursor, snapshot):
            // A successful 304 is a successful check.
            coverage.checkedSourceIDs = [source.id]
            coverage.checkedSourceNames = [source.displayName]
            coverage.budgetUsed = snapshot.checksUsed
            coverage.budgetLimit = snapshot.checksLimit
            coverage.budgetResetsAt = snapshot.resetsAt
            let committed = await controller.commitSharedFeedCheck(cursor)
            guard committed else {
                return failure(
                    subject: subject,
                    message: L10n.string("workspace.check.cursorFailed"),
                    at: checkNow,
                    coverage: coverage
                )
            }
            return await finishSuccess(
                subject: subject,
                added: [],
                coverage: coverage,
                at: checkNow
            )

        case let .modified(evidence, cursor, snapshot):
            coverage.checkedSourceIDs = [source.id]
            coverage.checkedSourceNames = [source.displayName]
            coverage.budgetUsed = snapshot.checksUsed
            coverage.budgetLimit = snapshot.checksLimit
            coverage.budgetResetsAt = snapshot.resetsAt

            let candidates = candidates(
                from: evidence,
                subject: subject,
                now: checkNow
            )
            let newCandidates = await unseenCandidates(
                candidates,
                subjectID: subject.id
            )
            if !candidates.isEmpty {
                do {
                    try await store.saveUpdates(candidates, for: subject.id)
                } catch {
                    await controller.recordSharedFeedFailure(
                        sourceID: source.id,
                        now: checkNow,
                        message: "workspace leads could not be saved"
                    )
                    return failure(
                        subject: subject,
                        message: L10n.string("workspace.check.leadSaveFailed"),
                        at: checkNow,
                        coverage: coverage
                    )
                }
            }

            // The shared cursor is also the event tracker's cursor. Ingest the
            // same evidence before committing, otherwise advancing the cursor
            // would hide these items from event discovery forever.
            let durable = await controller.ingest(evidence, now: checkNow)
            guard durable else {
                await controller.recordSharedFeedFailure(
                    sourceID: source.id,
                    now: checkNow,
                    message: "RSS evidence could not be persisted"
                )
                return failure(
                    subject: subject,
                    message: L10n.string("workspace.check.evidenceFailed"),
                    at: checkNow,
                    coverage: coverage
                )
            }

            guard await controller.commitSharedFeedCheck(cursor) else {
                return failure(
                    subject: subject,
                    message: L10n.string("workspace.check.cursorFailed"),
                    at: checkNow,
                    coverage: coverage
                )
            }
            return await finishSuccess(
                subject: subject,
                added: newCandidates,
                reviewCandidates: candidates,
                coverage: coverage,
                at: checkNow
            )

        case let .pending(snapshot, reason):
            coverage.budgetUsed = snapshot.checksUsed
            coverage.budgetLimit = snapshot.checksLimit
            coverage.budgetResetsAt = snapshot.resetsAt
            let until = checkNow.addingTimeInterval(10)
            var updated = subject
            let outcome = WorkspaceCheckOutcome.throttled(until: until)
            updated.lastCheckOutcome = outcome
            _ = try? await store.updateSubject(id: subject.id) { latest in
                latest.lastCheckOutcome = outcome
            }
            return WorkspaceUpdateCheckResult(
                subject: updated,
                added: [],
                outcome: outcome,
                coverage: coverage
            )

        case let .throttled(until, snapshot, reason):
            coverage.budgetUsed = snapshot.checksUsed
            coverage.budgetLimit = snapshot.checksLimit
            coverage.budgetResetsAt = snapshot.resetsAt
            coverage.retryAt = until
            var updated = subject
            let outcome = WorkspaceCheckOutcome.throttled(
                until: until ?? checkNow.addingTimeInterval(throttle)
            )
            updated.lastCheckOutcome = outcome
            _ = try? await store.updateSubject(id: subject.id) { latest in
                latest.lastCheckOutcome = outcome
            }
            return WorkspaceUpdateCheckResult(
                subject: updated,
                added: [],
                outcome: outcome,
                coverage: coverage
            )

        case let .failed(message, retryAt, snapshot):
            coverage.budgetUsed = snapshot.checksUsed
            coverage.budgetLimit = snapshot.checksLimit
            coverage.budgetResetsAt = snapshot.resetsAt
            coverage.retryAt = retryAt
            coverage.failureSourceName = source.displayName
            var updated = subject
            let outcome = WorkspaceCheckOutcome.failed(message: message, at: checkNow)
            updated.lastCheckOutcome = outcome
            _ = try? await store.updateSubject(id: subject.id) { latest in
                latest.lastCheckOutcome = outcome
            }
            return WorkspaceUpdateCheckResult(
                subject: updated,
                added: [],
                outcome: outcome,
                coverage: coverage
            )
        }
    }

    /// Persists a successful outcome and the report-age review flag. The lead
    /// candidates were already saved, so a failure here is reported without
    /// pretending the check did not happen.
    private func finishSuccess(
        subject: WorkspaceSubject,
        added: [WorkspaceUpdateCandidate],
        reviewCandidates: [WorkspaceUpdateCandidate]? = nil,
        coverage: WorkspaceCheckCoverage,
        at checkNow: Date
    ) async -> WorkspaceUpdateCheckResult {
        var updated = subject
        let outcome = WorkspaceCheckOutcome.checked(added: added.count, at: checkNow)
        let review = reviewCandidates ?? added
        var readyReport = false
        var hasNewerEvidence = false
        var pendingReviewIDs: [String] = []
        if !review.isEmpty, !updated.isArchived {
            let linkedRecord = await latestRecord(for: updated)
            let reportDate = linkedRecord?.report?.generatedAt
                ?? linkedRecord?.updatedAt
                ?? .distantPast
            readyReport = (linkedRecord?.status == .ready || linkedRecord?.status == .partial)
                && linkedRecord?.report != nil
            let analyzedURLs = Set(
                (linkedRecord?.report?.evidence ?? []).map {
                    ContentIdentity.canonicalURL($0.canonicalURL)
                }
            )
            let newer = review.filter { candidate in
                let canonical = ContentIdentity.canonicalURL(candidate.url)
                guard !analyzedURLs.contains(canonical) else { return false }
                let eventDate = candidate.publishedAt ?? candidate.discoveredAt
                return eventDate > reportDate
            }
            hasNewerEvidence = !newer.isEmpty
            pendingReviewIDs = newer.map(\.id)
        }

        do {
            updated = try await store.updateSubject(id: subject.id) { latest in
                if checkNow >= (latest.lastCheckedAt ?? .distantPast) {
                    latest.lastCheckedAt = checkNow
                    latest.lastCheckOutcome = outcome
                }
                if readyReport, hasNewerEvidence, !latest.isArchived {
                    latest.updateState = .needsReview
                    latest.pendingUpdateIDs = Array(
                        Set(latest.pendingUpdateIDs + pendingReviewIDs)
                    ).sorted()
                }
            }
        } catch {
            var failedCoverage = coverage
            failedCoverage.addedCount = added.count
            return failure(
                subject: subject,
                message: L10n.string("workspace.check.stateSaveFailed"),
                at: checkNow,
                coverage: failedCoverage
            )
        }

        var finalCoverage = coverage
        finalCoverage.addedCount = added.count
        return WorkspaceUpdateCheckResult(
            subject: updated,
            added: added,
            outcome: updated.lastCheckOutcome,
            coverage: finalCoverage
        )
    }

    // MARK: - Feed plan

    private enum FeedPlan {
        case source(NewsSource, NewsEventBudgetSnapshot?)
        case allBackingOff(Date, NewsEventBudgetSnapshot?)
    }

    private func planFeed(
        from sources: [NewsSource],
        now checkNow: Date
    ) async -> FeedPlan {
        let controller = controllerProvider()
        var cursorBySource: [String: NewsEventFeedCursor] = [:]
        for source in sources {
            do {
                if let cursor = try await NewsEventStore.shared.feedCursor(for: source.id) {
                    cursorBySource[source.id] = cursor
                }
            } catch {
                // A missing/unreadable cursor is treated as "never checked";
                // the fetch itself will surface a real failure.
            }
        }

        let due = sources
            .filter { source in
                guard let retry = cursorBySource[source.id]?.retryAfter else { return true }
                return retry <= checkNow
            }
            .sorted { lhs, rhs in
                let left = Self.latest(
                    cursorBySource[lhs.id]?.checkedAt,
                    cursorBySource[lhs.id]?.attemptedAt
                ) ?? .distantPast
                let right = Self.latest(
                    cursorBySource[rhs.id]?.checkedAt,
                    cursorBySource[rhs.id]?.attemptedAt
                ) ?? .distantPast
                if left != right { return left < right }
                return lhs.id < rhs.id
            }

        if let source = due.first {
            return .source(
                source,
                await controller.sharedFeedBudgetSnapshot(now: checkNow)
            )
        }

        let retryAt = sources
            .compactMap { cursorBySource[$0.id]?.retryAfter }
            .filter { $0 > checkNow }
            .min()
            ?? checkNow.addingTimeInterval(throttle)
        return .allBackingOff(
            retryAt,
            await controller.sharedFeedBudgetSnapshot(now: checkNow)
        )
    }

    // MARK: - Candidates

    /// Uses the already-durable event evidence for this exact RSS source. The
    /// normal refresh and a prior shared check ingest their RSS items into the
    /// event store, so no second HTTP request is needed to serve a new subject.
    private func reusableEvidence(
        source: NewsSource,
        cursor: NewsEventFeedCursor,
        now checkNow: Date
    ) async -> [NewsEventEvidence] {
        let anchor = cursor.checkedAt ?? checkNow
        let cutoff = min(checkNow, anchor).addingTimeInterval(-24 * 3_600)
        let events = (try? await eventStore.events()) ?? []
        var seen = Set<String>()
        return events
            .flatMap(\.evidence)
            .filter { item in
                guard item.sourceID == source.id,
                      item.inputKind != .research,
                      item.fetchedAt >= cutoff,
                      item.fetchedAt <= checkNow else { return false }
                return seen.insert(item.id).inserted
            }
            .sorted { $0.fetchedAt > $1.fetchedAt }
    }

    private func eligibleSources(from sources: [NewsSource]) -> [NewsSource] {
        var seen = Set<String>()
        return sources.compactMap { source in
            guard case .rss = source, seen.insert(source.id).inserted else { return nil }
            return source
        }
    }

    private func candidates(
        from evidence: [NewsEventEvidence],
        subject: WorkspaceSubject,
        now checkNow: Date
    ) -> [WorkspaceUpdateCandidate] {
        let aliases = [subject.title] + subject.aliases
        var seen = Set<String>()
        return evidence.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !url.isEmpty else { return nil }
            guard matcher.matches(title: title, summary: item.excerpt, aliases: aliases) else {
                return nil
            }
            let id = WorkspaceUpdateCandidate.identity(subjectID: subject.id, url: url)
            guard seen.insert(id).inserted else { return nil }
            return WorkspaceUpdateCandidate(
                id: id,
                subjectID: subject.id,
                title: title,
                url: url,
                sourceName: item.sourceName,
                publishedAt: item.publishedAt,
                discoveredAt: item.fetchedAt > .distantPast ? item.fetchedAt : checkNow,
                origin: .rss
            )
        }
    }

    private func unseenCandidates(
        _ candidates: [WorkspaceUpdateCandidate],
        subjectID: String
    ) async -> [WorkspaceUpdateCandidate] {
        guard !candidates.isEmpty else { return [] }
        let existing = Set(
            await store.updates(subjectID: subjectID).map { $0.canonicalized().id }
        )
        return candidates.filter { !existing.contains($0.id) }
    }

    private func latestRecord(for subject: WorkspaceSubject) async -> ResearchRecord? {
        var records: [ResearchRecord] = []
        for id in subject.researchRecordIDs {
            if let record = await researchStore.record(id: id),
               record.loadIssue == nil,
               record.status != .corrupt {
                records.append(record)
            }
        }
        return records.max { $0.updatedAt < $1.updatedAt }
    }

    private func failure(
        subject: WorkspaceSubject,
        message: String,
        at date: Date,
        coverage: WorkspaceCheckCoverage = WorkspaceCheckCoverage()
    ) -> WorkspaceUpdateCheckResult {
        var updated = subject
        updated.lastCheckOutcome = .failed(message: message, at: date)
        return WorkspaceUpdateCheckResult(
            subject: updated,
            added: [],
            outcome: .failed(message: message, at: date),
            coverage: coverage
        )
    }

    private func placeholderSubject(id: String, now date: Date) -> WorkspaceSubject {
        WorkspaceSubject(
            id: id,
            title: "",
            createdAt: date,
            updatedAt: date,
            lastActivityAt: date
        )
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }
}

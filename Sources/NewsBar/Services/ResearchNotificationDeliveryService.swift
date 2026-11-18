import Foundation

/// Converts materially changed, source-located report versions into one
/// policy-aware notification or existing digest entry. It never starts
/// research or changes report state.
@MainActor
final class ResearchNotificationDeliveryService {
    static let shared = ResearchNotificationDeliveryService()

    private struct PreparedDelivery {
        let subject: WorkspaceSubject?
        let currentVersion: WorkspaceReportVersion?
        let baselineVersion: WorkspaceReportVersion?
        let isCorrection: Bool
        let event: NewsEvent?
        let sourceURL: String?
    }

    private let workspaceStore: any WorkspacePersisting
    private let eventStore: any NewsEventPersisting
    private let coordinator: WorkspaceNotificationCoordinator

    init(
        workspaceStore: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared,
        coordinator: WorkspaceNotificationCoordinator = .shared
    ) {
        self.workspaceStore = workspaceStore
        self.eventStore = eventStore
        self.coordinator = coordinator
    }

    @discardableResult
    func deliver(
        _ record: ResearchRecord,
        settings: AppSettings,
        notificationCoordinator: WorkspaceNotificationCoordinator? = nil
    ) async -> Bool {
        guard ResearchNotificationPreferences.enabled,
              let prepared = await prepare(record) else { return false }

        let eventID = prepared.event?.id
        let item = NotificationService.makeResearchDigestItem(
            record: record,
            eventID: eventID,
            versionID: prepared.currentVersion?.id,
            compareFromVersionID: prepared.isCorrection ? prepared.baselineVersion?.id : nil,
            sourceURL: prepared.sourceURL,
            isCorrection: prepared.isCorrection
        )
        let deliveryCoordinator = notificationCoordinator ?? coordinator
        let decision = await deliveryCoordinator.authorizeResearch(recordID: record.id, at: Date())
        guard decision.isAllowed else { return false }

        let accepted: Bool
        let usesDigest = !prepared.isCorrection && (settings.hourlyPushEnabled || settings.dailyPushEnabled)
        if usesDigest {
            accepted = await NotificationService.deliverSummaryItem(
                item,
                pushCount: settings.pushCount,
                hourlyEnabled: settings.hourlyPushEnabled,
                dailyEnabled: settings.dailyPushEnabled,
                dailyHour: settings.dailyPushHour,
                dailyMinute: settings.dailyPushMinute
            )
        } else {
            do {
                let sent = try await NotificationService.sendResearchNotificationAndWait(
                    record: record,
                    subjectID: prepared.subject?.id,
                    eventID: eventID,
                    versionID: prepared.currentVersion?.id,
                    compareFromVersionID: prepared.isCorrection ? prepared.baselineVersion?.id : nil,
                    sourceURL: prepared.sourceURL,
                    isCorrection: prepared.isCorrection
                )
                accepted = sent != nil
            } catch {
                accepted = false
            }
        }

        guard accepted else { return false }
        await deliveryCoordinator.recordResearchNotified(recordID: record.id, at: Date())
        return true
    }

    /// Compatibility path for ResearchCoordinator instances that still use
    /// the original direct-notification callback. It goes through the same
    /// evidence, change, archive and preference gate as the current path.
    @discardableResult
    func deliverLegacy(_ record: ResearchRecord, subjectID: String? = nil) async -> Bool {
        guard ResearchNotificationPreferences.enabled,
              let prepared = await prepare(record) else { return false }
        let deliveryCoordinator = coordinator
        let decision = await deliveryCoordinator.authorizeResearch(recordID: record.id, at: Date())
        guard decision.isAllowed else { return false }

        do {
            guard try await NotificationService.sendResearchNotificationAndWait(
                record: record,
                subjectID: subjectID ?? prepared.subject?.id,
                eventID: prepared.event?.id,
                versionID: prepared.currentVersion?.id,
                compareFromVersionID: prepared.isCorrection ? prepared.baselineVersion?.id : nil,
                sourceURL: prepared.sourceURL,
                isCorrection: prepared.isCorrection
            ) != nil else { return false }
            await deliveryCoordinator.recordResearchNotified(recordID: record.id, at: Date())
            return true
        } catch {
            return false
        }
    }

    private func prepare(_ record: ResearchRecord) async -> PreparedDelivery? {
        guard record.loadIssue == nil,
              record.status == .ready || record.status == .partial,
              let report = record.report else { return nil }
        let qualifiedClaims = ResearchNotificationQualification.qualifiedClaims(in: report)
        guard !qualifiedClaims.isEmpty else { return nil }

        let subject = await workspaceStore.subject(containingResearchID: record.id)
        guard subject?.isArchived != true else { return nil }
        let versions = await workspaceStore.versions(recordID: record.id)
        let digest = WorkspaceReportDigest.make(report)
        let currentIndex = versions.lastIndex(where: { $0.digest == digest })
        let currentVersion = currentIndex.map { versions[$0] }
        let immediatePreviousVersion: WorkspaceReportVersion? = if let currentIndex, currentIndex > 0 {
            versions[currentIndex - 1]
        } else if currentIndex == nil {
            versions.last
        } else {
            nil
        }
        let previouslyNotifiedVersion = subject?.lastNotifiedReference.flatMap { reference in
            versions.last(where: { Self.causalToken(recordID: record.id, version: $0) == reference })
        }
        let baselineVersion = previouslyNotifiedVersion ?? immediatePreviousVersion
        let changedClaims = Self.changedClaims(
            current: qualifiedClaims,
            comparedWith: baselineVersion?.report
        )
        guard !changedClaims.isEmpty else { return nil }

        let isCorrection = previouslyNotifiedVersion != nil
            && subject?.lastNotificationKind != nil
            && Self.hasClaimReversal(
                changedClaims,
                from: previouslyNotifiedVersion?.report
            )

        let linkedEvents: [NewsEvent]
        if let subject {
            linkedEvents = (try? await eventStore.events())?.filter { subject.contains(eventID: $0.id) } ?? []
        } else {
            linkedEvents = []
        }
        let event = linkedEvents.max(by: { $0.lastEvidenceAt < $1.lastEvidenceAt })
        let changedClaim = isCorrection
            ? changedClaims.first(where: { Self.isReversal($0, from: previouslyNotifiedVersion?.report) })
            : changedClaims.first
        let sourceURL = changedClaim?.evidence.first?.url

        return PreparedDelivery(
            subject: subject,
            currentVersion: currentVersion,
            baselineVersion: baselineVersion,
            isCorrection: isCorrection,
            event: event,
            sourceURL: sourceURL
        )
    }

    private static func changedClaims(
        current: [QualifiedResearchClaim],
        comparedWith previousReport: BurstResearch?
    ) -> [QualifiedResearchClaim] {
        guard let previousReport else { return current }
        let previousClaims = previousReport.verification?.claims ?? []
        return current.filter { currentClaim in
            guard let previous = previousClaims.first(where: {
                ResearchNotificationQualification.normalizedClaim($0.claim)
                    == ResearchNotificationQualification.normalizedClaim(currentClaim.claim.claim)
            }) else { return true }
            return previous.status != currentClaim.claim.status
        }
    }

    private static func hasClaimReversal(
        _ changed: [QualifiedResearchClaim],
        from previousReport: BurstResearch?
    ) -> Bool {
        changed.contains { isReversal($0, from: previousReport) }
    }

    private static func isReversal(
        _ current: QualifiedResearchClaim,
        from previousReport: BurstResearch?
    ) -> Bool {
        guard let previous = previousReport?.verification?.claims.first(where: {
            ResearchNotificationQualification.normalizedClaim($0.claim)
                == ResearchNotificationQualification.normalizedClaim(current.claim.claim)
        }),
        let previousStatus = previous.status,
        let currentStatus = current.claim.status else { return false }
        return (previousStatus == .supports && currentStatus == .refutes)
            || (previousStatus == .refutes && currentStatus == .supports)
    }

    private static func causalToken(recordID: String, version: WorkspaceReportVersion) -> String {
        let generated = version.report.generatedAt.map { String($0.timeIntervalSince1970) } ?? "no-date"
        return "research:\(recordID):\(generated):\(version.digest)"
    }
}

private struct QualifiedResearchClaim {
    let claim: ClaimCheck
    let evidence: [EvidenceItem]
}

enum ResearchNotificationQualification {
    fileprivate static func qualifiedClaims(in report: BurstResearch) -> [QualifiedResearchClaim] {
        guard let claims = report.verification?.claims else { return [] }
        return claims.compactMap { claim in
            guard let status = claim.status, status == .supports || status == .refutes else { return nil }
            let evidence = report.evidence.filter { item in
                claim.evidenceIDs.contains(item.id)
                    && item.quoteVerified
                    && !item.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && item.stance == status
                    && ReaderNavigationPolicy.allowedURL(item.url) != nil
            }
            guard !evidence.isEmpty else { return nil }
            return QualifiedResearchClaim(claim: claim, evidence: evidence)
        }
    }

    static func allowsNotification(_ record: ResearchRecord) -> Bool {
        guard record.loadIssue == nil,
              record.status == .ready || record.status == .partial,
              let report = record.report else { return false }
        return !qualifiedClaims(in: report).isEmpty
    }

    static func verifiedPreview(in report: BurstResearch, language: AppLanguage) -> String? {
        guard let qualified = qualifiedClaims(in: report).first else { return nil }
        let claim = ResearchNotificationSummary.sanitize(qualified.claim.claim)
        guard !claim.isEmpty else { return nil }
        let prefix: String
        guard let status = qualified.claim.status else { return nil }
        switch status {
        case .supports:
            prefix = language == .en ? "Verified evidence supports:" : "核验来源支持："
        case .refutes:
            prefix = language == .en ? "Verified evidence refutes:" : "核验来源反驳："
        default:
            return nil
        }
        return ResearchNotificationSummary.truncate("\(prefix) \(claim)", to: 160)
    }

    fileprivate static func normalizedClaim(_ value: String) -> String {
        value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

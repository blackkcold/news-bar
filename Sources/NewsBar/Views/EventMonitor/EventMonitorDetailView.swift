import SwiftUI

struct EventMonitorDetailView: View {
    @Environment(AppSettings.self) private var settings

    @Bindable var model: EventMonitorCenterModel
    let event: NewsEvent
    let onOpenReminderSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                monitorStatus
                importanceAndInterest
                claims
                sourceAttribution
                timeline
                mergeReasons
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.visible)
        .appThemeSurface()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(event.title)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !event.eventDescription.isEmpty && event.eventDescription != event.title {
                Text(event.eventDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { statusTags }
                VStack(alignment: .leading, spacing: 6) { statusTags }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.string(
                    "event.publisherCount",
                    language: settings.appLanguage,
                    event.countablePublisherCount,
                    3
                ))
                .font(.title3.monospacedDigit().weight(.semibold))
                Text("event.publisherCount.caption".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("event.publisherCount.disclaimer".localized)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    Task { await model.checkNow() }
                } label: {
                    Label(
                        model.isChecking ? "event.check.checking".localized : "event.check.now".localized,
                        systemImage: model.isChecking ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .disabled(!settings.newsEventMonitoringEnabled || model.isChecking)
                .accessibilityHint("event.check.now.hint".localized)

                Button("event.settings.open".localized, systemImage: "slider.horizontal.3", action: onOpenReminderSettings)
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
            }
        }
        .padding(16)
        .newsCardSurface()
    }

    @ViewBuilder
    private var statusTags: some View {
        EditorialTag(text: L10n.string(lifecycleKey, language: settings.appLanguage), fallbackTint: lifecycleTint)
        if event.wasNotified {
            EditorialTag(text: "event.status.notified".localized, fallbackTint: .purple)
        }
        if event.trackingStatus == .budgetDeferred {
            EditorialTag(text: "event.status.budgetPaused".localized, fallbackTint: .orange)
        }
        if event.hasConflict {
            EditorialTag(text: "event.status.conflict".localized, fallbackTint: .red)
        }
    }

    private var monitorStatus: some View {
        detailSection("02", "event.detail.monitoring", "event.detail.monitoring.subtitle") {
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent("event.detail.trackingStatus".localized) {
                    Text(L10n.string(trackingStatusKey, language: settings.appLanguage))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("event.detail.globalMonitor".localized) {
                    Text(L10n.string(
                        settings.newsEventMonitoringEnabled ? "event.globalMonitor.on" : "event.globalMonitor.off",
                        language: settings.appLanguage
                    ))
                    .multilineTextAlignment(.trailing)
                }
                if let nextCheckAt = event.nextCheckAt {
                    LabeledContent("event.detail.nextCheck".localized) {
                        Text(nextCheckAt.formatted(date: .abbreviated, time: .shortened))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let lastCheckedAt = event.lastCheckedAt {
                    LabeledContent("event.detail.lastCheck".localized) {
                        Text(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("event.detail.lastEvidence".localized) {
                    Text(event.lastEvidenceAt, style: .relative)
                        .multilineTextAlignment(.trailing)
                }
                if let expiresAt = event.expiresAt {
                    LabeledContent("event.detail.expiredAt".localized) {
                        Text(expiresAt.formatted(date: .abbreviated, time: .shortened))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let trackingMessage = event.trackingMessage, !trackingMessage.isEmpty {
                    Text(trackingMessage)
                        .font(.callout)
                        .foregroundStyle(event.trackingStatus == .failed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L10n.string("event.detail.backendReason", language: settings.appLanguage, trackingMessage))
                }
                Text("event.detail.checkScope".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var importanceAndInterest: some View {
        detailSection("03", "event.detail.reasons", "event.detail.reasons.subtitle") {
            VStack(alignment: .leading, spacing: 12) {
                reasonBlock(
                    title: "event.detail.publicImportance".localized,
                    text: event.publicImportanceReason ?? "event.reason.unknown".localized,
                    symbol: "globe"
                )
                reasonBlock(
                    title: "event.detail.personalInterest".localized,
                    text: event.interestReasons.isEmpty
                        ? "event.reason.openDiscovery".localized
                        : event.interestReasons.joined(separator: " · "),
                    symbol: "person.crop.circle"
                )
                reasonBlock(
                    title: "event.detail.notificationEligibility".localized,
                    text: L10n.string(
                        "event.notificationEligibility.\(event.notificationEligibility.rawValue)",
                        language: settings.appLanguage
                    ),
                    symbol: "bell.badge"
                )
                reasonBlock(
                    title: "event.detail.notificationSetting".localized,
                    text: L10n.string(
                        settings.newsEventNotificationsEnabled
                            ? "event.notificationDelivery.enabled"
                            : "event.notificationDelivery.disabled",
                        language: settings.appLanguage
                    ),
                    symbol: "bell"
                )
                if !event.notificationMessage.isNilOrEmpty {
                    reasonBlock(
                        title: "event.detail.notificationRuntime".localized,
                        text: event.notificationMessage ?? "",
                        symbol: "bell"
                    )
                }
            }
        }
    }

    private var claims: some View {
        detailSection("04", "event.detail.facts", "event.detail.facts.subtitle") {
            if event.claims.isEmpty {
                Text("event.detail.noClaims".localized)
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(event.claims) { claim in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(L10n.string(claimStatusKey(claim.status), language: settings.appLanguage))
                                    .font(.subheadline.weight(.semibold))
                                if claim.risk == .highRisk {
                                    EditorialTag(text: "event.claim.highRisk".localized, fallbackTint: .orange)
                                }
                                if claim.scope == .detail {
                                    EditorialTag(text: "event.claim.detail".localized, fallbackTint: .secondary)
                                }
                            }
                            Text(claim.text)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            evidenceLinks(for: claim.evidenceIDs)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .newsCardSurface()
                    }
                }
            }

            if !event.coreConflictDetails.isEmpty || !event.detailConflictDetails.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !event.coreConflictDetails.isEmpty {
                        conflictBlock(title: "event.detail.coreConflict".localized, values: event.coreConflictDetails)
                    }
                    if !event.detailConflictDetails.isEmpty {
                        conflictBlock(title: "event.detail.detailConflict".localized, values: event.detailConflictDetails)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var sourceAttribution: some View {
        detailSection("05", "event.detail.sources", "event.detail.sources.subtitle") {
            if event.sourceGroups.isEmpty && event.evidence.isEmpty {
                Text("event.detail.noSources".localized)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(event.sourceGroups) { group in
                    sourceGroupRow(group)
                }
            }

            if !event.evidence.isEmpty {
                Divider().padding(.vertical, 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(event.evidence.sorted(by: evidenceOrder)) { evidence in
                        evidenceRow(evidence)
                    }
                }
            }
        }
    }

    private var timeline: some View {
        detailSection("06", "event.detail.timeline", "event.detail.timeline.subtitle") {
            if event.timeline.isEmpty {
                Text("event.detail.noTimeline".localized)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(event.timeline.enumerated()), id: \.element.id) { index, node in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(index == 0 ? Color.accentColor : Color.secondary.opacity(0.65))
                                    .frame(width: 8, height: 8)
                                if index < event.timeline.count - 1 {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.25))
                                        .frame(width: 1, height: 36)
                                }
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                if let occurredAt = node.occurredAt {
                                    Text(occurredAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(node.text)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                evidenceLinks(for: node.evidenceIDs)
                            }
                            .padding(.bottom, 14)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var mergeReasons: some View {
        Group {
            if !event.mergeReasons.isEmpty {
                detailSection("07", "event.detail.mergeReasons", "event.detail.mergeReasons.subtitle") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(event.mergeReasons.enumerated()), id: \.offset) { _, reason in
                            Label(reason, systemImage: "arrow.triangle.merge")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func detailSection<Content: View>(
        _ index: String,
        _ titleKey: String,
        _ subtitleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeading(
                index: index,
                title: L10n.string(titleKey, language: settings.appLanguage),
                subtitle: L10n.string(subtitleKey, language: settings.appLanguage)
            )
            content()
        }
        .padding(16)
        .newsCardSurface()
    }

    private func reasonBlock(title: String, text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func conflictBlock(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Label(value, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func evidenceLinks(for ids: [String]) -> some View {
        let linkedEvidence = ids.compactMap { id in event.evidence.first(where: { $0.id == id }) }
        if !linkedEvidence.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { evidenceLinkButtons(linkedEvidence) }
                VStack(alignment: .leading, spacing: 4) { evidenceLinkButtons(linkedEvidence) }
            }
        }
    }

    @ViewBuilder
    private func evidenceLinkButtons(_ evidence: [NewsEventEvidence]) -> some View {
        ForEach(evidence) { item in
            Button {
                open(item)
            } label: {
                Label(item.sourceName, systemImage: "arrow.up.right.square")
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.link)
            .accessibilityLabel(L10n.string(
                "event.openSource.accessibility",
                language: settings.appLanguage,
                item.sourceName,
                item.title
            ))
        }
    }

    private func sourceGroupRow(_ group: NewsEventSourceGroup) -> some View {
        let evidence = event.evidence.filter { group.evidenceIDs.contains($0.id) }
        let isTrend = !evidence.isEmpty && evidence.allSatisfy { $0.inputKind == .trend }
        let countable = group.publisherKind != .official && !isTrend && group.publisherKey != nil

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(group.displayName)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if isTrend {
                    EditorialTag(text: "event.source.trend".localized, fallbackTint: .orange)
                } else if group.publisherKind == .official {
                    EditorialTag(text: "event.source.official".localized, fallbackTint: .blue)
                } else if countable {
                    EditorialTag(text: "event.source.counted".localized, fallbackTint: .green)
                } else {
                    EditorialTag(text: "event.source.attributionUnknown".localized, fallbackTint: .secondary)
                }
            }
            if let publisherKey = group.publisherKey, !isTrend {
                Text(L10n.string("event.source.publisherIdentity", language: settings.appLanguage, publisherKey))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.string(independenceKey(group.independence), language: settings.appLanguage))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if group.publisherKind == .unknown && !isTrend {
                Text("event.source.unknownPublisherType".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .newsCardSurface()
        .accessibilityElement(children: .combine)
    }

    private func evidenceRow(_ evidence: NewsEventEvidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open(evidence)
            } label: {
                Text(evidence.title)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.link)
            .accessibilityLabel(L10n.string(
                "event.openSource.accessibility",
                language: settings.appLanguage,
                evidence.sourceName,
                evidence.title
            ))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { evidenceMetadata(evidence) }
                VStack(alignment: .leading, spacing: 4) { evidenceMetadata(evidence) }
            }

            if !evidence.excerpt.isEmpty && evidence.excerpt != evidence.title {
                Text(evidence.excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(evidence.url)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .newsCardSurface()
    }

    @ViewBuilder
    private func evidenceMetadata(_ evidence: NewsEventEvidence) -> some View {
        Text(L10n.string(inputKindKey(evidence.inputKind), language: settings.appLanguage))
        Text(evidence.sourceName)
        if let author = evidence.author, !author.isEmpty { Text(author) }
        Text(evidence.publishedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "event.source.timeUnknown".localized)
        Text(L10n.string(publisherKindKey(evidence.publisherKind), language: settings.appLanguage))
    }

    private func open(_ evidence: NewsEventEvidence) {
        NewsNavigationRouter.shared.open(
            url: evidence.url,
            title: evidence.title,
            surface: "newsEventMonitor"
        )
    }

    private func evidenceOrder(_ lhs: NewsEventEvidence, _ rhs: NewsEventEvidence) -> Bool {
        if lhs.publishedAt != rhs.publishedAt {
            return (lhs.publishedAt ?? lhs.fetchedAt) > (rhs.publishedAt ?? rhs.fetchedAt)
        }
        return lhs.id < rhs.id
    }

    private var lifecycleKey: String {
        switch event.lifecycle {
        case .queued: return "event.status.candidate"
        case .tracking: return "event.status.tracking"
        case .expired: return "event.status.expired"
        }
    }

    private var lifecycleTint: Color {
        switch event.lifecycle {
        case .queued: return Color.gray
        case .tracking: return Color.green
        case .expired: return Color.gray.opacity(0.65)
        }
    }

    private var trackingStatusKey: String {
        switch event.trackingStatus {
        case .scheduled: return "event.tracking.scheduled"
        case .checking: return "event.tracking.checking"
        case .budgetDeferred: return "event.tracking.budgetDeferred"
        case .noFreshSource: return "event.tracking.noFreshSource"
        case .failed: return "event.tracking.failed"
        }
    }

    private func claimStatusKey(_ status: NewsEventClaimStatus) -> String {
        switch status {
        case .unverified: return "event.claim.unverified"
        case .supported: return "event.claim.supported"
        case .contested: return "event.claim.contested"
        case .corrected: return "event.claim.corrected"
        }
    }

    private func independenceKey(_ independence: NewsEventIndependence) -> String {
        switch independence {
        case .independent: return "event.source.independenceDistinct"
        case .samePublisher: return "event.source.samePublisher"
        case .syndicated: return "event.source.syndicated"
        case .unknown: return "event.source.independenceUnknown"
        }
    }

    private func publisherKindKey(_ kind: NewsEventPublisherKind) -> String {
        switch kind {
        case .newsPublisher: return "event.source.newsPublisher"
        case .official: return "event.source.official"
        case .unknown: return "event.source.attributionUnknown"
        }
    }

    private func inputKindKey(_ kind: NewsEventInputKind) -> String {
        switch kind {
        case .rss: return "event.source.inputSubscribed"
        case .trend: return "event.source.inputTrend"
        case .research: return "event.source.inputResearch"
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

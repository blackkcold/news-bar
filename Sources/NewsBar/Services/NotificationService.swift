import Foundation
import UserNotifications

enum NotificationService {
    static let maxPushCount = 3

    enum SubmissionError: Error {
        case intentUnavailable
    }

    private struct DigestSelection {
        let newsItems: [NewsItem]
        let researchItems: [NotificationDigestResearchItem]
    }

    /// Builds the notification content for an aggregated push. The first item
    /// keeps the legacy `url`/`title`/`newsItemID` keys so notifications that
    /// were already delivered before the digest payload existed still open a
    /// single article; new notifications additionally carry a decodable digest.
    static func titleContent(
        items: [NewsItem],
        daily: Bool,
        researchItems: [NotificationDigestResearchItem] = []
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()

        guard !items.isEmpty || !researchItems.isEmpty else {
            content.title = L10n.string(daily ? "notif.dailyTitle" : "notif.hourlyTitle", language: L10n.currentLanguage)
            content.userInfo = ["type": "daily"]
            return content
        }

        let visibleResearch = researchItems.map { item in
            let sensitive = NewsEventRiskClassifier.isHighRisk(
                [item.title, item.detail ?? ""].joined(separator: "\n")
            )
            let safeTitle = sensitive ? genericTitle(for: item.kind) : clipped(item.title)
            let detail = ResearchNotificationPreferences.detailedPreviewEnabled && !sensitive
                ? item.detail.map { clipped($0, limit: 160) }
                : nil
            return NotificationDigestResearchItem(
                id: item.id,
                kind: item.kind,
                title: safeTitle,
                detail: detail,
                eventID: item.eventID,
                recordID: item.recordID,
                versionID: item.versionID,
                compareFromVersionID: item.compareFromVersionID,
                sourceURL: item.sourceURL,
                createdAt: item.createdAt,
                urgency: item.urgency,
                relatedNewsItemID: item.relatedNewsItemID
            )
        }
        let newsIDs = Set(items.map(\.id))
        let standaloneResearch = visibleResearch.filter { item in
            guard let relatedID = item.relatedNewsItemID else { return true }
            return !newsIDs.contains(relatedID)
        }
        let totalCount = items.count + standaloneResearch.count
        content.title = L10n.string(
            daily ? "notif.dailyTitleCount" : "notif.hourlyTitleCount",
            language: L10n.currentLanguage,
            totalCount
        )
        let sourceSummary = sourceSummary(items)
        let researchLabel = L10n.currentLanguage == .en ? "Research updates" : "研究进展"
        content.subtitle = [sourceSummary.isEmpty ? nil : sourceSummary,
                            visibleResearch.isEmpty ? nil : researchLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
        let newsLines = items.map { item in
            let attached = visibleResearch.filter { $0.relatedNewsItemID == item.id }
            let badge = attached.map { researchItem in
                let label = summaryLabel(for: researchItem.kind)
                guard let detail = researchItem.detail, !detail.isEmpty else { return label }
                return "\(label) — \(clipped(detail, limit: 60))"
            }.joined(separator: " · ")
            return "• " + clipped(item.displayTitle) + (badge.isEmpty ? "" : " · \(badge)")
        }
        let researchLines = standaloneResearch.map { item in
            let title = clipped(item.title)
            guard let detail = item.detail, !detail.isEmpty else { return "• " + title }
            return "• \(title) — \(clipped(detail, limit: 100))"
        }
        content.body = (newsLines + researchLines).joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "newsbar.digest"
        content.categoryIdentifier = NotificationIdentifier.digestCategory
        content.interruptionLevel = .active

        var userInfo: [String: Any] = ["type": "news"]
        if let first = items.first {
            userInfo["url"] = first.url
            userInfo["title"] = first.displayTitle
            userInfo["newsItemID"] = first.id
            userInfo["snapshotAsOf"] = Date().timeIntervalSince1970
        }
        if let digest = NotificationDigest.encode(
            NotificationDigest(
                kind: daily ? "daily" : "hourly",
                items: items,
                researchItems: visibleResearch
            )
        ) {
            userInfo["digest"] = digest
        }
        content.userInfo = userInfo
        return content
    }

    static func registerCategories() {
        let openDigest = UNNotificationAction(
            identifier: NotificationIdentifier.openDigestAction,
            title: L10n.string("notif.action.openDigest"),
            options: [.foreground]
        )
        let digestCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.digestCategory,
            actions: [openDigest],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let openResearch = UNNotificationAction(
            identifier: NotificationIdentifier.openResearchAction,
            title: L10n.string("research.action.open"),
            options: [.foreground]
        )
        let markRead = UNNotificationAction(
            identifier: NotificationIdentifier.markResearchReadAction,
            title: L10n.string("research.action.markRead"),
            options: []
        )
        let researchCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.researchCategory,
            actions: [openResearch, markRead],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let openWeibo = UNNotificationAction(
            identifier: NotificationIdentifier.openWeiboAction,
            title: L10n.string("weibo.notif.action.open"),
            options: [.foreground]
        )
        let muteWeibo = UNNotificationAction(
            identifier: NotificationIdentifier.muteWeiboAction,
            title: L10n.string("weibo.notif.action.mute1h"),
            options: []
        )
        let markWeiboRead = UNNotificationAction(
            identifier: NotificationIdentifier.markWeiboReadAction,
            title: L10n.string("weibo.notif.action.markRead"),
            options: []
        )
        let weiboCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.weiboCategory,
            actions: [openWeibo, muteWeibo, markWeiboRead],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // setNotificationCategories is replace-all; every category must be
        // registered together or the earlier actions disappear.
        UNUserNotificationCenter.current().setNotificationCategories([
            digestCategory,
            researchCategory,
            weiboCategory,
        ])
    }

    /// "微博热搜 2 · B站热搜 1", keeping first-seen order and capping at three
    /// source names.
    static func sourceSummary(_ items: [NewsItem]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            let name = item.source.displayName
            if counts[name] == nil {
                order.append(name)
            }
            counts[name, default: 0] += 1
        }

        let visible = order.prefix(3).map { "\($0) \(counts[$0, default: 0])" }
        guard !visible.isEmpty else { return "" }
        let joined = visible.joined(separator: " · ")
        return order.count > 3 ? "\(joined) \(L10n.string("notif.digest.etc"))" : joined
    }

    static func clipped(_ text: String, limit: Int = 60) -> String {
        let sanitized = SecurityPolicies.sanitizeHTMLContent(text)
        guard sanitized.count > limit else { return sanitized }
        return String(sanitized.prefix(limit)) + "…"
    }

    /// Keeps the settings value and the service in agreement even if an old
    /// UserDefaults value (or a corrupted one) is outside 1...3.
    static func normalizedPushCount(_ count: Int) -> Int {
        min(max(count, 1), maxPushCount)
    }

    private static func digestEventKey(for item: NotificationDigestResearchItem) -> String {
        if let eventID = item.eventID, !eventID.isEmpty { return "event:\(eventID)" }
        if let recordID = item.recordID, !recordID.isEmpty { return "record:\(recordID)" }
        return "item:\(item.id)"
    }

    private static func digestResearchPriority(
        _ lhs: NotificationDigestResearchItem,
        _ rhs: NotificationDigestResearchItem
    ) -> Bool {
        func priority(_ item: NotificationDigestResearchItem) -> Int {
            let urgency: NotificationDigestUrgency = item.kind == .correction
                ? .urgentCorrection
                : (item.urgency ?? .ordinary)
            switch urgency {
            case .urgentCorrection: return 0
            case .major: return 1
            case .ordinary: break
            }
            return switch item.kind {
            case .correction: 0
            case .reportReady: 2
            case .eventUpdate: 3
            }
        }
        if priority(lhs) != priority(rhs) {
            return priority(lhs) < priority(rhs)
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    private static func summaryLabel(for kind: NotificationDigestResearchKind) -> String {
        let english = L10n.currentLanguage == .en
        switch kind {
        case .eventUpdate: english ? "Verified update" : "核验进展"
        case .reportReady: english ? "Research" : "有深研"
        case .correction: english ? "Correction" : "有更正"
        }
    }

    /// Packs higher-priority research first into the configured total summary
    /// size. If a selected news article belongs to that event, attach the
    /// report/correction action to its news row instead of adding a duplicate
    /// row for the same event.
    private static func selectDigestContents(
        items: [NewsItem],
        researchCandidates: [NotificationDigestResearchItem],
        limit: Int
    ) async -> DigestSelection {
        let capacity = max(0, limit)
        guard capacity > 0 else { return DigestSelection(newsItems: [], researchItems: []) }
        guard !researchCandidates.isEmpty else {
            return DigestSelection(
                newsItems: Array(items.prefix(capacity)),
                researchItems: []
            )
        }
        guard !items.isEmpty else {
            var selected: [NotificationDigestResearchItem] = []
            var seenEvents: Set<String> = []
            for candidate in researchCandidates.sorted(by: digestResearchPriority) {
                let eventKey = digestEventKey(for: candidate)
                guard seenEvents.insert(eventKey).inserted else { continue }
                var item = candidate
                item.relatedNewsItemID = nil
                selected.append(item)
                if selected.count == capacity { break }
            }
            return DigestSelection(newsItems: [], researchItems: selected)
        }
        let events = (try? await NewsEventStore.shared.events()) ?? []
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var newsIDsByURL: [String: String] = [:]
        for item in items {
            for rawURL in [item.url, item.readerURL].compactMap({ $0 }) {
                let canonical = ContentIdentity.canonicalURL(rawURL)
                if !canonical.isEmpty { newsIDsByURL[canonical] = item.id }
            }
        }

        var matchingNewsID: [String: String] = [:]
        for candidate in researchCandidates {
            if let sourceURL = candidate.sourceURL {
                let canonical = ContentIdentity.canonicalURL(sourceURL)
                if let newsID = newsIDsByURL[canonical] {
                    matchingNewsID[candidate.id] = newsID
                    continue
                }
            }
            guard let eventID = candidate.eventID,
                  let event = eventsByID[eventID] else { continue }
            for evidence in event.evidence {
                let canonical = ContentIdentity.canonicalURL(evidence.url)
                if let newsID = newsIDsByURL[canonical] {
                    matchingNewsID[candidate.id] = newsID
                    break
                }
            }
        }

        var selectedResearch: [NotificationDigestResearchItem] = []
        var selectedNewsIDs: Set<String> = []
        var associatedNewsIDs: Set<String> = []
        var seenEvents: Set<String> = []
        var standaloneCount = 0
        let orderedCandidates = researchCandidates.sorted(by: digestResearchPriority)
        for candidate in orderedCandidates {
            let eventKey = digestEventKey(for: candidate)
            guard seenEvents.insert(eventKey).inserted else { continue }
            if let newsID = matchingNewsID[candidate.id] {
                if associatedNewsIDs.insert(newsID).inserted {
                    guard selectedNewsIDs.count + standaloneCount < capacity else {
                        associatedNewsIDs.remove(newsID)
                        continue
                    }
                    var attached = candidate
                    attached.relatedNewsItemID = newsID
                    selectedResearch.append(attached)
                    selectedNewsIDs.insert(newsID)
                }
            } else if selectedNewsIDs.count + standaloneCount < capacity {
                var standalone = candidate
                standalone.relatedNewsItemID = nil
                selectedResearch.append(standalone)
                standaloneCount += 1
            }
        }

        let remainingSlots = max(0, capacity - selectedNewsIDs.count - standaloneCount)
        if remainingSlots > 0 {
            for item in items where !selectedNewsIDs.contains(item.id) {
                selectedNewsIDs.insert(item.id)
                if selectedNewsIDs.count + standaloneCount >= capacity { break }
            }
        }
        let selectedNews = items.filter { selectedNewsIDs.contains($0.id) }
        return DigestSelection(newsItems: selectedNews, researchItems: selectedResearch)
    }

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            NSLog("[NotificationService] Authorization failed: %@", error.localizedDescription)
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func sendHourlyPush(items: [NewsItem], count: Int) async -> Bool {
        let limit = normalizedPushCount(count)
        let admissionDate = Date()
        let queuedResearch = ResearchNotificationPreferences.enabled
            ? await NotificationDeliveryLedger.shared.pendingSummaryCandidates(at: admissionDate)
            : []
        let selection = await selectDigestContents(items: items, researchCandidates: queuedResearch, limit: limit)
        let selectedResearch = selection.researchItems
        let selectedNews = selection.newsItems
        guard !selectedNews.isEmpty || !selectedResearch.isEmpty else { return false }

        guard await NotificationDeliveryLedger.shared.beginSubmission(
            selectedResearch,
            requestID: NotificationIdentifier.hourlyRequest,
            at: admissionDate
        ) else {
            // Keep the existing news digest usable if the local delivery ledger
            // cannot durably claim a research item.
            let newsOnly = Array(items.prefix(limit))
            guard !newsOnly.isEmpty else { return false }
            return await submit(
                content: titleContent(items: newsOnly, daily: false),
                requestID: NotificationIdentifier.hourlyRequest,
                trigger: nil,
                researchItems: []
            )
        }

        let content = titleContent(
            items: selectedNews,
            daily: false,
            researchItems: selectedResearch
        )
        return await submit(
            content: content,
            requestID: NotificationIdentifier.hourlyRequest,
            trigger: nil,
            researchItems: selectedResearch
        )
    }

    private static func submit(
        content: UNNotificationContent,
        requestID: String,
        trigger: UNNotificationTrigger?,
        researchItems: [NotificationDigestResearchItem]
    ) async -> Bool {
        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            await NotificationDeliveryLedger.shared.markAccepted(researchItems, requestID: requestID)
            return true
        } catch {
            await NotificationDeliveryLedger.shared.markFailed(
                researchItems,
                requestID: requestID,
                error: error.localizedDescription
            )
            NSLog("[NotificationService] Notification request failed: %@", error.localizedDescription)
            return false
        }
    }

    static func makeDailyRequest(
        items: [NewsItem],
        count: Int,
        hour: Int,
        minute: Int,
        researchItems: [NotificationDigestResearchItem] = []
    ) -> UNNotificationRequest? {
        let content: UNMutableNotificationContent
        if (!items.isEmpty || !researchItems.isEmpty), count > 0 {
            let topItems = Array(items.prefix(normalizedPushCount(count)))
            let newsIDs = Set(topItems.map(\.id))
            let attached = researchItems.filter {
                guard let newsID = $0.relatedNewsItemID else { return false }
                return newsIDs.contains(newsID)
            }
            let attachedIDs = Set(attached.map(\.id))
            let remainingResearch = researchItems.filter { !attachedIDs.contains($0.id) }
            let standalone = Array(remainingResearch.prefix(max(0, normalizedPushCount(count) - topItems.count)))
            content = titleContent(
                items: topItems,
                daily: true,
                researchItems: attached + standalone
            )
        } else {
            // A day without news still gets its daily reminder. The content is
            // replaced by the next refresh; the trigger must never disappear.
            content = templateDailyContent()
        }
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        return UNNotificationRequest(
            identifier: NotificationIdentifier.dailyRequest,
            content: content,
            trigger: trigger
        )
    }

    private static func templateDailyContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = L10n.string("notif.dailyTitle", language: L10n.currentLanguage)
        content.body = L10n.string("notif.clickToView", language: L10n.currentLanguage)
        content.sound = nil
        content.userInfo = ["type": "daily"]
        return content
    }

    static func rescheduleDailyPush(items: [NewsItem], count: Int, hour: Int, minute: Int = 0) {
        Task { _ = await rescheduleDailyPushAndWait(items: items, count: count, hour: hour, minute: minute) }
    }

    @discardableResult
    static func rescheduleDailyPushAndWait(
        items: [NewsItem],
        count: Int,
        hour: Int,
        minute: Int = 0
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let pending = await pendingRequests(center)
        let delivered = await deliveredNotifications(center)
        let prior = pending.first { $0.identifier == NotificationIdentifier.dailyRequest }
            .flatMap { NotificationDigest.decode($0.content.userInfo["digest"] as? String) }
        let deliveredResearchIDs = Set(delivered
            .filter { $0.request.identifier == NotificationIdentifier.dailyRequest }
            .compactMap { NotificationDigest.decode($0.request.content.userInfo["digest"] as? String) }
            .flatMap { $0.researchItems.map(\.id) })
        let queued = ResearchNotificationPreferences.enabled
            ? await NotificationDeliveryLedger.shared.pendingSummaryItems()
            : []
        var seen = Set<String>()
        let allResearch = ResearchNotificationPreferences.enabled
            ? (prior?.researchItems ?? []).filter { !deliveredResearchIDs.contains($0.id) } + queued
            : []
        let sortedResearch = allResearch.filter { seen.insert($0.id).inserted }
            .sorted(by: digestResearchPriority)
        let limit = normalizedPushCount(count)
        let admissionDate = Date()
        let priorResearch = ResearchNotificationPreferences.enabled
            ? (prior?.researchItems ?? []).filter { !deliveredResearchIDs.contains($0.id) }
            : []
        let quotaEligibleResearch = await NotificationDeliveryLedger.shared.summaryCandidates(
            from: sortedResearch,
            at: admissionDate
        )
        let selection = await selectDigestContents(
            items: items,
            researchCandidates: quotaEligibleResearch,
            limit: limit
        )
        let selectedResearch = selection.researchItems
        let selectedNews = selection.newsItems
        let queuedIDs = Set(queued.map(\.id))
        let newlyQueued = selectedResearch.filter { queuedIDs.contains($0.id) }
        guard await NotificationDeliveryLedger.shared.beginSubmission(
            newlyQueued,
            requestID: NotificationIdentifier.dailyRequest,
            at: admissionDate
        ) else {
            // Keep a previously scheduled research row if a new queue entry
            // cannot be claimed durably; do not replace the whole user's daily
            // summary with a research-free fallback.
            let fallbackSelection = await selectDigestContents(
                items: items,
                researchCandidates: await NotificationDeliveryLedger.shared.summaryCandidates(
                    from: priorResearch,
                    at: admissionDate
                ),
                limit: limit
            )
            guard let request = makeDailyRequest(
                items: fallbackSelection.newsItems,
                count: count,
                hour: hour,
                minute: minute,
                researchItems: fallbackSelection.researchItems
            ) else { return false }
            return await submit(
                content: request.content,
                requestID: NotificationIdentifier.dailyRequest,
                trigger: request.trigger,
                researchItems: fallbackSelection.researchItems
            )
        }
        let request = makeDailyRequest(
            items: selectedNews,
            count: count,
            hour: hour,
            minute: minute,
            researchItems: selectedResearch
        )
        guard let request else { return false }
        return await submit(
            content: request.content,
            requestID: NotificationIdentifier.dailyRequest,
            trigger: request.trigger,
            researchItems: selectedResearch
        )
    }

    static func scheduleDailyPush(hour: Int, minute: Int = 0) {
        let center = UNUserNotificationCenter.current()
        guard let request = makeDailyRequest(items: [], count: 0, hour: hour, minute: minute) else {
            return
        }
        center.add(request) { error in
            if let error = error {
                NSLog("[NotificationService] scheduleDailyPush failed: %@", error.localizedDescription)
            }
        }
    }

    /// Removes only pending requests owned by the research-notification layer.
    /// An existing scheduled news digest is rebuilt with its news articles and
    /// repeating trigger intact.
    static func withdrawPendingResearchNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await pendingRequests(center)
        for request in pending {
            let userInfo = request.content.userInfo
            let type = userInfo["type"] as? String
            if type == "research"
                || (type == "researchCorrection" && userInfo["recordID"] is String) {
                if let semanticID = userInfo["semanticID"] as? String {
                    await NotificationDeliveryLedger.shared.markSuppressed(semanticID: semanticID)
                }
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                continue
            }

            guard let digest = NotificationDigest.decode(userInfo["digest"] as? String) else { continue }
            let withdrawn = digest.researchItems.filter {
                $0.kind == .reportReady || ($0.kind == .correction && $0.recordID != nil)
            }
            guard !withdrawn.isEmpty else { continue }
            for item in withdrawn {
                await NotificationDeliveryLedger.shared.markSuppressed(item)
            }
            let retained = digest.researchItems.filter { item in
                !withdrawn.contains(where: { $0.id == item.id })
            }
            if digest.items.isEmpty && retained.isEmpty && digest.kind != "daily" {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                continue
            }

            let content: UNNotificationContent
            if digest.items.isEmpty && retained.isEmpty {
                content = templateDailyContent()
            } else {
                content = titleContent(
                    items: digest.items,
                    daily: digest.kind == "daily",
                    researchItems: retained
                )
            }
            let replacement = UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: request.trigger
            )
            do {
                try await center.add(replacement)
            } catch {
                NSLog("[NotificationService] Could not withdraw pending research details: %@", error.localizedDescription)
            }
        }
    }

    /// Sends only an alert that has already passed the news-event policy gate.
    /// The controller persists its de-duplication key before calling this method.
    /// `subjectID` is additive; legacy `type` / `eventID` keys stay unchanged.
    static func makeEventDigestItem(
        alert: NewsEventAlert,
        event: NewsEvent,
        evidence: NewsEventEvidence?,
        recordID: String? = nil,
        versionID: String? = nil,
        compareFromVersionID: String? = nil
    ) -> NotificationDigestResearchItem {
        let english = L10n.currentLanguage == .en
        let hasOfficialEvidence = NewsEventSummaryBuilder.hasOfficialOriginalEvidence(event)
        let officialGrounding = NewsEventSummaryBuilder.officialGrounding(
            in: event,
            evidenceID: evidence?.id,
            now: Date()
        )
        let topicSource = hasOfficialEvidence ? officialGrounding?.claim.text : event.title
        let topic = SecurityPolicies.sanitizeHTMLContent(topicSource ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sensitiveMaterial: String
        if hasOfficialEvidence {
            sensitiveMaterial = [
                officialGrounding?.claim.text ?? "",
                officialGrounding?.evidence.title ?? "",
                officialGrounding?.evidence.excerpt ?? "",
            ].joined(separator: "\n")
        } else {
            sensitiveMaterial = ([event.title, event.eventDescription] + event.claims.map(\.text))
                .joined(separator: "\n")
        }
        let sensitive = NewsEventRiskClassifier.isHighRisk(
            sensitiveMaterial
        )
        let genericTitle: String = if alert.change == .correction {
            english ? "A verified correction is ready" : "有新的核验更正"
        } else {
            english ? "A verified event update" : "有新的核验进展"
        }
        let safeTitle: String
        if sensitive || alert.change == .correction || topic.isEmpty {
            safeTitle = genericTitle
        } else if hasOfficialEvidence && officialGrounding == nil {
            safeTitle = genericTitle
        } else {
            safeTitle = clipped(topic)
        }

        let detail: String?
        if !ResearchNotificationPreferences.detailedPreviewEnabled || sensitive || alert.change == .correction {
            detail = nil
        } else if hasOfficialEvidence {
            detail = officialGrounding.map { grounding in
                let source = NewsEventSummaryBuilder.sanitizedSourceName(
                    grounding.evidence.sourceName,
                    language: L10n.currentLanguage
                )
                return clipped(
                    english ? "Verified official field · \(source)" : "已核验官方字段 · \(source)",
                    limit: 160
                )
            }
        } else {
            detail = clipped(alert.body, limit: 160)
        }

        let sourceURL: String?
        if alert.change == .correction {
            sourceURL = safeSourceURL(evidence?.url)
        } else if hasOfficialEvidence {
            sourceURL = officialGrounding.flatMap { safeSourceURL($0.evidence.url) }
        } else {
            sourceURL = safeSourceURL(evidence?.url ?? event.evidence.max(by: {
            ($0.publishedAt ?? $0.fetchedAt) < ($1.publishedAt ?? $1.fetchedAt)
            })?.url)
        }
        return NotificationDigestResearchItem(
            id: alert.notificationID,
            kind: alert.change == .correction ? .correction : .eventUpdate,
            title: safeTitle,
            detail: detail,
            eventID: event.id,
            recordID: recordID,
            versionID: versionID,
            compareFromVersionID: compareFromVersionID,
            sourceURL: sourceURL,
            createdAt: Date(),
            urgency: notificationUrgency(for: alert.change)
        )
    }

    static func makeResearchDigestItem(
        record: ResearchRecord,
        eventID: String? = nil,
        versionID: String? = nil,
        compareFromVersionID: String? = nil,
        sourceURL: String? = nil,
        isCorrection: Bool = false
    ) -> NotificationDigestResearchItem {
        let language = L10n.currentLanguage
        let rawSummary = record.report.flatMap {
            ResearchNotificationQualification.verifiedPreview(in: $0, language: language)
        }
        let sensitiveText = ([record.topic, rawSummary ?? ""]
            + (record.report?.verification?.claims.map(\.claim) ?? []))
            .joined(separator: "\n")
        let sensitive = NewsEventRiskClassifier.isHighRisk(sensitiveText)
        let genericTitle = language == .en
            ? (isCorrection ? "A research correction is ready" : "New verified research")
            : (isCorrection ? "研究结论有更正" : "有新的核验研究")
        let topic = SecurityPolicies.sanitizeHTMLContent(record.topic)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = sensitive || topic.isEmpty
            ? genericTitle
            : clipped(isCorrection
                ? (language == .en ? "\(topic) has a correction" : "\(topic) 有更正")
                : topic)
        let detail = ResearchNotificationPreferences.detailedPreviewEnabled && !sensitive
            ? rawSummary.map { clipped($0, limit: 160) }
            : nil
        let causal = WorkspaceResearchCausalToken.make(record: record)
            ?? "record:\(record.id):\(record.updatedAt.timeIntervalSince1970)"
        let kind: NotificationDigestResearchKind = isCorrection ? .correction : .reportReady
        let semanticID = ContentIdentity.digest(
            "\(kind.rawValue)\n\(eventID ?? record.id)\n\(causal)\n\(versionID ?? "latest")"
        )
        let fallbackURL = sourceURL
            ?? record.report?.evidence.first(where: { $0.quoteVerified })?.url
            ?? record.seed.url
        return NotificationDigestResearchItem(
            id: semanticID,
            kind: kind,
            title: safeTitle,
            detail: detail,
            eventID: eventID,
            recordID: record.id,
            versionID: versionID,
            compareFromVersionID: compareFromVersionID,
            sourceURL: safeSourceURL(fallbackURL),
            createdAt: Date(),
            urgency: isCorrection ? .urgentCorrection : .ordinary
        )
    }

    private static func notificationUrgency(for change: NewsEventChangeKind) -> NotificationDigestUrgency {
        switch change {
        case .correction: .urgentCorrection
        case .majorProgress: .major
        case .initial, .routine: .ordinary
        }
    }

    static func enqueueSummaryItem(_ item: NotificationDigestResearchItem) async -> Bool {
        await NotificationDeliveryLedger.shared.enqueueSummary(item)
    }

    static func deliveryMetrics(since date: Date = .distantPast) async -> NotificationDeliveryMetrics {
        await NotificationDeliveryLedger.shared.metrics(since: date)
    }

    @discardableResult
    static func deliverSummaryItem(
        _ item: NotificationDigestResearchItem,
        pushCount: Int,
        hourlyEnabled: Bool,
        dailyEnabled: Bool,
        dailyHour: Int,
        dailyMinute: Int
    ) async -> Bool {
        guard hourlyEnabled || dailyEnabled,
              await enqueueSummaryItem(item) else { return false }
        let acceptedRequest: Bool
        if hourlyEnabled {
            acceptedRequest = await sendHourlyPush(items: [], count: pushCount)
        } else {
            acceptedRequest = await rescheduleDailyPushAndWait(
                items: [],
                count: pushCount,
                hour: dailyHour,
                minute: dailyMinute
            )
        }
        guard acceptedRequest else { return false }
        return await NotificationDeliveryLedger.shared.wasAccepted(semanticID: item.id)
    }

    /// Sends only an alert that has already passed the news-event policy gate.
    /// The controller persists its semantic event key before calling this.
    /// Existing `type` and `eventID` keys stay additive-compatible.
    static func sendNewsEventAlert(
        _ alert: NewsEventAlert,
        subjectID: String? = nil,
        event: NewsEvent? = nil,
        evidence: NewsEventEvidence? = nil,
        recordID: String? = nil,
        versionID: String? = nil,
        compareFromVersionID: String? = nil
    ) async throws {
        let item: NotificationDigestResearchItem
        if let event {
            item = makeEventDigestItem(
                alert: alert,
                event: event,
                evidence: evidence,
                recordID: recordID,
                versionID: versionID,
                compareFromVersionID: compareFromVersionID
            )
        } else {
            let kind: NotificationDigestResearchKind = alert.change == .correction ? .correction : .eventUpdate
            item = NotificationDigestResearchItem(
                id: alert.notificationID,
                kind: kind,
                title: genericTitle(for: kind),
                detail: nil,
                eventID: alert.eventID,
                recordID: recordID,
                versionID: versionID,
                compareFromVersionID: compareFromVersionID,
                sourceURL: safeSourceURL(evidence?.url),
                createdAt: Date(),
                urgency: notificationUrgency(for: alert.change)
            )
        }

        let requestID = alert.notificationID
        guard await NotificationDeliveryLedger.shared.beginSubmission([item], requestID: requestID) else {
            _ = await enqueueSummaryItem(item)
            throw SubmissionError.intentUnavailable
        }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.detail ?? genericBody(for: item.kind)
        content.sound = .default
        content.threadIdentifier = "newsbar.events"
        if alert.change == .correction {
            content.categoryIdentifier = NotificationIdentifier.researchCategory
        }
        var userInfo: [AnyHashable: Any] = [
            "type": alert.change == .correction ? "researchCorrection" : "newsEvent",
            "eventID": alert.eventID,
            "semanticID": item.id,
            "change": alert.change.rawValue,
            "title": item.title,
        ]
        if let url = item.sourceURL { userInfo["url"] = url; userInfo["sourceURL"] = url }
        if let recordID { userInfo["recordID"] = recordID }
        if let versionID { userInfo["versionID"] = versionID }
        if let compareFromVersionID { userInfo["compareFromVersionID"] = compareFromVersionID }
        if let subjectID, !subjectID.isEmpty {
            userInfo["subjectID"] = subjectID
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: alert.notificationID,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            await NotificationDeliveryLedger.shared.markAccepted([item], requestID: requestID)
        } catch {
            await NotificationDeliveryLedger.shared.markFailed(
                [item],
                requestID: requestID,
                error: error.localizedDescription
            )
            throw error
        }
    }

    /// Compatibility adapter for the research coordinator's legacy callback.
    static func sendResearchNotification(record: ResearchRecord, subjectID: String? = nil) {
        Task { @MainActor in
            _ = await ResearchNotificationDeliveryService.shared.deliverLegacy(
                record,
                subjectID: subjectID
            )
        }
    }

    @discardableResult
    static func sendResearchNotificationAndWait(
        record: ResearchRecord,
        subjectID: String? = nil,
        eventID: String? = nil,
        versionID: String? = nil,
        compareFromVersionID: String? = nil,
        sourceURL: String? = nil,
        isCorrection: Bool = false
    ) async throws -> NotificationDigestResearchItem? {
        guard ResearchNotificationPreferences.enabled,
              ResearchNotificationQualification.allowsNotification(record),
              record.report != nil else { return nil }
        let item = makeResearchDigestItem(
            record: record,
            eventID: eventID,
            versionID: versionID,
            compareFromVersionID: compareFromVersionID,
            sourceURL: sourceURL,
            isCorrection: isCorrection
        )
        let requestID = "research-v2-\(item.id)"
        guard await NotificationDeliveryLedger.shared.beginSubmission([item], requestID: requestID) else {
            _ = await enqueueSummaryItem(item)
            throw SubmissionError.intentUnavailable
        }

        let content = UNMutableNotificationContent()
        content.title = item.title
        content.subtitle = ""
        content.body = item.detail ?? genericBody(for: item.kind)
        content.sound = .default
        content.threadIdentifier = "research"
        content.categoryIdentifier = NotificationIdentifier.researchCategory
        var userInfo: [AnyHashable: Any] = [
            "type": item.kind == .correction ? "researchCorrection" : "research",
            "recordID": record.id,
            "title": item.title,
            "semanticID": item.id,
        ]
        if let eventID { userInfo["eventID"] = eventID }
        if let versionID { userInfo["versionID"] = versionID }
        if let compareFromVersionID { userInfo["compareFromVersionID"] = compareFromVersionID }
        if let sourceURL = item.sourceURL {
            userInfo["url"] = sourceURL
            userInfo["sourceURL"] = sourceURL
        }
        if let subjectID, !subjectID.isEmpty {
            userInfo["subjectID"] = subjectID
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            await NotificationDeliveryLedger.shared.markAccepted([item], requestID: requestID)
            return item
        } catch {
            await NotificationDeliveryLedger.shared.markFailed(
                [item],
                requestID: requestID,
                error: error.localizedDescription
            )
            throw error
        }
    }

    private static func genericBody(for kind: NotificationDigestResearchKind) -> String {
        let english = L10n.currentLanguage == .en
        switch kind {
        case .eventUpdate:
            return english
                ? "A verified event update is ready. Open to view the source."
                : "新的核验进展已就绪，打开查看来源。"
        case .reportReady:
            return english
                ? "A verified research result is ready. Open to view its sources."
                : "新的核验研究已就绪，打开查看依据。"
        case .correction:
            return english
                ? "A verified correction is ready. Open to compare the versions."
                : "核验更正已就绪，打开查看版本变化。"
        }
    }

    private static func genericTitle(for kind: NotificationDigestResearchKind) -> String {
        let english = L10n.currentLanguage == .en
        switch kind {
        case .eventUpdate:
            return english ? "A verified event update" : "有新的核验进展"
        case .reportReady:
            return english ? "New verified research" : "有新的核验研究"
        case .correction:
            return english ? "A verified correction is ready" : "有新的核验更正"
        }
    }

    private static func safeSourceURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              let url = ReaderNavigationPolicy.allowedURL(rawValue) else { return nil }
        return url.absoluteString
    }

    private static func pendingRequests(
        _ center: UNUserNotificationCenter
    ) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    private static func deliveredNotifications(
        _ center: UNUserNotificationCenter
    ) async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
    }

    static func clearAllPending() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: - Weibo monitor

    static func sendWeiboAlert(_ alert: WeiboAlertNotification) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.threadID
        content.categoryIdentifier = NotificationIdentifier.weiboCategory
        var userInfo: [String: Any] = [
            "type": "weibo",
            "mid": alert.mid,
            "uid": alert.uid,
        ]
        if let url = alert.url, !url.isEmpty {
            userInfo["url"] = url
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: alert.requestID,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// One low-priority alert per login expiry. The user can sign in from the
    /// reader; the monitor notices the new cookie and probes automatically.
    static func sendWeiboAuthExpired(language: AppLanguage) async {
        let content = UNMutableNotificationContent()
        content.title = L10n.string("weibo.notif.authTitle", language: language)
        content.body = L10n.string("weibo.notif.authBody", language: language)
        content.sound = nil
        content.threadIdentifier = "weibo.auth"
        content.categoryIdentifier = NotificationIdentifier.weiboCategory
        content.userInfo = ["type": "weibo", "mid": "", "uid": ""]

        let request = UNNotificationRequest(
            identifier: "weibo-auth-expired",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func clearPersonalizedNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

/// Production bridge between the pure monitor service and UserNotifications.
struct WeiboNotificationAdapter: WeiboAlertNotifying {
    func send(_ notification: WeiboAlertNotification, language: AppLanguage) async {
        await NotificationService.sendWeiboAlert(notification)
    }

    func sendAuthExpired(language: AppLanguage) async {
        await NotificationService.sendWeiboAuthExpired(language: language)
    }
}

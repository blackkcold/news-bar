import Foundation

struct NewsEventSummaryBuilder: NewsEventSummaryBuilding {
    func make(event: NewsEvent) -> String {
        let language = L10n.currentLanguage
        if Self.containsHighRiskMaterial(event) {
            let subject = event.subjectAliases.first(where: { !Self.containsHighRiskMaterial($0) })
            let action = event.action.flatMap { Self.containsHighRiskMaterial($0) ? nil : $0 }
            let neutral = language == .en ? "has a news update" : "有新的动态"
            let sourcePhrase = Self.sourcePhrase(event, language: language)
            let lead = [subject, action].compactMap { $0 }.joined(separator: " ")
            let safeLead = lead.isEmpty ? (language == .en ? "Related parties" : "相关主体") : lead
            return "\(safeLead) \(neutral). \(sourcePhrase)"
        }

        let cleaned = SecurityPolicies.sanitizeHTMLContent(event.title)
        let body = String(cleaned.prefix(180))
        return "\(body)\n\(Self.sourcePhrase(event, language: language))"
    }

    private static func sourcePhrase(_ event: NewsEvent, language: AppLanguage) -> String {
        let hasUnknownIndependence = event.sourceGroups.contains { $0.independence == .unknown }
        if event.countablePublisherCount >= 2 && hasUnknownIndependence {
            return language == .en ? "Reported by multiple media; independence is unknown." : "多家媒体报道；来源独立性未知。"
        }
        if event.countablePublisherCount > 0 {
            return language == .en ? "News-source reports." : "新闻发布主体报道。"
        }
        return language == .en ? "A new source update is available." : "有新的来源信息。"
    }

    private static func containsHighRiskMaterial(_ event: NewsEvent) -> Bool {
        event.claims.contains { NewsEventRiskClassifier.isHighRisk($0.text) }
            || event.evidence.contains { containsHighRiskMaterial($0.title) || containsHighRiskMaterial($0.excerpt) }
    }

    private static func containsHighRiskMaterial(_ text: String) -> Bool {
        NewsEventRiskClassifier.isHighRisk(text)
    }
}

enum NewsEventSemanticFingerprint {
    private static let progressSignalGroups: [(key: String, terms: [String])] = [
        ("agreement", ["签署", "签约", "signed"]),
        ("approved", ["批准", "通过", "approved", "enacted"]),
        ("effective", ["生效", "took effect"]),
        ("completed", ["完成", "completed"]),
        ("restored", ["恢复", "修复", "重启", "restored", "recovered", "reopened", "resumed", "returned to service"]),
        ("opened", ["开通", "投入运营", "entered service"]),
        ("ruled", ["判决", "ruled"]),
        ("arrested", ["逮捕", "arrested"]),
        ("withdrawn", ["撤销", "取消", "withdrawn", "cancelled"]),
        ("launched", ["正式发布", "发布", "launched", "launch"]),
    ]

    static func make(for event: NewsEvent) -> String {
        let subjects = event.subjectAliases.map(normalized).filter { !$0.isEmpty }.sorted()
        let action = normalized(event.action ?? NewsEventMatcher.action(in: event.eventDescription) ?? "")
        let claims = event.claims.filter {
            ($0.scope != .detail && $0.status != .unverified) || $0.status == .corrected
        }.map { "\(normalized($0.text)):\($0.status.rawValue)" }.sorted()
        let progressText = [event.title, event.action ?? "", event.eventDescription]
            + event.evidence.flatMap { [$0.title, $0.excerpt] }
            + event.timeline.map(\.text)
        let milestones = Set(progressText.flatMap(progressSignals(in:))).sorted()
        let conflicts = event.coreConflictDetails.map(normalized).filter { !$0.isEmpty }.sorted()
        let material = [subjects.joined(separator: ","), action, claims.joined(separator: ","),
                        milestones.joined(separator: ","), conflicts.joined(separator: ",")]
            .joined(separator: "|")
        return ContentIdentity.digest(material)
    }

    static func hasMeaningfulProgress(
        evidence: NewsEventEvidence,
        previousEvent: NewsEvent,
        updatedEvent: NewsEvent
    ) -> Bool {
        guard make(for: previousEvent) != make(for: updatedEvent) else { return false }
        let previousClaimTexts = Set(previousEvent.claims.map { normalized($0.text) })
        if evidence.claims.contains(where: {
            $0.scope != .detail && $0.status == .supported && !previousClaimTexts.contains(normalized($0.text))
        }) {
            return true
        }
        let previousMilestones = Set(previousEvent.timeline
            .filter { containsProgressSignal(in: $0.text) }
            .map { normalized($0.text) })
        if evidence.timeline.contains(where: {
            containsProgressSignal(in: $0.text) && !previousMilestones.contains(normalized($0.text))
        }) {
            return true
        }
        return containsProgressSignal(in: evidence.title + " " + evidence.excerpt + " " + evidence.eventDescription)
    }

    static func containsProgressSignal(in text: String) -> Bool {
        !progressSignals(in: text).isEmpty
    }

    private static func progressSignals(in text: String) -> [String] {
        let lower = text.lowercased()
        return progressSignalGroups.compactMap { group in
            group.terms.contains(where: lower.contains) ? group.key : nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct NewsEventNotificationPolicy: NewsEventNotificationPolicing {
    private let summaryBuilder: any NewsEventSummaryBuilding
    private let sourceResolver: any NewsEventSourceResolving
    private let clock: @Sendable () -> Date

    init(
        summaryBuilder: any NewsEventSummaryBuilding = NewsEventSummaryBuilder(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sourceResolver: any NewsEventSourceResolving = NewsEventSourceResolver()
    ) {
        self.summaryBuilder = summaryBuilder
        self.clock = clock
        self.sourceResolver = sourceResolver
    }

    func eligibility(for event: NewsEvent) -> NewsEventNotificationEligibility {
        eligibility(for: event, now: clock())
    }

    func explanation(for event: NewsEvent, now: Date) -> String? {
        guard event.lastNotifiedAt == nil, event.notificationKeys.isEmpty else { return nil }
        let eligibility = eligibility(for: event, now: now)
        guard eligibility == .insufficientPublishers || eligibility == .staleEvidence else { return nil }
        return reason(for: eligibility, event: event, now: now)
    }

    private func eligibility(for event: NewsEvent, now: Date) -> NewsEventNotificationEligibility {
        if event.lastNotifiedAt != nil { return .alreadyNotified }
        if !event.coreConflictDetails.isEmpty || event.coreConsistency == .contested { return .coreContested }
        if event.coreConsistency == .unknown { return .coreUnknown }
        let recentEvidence = freshEvidence(in: event, now: now)
        if recentEvidence.isEmpty { return .staleEvidence }
        if sourceResolver.countablePublisherCount(in: recentEvidence) < 3 { return .insufficientPublishers }
        return .eligible
    }

    func decide(event: NewsEvent, change: NewsEventChangeKind) -> NewsEventNotificationDecision {
        if event.lastNotifiedAt == nil && !event.notificationKeys.isEmpty {
            return .suppress(reason: "此前通知申请未确认或失败；去重键已保留，不自动重发。")
        }
        let isRepeat = event.lastNotifiedAt != nil
        var groundedCorrectionEvidence: NewsEventEvidence?
        if isRepeat {
            guard change == .majorProgress || change == .correction else {
                return .suppress(reason: "已通知事件仅在重大进展或更正时提醒")
            }
            let now = clock()
            if change == .correction {
                guard event.lastNotifiedFingerprint != nil else {
                    return .suppress(reason: "缺少此前通知语义指纹，无法确认更正对应实际变更")
                }
                guard let evidence = latestCorrectionEvidence(in: event, now: now) else {
                    return .suppress(reason: "最新证据未包含可追溯的更正主张或明确更正/撤回/否认依据")
                }
                groundedCorrectionEvidence = evidence
            } else {
                guard event.coreConsistency == .consistent, event.coreConflictDetails.isEmpty else {
                    return .suppress(reason: event.coreConsistency == .contested || !event.coreConflictDetails.isEmpty
                        ? "事件核心内容存在冲突"
                        : "事件核心状态未知")
                }
            }
            guard isFresh(event, now: now) else {
                return .suppress(reason: "新增证据不在 24 小时通知新鲜度窗口内")
            }
        } else {
            guard change == .initial else { return .suppress(reason: "未通知事件只允许首次通知") }
            let now = clock()
            let result = eligibility(for: event, now: now)
            guard result == .eligible else { return .suppress(reason: reason(for: result, event: event, now: now)) }
        }

        let fingerprint = NewsEventSemanticFingerprint.make(for: event)
        if isRepeat, event.lastNotifiedFingerprint == fingerprint {
            return .suppress(reason: "事件语义指纹未变化；不重复通知")
        }
        let key = "news-event-\(event.id)-\(change.rawValue)-\(fingerprint)"
        if event.notificationKeys.contains(key) {
            return .suppress(reason: "相同事件语义已有持久化通知指纹；不重复通知")
        }
        let language = L10n.currentLanguage
        let title: String
        let body: String
        if let groundedCorrectionEvidence {
            title = L10n.string("event.notification.correction.title", language: language)
            let source = correctionSourceName(groundedCorrectionEvidence, language: language)
            body = L10n.string("event.notification.correction.body", language: language, source)
        } else {
            title = language == .en ? "News event update" : "新闻事件进展"
            body = summaryBuilder.make(event: event)
        }
        return .notify(NewsEventAlert(
            eventID: event.id,
            notificationID: key,
            title: title,
            body: body,
            change: change,
            semanticFingerprint: fingerprint
        ))
    }

    private func freshEvidence(in event: NewsEvent, now: Date) -> [NewsEventEvidence] {
        event.evidence.filter { evidence in
            guard evidence.inputKind != .trend else { return false }
            let effectiveDate = evidence.publishedAt ?? evidence.fetchedAt
            return effectiveDate <= now.addingTimeInterval(5 * 60)
                && now.timeIntervalSince(effectiveDate) <= 24 * 3600
        }
    }

    private func isFresh(_ event: NewsEvent, now: Date) -> Bool {
        !freshEvidence(in: event, now: now).isEmpty
    }

    private func latestCorrectionEvidence(in event: NewsEvent, now: Date) -> NewsEventEvidence? {
        guard let latest = freshEvidence(in: event, now: now).max(by: { lhs, rhs in
            let lhsDate = lhs.publishedAt ?? lhs.fetchedAt
            let rhsDate = rhs.publishedAt ?? rhs.fetchedAt
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            if lhs.fetchedAt != rhs.fetchedAt { return lhs.fetchedAt < rhs.fetchedAt }
            return lhs.id < rhs.id
        }) else { return nil }

        let hasLinkedCorrectedClaim = (event.claims + latest.claims).contains {
            $0.status == .corrected && $0.evidenceIDs.contains(latest.id)
        }
        let latestText = [latest.title, latest.excerpt, latest.eventDescription].joined(separator: " ")
        let hasExplicitCorrectionWording = Self.explicitCorrectionTerms.contains { term in
            latestText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return hasLinkedCorrectedClaim || hasExplicitCorrectionWording ? latest : nil
    }

    private func correctionSourceName(_ evidence: NewsEventEvidence, language: AppLanguage) -> String {
        let sanitized = SecurityPolicies.sanitizeHTMLContent(evidence.sourceName)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return L10n.string("event.notification.correction.sourceUnknown", language: language)
        }
        return String(sanitized.prefix(80))
    }

    private static let explicitCorrectionTerms = [
        "更正", "修正", "撤回", "撤销", "否认", "辟谣", "澄清", "报道不实", "与事实不符",
        "correction", "corrected", "retract", "withdraw", "deny", "denial", "denies", "denied",
        "refut", "clarif", "false report", "disavow",
    ]

    private func reason(
        for eligibility: NewsEventNotificationEligibility,
        event: NewsEvent,
        now: Date
    ) -> String {
        switch eligibility {
        case .eligible: return "可通知"
        case .insufficientPublishers:
            let freshCount = sourceResolver.countablePublisherCount(in: freshEvidence(in: event, now: now))
            return "最近 24 小时有效新闻证据覆盖 \(freshCount)/3 个发布主体（已保留证据共 \(event.countablePublisherCount) 家）；旧报道、官方来源与趋势信号不计入首次通知门槛。"
        case .coreUnknown: return "事件核心状态未知"
        case .coreContested: return "事件核心内容存在冲突"
        case .alreadyNotified: return "已通知"
        case .staleEvidence: return "最近 24 小时没有有效的非趋势新闻证据；旧报道不计入首次通知门槛。"
        }
    }
}

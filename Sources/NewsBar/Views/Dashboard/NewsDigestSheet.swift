import SwiftUI

/// Lists every item that was bundled into one aggregated notification so the
/// user can choose which one to read.
struct NewsDigestSheet: View {
    let request: NewsDigestRequest

    private var sourceSummary: String {
        let news = NotificationService.sourceSummary(request.items)
        guard !request.researchItems.isEmpty else { return news }
        let research = L10n.currentLanguage == .en ? "Research updates" : "研究进展"
        return news.isEmpty ? research : "\(news) · \(research)"
    }

    private var standaloneResearchItems: [NotificationDigestResearchItem] {
        let newsIDs = Set(request.items.map(\.id))
        return request.researchItems.filter { item in
            guard let relatedID = item.relatedNewsItemID else { return true }
            return !newsIDs.contains(relatedID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            DigestRule()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(request.items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                        if index < request.itemCount - 1 {
                            DigestRule(inset: 52)
                        }
                    }
                    ForEach(Array(standaloneResearchItems.enumerated()), id: \.element.id) { index, item in
                        researchRow(item)
                        if request.items.count + index < request.itemCount - 1 {
                            DigestRule(inset: 52)
                        }
                    }
                }
            }
            DigestRule()
            footer
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 260, maxHeight: 460)
        .adaptiveColorScheme()
        .appThemeSurface()
    }

    private var titleKey: String {
        request.kind == NewsDigestRequest.liveKind ? "notif.digest.liveTitle" : "notif.digest.title"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(titleKey, request.itemCount))
                    .font(.system(size: 16, weight: .semibold))
                if !sourceSummary.isEmpty {
                    Text(sourceSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Text(request.generatedAt, style: .relative)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func row(_ item: NewsItem) -> some View {
        let presentation = DashboardTrendPresentation(for: item.source)
        let attachedResearch = request.researchItems.filter { $0.relatedNewsItemID == item.id }
        return HStack(spacing: 8) {
            Button {
                NewsNavigationRouter.shared.open(item, surface: "notificationDigest")
                NewsNavigationRouter.shared.dismissDigest()
            } label: {
                HStack(spacing: 10) {
                    EditorialSourceBadge(
                        mark: presentation.mark,
                        fallbackTint: presentation.accent,
                        size: 28,
                        rotation: 0
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            Text(presentation.title)
                            if let rank = item.rank {
                                Text("#\(rank)")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(presentation.title)，\(item.displayTitle)")
            ForEach(attachedResearch) { researchItem in
                researchBadge(researchItem)
            }
        }
    }

    private func researchRow(_ item: NotificationDigestResearchItem) -> some View {
        let english = L10n.currentLanguage == .en
        let symbol: String = switch item.kind {
        case .eventUpdate: "newspaper"
        case .reportReady: "doc.text.magnifyingglass"
        case .correction: "exclamationmark.arrow.circlepath"
        }
        return Button {
            openResearchItem(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.kind == .correction ? .orange : Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background((item.kind == .correction ? Color.orange : Color.accentColor).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(item.kind == .correction
                             ? (english ? "A verified correction is ready" : "有新的核验更正")
                             : (english ? "Open the verified research" : "查看核验报告"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint(english ? "Open the related source or research report" : "打开关联原文或研究报告")
    }

    private func researchBadge(_ item: NotificationDigestResearchItem) -> some View {
        let english = L10n.currentLanguage == .en
        let title: String = switch item.kind {
        case .eventUpdate: english ? "Update" : "进展"
        case .reportReady: english ? "Research" : "研究"
        case .correction: english ? "Correction" : "更正"
        }
        return Button {
            openResearchItem(item)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.kind == .correction ? "exclamationmark.arrow.circlepath" : "doc.text.magnifyingglass")
                Text(title)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(item.kind == .correction ? Color.orange : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background((item.kind == .correction ? Color.orange : Color.accentColor).opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint(english ? "Open the related research or correction" : "打开关联研究或更正")
    }

    private func openResearchItem(_ item: NotificationDigestResearchItem) {
        Task { await NotificationDeliveryLedger.shared.markRead(semanticID: item.id) }
        if item.kind == .eventUpdate,
           let sourceURL = item.sourceURL,
           let safeURL = ReaderNavigationPolicy.allowedURL(sourceURL) {
            NewsNavigationRouter.shared.open(
                url: safeURL.absoluteString,
                title: item.title,
                surface: "notificationDigest"
            )
        } else {
            var userInfo: [String: Any] = [:]
            if let eventID = item.eventID { userInfo["eventID"] = eventID }
            if let recordID = item.recordID { userInfo["recordID"] = recordID }
            if let versionID = item.versionID { userInfo["versionID"] = versionID }
            if let compareFromVersionID = item.compareFromVersionID {
                userInfo["compareFromVersionID"] = compareFromVersionID
            }
            if let sourceURL = item.sourceURL { userInfo["sourceURL"] = sourceURL }
            userInfo["title"] = item.title
            NotificationCenter.default.post(
                name: .transientResearchRequested,
                object: nil,
                userInfo: userInfo
            )
        }
        NewsNavigationRouter.shared.dismissDigest()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(L10n.string("notif.digest.subtitleHint"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Button(L10n.string("notif.digest.close")) {
                NewsNavigationRouter.shared.dismissDigest()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }
}

/// A hairline in the standard theme and an ink rule in the retro editorial one,
/// so the sheet sits on the same paper as the rest of the dashboard.
private struct DigestRule: View {
    @Environment(AppSettings.self) private var settings
    var inset: CGFloat = 0

    var body: some View {
        Group {
            if settings.appTheme == .retroEditorial {
                Rectangle()
                    .fill(RetroEditorialTokens.rule)
                    .frame(height: 1.2)
            } else {
                Divider()
            }
        }
        .padding(.leading, inset)
    }
}

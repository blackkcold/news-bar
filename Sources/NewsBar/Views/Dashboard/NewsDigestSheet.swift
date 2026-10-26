import SwiftUI

/// Lists every item that was bundled into one aggregated notification so the
/// user can choose which one to read.
struct NewsDigestSheet: View {
    let request: NewsDigestRequest

    private var sourceSummary: String {
        NotificationService.sourceSummary(request.items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(request.items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                        if index < request.items.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 260, maxHeight: 460)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("notif.digest.title", request.items.count))
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
        return Button {
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

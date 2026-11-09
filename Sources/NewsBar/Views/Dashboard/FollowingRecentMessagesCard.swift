import SwiftUI

/// The sidebar's following column. It mirrors the hot-search card's editorial
/// surface but keeps following semantics: five recent posts, unread dots and a
/// "show more" link into the standalone waterfall.
struct FollowingRecentMessagesCard: View {
    let entries: [FollowingPostEntry]
    let unreadCount: Int
    let onOpen: (WeiboPost) -> Void
    let onShowMore: () -> Void

    @Environment(AppSettings.self) private var settings

    private var language: AppLanguage { settings.appLanguage }
    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : Color.accentColor }
    private var visibleEntries: [FollowingPostEntry] { Array(entries.prefix(5)) }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if visibleEntries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        row(entry)
                        if index < visibleEntries.count - 1 {
                            Divider()
                                .opacity(0.4)
                                .padding(.leading, 30)
                        }
                    }
                }
                footer
            }
        }
        .padding(14)
        .newsCardSurface(rotation: 0.08)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.string("dash.followingRecent.title", language: language))
                        .editorialHeading(size: 14)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !visibleEntries.isEmpty, unreadCount > 0 {
                        EditorialTag(
                            text: L10n.string(
                                "weibo.feed.unreadCount",
                                language: language,
                                unreadCount
                            ),
                            fallbackTint: .red
                        )
                    }
                }

                Text(L10n.string("dash.followingRecent.subtitle", language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }

    private func row(_ entry: FollowingPostEntry) -> some View {
        Button {
            onOpen(entry.post)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                FollowingAvatar(user: entry.user, size: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(entry.user.screenName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(accent)
                            .lineLimit(1)

                        if entry.user.priority == .p0 {
                            Text("P0")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(isRetro ? RetroEditorialTokens.raisedPaper : .red)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(
                                        isRetro
                                            ? RetroEditorialTokens.brick
                                            : Color.red.opacity(0.12)
                                    )
                                )
                        }

                        Spacer(minLength: 4)

                        Text(Self.relativeFormatter.localizedString(
                            for: entry.post.createdAt,
                            relativeTo: Date()
                        ))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    }

                    Text(entry.post.displayText.isEmpty
                        ? L10n.string("weibo.feed.noText", language: language)
                        : entry.post.displayText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !entry.post.read {
                    Circle()
                        .fill(isRetro ? RetroEditorialTokens.brick : Color.red)
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.user.screenName)，\(entry.post.displayText)")
        .accessibilityValue(
            entry.post.read
                ? ""
                : L10n.string("weibo.feed.unreadCount", language: language, 1)
        )
        .accessibilityHint(L10n.string("weibo.feed.openPost", language: language))
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(L10n.string("dash.followingRecent.empty", language: language))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.45)
                .padding(.top, 8)
            Button(action: onShowMore) {
                HStack(spacing: 4) {
                    Text(L10n.string("dash.followingRecent.showMore", language: language))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.string("dash.followingRecent.showMore", language: language)
            )
        }
    }
}

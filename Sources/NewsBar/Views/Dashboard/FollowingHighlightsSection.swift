import SwiftUI

/// The "关注动态" block above the ranked recommendation feed. It is a
/// separate waterfall section, not a ranking input: following posts keep their
/// own recency/unread semantics and never enter `InterestController`.
struct FollowingHighlightsSection: View {
    let entries: [FollowingPostEntry]
    let width: CGFloat
    let onOpen: (WeiboPost) -> Void
    let onShowFollowing: () -> Void

    @Environment(AppSettings.self) private var settings

    private var language: AppLanguage { settings.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    L10n.string("dash.followingHighlights.title", language: language),
                    systemImage: "person.2.wave.2"
                )
                .editorialHeading(size: 20)

                Text(L10n.string(
                    "dash.followingHighlights.subtitle",
                    language: language,
                    entries.count
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    onShowFollowing()
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.string("dash.followingHighlights.showAll", language: language))
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(
                    L10n.string("dash.followingHighlights.showAll", language: language)
                )
            }

            FollowingMasonryFeed(
                entries: Array(entries.prefix(6)),
                width: width,
                initialVisibleCount: 6,
                showsLoadMore: false,
                onOpen: onOpen
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

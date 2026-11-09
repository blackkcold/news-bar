import SwiftUI

/// One following post in the masonry. The account identity travels with the
/// card; the standalone page no longer groups by account, so every card must
/// stand on its own.
struct FollowingPostCard: View {
    let entry: FollowingPostEntry
    let columnWidth: CGFloat
    let onOpen: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : Color.accentColor }
    private var imageURL: URL? {
        guard let raw = entry.post.imageURLs.first else { return nil }
        return URL(string: raw)
    }
    private var imageHeight: CGFloat {
        FollowingMasonryLayout.imageHeight(forColumnWidth: columnWidth)
    }
    private var relativeTime: String {
        Self.relativeFormatter.localizedString(for: entry.post.createdAt, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                accountRow
                postText
                if let imageURL {
                    cover(imageURL)
                }
                metaRow
            }
            .padding(FollowingMasonryLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .newsCardSurface(cornerRadius: 14, isHovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    hovering = value
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.user.screenName)，\(text)")
        .accessibilityValue(entry.post.read ? "" : L10n.string("weibo.feed.unreadCount", language: settings.appLanguage, 1))
        .accessibilityHint(L10n.string("weibo.feed.openPost", language: settings.appLanguage))
    }

    private var text: String {
        let value = entry.post.displayText
        return value.isEmpty
            ? L10n.string("weibo.feed.noText", language: settings.appLanguage)
            : value
    }

    private var accountRow: some View {
        HStack(alignment: .center, spacing: 7) {
            FollowingAvatar(user: entry.user, size: 20)
            Text(entry.user.screenName)
                .font(.system(
                    size: 11,
                    weight: .semibold,
                    design: isRetro ? .serif : .default
                ))
                .lineLimit(1)
                .foregroundStyle(accent)

            if entry.user.priority == .p0 {
                Text("P0")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isRetro ? RetroEditorialTokens.raisedPaper : .red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isRetro
                                ? RetroEditorialTokens.brick
                                : Color.red.opacity(0.12)
                        )
                    )
            }

            Spacer(minLength: 0)

            if !entry.post.read {
                Circle()
                    .fill(isRetro ? RetroEditorialTokens.brick : Color.red)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
        }
    }

    private var postText: some View {
        Text(text)
            .font(.system(size: 12.5, weight: entry.post.read ? .regular : .medium))
            .lineLimit(6)
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primary)
    }

    private func cover(_ url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )

            if entry.post.imageURLs.count > 1 {
                Text("+\(entry.post.imageURLs.count - 1)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(6)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(relativeTime)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if entry.post.isLongText {
                metaTag(L10n.string("weibo.feed.longText", language: settings.appLanguage))
            }
            if entry.post.isRetweet {
                metaTag(L10n.string("weibo.feed.retweet", language: settings.appLanguage))
            }
            if entry.post.imageURLs.count > 1 {
                metaTag(L10n.string("weibo.feed.images", language: settings.appLanguage, entry.post.imageURLs.count))
            }

            Spacer(minLength: 0)

            if let verdict = entry.post.relevance?.verdict, verdict != .relevant {
                Text(L10n.string(verdict.titleKey, language: settings.appLanguage))
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
            }
        }
    }

    private func metaTag(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 7.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.08)))
    }
}

/// Small account avatar shared by the following waterfall and the sidebar
/// recent-messages card. It falls back to the account's first character while
/// the remote image is loading or missing.
struct FollowingAvatar: View {
    let user: WeiboMonitorUser
    let size: CGFloat

    @Environment(AppSettings.self) private var settings

    private var accent: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : Color.accentColor
    }

    var body: some View {
        Group {
            if let raw = user.avatarURL, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(accent.opacity(0.14))
            Text(String(user.screenName.prefix(1)))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(accent)
        }
    }
}

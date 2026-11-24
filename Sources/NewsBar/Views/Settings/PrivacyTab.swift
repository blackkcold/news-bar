import SwiftUI

/// 隐私与数据：兴趣与推荐、浏览数据、存储与清理。
///
/// Three subpages because the old single page stacked eleven sections and about
/// thirty buttons. The topic draft lives here so switching subpages keeps a
/// half-typed topic.
struct PrivacyTab: View {
    enum Page: String, CaseIterable, Identifiable {
        case interests
        case browsing
        case storage

        var id: String { rawValue }
        var titleKey: String { "settings.privacy.page.\(rawValue)" }
    }

    @State private var page: Page = .interests
    @State private var interestTopic = ""
    @State private var interestTopicMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsSubpageTabs(
                values: Page.allCases,
                title: { L10n.string($0.titleKey) },
                groupLabel: "settings.privacy.pages".localized,
                selection: $page
            )

            Form {
                switch page {
                case .interests:
                    InterestPrivacySection(
                        topic: $interestTopic,
                        topicMessage: $interestTopicMessage
                    )
                case .browsing:
                    BrowserDataTab()
                case .storage:
                    ResearchDataSection()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

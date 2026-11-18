import SwiftUI

/// A small, optional overlay for an article that has an exact research match.
/// It sits outside the article's primary button so opening the original story
/// keeps its existing target and behavior.
struct ResearchAssociationBadge: View {
    @Environment(AppSettings.self) private var settings
    @AppStorage("researchReadingEnabled") private var researchReadingEnabled = true

    let item: NewsItem
    var compact = false
    let matchOverride: WorkspaceReaderResearchMatch?

    @State private var resolvedMatch: WorkspaceReaderResearchMatch?

    init(
        item: NewsItem,
        match: WorkspaceReaderResearchMatch? = nil,
        compact: Bool = false
    ) {
        self.item = item
        self.matchOverride = match
        self.compact = compact
    }

    private var match: WorkspaceReaderResearchMatch? { matchOverride ?? resolvedMatch }

    private var english: Bool { settings.appLanguage == .en }
    private var label: String {
        if match?.hasPublishedReport == true {
            return english ? "Research" : "有深研"
        }
        return english ? "Researching" : "研究中"
    }

    var body: some View {
        Group {
            if researchReadingEnabled, let match, match.isVisibleToReaders,
               match.recordID != nil {
                Button {
                    var userInfo: [String: Any] = [:]
                    if let recordID = match.recordID { userInfo["recordID"] = recordID }
                    if let eventID = match.eventID { userInfo["eventID"] = eventID }
                    NotificationCenter.default.post(
                        name: .transientResearchRequested,
                        object: nil,
                        userInfo: userInfo
                    )
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: match.hasPublishedReport ? "doc.text.magnifyingglass" : "hourglass")
                            .font(.system(size: compact ? 7 : 8, weight: .semibold))
                        Text(label)
                            .font(.system(size: compact ? 8 : 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, compact ? 5 : 7)
                    .padding(.vertical, compact ? 3 : 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint(english ? "Open the related research report" : "打开关联研究报告")
                .help(english ? "Open the related research report" : "打开关联研究报告")
            }
        }
        .task(id: item.id + "\n" + (item.readerURL ?? item.url)) {
            if matchOverride == nil { await refreshMatch() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchRecordsChanged)) { notification in
            let changedID = notification.userInfo?[ResearchChangeKey.recordID] as? String
            guard matchOverride == nil,
                  changedID == nil || changedID == match?.recordID else { return }
            Task { await refreshMatch() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchWorkspaceChanged)) { _ in
            if matchOverride == nil { Task { await refreshMatch() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newsEventsChanged)) { _ in
            if matchOverride == nil { Task { await refreshMatch() } }
        }
    }

    @MainActor
    private func refreshMatch() async {
        let match = await WorkspaceReaderResearchMatcher.shared.match(item: item, url: item.readerURL ?? item.url)
        guard !Task.isCancelled else { return }
        resolvedMatch = match
    }
}

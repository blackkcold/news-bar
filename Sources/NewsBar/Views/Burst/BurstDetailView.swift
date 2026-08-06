import SwiftUI

/// Detail window for a "爆" (burst) Weibo topic: quick summary, chain-of-events
/// overview, and a visual timeline. Loads pre-generated research from the
/// orchestrator, or regenerates on demand (retry action).
struct BurstDetailView: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator
    let burst: NewsItem

    private enum Phase {
        case loading
        case loaded(BurstResearch)
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var research: BurstResearch = BurstResearch()

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .red }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                masthead

                if case .loading = phase {
                    loadingState
                } else if case .failed = phase {
                    failedState
                } else {
                    loadedContent
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 560)
        .adaptiveColorScheme()
        .appThemeSurface()
        .task {
            await load()
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                EditorialSourceBadge(mark: .weibo, fallbackTint: accent, size: 32, rotation: -1)
                EditorialTag(text: "爆", fallbackTint: accent, filled: true)
                Text("burst.badge".localized)
                    .font(.system(size: 10, weight: .medium, design: isRetro ? .serif : .default))
                    .foregroundStyle(.secondary)
            }

            Text(burst.title)
                .editorialHeading(size: 24)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                Text("burst.subtitle".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .newsCardSurface(cornerRadius: 14, rotation: isRetro ? -0.2 : 0)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("burst.loading".localized)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var failedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            Text("burst.failed".localized)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("burst.retry".localized) {
                Task { await load() }
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    @ViewBuilder
    private var loadedContent: some View {
        if research.searchStatus == .failed {
            searchFailedNotice
        }
        if !research.summary.isEmpty {
            summarySection
        }
        if !research.overview.isEmpty {
            overviewSection
        }
        if !research.timeline.isEmpty {
            timelineSection
        } else if !research.overview.isEmpty {
            noTimelineNote
        }
        if !research.sources.isEmpty {
            sourcesSection
        }
    }

    private var searchFailedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("burst.searchFailed".localized)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .newsCardSurface(cornerRadius: 12)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(index: "01", title: "burst.summary".localized, subtitle: "burst.summary.subtitle".localized)
            Text(research.summary)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .newsCardSurface(cornerRadius: 12)
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(index: "02", title: "burst.overview".localized, subtitle: "burst.overview.subtitle".localized)
            Text(research.overview)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .newsCardSurface(cornerRadius: 12)
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(index: "03", title: "burst.timeline".localized, subtitle: "burst.timeline.subtitle".localized)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(research.timeline.enumerated()), id: \.element.id) { index, node in
                    timelineNode(node, isLast: index == research.timeline.count - 1)
                }
            }
            .padding(16)
            .newsCardSurface(cornerRadius: 12)
        }
    }

    private func timelineNode(_ node: TimelineNode, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(accent)
                        .frame(width: 12, height: 12)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                        }
                }
                .frame(width: 12, height: 12)
                .padding(.top, 5)

                if !isLast {
                    Rectangle()
                        .fill(accent.opacity(0.35))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 5) {
                if !node.date.isEmpty {
                    Text(node.date)
                        .font(.system(size: 11, weight: .bold, design: isRetro ? .monospaced : .default))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                Text(node.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !node.detail.isEmpty {
                    Text(node.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var noTimelineNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("burst.noTimeline".localized)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .newsCardSurface(cornerRadius: 12)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(index: "04", title: "burst.sources".localized, subtitle: "burst.sources.subtitle".localized)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(research.sources, id: \.self) { source in
                    Button {
                        URLOpener.open(source)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                                .foregroundStyle(accent)
                            Text(source)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .newsCardSurface(cornerRadius: 12)
        }
    }

    private func sectionHeading(index: String, title: String, subtitle: String) -> some View {
        EditorialSectionHeading(index: index, title: title, subtitle: subtitle)
    }

    private func load() async {
        phase = .loading
        if let cached = orchestrator.cachedBurstResearch(for: burst.title) {
            research = cached
            phase = .loaded(cached)
            return
        }
        // A background fake push may already be researching this title. Wait for
        // it to finish and cache the result instead of starting a second pass.
        let deadline = Date().addingTimeInterval(90)
        while orchestrator.isBurstResearchInFlight(for: burst.title), Date() < deadline {
            if let cached = orchestrator.cachedBurstResearch(for: burst.title) {
                research = cached
                phase = .loaded(cached)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let cached = orchestrator.cachedBurstResearch(for: burst.title) {
            research = cached
            phase = .loaded(cached)
            return
        }
        let result = await orchestrator.regenerateBurstResearch(for: burst, settings: settings)
        if !result.summary.isEmpty || !result.overview.isEmpty || !result.timeline.isEmpty {
            research = result
            phase = .loaded(result)
        } else {
            phase = .failed
        }
    }
}

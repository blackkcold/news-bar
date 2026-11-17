import SwiftUI

struct WorkspaceTimelinePane: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let detail: WorkspaceDetail
    let onRequestSegment: (WorkspaceSegment) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var anchorBinding: Binding<String?> {
        Binding(
            get: { model.presentation.anchor(for: detail.subject.id, segment: .timeline) ?? "timeline.top" },
            set: { model.presentation.setAnchor($0, for: detail.subject.id, segment: .timeline) }
        )
    }

    private var dated: [WorkspaceTimelineEntry] {
        detail.timeline.filter { $0.occurredAt != nil }
    }

    private var undated: [WorkspaceTimelineEntry] {
        detail.timeline.filter { $0.occurredAt == nil }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .frame(height: 1)
                    .id("timeline.top")
                if detail.timeline.isEmpty {
                    emptyState
                        .id("timeline.empty")
                } else {
                    if !dated.isEmpty {
                        WorkspaceSectionHeader(
                            symbol: "clock",
                            title: "workspace.timeline.dated".localized,
                            trailing: "\(dated.count)"
                        )
                        .id("timeline.dated")
                        .padding(.bottom, 4)
                        ForEach(dated) { entry in
                            timelineRow(entry)
                                .id(entry.id)
                        }
                    }
                    if !undated.isEmpty {
                        WorkspaceSectionHeader(
                            symbol: "questionmark.circle",
                            title: "workspace.timeline.unknown".localized,
                            trailing: "\(undated.count)"
                        )
                        .id("timeline.unknown")
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        ForEach(undated) { entry in
                            timelineRow(entry)
                                .id(entry.id)
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: anchorBinding)
    }

    private func timelineRow(_ entry: WorkspaceTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dateLabel(entry.occurredAt))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                if let confidence = entry.confidence {
                    Text(confidenceLabel(confidence))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    WorkspaceOriginBadge(isEvent: entry.origin == .event)
                    if !entry.evidenceIDs.isEmpty {
                        Button {
                            onRequestSegment(.evidence)
                        } label: {
                            Label(L10n.string(
                                "workspace.timeline.citations",
                                language: settings.appLanguage,
                                entry.evidenceIDs.count
                            ), systemImage: "link")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("workspace.timeline.openEvidence".localized)
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.text)
                    .font(.system(size: 11.5, design: isRetro ? .serif : .default))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 21))
                .foregroundStyle(.tertiary)
            Text("workspace.timeline.empty".localized)
                .font(.system(size: 12, weight: .medium))
            Text("workspace.timeline.empty.body".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "workspace.timeline.unknown".localized }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func confidenceLabel(_ confidence: Confidence) -> String {
        switch confidence {
        case .high: return "workspace.timeline.confidence.high".localized
        case .medium: return "workspace.timeline.confidence.medium".localized
        case .low: return "workspace.timeline.confidence.low".localized
        }
    }
}

import SwiftUI

struct WorkspaceEvidencePane: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: ResearchWorkspaceModel
    let detail: WorkspaceDetail
    let onRequestSegment: (WorkspaceSegment) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlightID: String?
    @State private var handledFocusID: UUID?
    @State private var highlightTask: Task<Void, Never>?

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var anchorBinding: Binding<String?> {
        Binding(
            get: { model.presentation.anchor(for: detail.subject.id, segment: .evidence) ?? "evidence.top" },
            set: { model.presentation.setAnchor($0, for: detail.subject.id, segment: .evidence) }
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .frame(height: 1)
                    .id("evidence.top")
                if detail.evidence.isEmpty {
                    emptyState
                } else {
                    WorkspaceSectionHeader(
                        symbol: "quote.bubble",
                        title: "workspace.evidence.title".localized,
                        trailing: "\(detail.evidence.count)"
                    )
                    .id("evidence.header")
                    ForEach(detail.evidence) { item in
                        evidenceRow(item)
                            .id(item.id)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: anchorBinding)
        .onChange(of: model.evidenceFocus?.id, initial: true) { _, _ in
            applyFocus()
        }
        .onDisappear {
            highlightTask?.cancel()
        }
    }

    private func applyFocus() {
        guard let focus = model.evidenceFocus,
              detail.subject.id == model.selectedSubjectID,
              handledFocusID != focus.id else { return }
        handledFocusID = focus.id
        guard let item = matchingEvidence(focus) else {
            model.presentNotice(
                L10n.string("workspace.search.evidenceMissing", language: settings.appLanguage),
                tone: .info,
                subjectID: detail.subject.id
            )
            return
        }
        model.presentation.setAnchor(item.id, for: detail.subject.id, segment: .evidence)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            highlightID = item.id
        }
        highlightTask?.cancel()
        highlightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                highlightID = nil
            }
        }
    }

    private func matchingEvidence(_ focus: WorkspaceEvidenceFocus) -> WorkspaceEvidence? {
        let canonical = focus.canonicalURL
        if !canonical.isEmpty {
            if let exact = detail.evidence.first(where: { $0.canonicalURL == canonical }) {
                return exact
            }
            if let byURL = detail.evidence.first(where: {
                ContentIdentity.canonicalURL($0.url) == canonical
            }) {
                return byURL
            }
        }
        let hint = QuoteVerifier.normalize(focus.quoteHint)
        if hint.count >= 12 {
            if let byQuote = detail.evidence.first(where: { item in
                let stored = QuoteVerifier.normalize(item.quote)
                guard !stored.isEmpty else { return false }
                return stored.contains(hint) || hint.contains(stored)
            }) {
                return byQuote
            }
        }
        return nil
    }

    private func evidenceRow(_ item: WorkspaceEvidence) -> some View {
        Button {
            model.openEvidenceURL(item.url, title: item.title)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.title.isEmpty ? item.sourceName : item.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if item.sharedWithEvent {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("workspace.evidence.shared".localized)
                            .accessibilityLabel("workspace.evidence.shared".localized)
                    }
                }

                if !item.quote.isEmpty {
                    Text("“\(item.quote)”")
                        .font(.system(size: 10.5, design: isRetro ? .serif : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    WorkspaceOriginBadge(isEvent: item.origin == .event)
                    WorkspaceVerificationBadge(verification: item.verification)
                    Text(item.sourceName)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if let publishedAt = item.publishedAt {
                        Text("·")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    if let stance = stanceLabel(item) {
                        Text(stance)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                    if let tier = item.tier {
                        Text("T\(tier.rawValue)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.20))
            .editorialClipShape(cornerRadius: 7)
            .overlay {
                if highlightID == item.id {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isRetro ? RetroEditorialTokens.brick : Color.accentColor,
                            lineWidth: 1.6
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityHint("workspace.evidence.openHint".localized)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 21))
                .foregroundStyle(.tertiary)
            Text("workspace.evidence.empty".localized)
                .font(.system(size: 12, weight: .medium))
            Text("workspace.evidence.empty.body".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("workspace.evidence.viewReport".localized) {
                onRequestSegment(.research)
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func stanceLabel(_ item: WorkspaceEvidence) -> String? {
        guard item.origin == .research else { return nil }
        switch item.verification {
        case .verifiedQuote: return "workspace.evidence.stance.verified".localized
        case .unverifiedQuote: return "workspace.evidence.stance.unverified".localized
        case .snippetOnly: return nil
        }
    }

    private func accessibilityLabel(_ item: WorkspaceEvidence) -> String {
        var parts = [
            item.title.isEmpty ? item.sourceName : item.title,
            item.origin == .event
                ? "workspace.origin.event".localized
                : "workspace.origin.research".localized,
        ]
        switch item.verification {
        case .verifiedQuote: parts.append("workspace.evidence.verified".localized)
        case .unverifiedQuote: parts.append("workspace.evidence.unverified".localized)
        case .snippetOnly: parts.append("workspace.evidence.snippet".localized)
        }
        if item.sharedWithEvent {
            parts.append("workspace.evidence.shared".localized)
        }
        return parts.joined(separator: "，")
    }
}

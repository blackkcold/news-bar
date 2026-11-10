import SwiftUI

/// Preview and confirmation for every batch import path. The sheet owns only
/// selection state; parsing and validation happened before it appeared, so the
/// person always sees the exact list that will be written.
struct RSSImportSheet: View {
    enum Mode {
        case file(format: RSSImportFormat, plan: RSSImportPlan)
        case googleNews
    }

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let existingSources: [RSSSourceConfig]
    let onApply: ([RSSImportCandidate]) -> Void

    @State private var plan: RSSImportPlan
    @State private var selection: Set<String>
    @State private var googleNewsText = ""
    @State private var googleNewsError: String?
    @State private var showRejections = false

    init(
        mode: Mode,
        existingSources: [RSSSourceConfig],
        onApply: @escaping ([RSSImportCandidate]) -> Void
    ) {
        self.mode = mode
        self.existingSources = existingSources
        self.onApply = onApply
        switch mode {
        case .file(_, let plan):
            _plan = State(initialValue: plan)
            _selection = State(initialValue: Set(plan.accepted.map(\.id)))
        case .googleNews:
            _plan = State(initialValue: RSSImportPlan())
            _selection = State(initialValue: [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isGoogleNews {
                googleNewsInput
            }

            if plan.total > 0 {
                summary
                candidateList
                if !plan.rejections.isEmpty { rejectionList }
            } else if !isGoogleNews {
                emptyState
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 460)
        .appThemeSurface()
    }

    private var isGoogleNews: Bool {
        if case .googleNews = mode { return true }
        return false
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            EditorialSourceBadge(mark: .rss, fallbackTint: .blue, size: 36, rotation: -1)

            VStack(alignment: .leading, spacing: 2) {
                Text(isGoogleNews ? "rss.import.googleNews.title".localized : "rss.import.title".localized)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch mode {
        case .file(let format, _):
            return L10n.string("rss.import.fileSubtitle", format.displayName)
        case .googleNews:
            return "rss.import.googleNews.body".localized
        }
    }

    // MARK: - Google News input

    private var googleNewsInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $googleNewsText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 108)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                    }

                if googleNewsText.isEmpty {
                    Text("rss.import.googleNews.placeholder".localized)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                if let googleNewsError {
                    Text(googleNewsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("rss.import.googleNews.preview".localized) {
                    previewGoogleNews()
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
                .controlSize(.small)
            }
        }
    }

    private func previewGoogleNews() {
        let lines = googleNewsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var candidates: [RSSImportCandidate] = []
        for line in lines {
            if line.lowercased().hasPrefix("http") {
                candidates.append(RSSImportCandidate(name: "", url: line))
            } else {
                candidates.append(contentsOf: RSSImportService.googleNewsCandidates(queries: [line]))
            }
        }

        guard !candidates.isEmpty else {
            googleNewsError = "rss.import.googleNews.empty".localized
            return
        }

        // A blank name falls back to the host inside plan(candidates:).
        let normalized = candidates.map {
            RSSImportCandidate(
                name: $0.name.isEmpty ? (URL(string: $0.url)?.host ?? $0.url) : $0.name,
                url: $0.url,
                displayMode: $0.displayMode,
                group: $0.group
            )
        }
        plan = RSSImportService.plan(candidates: normalized, existing: existingSources)
        selection = Set(plan.accepted.map(\.id))
        googleNewsError = plan.accepted.isEmpty ? "rss.import.none".localized : nil
        showRejections = false
    }

    // MARK: - Summary and list

    private var summary: some View {
        HStack(spacing: 8) {
            Text(L10n.string("rss.import.summary", plan.accepted.count, plan.rejections.count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button(
                selection.count == plan.accepted.count
                    ? "rss.import.deselectAll".localized
                    : "rss.import.selectAll".localized
            ) {
                if selection.count == plan.accepted.count {
                    selection.removeAll()
                } else {
                    selection = Set(plan.accepted.map(\.id))
                }
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)
            .disabled(plan.accepted.isEmpty)
        }
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(plan.accepted.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.28))
                            .frame(height: 1)
                    }
                    candidateRow(candidate)
                }
            }
        }
        .frame(maxHeight: 280)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.5),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
        }
        .opacity(plan.accepted.isEmpty ? 0 : 1)
    }

    private func candidateRow(_ candidate: RSSImportCandidate) -> some View {
        HStack(spacing: 9) {
            Toggle("", isOn: selectionBinding(for: candidate))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(candidate.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let group = candidate.group, !group.isEmpty {
                EditorialTag(text: group, fallbackTint: .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.contains(candidate.id) {
                selection.remove(candidate.id)
            } else {
                selection.insert(candidate.id)
            }
        }
    }

    private func selectionBinding(for candidate: RSSImportCandidate) -> Binding<Bool> {
        Binding(
            get: { selection.contains(candidate.id) },
            set: { isOn in
                if isOn { selection.insert(candidate.id) } else { selection.remove(candidate.id) }
            }
        )
    }

    private var rejectionList: some View {
        DisclosureGroup(isExpanded: $showRejections) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(plan.rejections) { rejection in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(rejection.name.isEmpty ? rejection.url : rejection.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Text(reasonText(for: rejection))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text(L10n.string("rss.import.skipped", plan.rejections.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("rss.import.none".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 18)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            Button("rss.import.cancel".localized) {
                dismiss()
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)

            Button {
                let chosen = plan.accepted.filter { selection.contains($0.id) }
                guard !chosen.isEmpty else { return }
                onApply(chosen)
                dismiss()
            } label: {
                Text(L10n.string("rss.import.apply", selection.count))
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
            .controlSize(.small)
            .disabled(selection.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Reasons

    private func reasonText(for rejection: RSSImportRejection) -> String {
        switch rejection.kind {
        case .duplicate:
            return "rss.import.duplicate".localized
        case .invalidURL:
            return "rss.import.invalid".localized
        case .overLimit:
            return "rss.import.overLimit".localized
        case .blocked(let reason):
            return localizedBlockReason(reason)
        }
    }

    private func localizedBlockReason(_ reason: String) -> String {
        if reason == "Invalid URL or scheme" {
            return "rss.import.invalid".localized
        }
        if reason.hasPrefix("Blocked host: ") {
            return L10n.string(
                "rss.import.blocked",
                reason.replacingOccurrences(of: "Blocked host: ", with: "")
            )
        }
        if reason.hasPrefix("Private IP range: ") {
            return L10n.string(
                "rss.import.blocked",
                reason.replacingOccurrences(of: "Private IP range: ", with: "")
            )
        }
        return reason
    }
}

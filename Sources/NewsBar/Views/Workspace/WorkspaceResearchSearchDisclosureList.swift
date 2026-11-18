import SwiftUI

/// Collapses report/evidence hits only when the search index ties them to the
/// same persistent workspace subject. The same view is used by reader quick
/// search and Workspace management search so their identity rules stay equal.
struct WorkspaceResearchSearchDisclosureList: View {
    let results: [WorkspaceSearchResult]
    let subjectTitles: [String: String]
    let activeRuns: [WorkspaceSearchRunSnapshot]
    let language: AppLanguage
    let onOpenResult: (WorkspaceSearchResult) -> Void
    let onOpenSource: (URL, String) -> Void
    var onExpandSubject: (String) -> Void = { _ in }

    @State private var expandedGroups: Set<String> = []

    private enum Entry: Identifiable {
        case result(WorkspaceSearchResult)
        case group(id: String, subjectID: String, results: [WorkspaceSearchResult], runs: [WorkspaceSearchRunSnapshot])

        var id: String {
            switch self {
            case .result(let result): return result.id
            case .group(let id, _, _, _): return "research-subject:\(id)"
            }
        }
    }

    private var entries: [Entry] {
        let researchResults = results.filter(\.isResearchMatch)
        var bySubjectID: [String: [WorkspaceSearchResult]] = [:]
        for result in researchResults {
            guard let subjectID = result.associatedSubjectID else { continue }
            bySubjectID[subjectID, default: []].append(result)
        }

        var emittedSubjectIDs: Set<String> = []
        var entries: [Entry] = []
        for result in researchResults {
            guard let subjectID = result.associatedSubjectID,
                  let related = bySubjectID[subjectID] else {
                entries.append(.result(result))
                continue
            }
            let runs = activeRuns.filter { $0.subjectID == subjectID }
            guard related.count > 1 || !runs.isEmpty else {
                entries.append(.result(result))
                continue
            }
            guard emittedSubjectIDs.insert(subjectID).inserted else { continue }
            entries.append(.group(
                id: subjectID,
                subjectID: subjectID,
                results: related,
                runs: runs
            ))
        }
        return entries
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(entries) { entry in
                switch entry {
                case .result(let result):
                    resultRow(result, nested: false)
                case let .group(id, subjectID, related, runs):
                    DisclosureGroup(isExpanded: expandedBinding(for: id)) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(related) { result in
                                resultRow(result, nested: true)
                            }
                            ForEach(runs) { run in
                                activeRun(run)
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subjectTitles[subjectID] ?? fallbackTitle(related.first))
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(2)
                                Text(L10n.string(
                                    "workspace.search.researchMatches",
                                    language: language,
                                    related.count
                                ))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func resultRow(_ result: WorkspaceSearchResult, nested: Bool) -> some View {
        let title = resultTitle(result)
        let snippet = resultSnippet(result)
        return Button {
            onOpenResult(result)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: resultSymbol(result))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(resultKindTitle(result))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, nested ? 8 : 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(nested ? 0.12 : 0.18))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(resultKindTitle(result)), \(title), \(snippet)")
    }

    private func activeRun(_ run: WorkspaceSearchRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(run.phase == .idle || run.phase == .done
                     ? L10n.string("research.status.\(run.status.rawValue)", language: language)
                     : L10n.string("research.phase.\(run.phase.rawValue)", language: language))
                    .font(.system(size: 9.5, weight: .medium))
            }
            if let metrics = runMetrics(run) {
                Text(metrics)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array((run.progressFacts ?? []).suffix(3))) { fact in
                progressFact(fact)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private func progressFact(_ fact: ResearchRunFact) -> some View {
        let sourceURL = ReaderNavigationPolicy.allowedURL(fact.url)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: fact.kind == .claimSupported ? "checkmark.seal" : "quote.bubble")
                .font(.caption2)
                .foregroundStyle(fact.kind == .claimSupported ? .green : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.claim ?? fact.title)
                    .font(.system(size: 9))
                    .fixedSize(horizontal: false, vertical: true)
                if let quote = fact.quote, !quote.isEmpty {
                    Text("“\(quote)”")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(fact.title.isEmpty ? L10n.string("workspace.evidence.open", language: language) : fact.title) {
                    guard let sourceURL else { return }
                    onOpenSource(sourceURL, fact.title)
                }
                .font(.system(size: 8.5))
                .buttonStyle(.link)
                .disabled(sourceURL == nil)
            }
        }
        .padding(.leading, 7)
    }

    private func runMetrics(_ run: WorkspaceSearchRunSnapshot) -> String? {
        var values: [String] = []
        if run.queriesPlanned > 0 {
            values.append(L10n.string(
                "workspace.research.queries",
                language: language,
                run.queriesCompleted,
                run.queriesPlanned
            ))
        }
        if run.pagesRead > 0 {
            values.append(L10n.string("workspace.research.pages", language: language, run.pagesRead))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    if expandedGroups.insert(id).inserted { onExpandSubject(id) }
                } else {
                    expandedGroups.remove(id)
                }
            }
        )
    }

    private func resultTitle(_ result: WorkspaceSearchResult) -> String {
        switch result {
        case let .report(_, _, title, _, _): return title
        case let .evidence(_, _, title, _, _): return title
        case .subject, .answer: return ""
        }
    }

    private func resultSnippet(_ result: WorkspaceSearchResult) -> String {
        switch result {
        case let .report(_, _, _, snippet, _): return snippet
        case let .evidence(_, _, _, snippet, _): return snippet
        case .subject, .answer: return ""
        }
    }

    private func resultSymbol(_ result: WorkspaceSearchResult) -> String {
        switch result {
        case .report: return "doc.text"
        case .evidence: return "quote.bubble"
        case .subject, .answer: return "doc.text.magnifyingglass"
        }
    }

    private func resultKindTitle(_ result: WorkspaceSearchResult) -> String {
        switch result {
        case .report: return L10n.string("workspace.result.report", language: language)
        case .evidence: return L10n.string("workspace.result.evidence", language: language)
        case .subject: return L10n.string("workspace.result.subject", language: language)
        case .answer: return L10n.string("workspace.result.answer", language: language)
        }
    }

    private func fallbackTitle(_ result: WorkspaceSearchResult?) -> String {
        guard let result else { return L10n.string("workspace.result.researchRecords", language: language) }
        return resultTitle(result)
    }
}

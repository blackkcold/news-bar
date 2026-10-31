import SwiftUI

struct AISearchArchiveView: View {
    let entries: [AISearchArchiveEntry]
    let query: String
    let language: AppLanguage
    let onSelect: (AISearchArchiveEntry) -> Void
    let onCopy: (AISearchArchiveEntry) -> Void
    let onOpenSource: (URL) -> Void
    let onRemove: (AISearchArchiveEntry) -> Void

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [AISearchArchiveEntry]

        var id: Date { day }
    }

    private var filtered: [AISearchArchiveEntry] {
        Self.filteredEntries(entries, query: query)
    }

    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                entries: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            )
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if dayGroups.isEmpty {
                    ContentUnavailableView(
                        entries.isEmpty
                            ? L10n.string("reader.quickSearch.archive.empty", language: language)
                            : L10n.string("reader.quickSearch.archive.noResults", language: language),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(dayGroups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.day.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)

                            ForEach(group.entries) { entry in
                                archiveRow(entry)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 460)
        .accessibilityElement(children: .contain)
    }

    private func archiveRow(_ entry: AISearchArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onSelect(entry)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.query)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let pageTitle = entry.pageTitle, !pageTitle.isEmpty {
                        Text(pageTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !entry.answer.oneLine.isEmpty {
                        Text(entry.answer.oneLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(QuickSearchAccessibilityLabels.archiveRow(entry, language: language))
            .accessibilityHint(L10n.string("reader.quickSearch.archive.replay", language: language))

            HStack(spacing: 8) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                Button {
                    onCopy(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(QuickSearchAccessibilityLabels.copy(language: language))

                ForEach(entry.answer.sources, id: \.index) { source in
                    if let url = source.url.flatMap(ReaderNavigationPolicy.allowedURL) {
                        Button {
                            onOpenSource(url)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            QuickSearchAccessibilityLabels.openSource(source.title, language: language)
                        )
                        .help(source.title)
                    }
                }

                Button(role: .destructive) {
                    onRemove(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(QuickSearchAccessibilityLabels.remove(language: language))
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func filteredEntries(
        _ entries: [AISearchArchiveEntry],
        query: String
    ) -> [AISearchArchiveEntry] {
        let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.query, entry.pageTitle, entry.answer.oneLine]
                .compactMap { $0 }
                .contains { normalized($0).contains(needle) }
        }
    }

    static func restoredAnswer(for entry: AISearchArchiveEntry) -> AnswerDocument {
        entry.answerDocument()
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

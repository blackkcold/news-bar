import SwiftUI

/// One paragraph of answer text with its citation markers turned into links.
///
/// The marker is only a link when the number resolves to a page this run read.
/// Everything else stays on screen as literal text: rewriting the model's words
/// would hide the mistake, and drawing a chip would invent a source.
struct AnswerRichText: View {
    let text: String
    let sourceCount: Int
    let font: Font
    var lineSpacing: CGFloat = 3
    let onCite: (Int) -> Void

    var body: some View {
        Text(attributed)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "newsbar-source",
                      let index = url.host.flatMap(Int.init) else {
                    return .systemAction
                }
                onCite(index)
                return .handled
            })
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in AnswerCitationScanner.segments(in: text, sourceCount: sourceCount) {
            switch segment {
            case .text(let value):
                var run = AttributedString(value)
                run.font = font
                result += run
            case .citation(let index):
                var run = AttributedString("[\(index)]")
                run.font = .system(size: 10, weight: .semibold)
                run.foregroundColor = .accentColor
                run.link = URL(string: "newsbar-source://\(index)")
                result += run
            }
        }
        return result
    }
}

/// A titled section. Consecutive `label: value` bullets become a two-column
/// grid, which is what makes a comparison readable at 400 pt; everything else
/// stays a paragraph, bullet or quote.
struct AnswerBlockView: View {
    let block: AnswerBlock
    let sourceCount: Int
    let onCite: (Int) -> Void

    private struct Row: Identifiable {
        let id: Int
        let label: String
        let value: String
    }

    private enum Content {
        case line(AnswerLine)
        case definitions([Row])
    }

    private struct Item: Identifiable {
        let id: Int
        let content: Content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading = block.heading, !heading.isEmpty {
                Text(heading)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(items) { item in
                switch item.content {
                case .line(let line):
                    lineView(line)
                case .definitions(let rows):
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                        ForEach(rows) { row in
                            GridRow {
                                Text(row.label)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                AnswerRichText(
                                    text: row.value,
                                    sourceCount: sourceCount,
                                    font: .callout,
                                    onCite: onCite
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: AnswerLine) -> some View {
        switch line {
        case .paragraph(let text):
            AnswerRichText(text: text, sourceCount: sourceCount, font: .callout, onCite: onCite)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                AnswerRichText(text: text, sourceCount: sourceCount, font: .callout, onCite: onCite)
            }
        case .definition(let label, let value):
            // A lone definition still aligns like a row of the same block.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                AnswerRichText(text: value, sourceCount: sourceCount, font: .callout, onCite: onCite)
            }
        case .quote(let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                AnswerRichText(text: text, sourceCount: sourceCount, font: .callout, onCite: onCite)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        var pending: [Row] = []

        func flush() {
            guard !pending.isEmpty else { return }
            items.append(Item(id: items.count, content: .definitions(pending)))
            pending = []
        }

        for line in AnswerFormatter.lines(block.body) {
            if case .definition(let label, let value) = line {
                pending.append(Row(id: pending.count, label: label, value: value))
                continue
            }
            flush()
            items.append(Item(id: items.count, content: .line(line)))
        }
        flush()
        return items
    }
}

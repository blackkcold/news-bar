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
    /// Off while the answer streams. Selectable text is drawn through a second
    /// layer, and replacing the string fifteen times a second is what left the
    /// previous frame's paragraph painted under the new one.
    var selectable: Bool = true
    let onCite: (Int) -> Void

    var body: some View {
        Text(attributed)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .selectableText(selectable)
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

/// `textSelection` takes a selectability value, not a flag, so the two states
/// cannot be chosen by a ternary.
private extension View {
    @ViewBuilder
    func selectableText(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}

/// A titled section. Consecutive `label: value` bullets become a two-column
/// grid, which is what makes a comparison readable at 400 pt; everything else
/// stays a paragraph, bullet or quote.
struct AnswerBlockView: View {
    let block: AnswerBlock
    let sourceCount: Int
    var selectable: Bool = true
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
        let id: String
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
                                    selectable: selectable,
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
            AnswerRichText(text: text, sourceCount: sourceCount, font: .callout, selectable: selectable, onCite: onCite)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                AnswerRichText(text: text, sourceCount: sourceCount, font: .callout, selectable: selectable, onCite: onCite)
            }
        case .definition(let label, let value):
            // A lone definition still aligns like a row of the same block.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                AnswerRichText(text: value, sourceCount: sourceCount, font: .callout, selectable: selectable, onCite: onCite)
            }
        case .quote(let text):
            AnswerRichText(text: text, sourceCount: sourceCount, font: .callout, selectable: selectable, onCite: onCite)
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
                // The rule is drawn over the text instead of beside it. A 2 pt
                // shape inside the HStack takes part in the first-text-baseline
                // row, and a `maxHeight: .infinity` shape in a `fixedSize` row
                // was the most expensive thing in the card to re-measure on
                // every streamed character.
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 2)
                        .accessibilityHidden(true)
                }
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        var pending: [Row] = []
        var pendingStart = 0
        var lineIndex = 0

        func flush() {
            guard !pending.isEmpty else { return }
            // A grid keeps the identity of its first row: while text streams,
            // a row can be absorbed into the grid in front of it, and an
            // index-based id would re-bind the following paragraph to it.
            items.append(Item(id: "d\(pendingStart)", content: .definitions(pending)))
            pending = []
        }

        for line in AnswerFormatter.lines(block.body) {
            defer { lineIndex += 1 }
            if case .definition(let label, let value) = line {
                if pending.isEmpty { pendingStart = lineIndex }
                pending.append(Row(id: pending.count, label: label, value: value))
                continue
            }
            flush()
            items.append(Item(id: "l\(lineIndex)", content: .line(line)))
        }
        flush()
        return items
    }
}

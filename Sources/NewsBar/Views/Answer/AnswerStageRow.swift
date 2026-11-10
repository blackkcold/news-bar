import SwiftUI

/// The only stages the app can actually observe. There is no "understanding"
/// step: the model reports the kind itself, so showing one would be theatre.
struct AnswerStageRow: View {
    let state: AISearchPanelModel.State
    let scope: AISearchScope
    let language: AppLanguage
    /// The assess step only exists for this run when the user enabled source
    /// assessment; showing a step that will never run is worse than omitting it.
    var showsAssessment: Bool = false

    private struct Step: Identifiable {
        let id: Int
        let title: String
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(for: step.id))
                        .frame(width: 5, height: 5)
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step.id == currentIndex ? Color.primary : Color.secondary)
                }
                if step.id != steps.last?.id {
                    Text("›")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var steps: [Step] {
        var steps: [Step] = []
        if scope == .web {
            steps.append(Step(id: steps.count, title: L10n.string("reader.search.stage.search", language: language)))
        }
        steps.append(Step(id: steps.count, title: readingTitle))
        if scope == .web, showsAssessment {
            steps.append(Step(id: steps.count, title: L10n.string("reader.search.stage.assess", language: language)))
        }
        steps.append(Step(id: steps.count, title: L10n.string("reader.search.stage.answer", language: language)))
        return steps
    }

    private var readingTitle: String {
        if case .reading(let index, let total) = state {
            return L10n.string("reader.search.stage.read", language: language, index, total)
        }
        return L10n.string("reader.search.stage.readShort", language: language)
    }

    private var currentIndex: Int {
        switch state {
        case .searching:
            return scope == .web ? 0 : 0
        case .reading:
            return scope == .web ? 1 : 0
        case .assessing:
            return scope == .web ? 2 : 0
        case .answering:
            return max(0, steps.count - 1)
        default:
            return -1
        }
    }

    private func color(for index: Int) -> Color {
        if index == currentIndex { return .accentColor }
        if index < currentIndex { return .secondary }
        return Color.secondary.opacity(0.3)
    }
}

import SwiftUI

struct QuickSearchEdgeButton: View {
    let isVisible: Bool
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        if isVisible {
            Button(action: action) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 34, height: 42)
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .clipShape(Capsule())
            .accessibilityLabel(L10n.string("reader.quickSearch.edge", language: language))
            .help(L10n.string("reader.quickSearch.edge", language: language))
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    static func shouldBeVisible(
        readerPresented: Bool,
        researchOpen: Bool,
        searchOrArchiveOpen: Bool,
        selectionExplanationOpen: Bool,
        auxiliaryRailOpen: Bool = false
    ) -> Bool {
        readerPresented
            && !researchOpen
            && !searchOrArchiveOpen
            && !selectionExplanationOpen
            && !auxiliaryRailOpen
    }
}

import Foundation

/// Picks which stretch of a report's timeline the popup previews as a strip.
///
/// The strip shows three captions. The nodes themselves stay in time order and
/// all of them are reachable by scrolling the strip; this type only decides
/// where the strip starts, which is what "show the important part first"
/// means without reordering anything.
///
/// A contiguous window rather than three picked nodes: a timeline with holes
/// reads as "nothing happened in between", which the data does not say.
struct ResearchTimelinePreview {
    /// How many captions the strip shows before it starts pushing sideways.
    /// Fixed rather than computed from the window width: the body column is
    /// already capped at 640pt, so both the narrow and the default window fit
    /// this many, and a value that changed with the window would make `+N`
    /// jump under the reader's eyes.
    static let visibleCount = 3

    let nodes: [ReportPresentation.Node]
    /// Index the strip scrolls to on first appearance.
    let anchorIndex: Int
    /// `nodes.count - visibleCount`; zero or less means no `+N` badge.
    let hiddenCount: Int

    init(nodes: [ReportPresentation.Node]) {
        self.nodes = nodes
        anchorIndex = Self.windowStart(for: nodes)
        hiddenCount = max(0, nodes.count - Self.visibleCount)
    }

    var showsOverflow: Bool { nodes.count > Self.visibleCount }

    /// The node ids the initial window covers. Exposed for tests so the choice
    /// can be asserted without computing scroll offsets.
    var initialWindow: [ReportPresentation.Node] {
        guard !nodes.isEmpty else { return [] }
        let count = min(Self.visibleCount, nodes.count)
        let start = min(anchorIndex, max(0, nodes.count - count))
        return Array(nodes[start..<(start + count)])
    }

    /// Highest-scoring contiguous window, ties going to the later one because
    /// the recent part of a story is what a reader just interrupted wants.
    static func windowStart(for nodes: [ReportPresentation.Node]) -> Int {
        guard nodes.count > visibleCount else { return 0 }
        let scores = nodes.map(score)
        var bestStart = nodes.count - visibleCount
        var bestScore = Int.min
        let lastStart = nodes.count - visibleCount
        for start in 0...lastStart {
            let total = scores[start..<(start + visibleCount)].reduce(0, +)
            if total >= bestScore {
                bestScore = total
                bestStart = start
            }
        }
        return bestStart
    }

    /// Built only from fields the report already carries. `ReportPresentation`
    /// has already downgraded a node whose quotes failed verification, so an
    /// unsourced node cannot score high here either.
    static func score(_ node: ReportPresentation.Node) -> Int {
        var total = 0
        switch node.state {
        case .verified: total += 2
        case .citedUnverified: total += 1
        case .unsourced: total += 0
        }
        switch node.node.confidence {
        case .high: total += 2
        case .medium: total += 1
        case .low: total += 0
        }
        total += min(node.evidence.count, 3)
        if node.node.sortDate != nil { total += 1 }
        return total
    }
}

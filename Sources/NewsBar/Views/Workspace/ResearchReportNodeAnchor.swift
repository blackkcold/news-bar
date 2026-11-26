import Foundation

/// Namespaces inside the report reader's own scroll view.
///
/// The timeline strip and the detail chapter both render the same node, and
/// both need to be scroll targets. `ScrollViewReader.scrollTo(_:)` is a flat
/// id space, so the two must not share an id: scrolling to a node means
/// "scroll to that node's row in the detail chapter", never "scroll to its
/// capsule".
enum ResearchReportNodeAnchor {
    /// The capsule inside the horizontal strip.
    static func capsule(_ nodeID: String) -> String { "capsule:\(nodeID)" }

    /// The node's row inside the timeline chapter.
    static func detail(_ nodeID: String) -> String { "detail:\(nodeID)" }

    /// The node's own id as published by `ReportPresentation`, used where the
    /// consumer scrolls within the strip itself.
    static func raw(_ nodeID: String) -> String { nodeID }
}

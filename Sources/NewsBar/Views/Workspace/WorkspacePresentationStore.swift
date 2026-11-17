import Foundation
import Observation

/// Session-only presentation memory for the workspace. It is keyed by the
/// canonical subject ID and never persisted. Only the current subject's panes
/// are mounted; this stores the small amount of state needed to make A→B→A
/// feel continuous.
@MainActor
@Observable
final class WorkspacePresentationStore {
    struct State: Equatable {
        var segment: WorkspaceSegment = .overview
        var selectedVersionID: String?
        var depth: ResearchDepth?
        var anchors: [WorkspaceSegment: String] = [:]
    }

    private var states: [String: State] = [:]

    func state(for subjectID: String) -> State {
        guard !subjectID.isEmpty else { return State() }
        return states[subjectID] ?? State()
    }

    func segment(for subjectID: String) -> WorkspaceSegment {
        state(for: subjectID).segment
    }

    func setSegment(_ segment: WorkspaceSegment, for subjectID: String) {
        guard !subjectID.isEmpty else { return }
        var current = state(for: subjectID)
        guard current.segment != segment else { return }
        current.segment = segment
        states[subjectID] = current
    }

    func selectedVersionID(for subjectID: String) -> String? {
        state(for: subjectID).selectedVersionID
    }

    func setSelectedVersionID(_ versionID: String?, for subjectID: String) {
        guard !subjectID.isEmpty else { return }
        var current = state(for: subjectID)
        guard current.selectedVersionID != versionID else { return }
        current.selectedVersionID = versionID
        states[subjectID] = current
    }

    func resetVersion(for subjectID: String) {
        setSelectedVersionID(nil, for: subjectID)
    }

    func depth(for subjectID: String) -> ResearchDepth? {
        state(for: subjectID).depth
    }

    func setDepth(_ depth: ResearchDepth?, for subjectID: String) {
        guard !subjectID.isEmpty else { return }
        var current = state(for: subjectID)
        guard current.depth != depth else { return }
        current.depth = depth
        states[subjectID] = current
    }

    func anchor(for subjectID: String, segment: WorkspaceSegment) -> String? {
        state(for: subjectID).anchors[segment]
    }

    func setAnchor(_ anchor: String?, for subjectID: String, segment: WorkspaceSegment) {
        guard !subjectID.isEmpty else { return }
        var current = state(for: subjectID)
        if let anchor {
            guard current.anchors[segment] != anchor else { return }
            current.anchors[segment] = anchor
        } else {
            guard current.anchors[segment] != nil else { return }
            current.anchors.removeValue(forKey: segment)
        }
        states[subjectID] = current
    }

    /// A merge in the domain layer can retire a subject ID. Preserve the
    /// presentation the user was looking at when they follow the redirect.
    func migrate(from oldID: String, to newID: String) {
        guard !oldID.isEmpty, !newID.isEmpty, oldID != newID else { return }
        guard let old = states[oldID] else { return }
        if var existing = states[newID] {
            // The state the user is looking at (old) wins for tab/version/depth;
            // keep canonical anchors that only the survivor had.
            var merged = old
            for (segment, anchor) in existing.anchors where merged.anchors[segment] == nil {
                merged.anchors[segment] = anchor
            }
            existing = merged
            states[newID] = existing
        } else {
            states[newID] = old
        }
        states[oldID] = nil
    }
}

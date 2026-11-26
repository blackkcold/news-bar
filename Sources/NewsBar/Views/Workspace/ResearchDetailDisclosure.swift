import Foundation

/// The popup's single disclosure: the conclusion is always visible and the
/// three detail chapters sit behind one strip. Extracted from the view so the
/// expand-then-scroll sequence and its persistence can be tested without
/// rendering anything.
///
/// The strip never moves. Toggling appends or removes content *below* it, so
/// whatever the reader was looking at keeps its place on screen.
struct ResearchDetailDisclosureState: Equatable {
    /// The defaults key survives closing the popup, which is what the spec
    /// asks for: reopening a report returns to the layout the reader chose.
    static let defaultsKey = "reader.research.detailsExpanded"

    private(set) var isExpanded: Bool
    /// A node the reader asked to see while the detail was folded. It is
    /// consumed on the next layout pass, after the chapters exist.
    private(set) var pendingRevealID: String?

    init(isExpanded: Bool) {
        self.isExpanded = isExpanded
    }

    init(defaults: UserDefaults = TestIsolation.defaults) {
        self.isExpanded = defaults.bool(forKey: Self.defaultsKey)
    }

    static func persist(_ isExpanded: Bool, defaults: UserDefaults = TestIsolation.defaults) {
        defaults.set(isExpanded, forKey: defaultsKey)
    }

    /// A plain toggle never schedules a reveal: the reader changed the layout,
    /// not the target.
    mutating func toggle() {
        isExpanded.toggle()
        pendingRevealID = nil
    }

    /// Clicking a timeline capsule always lands on that node. The reveal is
    /// always queued rather than scrolled immediately: a folded detail has no
    /// chapter in the view tree yet, so scrolling now would land nowhere.
    ///
    /// Expanding here also persists, exactly as the fold control does. Otherwise
    /// a reader who opened the detail by clicking a capsule would find it
    /// folded again after closing the report — their choice silently undone.
    mutating func reveal(_ targetID: String) {
        if !isExpanded {
            isExpanded = true
            Self.persist(true)
        }
        pendingRevealID = targetID
    }

    /// Called once the detail chapters are on screen. Returns the id to scroll
    /// to and clears it so a later layout pass cannot scroll again.
    mutating func consumePendingReveal() -> String? {
        guard isExpanded, let pendingRevealID else { return nil }
        self.pendingRevealID = nil
        return pendingRevealID
    }
}

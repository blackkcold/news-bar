import Foundation

/// One newly available lead for an incremental research pass. A material is a
/// discovery input, never evidence: the page must still be read and its quote
/// verified by the existing pipeline.
struct ResearchMaterial: Codable, Hashable, Sendable {
    var url: String
    var canonicalURL: String
    var title: String
    var snippet: String
    var publishedAt: Date?
    var sourceName: String

    init(
        url: String,
        title: String,
        snippet: String = "",
        publishedAt: Date? = nil,
        sourceName: String = ""
    ) {
        self.url = url
        self.canonicalURL = ContentIdentity.canonicalURL(url)
        self.title = title
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.sourceName = sourceName
    }
}

/// Everything that must match before an existing report can be reused without
/// a new analysis. The evidence fingerprint is stored separately on
/// `WorkspaceReportState`; this value covers the analysis configuration.
struct ResearchReuseSignature: Codable, Hashable, Sendable {
    var subjectID: String
    var depth: ResearchDepth
    var provider: String
    var model: String
    var promptVersion: Int
    var recency: String
    /// Stable destination identity (base URL/auth/wire fields), never a key.
    var endpointIdentity: String? = nil
    /// Provider id + endpoint identity. Custom providers can share `provider`
    /// while pointing at a different endpoint.
    var providerIdentity: String? = nil
}

/// Hand-off from `WorkspaceResearchLauncher` to the production executor.
///
/// The launcher cannot pass extra parameters through the frozen
/// `WorkspaceResearchExecutor` type, so it leaves the context here keyed by
/// record. `take` is destructive: a run consumes exactly one context. If the
/// app restarts, the context is gone and the next run is a full run, which is
/// the safe fallback.
actor ResearchIncrementalContextStore {
    static let shared = ResearchIncrementalContextStore()
    private static let lifetime: TimeInterval = 10 * 60
    /// A force-refresh may wait behind queued runs; do not silently downgrade
    /// it to a cached-page run after ten minutes.
    private static let forceLifetime: TimeInterval = 60 * 60

    private struct Entry {
        let context: ResearchIncrementalContext
        let storedAt: Date
    }

    private struct DepthEntry {
        let depth: ResearchDepth
        let storedAt: Date
    }

    private struct TimestampEntry {
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var depths: [String: DepthEntry] = [:]
    private var forceFlags: [String: TimestampEntry] = [:]

    func put(_ context: ResearchIncrementalContext, recordID: String) {
        entries[recordID] = Entry(context: context, storedAt: Date())
    }

    /// Depth chosen for this start. This makes `request.depth` authoritative
    /// even if a caller supplies an executor that does not pass it explicitly.
    func putDepth(_ depth: ResearchDepth, recordID: String) {
        depths[recordID] = DepthEntry(depth: depth, storedAt: Date())
    }

    func takeDepth(recordID: String) -> ResearchDepth? {
        guard let entry = depths.removeValue(forKey: recordID) else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) <= Self.lifetime else {
            return nil
        }
        return entry.depth
    }

    func putForceRefresh(_ force: Bool, recordID: String) {
        if force {
            forceFlags[recordID] = TimestampEntry(storedAt: Date())
        } else {
            forceFlags.removeValue(forKey: recordID)
        }
    }

    func takeForceRefresh(recordID: String) -> Bool {
        guard let entry = forceFlags.removeValue(forKey: recordID) else { return false }
        return Date().timeIntervalSince(entry.storedAt) <= Self.forceLifetime
    }

    func take(recordID: String) -> ResearchIncrementalContext? {
        guard let entry = entries.removeValue(forKey: recordID) else { return nil }
        // A rejected/cancelled start must not leak an incremental plan into a
        // much later run.
        guard Date().timeIntervalSince(entry.storedAt) <= Self.lifetime else {
            return nil
        }
        return entry.context
    }

    func discard(recordID: String) {
        entries.removeValue(forKey: recordID)
        depths.removeValue(forKey: recordID)
        forceFlags.removeValue(forKey: recordID)
    }
}

struct ResearchIncrementalContext: Sendable {
    var priorReport: BurstResearch
    /// New leads only. An empty list is not scheduled; the launcher reuses a
    /// compatible report instead.
    var newMaterials: [ResearchMaterial]
    var signature: ResearchReuseSignature
}

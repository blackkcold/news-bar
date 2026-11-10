import Foundation

/// The page-overview evidence policy is deliberately pure: private reading and
/// the per-run toggle are product rules, and they must be testable without a
/// network, a keychain or an API key.
enum PageSummaryEvidencePolicy {
    static let externalTTL: TimeInterval = 24 * 60 * 60
    /// A failed external pass is cached briefly so the next open can retry
    /// instead of being stuck with a page-only overview for a week.
    static let failedExternalTTL: TimeInterval = 60 * 60

    static func shouldSearch(
        isPrivate: Bool,
        webSupplement: Bool,
        scope: PageSummaryScope
    ) -> Bool {
        !isPrivate && webSupplement && scope == .article
    }

    static func cacheTTL(
        webSupplement: Bool,
        adoptedExternalCount: Int
    ) -> TimeInterval {
        guard webSupplement else { return PageSummaryCacheStore.retention }
        return adoptedExternalCount > 0 ? externalTTL : failedExternalTTL
    }
}

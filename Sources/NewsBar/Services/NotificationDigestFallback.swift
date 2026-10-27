import Foundation

/// What a notification click shows when its payload has no usable digest:
/// the legacy `type: daily` template, a payload from a pre-digest build, or a
/// digest that failed to decode.
///
/// The fallback is deliberately conservative. A single item is opened directly
/// in the reader by `NotificationClickRouter`, so the digest sheet is only a
/// meaningful substitute when at least two items are available; otherwise the
/// click keeps its previous behaviour (dashboard only).
enum NotificationDigestFallback {
    static let minimumItemCount = 2

    /// Picks at most `limit` candidates, in their existing order, when there are
    /// enough of them to fill a digest sheet. Returns an empty array otherwise.
    static func items(from candidates: [NewsItem], limit: Int) -> [NewsItem] {
        let picked = Array(candidates.prefix(NotificationService.normalizedPushCount(limit)))
        return picked.count >= minimumItemCount ? picked : []
    }
}

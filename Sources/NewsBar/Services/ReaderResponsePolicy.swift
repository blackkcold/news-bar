import Foundation

enum ReaderResponsePolicy {
    /// HTTP 412 is what bilibili and some other edges return when their risk
    /// engine rejects a session. Rendering that error document would look like a
    /// successful load and count as an open, so the reader stops the navigation.
    static func isRiskControlRejection(status: Int?) -> Bool {
        status == 412
    }
}

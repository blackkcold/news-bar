import SwiftUI

/// One source of truth for how a research status reads and looks. The list,
/// the detail header and the dashboard all resolve through this type so a new
/// status cannot drift between surfaces.
enum ResearchStatusPresentation {
    static func label(_ status: ResearchStatus, language: AppLanguage) -> String {
        L10n.string("research.status.\(status.rawValue)", language: language)
    }

    static func tint(_ status: ResearchStatus) -> Color {
        switch status {
        case .queued, .running: return .accentColor
        case .ready: return .green
        case .partial: return .orange
        case .failed: return .red
        case .cancelled, .interrupted: return .secondary
        case .corrupt: return .purple
        }
    }

    /// Secondary dot used by the list when a row shows the report badge but the
    /// last run did not finish cleanly. Without it, a failed re-run of a record
    /// with an older report looks like a stale row.
    static func needsAttentionDot(_ status: ResearchStatus) -> Bool {
        switch status {
        case .partial, .failed, .cancelled, .interrupted: return true
        case .queued, .running, .ready, .corrupt: return false
        }
    }
}

import Foundation
import SwiftUI

/// One row in the subscription health center. Derived from the refresh cycle's
/// existing observable state; it is not a second source of truth.
struct RSSSourceHealth: Identifiable, Sendable {
    enum Status: String, Sendable {
        case loaded
        case idle
        case loading
        case failed

        var tint: Color {
            switch self {
            case .loaded: return .green
            case .idle: return .secondary
            case .loading: return .blue
            case .failed: return .orange
            }
        }

        var symbol: String {
            switch self {
            case .loaded: return "checkmark.circle.fill"
            case .idle: return "clock"
            case .loading: return "arrow.triangle.2.circlepath"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    let id: String
    let name: String
    let status: Status
    let detail: String?
    let lastAttempt: Date?
}

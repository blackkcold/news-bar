import AppKit
import Observation

struct NewsReaderRequest: Identifiable {
    let id = UUID()
    let url: String
    let title: String
    let item: NewsItem?
    let surface: String
    let contextID: String?
    let consentEpoch: UUID
    let privateSession: Bool
}

@MainActor
@Observable
final class NewsNavigationRouter {
    static let shared = NewsNavigationRouter()
    var selection: NewsReaderRequest?

    func open(_ item: NewsItem, surface: String, contextID: String? = nil) {
        open(url: item.url, title: item.displayTitle, item: item, surface: surface, contextID: contextID)
    }

    func open(url: String, title: String = "", item: NewsItem? = nil, surface: String, contextID: String? = nil) {
        let interest = InterestController.shared
        let request = NewsReaderRequest(url: url, title: title.isEmpty ? (URL(string: url)?.host ?? url) : title,
                                        item: item, surface: surface, contextID: contextID,
                                        consentEpoch: interest.state.consentEpoch, privateSession: interest.privateReading)
        selection = request
        if let item, !request.privateSession {
            interest.record(item, kind: .opened, epoch: request.consentEpoch, sessionID: request.id)
        }
        NotificationCenter.default.post(name: .newsReaderRequested, object: nil)
    }

    func close() { selection = nil }

    func external(_ request: NewsReaderRequest, currentURL: String) {
        guard let url = ReaderNavigationPolicy.allowedURL(currentURL) else { return }
        if let item = request.item, !request.privateSession {
            InterestController.shared.record(item, kind: .externalHandoff, epoch: request.consentEpoch, sessionID: request.id)
        }
        // Explicit user action only. Never invoked by a page or failure callback.
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    static let newsReaderRequested = Notification.Name("newsReaderRequested")
}

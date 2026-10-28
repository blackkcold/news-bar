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
    // Frozen ranking-batch provenance captured when the row was opened.
    var policyVersion: String? = nil
    var profileVersion: Int? = nil
    var position: Int? = nil
}

/// The payload a digest notification click presents in the dashboard sheet.
struct NewsDigestRequest: Identifiable, Equatable {
    /// `kind` used when the sheet is filled from live app data because the
    /// notification itself carried no usable digest.
    static let liveKind = "live"

    let id = UUID()
    let items: [NewsItem]
    let kind: String
    let generatedAt: Date

    init(digest: NotificationDigest) {
        self.init(items: digest.items, kind: digest.kind, generatedAt: digest.generatedAt)
    }

    init(items: [NewsItem], kind: String, generatedAt: Date = Date()) {
        self.items = items
        self.kind = kind
        self.generatedAt = generatedAt
    }
}

@MainActor
@Observable
final class NewsNavigationRouter {
    static let shared = NewsNavigationRouter()
    var selection: NewsReaderRequest?
    var digest: NewsDigestRequest?

    func open(
        _ item: NewsItem,
        surface: String,
        contextID: String? = nil,
        policyVersion: String? = nil,
        profileVersion: Int? = nil,
        position: Int? = nil
    ) {
        open(
            url: item.readerURL ?? item.url,
            title: item.displayTitle,
            item: item,
            surface: surface,
            contextID: contextID,
            policyVersion: policyVersion,
            profileVersion: profileVersion,
            position: position
        )
    }

    func open(
        url: String,
        title: String = "",
        item: NewsItem? = nil,
        surface: String,
        contextID: String? = nil,
        policyVersion: String? = nil,
        profileVersion: Int? = nil,
        position: Int? = nil
    ) {
        let interest = InterestController.shared
        let request = NewsReaderRequest(
            url: url,
            title: title.isEmpty ? (URL(string: url)?.host ?? url) : title,
            item: item,
            surface: surface,
            contextID: contextID,
            consentEpoch: interest.state.consentEpoch,
            privateSession: interest.privateReading,
            policyVersion: policyVersion,
            profileVersion: profileVersion,
            position: position
        )
        selection = request
        // Opening is only an attempt. The reader records `opened` after a
        // successfully loaded, attributed document; a failed open stays a
        // failed/zero-strength event and never becomes positive evidence.
        NotificationCenter.default.post(name: .newsReaderRequested, object: nil)
    }

    func presentDigest(_ request: NewsDigestRequest) { digest = request }
    func dismissDigest() { digest = nil }

    func close() { selection = nil }

    func external(_ request: NewsReaderRequest, currentURL: String) {
        guard let url = ReaderNavigationPolicy.allowedURL(currentURL) else { return }
        if let item = request.item, !request.privateSession {
            InterestController.shared.record(
                item,
                kind: .externalHandoff,
                epoch: request.consentEpoch,
                sessionID: request.id,
                surface: request.surface,
                contextID: request.contextID,
                position: request.position,
                readerSessionID: request.id,
                policyVersion: request.policyVersion,
                profileVersion: request.profileVersion
            )
        }
        // Explicit user action only. Never invoked by a page or failure callback.
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    static let newsReaderRequested = Notification.Name("newsReaderRequested")
}

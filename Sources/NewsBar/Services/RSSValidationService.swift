import Foundation

// MARK: - Validation Outcome

/// Structured outcome for a single RSS feed validation attempt.
/// Designed to be serial, cancellable, and UI-ready — no persistence, no caching.
enum RSSValidationOutcome: Equatable {
    /// URL was blocked by security policy before any network request.
    case blocked(reason: String)

    /// The URL string itself was malformed.
    case invalidURL

    /// Validation was cancelled before or between serial entries.
    case cancelled

    /// Network-level failure: non-2xx status, timeout, or connection error.
    case networkError(summary: String)

    /// Data was received but it does not look like RSS or Atom.
    case notRSSFeed

    /// Valid RSS/Atom feed detected with the given item count.
    case success(itemCount: Int)
}

// MARK: - Validation Summary

/// Aggregated results for a batch of feed validations.
struct RSSValidationSummary: Equatable {
    let outcomes: [Entry]

    struct Entry: Equatable {
        let feedName: String
        let url: String
        let outcome: RSSValidationOutcome
    }

    var successCount: Int {
        outcomes.filter { if case .success = $0.outcome { true } else { false } }.count
    }

    var failedCount: Int {
        outcomes.count - successCount
    }

    var wasCancelled: Bool {
        outcomes.contains { $0.outcome == .cancelled }
    }
}

// MARK: - Validation Service

/// Self-contained RSS recommendation validator.
///
/// Responsibilities:
/// 1. Validate URL safety via `SecurityPolicies.validateRSSURL` *before* any network access.
/// 2. Distinguish blocked / cancelled / network-error / non-feed / success outcomes.
/// 3. Support cooperative cancellation between serial entries.
///
/// Does NOT modify `RSSService`, `HTTPClient`, `SecurityPolicies`, or any existing fetch flow.
enum RSSValidationService {

    // MARK: - Pure (Deterministic) Functions

    /// Classify a URL string into an outcome using only local checks — no network call.
    /// Returns `.valid` if the URL passes all pre-flight checks and is ready for a network attempt.
    static func validateURLOnly(_ urlString: String) -> RSSValidationOutcome {
        switch SecurityPolicies.validateRSSURL(urlString) {
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .warning:
            break
        case .valid:
            break
        }

        guard URL(string: urlString) != nil else {
            return .invalidURL
        }

        return .success(itemCount: 0)
    }

    /// Classify a completed (or failed) fetch into a structured outcome.
    /// Pure function — no side effects.
    static func classifyFetchResult(urlString: String,
                                    data: Data?,
                                    error: Error?) -> RSSValidationOutcome {
        // 1. Pre-flight URL validation
        let preflight = validateURLOnly(urlString)
        guard preflight == .success(itemCount: 0) else {
            return preflight
        }

        // 2. Check for errors
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return .cancelled
            }
            return .networkError(summary: sanitizedNetworkMessage(for: error))
        }

        guard let data = data, !data.isEmpty else {
            return .networkError(summary: "Empty response")
        }

        if !isRSSOrAtom(data: data) {
            return .notRSSFeed
        }

        let itemCount = countRSSItems(data: data)
        return .success(itemCount: itemCount)
    }

    // MARK: - Serial Validator (for UI-driven testing)

    /// Validate a list of feed URLs serially, yielding outcomes one-by-one via callback.
    /// Cooperative cancellation: stops processing new entries when task is cancelled.
    static func validateFeedsSerially(
        _ feeds: [(name: String, url: String)],
        onOutcome: @Sendable @escaping (String, String, RSSValidationOutcome) -> Void
    ) async -> RSSValidationSummary {
        var results: [RSSValidationSummary.Entry] = []

        for feed in feeds {
            if Task.isCancelled {
                let cancelledOutcome = RSSValidationOutcome.cancelled
                results.append(.init(feedName: feed.name, url: feed.url, outcome: cancelledOutcome))
                onOutcome(feed.name, feed.url, cancelledOutcome)
                continue
            }

            let outcome = await validateSingleFeed(name: feed.name, url: feed.url)
            results.append(.init(feedName: feed.name, url: feed.url, outcome: outcome))
            onOutcome(feed.name, feed.url, outcome)
        }

        return RSSValidationSummary(outcomes: results)
    }

    /// Validate a list of RSSRecommendations serially.
    static func validateRecommendationsSerially(
        _ recommendations: [RSSRecommendation],
        onOutcome: @Sendable @escaping (String, String, RSSValidationOutcome) -> Void
    ) async -> RSSValidationSummary {
        let feeds = recommendations.map { (name: $0.name, url: $0.url) }
        return await validateFeedsSerially(feeds, onOutcome: onOutcome)
    }

    // MARK: - Private Helpers

    private static func validateSingleFeed(name: String, url urlString: String) async -> RSSValidationOutcome {
        switch SecurityPolicies.validateRSSURL(urlString) {
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .warning, .valid:
            break
        }

        guard let url = URL(string: urlString) else {
            return .invalidURL
        }

        do {
            let (data, _) = try await HTTPClient.data(for: url, config: .rss)

            if !isRSSOrAtom(data: data) {
                return .notRSSFeed
            }

            let itemCount = countRSSItems(data: data)
            return .success(itemCount: itemCount)
        } catch {
            return classifyNetworkError(error)
        }
    }

    private static func classifyNetworkError(_ error: Error) -> RSSValidationOutcome {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        return .networkError(summary: sanitizedNetworkMessage(for: error))
    }

    /// Produce a user-safe, non-sensitive error summary.
    private static func sanitizedNetworkMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "Request timed out"
            case NSURLErrorCannotConnectToHost:
                return "Cannot connect to server"
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection"
            case NSURLErrorCannotFindHost:
                return "Server not found"
            case NSURLErrorBadServerResponse:
                return "Invalid server response"
            default:
                return "Network error"
            }
        }
        if let newsBarError = error as? NewsBarError {
            switch newsBarError {
            case .requestFailed:
                return "Server returned an error"
            case .parseFailed, .parseFailedWithDetail:
                return "Feed parse failed"
            default:
                return "Unexpected error"
            }
        }
        return "Network error"
    }

    // MARK: - RSS Detection & Item Counting (reuses existing conventions)

    /// Lightweight check: does the data contain RSS or Atom root elements?
    private static func isRSSOrAtom(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        SecurityPolicies.configureXMLParser(parser)
        let delegate = RSSValidationRootDetector()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.isRSSOrAtom
    }

    /// Count RSS items without full parsing to avoid duplicate logic.
    private static func countRSSItems(data: Data) -> Int {
        let cleanData = SecurityPolicies.sanitizeXMLData(data)
        let parser = XMLParser(data: cleanData)
        SecurityPolicies.configureXMLParser(parser)
        let delegate = RSSItemCounterDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.itemCount
    }
}

// MARK: - Private XML Delegates (mirrors existing patterns)

private final class RSSValidationRootDetector: NSObject, XMLParserDelegate {
    var isRSSOrAtom = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "rss" || elementName == "feed" || elementName == "rdf:RDF" {
            isRSSOrAtom = true
        }
        parser.abortParsing()
    }
}

private final class RSSItemCounterDelegate: NSObject, XMLParserDelegate {
    var itemCount = 0
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "item" || elementName == "entry" {
            itemCount += 1
        }
    }
}

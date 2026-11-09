import Foundation
import Observation

enum ReaderAuxiliaryTab: Hashable {
    case search
    case overview
}

/// Identity of the page an overview belongs to. The URL is the primary key;
/// the title covers the rare reader-mode page that has no URL yet.
struct ReaderOverviewContext: Equatable {
    let title: String
    let url: String?
    let isPrivate: Bool
    let language: AppLanguage

    var pageKey: String {
        if let url, !url.isEmpty { return url }
        return "title:" + title
    }
}

/// One reader page's auxiliary rail: which tab is showing, the search surface,
/// and the overview lifecycle. The view reads this state; no request state is
/// scattered across `ReaderContentView`.
@MainActor
@Observable
final class ReaderAuxiliaryModel {
    private(set) var tab: ReaderAuxiliaryTab?
    var searchSurface: QuickSearchSurface = .ai
    var archiveReplay: AISearchArchiveEntry?
    private(set) var overviewContext: ReaderOverviewContext?
    private(set) var overviewInput: PageSummaryInput?
    private(set) var isPreparingOverview = false
    private(set) var preparationError: String?
    private(set) var acknowledgedURL: String?
    let summary = PageSummaryModel()

    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparationToken = 0
    @ObservationIgnored private var extract: (@MainActor () async -> String?)?

    init(initialTab: ReaderAuxiliaryTab? = nil) {
        self.tab = initialTab
    }

    var isOpen: Bool { tab != nil }

    var phase: PageSummaryPanelPhase {
        if isPreparingOverview { return .preparing }
        if let preparationError { return .unavailable(preparationError) }
        guard overviewInput != nil else { return .preparing }
        if summary.isBusy { return .generating }
        if let summaryMessage = failedMessage {
            return .failed(summaryMessage)
        }
        if summary.summary != nil { return .ready }
        if isAcknowledged { return .readyToGenerate }
        return .disclosure
    }

    private var failedMessage: String? {
        if case .failed(let message) = summary.state { return message }
        return nil
    }

    var isAcknowledged: Bool {
        guard let key = overviewContext?.pageKey else { return false }
        return acknowledgedURL == key
    }

    // MARK: - Navigation

    func open(_ next: ReaderAuxiliaryTab) {
        tab = next
        if next != .search {
            archiveReplay = nil
        }
    }

    func toggle(_ next: ReaderAuxiliaryTab) {
        if tab == next {
            close()
        } else {
            open(next)
        }
    }

    /// Closing keeps a finished overview (the same page can be reopened
    /// without a second request) but cancels an in-flight one.
    func close() {
        tab = nil
        archiveReplay = nil
        preparationTask?.cancel()
        preparationTask = nil
        isPreparingOverview = false
        summary.cancel()
    }

    /// The reader navigated to another page. Everything tied to the previous
    /// page is discarded, including the one-time disclosure acknowledgment.
    func resetForNavigation() {
        close()
        preparationToken += 1
        overviewContext = nil
        overviewInput = nil
        preparationError = nil
        acknowledgedURL = nil
        extract = nil
        summary.reset()
    }

    // MARK: - Overview

    /// Starts reading the page body as soon as the tab opens. Nothing is sent
    /// to a provider until `generate` is called.
    func prepareOverview(
        context: ReaderOverviewContext,
        extract: @escaping @MainActor () async -> String?
    ) {
        if let existing = overviewContext,
           existing.pageKey == context.pageKey,
           isPreparingOverview {
            overviewContext = context
            return
        }

        if let existing = overviewContext,
           existing.pageKey == context.pageKey,
           (overviewInput != nil || summary.summary != nil) {
            overviewContext = context
            return
        }

        preparationTask?.cancel()
        preparationToken += 1
        let token = preparationToken
        overviewContext = context
        self.extract = extract
        overviewInput = nil
        preparationError = nil
        isPreparingOverview = true

        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let text = await extract()
            guard !Task.isCancelled, self.preparationToken == token else { return }
            self.isPreparingOverview = false
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.preparationError = context.language == .en
                    ? "No readable page text"
                    : "没有可读页面正文"
                return
            }
            self.overviewInput = .article(
                title: context.title,
                url: context.url,
                text: text,
                language: context.language,
                isPrivate: context.isPrivate
            )
        }
    }

    func retryPreparation() {
        guard let context = overviewContext, let extract else { return }
        prepareOverview(context: context, extract: extract)
    }

    func generate(settings: AppSettings) {
        guard let input = overviewInput, !summary.isBusy else { return }
        acknowledgeOverview()
        summary.summarize(input: input, settings: settings)
    }

    /// Records the one-time disclosure acknowledgment for this page. Separate
    /// from `generate` so a page can be acknowledged without a request.
    func acknowledgeOverview() {
        guard let key = overviewContext?.pageKey else { return }
        acknowledgedURL = key
    }
}

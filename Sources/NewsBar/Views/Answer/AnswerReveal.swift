import Foundation
import Observation

/// Reveals a streaming answer at reading speed instead of letting each network
/// burst repaint the whole card.
///
/// The rule is catch-up, not a fixed rate: the visible text may trail the
/// received text by at most a few hundred characters, so a fast model is never
/// throttled to a crawl and a slow one never looks frozen. Pure document
/// truncation lives in `AnswerDocument.revealed(upTo:)`; this type only owns
/// the clock.
@MainActor
@Observable
final class AnswerReveal {
    private(set) var document: AnswerDocument?
    private(set) var isStreaming = false
    /// False when Reduce Motion is on: text appears as it arrives.
    var isEnabled = true {
        didSet { if !isEnabled { jumpToTarget() } }
    }

    @ObservationIgnored private var target: AnswerDocument?
    @ObservationIgnored private var shown = 0
    @ObservationIgnored private var total = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func begin() {
        isStreaming = true
    }

    func receive(_ document: AnswerDocument) {
        target = document
        total = Self.bodyCount(document)
        if !isEnabled { jumpToTarget() }
        startTickerIfNeeded()
    }

    func finish(with document: AnswerDocument) {
        target = document
        total = Self.bodyCount(document)
        isStreaming = false
        // Nothing was ever revealed (single-shot provider, test double, or a
        // cancelled typewriter): show the answer immediately.
        if !isEnabled || shown == 0 { jumpToTarget() }
        startTickerIfNeeded()
    }

    func reset() {
        ticker?.cancel()
        ticker = nil
        document = nil
        target = nil
        shown = 0
        total = 0
        isStreaming = false
    }

    private func jumpToTarget() {
        shown = total
        document = target
    }

    private func startTickerIfNeeded() {
        guard isEnabled else { return }
        if shown >= total, !isStreaming {
            document = target
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.advance() { break }
                try? await Task.sleep(for: .milliseconds(33))
            }
            self?.ticker = nil
        }
    }

    /// Returns true when there is nothing left to reveal.
    private func advance() -> Bool {
        guard let target else { return true }
        if shown >= total {
            document = target
            return !isStreaming
        }
        shown = min(total, shown + max(1, (total - shown) / 6))
        document = target.revealed(upTo: shown)
        return false
    }

    private static func bodyCount(_ document: AnswerDocument) -> Int {
        document.blocks.reduce(0) { $0 + $1.body.count }
    }
}

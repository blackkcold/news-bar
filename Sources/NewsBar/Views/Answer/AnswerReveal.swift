import Foundation
import Observation

/// Reveals a streaming answer at reading speed instead of letting each network
/// burst repaint the whole card.
///
/// The rule is catch-up, not a fixed rate: the visible text may trail the
/// received text by at most a few frames, so a fast model is never throttled to
/// a crawl and a slow one never looks frozen. Pure document truncation lives in
/// `AnswerDocument.revealed(upTo:)`; this type only owns the clock.
///
/// One frame replaces the whole document, and every replacement rebuilds every
/// paragraph. Thirty of those a second was enough for the canvas to keep
/// painting the previous frame's text under the new one — two layers of the
/// same paragraph, offset by the line that had just been added. The rate is
/// therefore a reading rate, and a burst is caught up in `catchUpFrames`
/// frames rather than spread over a dozen.
@MainActor
@Observable
final class AnswerReveal {
    /// 66 ms is ~15 fps: still typing, not a repaint storm.
    private static let frameInterval = Duration.milliseconds(66)
    /// A burst is on screen in about this many frames: each frame halves the
    /// backlog, so a long answer catches up in well under a second.
    private static let catchUpFrames = 2
    /// Below this backlog the frame is finished rather than dribbled out a
    /// character at a time: a geometric rule alone spends a dozen frames on the
    /// last few characters.
    private static let minimumStep = 24

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
        // A `## heading` closes the section it was typed into, so the body that
        // is already revealed can be longer than the new one. Clamp instead of
        // letting the counter run past the text.
        shown = min(shown, total)
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
                try? await Task.sleep(for: Self.frameInterval)
            }
            self?.ticker = nil
        }
    }

    /// Returns true when there is nothing left to reveal.
    private func advance() -> Bool {
        guard let target else { return true }
        guard shown < total else {
            document = target
            // Caught up mid-stream: stop the clock instead of spinning at 15 fps
            // until the next burst. `receive(_:)` restarts it.
            return true
        }
        shown = min(total, shown + Self.step(remaining: total - shown))
        document = target.revealed(upTo: shown)
        return false
    }

    /// Characters revealed per frame. Pure so the catch-up rule is tested
    /// without a clock: a burst of `remaining` characters lands in under a
    /// second, and the tail is never stranded one character per frame.
    static func step(remaining: Int) -> Int {
        max(minimumStep, remaining / catchUpFrames)
    }

    private static func bodyCount(_ document: AnswerDocument) -> Int {
        document.blocks.reduce(0) { $0 + $1.body.count }
    }
}

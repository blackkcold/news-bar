import Foundation

struct ReaderEvidence {
    private(set) var activeSeconds: TimeInterval = 0
    private(set) var scrollCoverage: Double = 0
    var estimatedReadingSeconds: TimeInterval?
    private var lastEmission: TimeInterval = 0

    mutating func shouldEmit(final: Bool) -> Bool {
        guard activeSeconds >= 15, final || activeSeconds - lastEmission >= 15 else { return false }
        lastEmission = activeSeconds
        return true
    }

    mutating func tick(elapsed: TimeInterval, loaded: Bool, active: Bool, visible: Bool, unlocked: Bool, idle: TimeInterval) {
        guard loaded, active, visible, unlocked, idle < 60, elapsed.isFinite, elapsed > 0, elapsed <= 30 else { return }
        activeSeconds += elapsed
    }

    mutating func setScroll(_ fraction: Double) {
        guard fraction.isFinite, (0...1).contains(fraction) else { return }
        scrollCoverage = max(scrollCoverage, fraction)
    }

    func signal(articleAdapted: Bool) -> InterestEventKind? {
        guard activeSeconds >= 15 else { return nil }
        guard articleAdapted else { return .browsed }
        let target = max(30, min(1200, estimatedReadingSeconds ?? 240))
        guard scrollCoverage >= 0.25 || activeSeconds >= target * 0.5 else { return nil }
        return activeSeconds >= 60 && (scrollCoverage >= 0.75 || activeSeconds >= target) ? .deepRead : .qualifiedRead
    }
}

struct QualifiedExposure {
    private var startedAt: TimeInterval?
    private var recorded = false
    mutating func update(visibleFraction: Double, active: Bool, now: TimeInterval) -> Bool {
        guard !recorded else { return false }
        guard active, visibleFraction >= 0.5 else { startedAt = nil; return false }
        guard let startedAt else { self.startedAt = now; return false }
        guard now - startedAt >= 1 else { return false }
        recorded = true
        return true
    }
}

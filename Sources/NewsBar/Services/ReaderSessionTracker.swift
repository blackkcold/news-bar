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

/// Opening is an attempt; only a successfully loaded, attributed document may
/// contribute positive "opened" evidence. Keeping this gate in one value type
/// makes the distinction testable without a network or a real WebKit session.
struct OpenAttribution {
    private var recorded = false

    mutating func beginNavigation() {
        recorded = false
    }

    mutating func shouldRecordLoaded(attributed: Bool, privateSession: Bool) -> Bool {
        guard attributed, !privateSession, !recorded else { return false }
        recorded = true
        return true
    }
}

/// Decides whether the document on screen is still the item the reader opened.
///
/// A short link (`b23.tv/BV1xx`) only becomes its sign-in host
/// (`www.bilibili.com/video/BV1xx`) after a server redirect, so comparing
/// canonical URLs alone drops every read of those items. The relaxed comparison
/// applies to the initial document only and never across sites, so following a
/// link on the same page still ends attribution.
struct DocumentAttribution {
    private var awaitingInitialDocument = true
    private var sawServerRedirect = false

    mutating func noteServerRedirect() {
        guard awaitingInitialDocument else { return }
        sawServerRedirect = true
    }

    /// A user-initiated navigation means the reader left the opened item.
    mutating func noteUserNavigation() {
        awaitingInitialDocument = false
    }

    mutating func evaluate(finalURL: String, itemURL: String) -> Bool {
        let exact = ContentIdentity.canonicalURL(finalURL) == ContentIdentity.canonicalURL(itemURL)
        let sameSiteRedirect = awaitingInitialDocument
            && sawServerRedirect
            && ReaderCookieSiteScope.sameSite(finalURL, itemURL)
        awaitingInitialDocument = false
        return exact || sameSiteRedirect
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

/// The readers currently alive, so the app can flush every tab's cookies
/// before the process exits. Weak: a closed tab disappears on its own.
@MainActor
enum ReaderSessionRegistry {
    private final class WeakBox {
        weak var value: NewsReaderModel?
        init(_ value: NewsReaderModel) { self.value = value }
    }

    private static var readers: [WeakBox] = []

    static func register(_ reader: NewsReaderModel) {
        readers.removeAll { $0.value == nil || $0.value === reader }
        readers.append(WeakBox(reader))
    }

    static func unregister(_ reader: NewsReaderModel) {
        readers.removeAll { $0.value == nil || $0.value === reader }
    }

    static var all: [NewsReaderModel] {
        readers.compactMap(\.value)
    }

    /// Compatibility for callers that only need one representative reader.
    static var active: NewsReaderModel? { all.last }
}

enum ReaderTerminationPolicy {
    /// Only an open reader with cookie memory on has anything left to flush.
    /// Everything else keeps the normal, immediate quit.
    static func needsCookieFlush(cookieMemoryEnabled: Bool, hasActiveReader: Bool) -> Bool {
        cookieMemoryEnabled && hasActiveReader
    }
}

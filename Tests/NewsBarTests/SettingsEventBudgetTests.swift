import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import NewsBar

@MainActor
final class SettingsEventBudgetTests: XCTestCase {
    func testEnteringEventNotificationSettingsReadsBudgetWithoutLoadingOrWritingEvents() async throws {
        let now = Date()
        let largeHistory = (0..<NewsEventStore.maximumEvents).map { index in
            NewsEvent(
                id: "settings-budget-event-\(index)",
                title: "Fixture event \(index)",
                eventDescription: "Isolated fixture history item.",
                subjectAliases: [],
                firstSeenAt: now,
                lastEvidenceAt: now
            )
        }
        let store = CountingNewsEventSettingsStore(events: largeHistory)
        let settings = AppSettings()
        let controller = NewsEventController(settings: settings, store: store)
        let root = Form {
            EventMonitorNotificationSettingsSection(authorizationGranted: true, controller: controller)
        }
        .environment(settings)
        .defaultAppStorage(TestIsolation.defaults)

        let size = NSSize(width: 720, height: 580)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        var counts = await store.callCounts()
        while counts.trackingAttemptReads == 0, ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
            counts = await store.callCounts()
        }

        XCTAssertEqual(counts.fixtureEventCount, NewsEventStore.maximumEvents)
        XCTAssertEqual(counts.trackingAttemptReads, 1, "settings should query only the shared tracking budget")
        XCTAssertEqual(counts.eventReads, 0, "opening the settings pane must not load the event history")
        XCTAssertEqual(counts.persistedBudgetReads, 0, "settings should use the tracker budget API")
        XCTAssertEqual(counts.trackingStateReads, 0)
        XCTAssertEqual(counts.persistenceWrites, 0, "opening settings must not rewrite or normalize event records")
        XCTAssertTrue(controller.events.isEmpty, "settings should not populate or recompute the controller event list")
    }

    func testReminderTabSharesOneAuthorizationReadAndRefreshesOnActivation() async throws {
        let store = CountingNewsEventSettingsStore(events: [])
        let settings = AppSettings()
        let controller = NewsEventController(settings: settings, store: store)
        let activationNotificationCenter = NotificationCenter()
        let authorization = CountingSettingsNotificationAuthorizationAction(
            statuses: [.authorized, .denied]
        )
        let root = ReminderTab(
            eventController: controller,
            activationNotificationCenter: activationNotificationCenter
        )
            .environment(settings)
            .environment(\.settingsNotificationAuthorizationStatusAction) {
                await authorization.query()
            }
            .defaultAppStorage(TestIsolation.defaults)

        let size = NSSize(width: 720, height: 580)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        let initialDeadline = ProcessInfo.processInfo.systemUptime + 2.0
        var counts = await store.callCounts()
        while (authorization.queryCount == 0 || counts.trackingAttemptReads == 0),
              ProcessInfo.processInfo.systemUptime < initialDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
            counts = await store.callCounts()
        }

        XCTAssertEqual(authorization.queryCount, 1, "the parent tab should perform the only initial authorization query")
        XCTAssertEqual(counts.trackingAttemptReads, 1, "the child section should retain its single shared budget read")
        XCTAssertEqual(counts.eventReads, 0, "mounting the notification tab must not load event history")
        XCTAssertEqual(counts.persistenceWrites, 0, "mounting the notification tab must not persist event changes")

        activationNotificationCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        activationNotificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        let refreshDeadline = ProcessInfo.processInfo.systemUptime + 2.0
        while authorization.queryCount < 2, ProcessInfo.processInfo.systemUptime < refreshDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(authorization.queryCount, 2, "returning from system settings should refresh authorization once")
    }
}

@MainActor
private final class CountingSettingsNotificationAuthorizationAction {
    private let statuses: [UNAuthorizationStatus]
    private(set) var queryCount = 0

    init(statuses: [UNAuthorizationStatus]) {
        self.statuses = statuses
    }

    func query() async -> UNAuthorizationStatus {
        queryCount += 1
        return statuses[min(queryCount - 1, statuses.count - 1)]
    }
}

private struct EventStoreCallCounts {
    let fixtureEventCount: Int
    let trackingAttemptReads: Int
    let eventReads: Int
    let persistedBudgetReads: Int
    let trackingStateReads: Int
    let persistenceWrites: Int
}

private actor CountingNewsEventSettingsStore: NewsEventPersisting {
    private var storedEvents: [String: NewsEvent]
    private var trackingAttemptReads = 0
    private var eventReads = 0
    private var persistedBudgetReads = 0
    private var trackingStateReads = 0
    private var persistenceWrites = 0

    init(events: [NewsEvent]) {
        storedEvents = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    }

    func events() async throws -> [NewsEvent] {
        eventReads += 1
        return Array(storedEvents.values)
    }

    func event(id: String) async throws -> NewsEvent? {
        eventReads += 1
        return storedEvents[id]
    }

    func upsert(_ event: NewsEvent) async throws {
        persistenceWrites += 1
        storedEvents[event.id] = event
    }

    func claimNotification(eventID: String, key: String, at: Date) async throws -> Bool {
        persistenceWrites += 1
        return false
    }

    func feedCursor(for sourceID: String) async throws -> NewsEventFeedCursor? { nil }

    func saveFeedCursor(_ cursor: NewsEventFeedCursor) async throws {
        persistenceWrites += 1
    }

    func trackingAttempts(since start: Date) async throws -> [Date] {
        trackingAttemptReads += 1
        return []
    }

    func recordTrackingAttempt(at date: Date) async throws {
        persistenceWrites += 1
    }

    func trackingState() async throws -> NewsEventTrackingState {
        trackingStateReads += 1
        return .idle
    }

    func saveTrackingState(_ state: NewsEventTrackingState) async throws {
        persistenceWrites += 1
    }

    func budgetSnapshot() async throws -> NewsEventBudgetSnapshot {
        persistedBudgetReads += 1
        return NewsEventBudgetSnapshot()
    }

    func saveBudgetSnapshot(_ snapshot: NewsEventBudgetSnapshot) async throws {
        persistenceWrites += 1
    }

    func prune(
        now: Date,
        maximumEvents: Int,
        terminalRetention: TimeInterval
    ) async throws -> NewsEventPruneResult {
        persistenceWrites += 1
        return NewsEventPruneResult(deletedEventIDs: [], capacityLimited: false)
    }

    func callCounts() -> EventStoreCallCounts {
        EventStoreCallCounts(
            fixtureEventCount: storedEvents.count,
            trackingAttemptReads: trackingAttemptReads,
            eventReads: eventReads,
            persistedBudgetReads: persistedBudgetReads,
            trackingStateReads: trackingStateReads,
            persistenceWrites: persistenceWrites
        )
    }
}

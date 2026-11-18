import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class SettingsWindowInteractionTests: XCTestCase {
    func testAppKitListSelectionUpdatesSelectionAndRealPaneAcrossThemes() async throws {
        for theme in [AppTheme.modern, .retroEditorial] {
            let settings = makeSettings(theme: theme)
            var selectionDelays: [TimeInterval] = []
            var detailDelays: [TimeInterval] = []
            let selection = SettingsPaneSelection(initialPane: .about)
            let renderSnapshot = SettingsPaneRenderSnapshot()
            let (window, host) = makeHost(settings: settings, selection: selection, renderSnapshot: renderSnapshot)
            defer { window.contentView = nil }

            _ = try await waitForRender(.about, selection: selection, snapshot: renderSnapshot, host: host)
            for pane in SettingsPane.allCases {
                let selectionStartedAt = try selectSidebarRow(pane, in: host)
                let selectionElapsed = try await waitForSelection(
                    pane,
                    selection: selection,
                    host: host,
                    startedAt: selectionStartedAt
                )
                let renderTiming = try await waitForRender(
                    pane,
                    selection: selection,
                    snapshot: renderSnapshot,
                    host: host,
                    startedAt: selectionStartedAt
                )
                selectionDelays.append(selectionElapsed)
                detailDelays.append(renderTiming.endToEnd)
                let selectedTable = try XCTUnwrap(sidebarTable(in: host))
                let selectedRow = try XCTUnwrap(selectedTable.selectedRowIndexes.first)
                let expectedRow = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: pane))

                XCTAssertEqual(selection.selectedPane, pane, "selection model did not track the AppKit List selection")
                XCTAssertEqual(selectedRow, expectedRow, "sidebar List did not select \(pane.rawValue)")
                assertRenderedDetail(pane, snapshot: renderSnapshot, language: .en)
                XCTAssertLessThanOrEqual(
                    renderTiming.waitDuration,
                    1.0,
                    "\(theme.rawValue) pane \(pane.rawValue) exceeded the independent right-pane one-second hang guard"
                )
                print(
                    String(
                        format: "[SettingsPaneTiming] theme=%@ pane=%@ select-to-highlight=%.1fms select-to-header+detail=%.1fms right-wait-guard=%.1fms",
                        theme.rawValue,
                        pane.rawValue,
                        selectionElapsed * 1_000,
                        renderTiming.endToEnd * 1_000,
                        renderTiming.waitDuration * 1_000
                    )
                )
            }
            XCTAssertEqual(SettingsPane.allCases.count, 8)
            let selectionP95 = percentile95(selectionDelays)
            let detailP95 = percentile95(detailDelays)
            XCTAssertLessThanOrEqual(
                selectionP95,
                0.2,
                "\(theme.rawValue) test-host selection/highlight p95 must meet the 200 ms target; right-pane rendering has a separate metric"
            )
            let summary = String(
                format: "test-host=unshown NSHostingView; theme=%@; n=%d; select-to-highlight[min=%.1fms p95=%.1fms max=%.1fms target-p95=200ms]; select-to-header+detail[min=%.1fms p95=%.1fms max=%.1fms]; right-wait-guard=1000ms",
                theme.rawValue,
                selectionDelays.count,
                (selectionDelays.min() ?? 0) * 1_000,
                selectionP95 * 1_000,
                (selectionDelays.max() ?? 0) * 1_000,
                (detailDelays.min() ?? 0) * 1_000,
                detailP95 * 1_000,
                (detailDelays.max() ?? 0) * 1_000
            )
            XCTContext.runActivity(named: "Settings pane transition timing (test host only)") { activity in
                activity.add(XCTAttachment(string: summary))
            }
            print("[SettingsPaneTiming] \(summary)")
        }
    }

    func testAlreadyOpenSettingsWindowRoutesAITabNotificationToLeftAndRight() async throws {
        let settings = makeSettings(theme: .modern)
        let selection = SettingsPaneSelection(initialPane: .about)
        let renderSnapshot = SettingsPaneRenderSnapshot()
        let (window, host) = makeHost(settings: settings, selection: selection, renderSnapshot: renderSnapshot)
        defer { window.contentView = nil }

        _ = try await waitForRender(.about, selection: selection, snapshot: renderSnapshot, host: host)
        // This is the notification AppDelegate.openSettings(toAITab: true) posts
        // when its Settings window already exists.
        NotificationCenter.default.post(name: .switchToAITab, object: nil)

        _ = try await waitForRender(.ai, selection: selection, snapshot: renderSnapshot, host: host)
        XCTAssertEqual(selection.selectedPane, .ai)
        let selectedTable = try XCTUnwrap(sidebarTable(in: host))
        let selectedRows = try XCTUnwrap(selectedTable.selectedRowIndexes.first)
        XCTAssertEqual(selectedRows, try XCTUnwrap(SettingsPane.allCases.firstIndex(of: .ai)))
        assertRenderedDetail(.ai, snapshot: renderSnapshot, language: .en)
    }

    func testPaneSwitchCompletesWhileResearchReadIsSuspendedAndUpdatesArrive() async throws {
        let settings = makeSettings(theme: .modern)
        let selection = SettingsPaneSelection(initialPane: .general)
        let renderSnapshot = SettingsPaneRenderSnapshot()
        let (window, host) = makeHost(settings: settings, selection: selection, renderSnapshot: renderSnapshot)
        defer { window.contentView = nil }

        let store = SuspendedResearchStore()
        let readTask = Task.detached { await store.index() }
        defer { Task.detached { await store.releaseIndexRead() } }

        let readDeadline = ProcessInfo.processInfo.systemUptime + 1.0
        while !(await store.isIndexReadSuspended()), ProcessInfo.processInfo.systemUptime < readDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let suspended = await store.isIndexReadSuspended()
        XCTAssertTrue(suspended, "the in-memory research read did not reach its suspended gate")

        // The AI pane subscribes to research updates. Flood its local observer
        // while the store actor remains suspended, then switch panes before release.
        let aiSelectionStartedAt = try selectSidebarRow(.ai, in: host)
        _ = try await waitForSelection(.ai, selection: selection, host: host, startedAt: aiSelectionStartedAt)
        _ = try await waitForRender(
            .ai,
            selection: selection,
            snapshot: renderSnapshot,
            host: host,
            startedAt: aiSelectionStartedAt
        )
        for _ in 0..<24 {
            await store.noteLocalUpdate()
            NotificationCenter.default.post(name: .researchRecordsChanged, object: nil)
        }
        let selectionStartedAt = try selectSidebarRow(.notifications, in: host)
        _ = try await waitForSelection(
            .notifications,
            selection: selection,
            host: host,
            startedAt: selectionStartedAt
        )
        let renderTiming = try await waitForRender(
            .notifications,
            selection: selection,
            snapshot: renderSnapshot,
            host: host,
            startedAt: selectionStartedAt
        )

        let updateCount = await store.localUpdateCount
        let stillSuspended = await store.isIndexReadSuspended()
        XCTAssertEqual(updateCount, 24)
        XCTAssertTrue(stillSuspended, "research read completed before the explicit release")
        assertRenderedDetail(.notifications, snapshot: renderSnapshot, language: .en)
        XCTAssertLessThanOrEqual(
            renderTiming.waitDuration,
            1.0,
            "notification pane did not update while research work was suspended"
        )

        await store.releaseIndexRead()
        _ = await readTask.value
    }

    private func makeSettings(theme: AppTheme) -> AppSettings {
        let settings = AppSettings(modelService: makeModelService())
        settings.appTheme = theme
        settings.appLanguage = .en
        settings.colorScheme = "light"
        return settings
    }

    private func makeHost(
        settings: AppSettings,
        selection: SettingsPaneSelection,
        renderSnapshot: SettingsPaneRenderSnapshot? = nil
    ) -> (NSWindow, NSHostingView<AnyView>) {
        let view = AnyView(
            SettingsWindow(
                initialPane: selection.selectedPane,
                paneSelection: selection,
                renderSnapshot: renderSnapshot
            )
                .environment(settings)
                .environment(\.settingsNotificationAuthorizationStatusAction) { .authorized }
                .defaultAppStorage(TestIsolation.defaults)
        )
        let size = NSSize(width: 860, height: 620)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Isolated Settings Test Host"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func selectSidebarRow(
        _ pane: SettingsPane,
        in host: NSHostingView<AnyView>
    ) throws -> TimeInterval {
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(sidebarTable(in: host), "Settings sidebar table was not hosted")
        let rowIndex = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: pane))
        let row = try XCTUnwrap(table.rowView(atRow: rowIndex, makeIfNecessary: true))
        let pointInHost = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: host)
        let hit = try XCTUnwrap(host.hitTest(pointInHost), "sidebar row hit-test returned no view")
        let pointInTable = table.convert(pointInHost, from: host)
        XCTAssertTrue(
            hasAncestor(hit, matching: table),
            "sidebar row center hit a view outside the settings List"
        )
        XCTAssertEqual(table.row(at: pointInTable), rowIndex, "sidebar hit test resolved a different row")

        // Select in the test-owned AppKit table and deliver its delegate callback.
        // This exercises the SwiftUI List binding without posting system input.
        let selectionStartedAt = ProcessInfo.processInfo.systemUptime
        table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        table.delegate?.tableViewSelectionDidChange?(Notification(
            name: Notification.Name("NSTableViewSelectionDidChangeNotification"),
            object: table
        ))
        return selectionStartedAt
    }

    private func sidebarTable(in host: NSHostingView<AnyView>) -> NSTableView? {
        allViews(in: host).compactMap { $0 as? NSTableView }
            .first { $0.numberOfRows == SettingsPane.allCases.count }
    }

    private func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }

    private func hasAncestor(_ view: NSView, matching expected: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node === expected { return true }
            current = node.superview
        }
        return false
    }

    private func waitForSelection(
        _ pane: SettingsPane,
        selection: SettingsPaneSelection,
        host: NSHostingView<AnyView>,
        startedAt: TimeInterval
    ) async throws -> TimeInterval {
        let deadline = startedAt + 1.0
        let rowIndex = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: pane))
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(sidebarTable(in: host))
            if selection.selectedPane == pane, table.selectedRowIndexes.contains(rowIndex) {
                return ProcessInfo.processInfo.systemUptime - startedAt
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Sidebar selection and highlight for \(pane.rawValue) did not update within one second")
        return ProcessInfo.processInfo.systemUptime - startedAt
    }

    private func waitForRender(
        _ pane: SettingsPane,
        selection: SettingsPaneSelection,
        snapshot: SettingsPaneRenderSnapshot,
        host: NSHostingView<AnyView>,
        startedAt: TimeInterval? = nil
    ) async throws -> PaneRenderTiming {
        let startedAt = startedAt ?? ProcessInfo.processInfo.systemUptime
        let renderWaitStartedAt = ProcessInfo.processInfo.systemUptime
        let deadline = renderWaitStartedAt + 1.0
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            if selection.selectedPane == pane,
               snapshot.renderedContentPane == pane,
               snapshot.renderedHeaderTitle == L10n.string(pane.headingKey, language: .en) {
                let now = ProcessInfo.processInfo.systemUptime
                return PaneRenderTiming(
                    endToEnd: now - startedAt,
                    waitDuration: now - renderWaitStartedAt
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Settings pane \(pane.rawValue) did not update selection, heading, and content within one second")
        let now = ProcessInfo.processInfo.systemUptime
        return PaneRenderTiming(endToEnd: now - startedAt, waitDuration: now - renderWaitStartedAt)
    }

    private func percentile95(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted.isEmpty ? 0 : sorted[index]
    }

    private func assertRenderedDetail(
        _ pane: SettingsPane,
        snapshot: SettingsPaneRenderSnapshot,
        language: AppLanguage
    ) {
        XCTAssertEqual(snapshot.renderedHeaderTitle, L10n.string(pane.headingKey, language: language))
        XCTAssertEqual(snapshot.renderedContentPane, pane, "right pane view for \(pane.rawValue) did not appear")
    }

    private func makeModelService() -> ProviderModelService {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("models.json")
        return ProviderModelService(fileURL: cache, transport: { request in
            let body = #"{"models":[{"name":"test-model","capabilities":["completion"]}]}"#
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (Data(body.utf8), response)
        })
    }
}

private struct PaneRenderTiming {
    let endToEnd: TimeInterval
    let waitDuration: TimeInterval
}

private actor SuspendedResearchStore: ResearchPersisting {
    private var indexReadStarted = false
    private var indexReadContinuation: CheckedContinuation<Void, Never>?
    private(set) var localUpdateCount = 0

    func bootstrap() async -> ResearchStoreBootstrap { ResearchStoreBootstrap() }

    func index() async -> [ResearchIndexEntry] {
        await withCheckedContinuation { continuation in
            indexReadStarted = true
            indexReadContinuation = continuation
        }
        return []
    }

    func records() async -> [ResearchRecord] { [] }
    func record(id: String) async -> ResearchRecord? { nil }
    func save(_ record: ResearchRecord) async throws {}
    func saveProgress(_ record: ResearchRecord) async {}
    func flushPendingWrites() async {}
    func delete(id: String) async throws {}

    func isIndexReadSuspended() -> Bool {
        indexReadStarted && indexReadContinuation != nil
    }

    func releaseIndexRead() {
        indexReadContinuation?.resume()
        indexReadContinuation = nil
    }

    func noteLocalUpdate() {
        localUpdateCount += 1
    }
}

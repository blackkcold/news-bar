import XCTest
@testable import NewsBar

@MainActor
final class WorkspaceTabStoreTests: XCTestCase {
    func testOpeningTwoRequestsCreatesTwoTabsAndActivatesTheNewest() {
        let store = WorkspaceTabStore()
        let first = makeRequest("https://example.com/a")
        let second = makeRequest("https://example.com/b")

        store.openOrActivate(first)
        store.openOrActivate(second)

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeRequest?.id, second.id)
        XCTAssertTrue(store.model(for: store.tabs[0]).isTabActive == false)
        XCTAssertTrue(store.model(for: store.tabs[1]).isTabActive == true)
    }

    func testReopeningSameRequestActivatesInsteadOfDuplicating() {
        let store = WorkspaceTabStore()
        let first = makeRequest("https://example.com/a")
        let second = makeRequest("https://example.com/b")

        store.openOrActivate(first)
        store.openOrActivate(second)
        store.openOrActivate(first)

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeRequest?.id, first.id)
        XCTAssertTrue(store.model(for: store.tabs[0]).isTabActive == true)
        XCTAssertTrue(store.model(for: store.tabs[1]).isTabActive == false)
    }

    func testClosingActiveTabSelectsItsNeighbour() {
        let store = WorkspaceTabStore()
        let first = makeRequest("https://example.com/a")
        let second = makeRequest("https://example.com/b")
        store.openOrActivate(first)
        store.openOrActivate(second)

        let next = store.close(store.tabs[1].id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(next?.request.id, first.id)
        XCTAssertEqual(store.activeRequest?.id, first.id)
        XCTAssertTrue(store.model(for: store.tabs[0]).isTabActive == true)
    }

    func testClosingInactiveTabKeepsCurrentSelection() {
        let store = WorkspaceTabStore()
        let first = makeRequest("https://example.com/a")
        let second = makeRequest("https://example.com/b")
        store.openOrActivate(first)
        store.openOrActivate(second)

        let activeBefore = store.activeID
        _ = store.close(store.tabs[0].id)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeID, activeBefore)
        XCTAssertEqual(store.activeRequest?.id, second.id)
    }

    func testClosingLastTabReturnsToBrowse() {
        let store = WorkspaceTabStore()
        let request = makeRequest("https://example.com/a")
        store.openOrActivate(request)

        let next = store.close(store.tabs[0].id)

        XCTAssertNil(next)
        XCTAssertNil(store.activeID)
        XCTAssertTrue(store.tabs.isEmpty)
    }

    func testDeactivateKeepsTabsButStopsTheReadingClock() {
        let store = WorkspaceTabStore()
        let request = makeRequest("https://example.com/a")
        store.openOrActivate(request)
        let model = store.model(for: store.tabs[0])

        store.deactivate()

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNil(store.activeID)
        XCTAssertFalse(model.isTabActive)
    }

    func testTerminateAllClearsTabsAndModels() {
        let store = WorkspaceTabStore()
        store.openOrActivate(makeRequest("https://example.com/a"))
        store.openOrActivate(makeRequest("https://example.com/b"))

        store.terminateAll()

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeID)
        XCTAssertNil(store.activeRequest)
    }

    private func makeRequest(_ url: String) -> NewsReaderRequest {
        NewsReaderRequest(
            url: url,
            title: url,
            item: nil,
            surface: "test",
            contextID: nil,
            consentEpoch: UUID(),
            privateSession: false
        )
    }
}

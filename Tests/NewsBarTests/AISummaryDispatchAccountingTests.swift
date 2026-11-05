import XCTest
@testable import NewsBar

final class AISummaryDispatchAccountingTests: XCTestCase {
    private actor DispatchCounter {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func pricedConnection(baseURL: String) -> ResolvedAIConnection {
        var connection = AIProvider.deepseek.resolvedConnection()
        connection.baseURL = baseURL
        connection.customPrice = ModelPrice(
            provider: "fictional", modelPrefix: "fixture", inputPerMTok: 1, outputPerMTok: 2,
            cacheReadPerMTok: nil, cacheWritePerMTok: nil, currency: "CNY", updatedAt: "fixture"
        )
        return connection
    }

    func testInvalidRequestDoesNotReserveOrDispatch() async throws {
        let directory = try researchTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        let dispatches = DispatchCounter()
        AISummaryService.initBudget(target: .popup, mode: .independent, policy: .unlimited, forceReset: true)
        do {
            _ = try await AISummaryService.makeRequest(
                connection: pricedConnection(baseURL: "https://["), apiKey: "fictional-key", model: "fixture",
                systemPrompt: "system", userPrompt: "user", maxTokens: 100,
                disableDeepSeekThinking: false, target: .popup, budgetMode: .independent,
                ledger: ledger, transport: { _ in
                    await dispatches.record()
                    throw URLError(.timedOut)
                }
            )
            XCTFail("An invalid endpoint must be rejected before reservation")
        } catch NewsBarError.invalidURL {
            // Expected.
        }
        XCTAssertEqual(ledger.snapshot().count, 0)
        XCTAssertEqual(ledger.snapshot().costMicros, 0)
        let dispatched = await dispatches.count
        XCTAssertEqual(dispatched, 0)
    }

    func testTransportFailureKeepsReservationAndMarksUnknownCost() async throws {
        let directory = try researchTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        AISummaryService.initBudget(target: .popup, mode: .independent, policy: .unlimited, forceReset: true)
        do {
            _ = try await AISummaryService.makeRequest(
                connection: pricedConnection(baseURL: "https://provider.example.com/v1/chat"),
                apiKey: "fictional-key", model: "fixture", systemPrompt: "system", userPrompt: "user",
                maxTokens: 100, disableDeepSeekThinking: false, target: .popup, budgetMode: .independent,
                ledger: ledger, transport: { _ in throw URLError(.timedOut) }
            )
            XCTFail("The fixture transport must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        let snapshot = ledger.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertGreaterThan(snapshot.costMicros, 0)
        XCTAssertEqual(snapshot.unpricedCalls, 1)
    }

    func testLateSummaryFailureCannotSettleAgainstResetBudget() async throws {
        enum FixtureError: Error { case setupFailed }
        let directory = try researchTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        AISummaryService.initBudget(target: .popup, mode: .independent, policy: .unlimited, forceReset: true)
        do {
            _ = try await AISummaryService.makeRequest(
                connection: pricedConnection(baseURL: "https://provider.example.com/v1/chat"),
                apiKey: "fictional-key", model: "fixture", systemPrompt: "system", userPrompt: "user",
                maxTokens: 100, disableDeepSeekThinking: false, target: .popup, budgetMode: .independent,
                ledger: ledger, transport: { _ in
                    guard ledger.resetToday(),
                          ledger.reserveTracked(.research, policy: .unlimited, reservedCostMicros: 500) != nil else {
                        throw FixtureError.setupFailed
                    }
                    throw URLError(.timedOut)
                }
            )
            XCTFail("The fixture transport must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        let snapshot = ledger.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.costMicros, 500)
        XCTAssertEqual(snapshot.unpricedCalls, 0)
    }
}

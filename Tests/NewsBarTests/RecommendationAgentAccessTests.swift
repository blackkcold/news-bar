import Darwin
import Foundation
import NewsBarAgentProtocol
import XCTest
@testable import NewsBar

final class RecommendationAgentAccessTests: XCTestCase {
    @MainActor
    func testAuthorizationBindsScopeWindowTimeAndFixedResponse() throws {
        let access = RecommendationAgentAccess()
        let scope = RecommendationAgentAccess.Scope(diagnostics: UUID(), agent: UUID())
        let response = RecommendationSummaryReply(status: .ok, window: .week, availableFromDay: "2026-10-01",
                                                  completeThroughDay: "2026-10-07", coverage: .complete,
                                                  counts: .init(qualifiedExposures: 20, exposuresWithEngagedRead: 3,
                                                                clickedExposures: 4, clickAttempts: 6,
                                                                attributedClickAttempts: 4, opens: 3))
        XCTAssertEqual(access.begin(.week, scope: scope, now: 1).status, .notAuthorized)
        access.grant(response, scope: scope, now: 100)
        XCTAssertEqual(access.begin(.month, scope: scope, now: 101).status, .notAuthorized)
        for _ in 0..<10 {
            let admitted = access.begin(.week, scope: scope, now: 101)
            let ticket = try XCTUnwrap(admitted.ticket)
            XCTAssertEqual(access.deliver(ticket, scope: scope, now: 101), response)
        }
        XCTAssertEqual(access.begin(.week, scope: scope, now: 102).status, .rateLimited)
        let admitted = access.begin(.week, scope: scope, now: 161)
        let pending = try XCTUnwrap(admitted.ticket)
        access.revoke()
        XCTAssertEqual(access.deliver(pending, scope: scope, now: 161).status, .notAuthorized)
        access.grant(response, scope: scope, now: 300)
        let next = try XCTUnwrap(access.begin(.week, scope: scope, now: 301).ticket)
        XCTAssertEqual(access.deliver(next, scope: .init(diagnostics: UUID(), agent: scope.agent), now: 301).status, .notAuthorized)
        XCTAssertEqual(access.begin(.week, scope: scope, now: 1_200).status, .notAuthorized)
        XCTAssertEqual(RecommendationAgentAccess().begin(.week, scope: scope, now: 301).status, .notAuthorized)
    }

    @MainActor
    func testClosingAgentSwitchRevokesGrantWithoutAnyRequest() throws {
        let access = RecommendationAgentAccess()
        let scope = RecommendationAgentAccess.Scope(diagnostics: UUID(), agent: UUID())
        let response = RecommendationSummaryReply(status: .ok, window: .week, availableFromDay: "2026-10-01",
                                                  completeThroughDay: "2026-10-07", coverage: .complete,
                                                  counts: .init(qualifiedExposures: 20, exposuresWithEngagedRead: 3,
                                                                clickedExposures: 4, clickAttempts: 6,
                                                                attributedClickAttempts: 4, opens: 3))
        access.grant(response, scope: scope, now: 100)
        let inFlight = try XCTUnwrap(access.begin(.week, scope: scope, now: 101).ticket)

        // No request arrives while the switch is off; only the switch change.
        access.setAgentEnabled(false)
        XCTAssertFalse(access.agentEnabled)
        XCTAssertNil(access.activeGrant(scope: scope, now: 102))
        XCTAssertEqual(access.deliver(inFlight, scope: scope, now: 102).status, .notAuthorized)

        // Reopening the switch must not revive the old grant or ticket.
        access.setAgentEnabled(true)
        XCTAssertNil(access.grant)
        XCTAssertEqual(access.begin(.week, scope: scope, now: 103).status, .notAuthorized)
        XCTAssertEqual(access.deliver(inFlight, scope: scope, now: 103).status, .notAuthorized)

        // A grant cannot be created while the switch is off either.
        access.setAgentEnabled(false)
        access.grant(response, scope: scope, now: 200)
        XCTAssertNil(access.activeGrant(scope: scope, now: 201))
    }

    @MainActor
    func testAgentSwitchSettingIsBroadcastForRevocation() {
        let settings = AppSettings()
        let original = settings.agentAccessEnabled
        defer { settings.agentAccessEnabled = original }
        settings.agentAccessEnabled = true
        let expected = expectation(forNotification: .agentAccessSettingChanged, object: nil) { notification in
            notification.userInfo?["enabled"] as? Bool == false
        }
        settings.agentAccessEnabled = false
        wait(for: [expected], timeout: 1)
    }

    func testRequestAndReplyWhitelist() throws {
        XCTAssertEqual(RecommendationSummaryRequest.parse(Data("7d\n".utf8)), .week)
        for invalid in ["31d\n", "7d,rank\n", "7d\nextra", "7d", "7d\n\n"] {
            XCTAssertNil(RecommendationSummaryRequest.parse(Data(invalid.utf8)))
        }
        let response = RecommendationSummaryReply(status: .insufficientData, window: .week)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["schemaVersion", "metricDefinitionVersion", "status", "window", "view"])
        XCTAssertEqual(fields["status"] as? String, "insufficient_data")
    }

    @MainActor
    func testUnixRoundTripAndInFlightRevocationHaveNoDiskPayload() async throws {
        let root = TestIsolation.root.appendingPathComponent("r\(UUID().uuidString.prefix(4))")
        let path = root.appendingPathComponent("s")
        let agentRoot = TestIsolation.directory("agent-\(UUID())")
        agentRoot.path.withCString { _ = Darwin.setenv("NEWSBAR_AGENT_ROOT", $0, 1) }
        defer { _ = Darwin.unsetenv("NEWSBAR_AGENT_ROOT") }
        let access = RecommendationAgentAccess()
        let scope = RecommendationAgentAccess.Scope(diagnostics: UUID(), agent: UUID())
        let server = RecommendationAgentSocketServer(path: path, access: access, scope: { scope }) {
            // Deterministically interleave a revoke after admission, before bytes.
            access.revoke()
        }
        defer { server.stop() }
        let offline = await Task.detached { RecommendationSummarySocket.request(.week, socket: path) }.value
        XCTAssertEqual(offline.status, .appUnavailable)
        try server.start()
        access.grant(.init(status: .insufficientData, window: .week), scope: scope)
        let reply = await Task.detached { RecommendationSummarySocket.request(.week, socket: path) }.value
        XCTAssertEqual(reply.status, .notAuthorized)
        XCTAssertNil(reply.counts)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["s"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agentRoot.path), [])
    }

    @MainActor
    func testSmallSampleIsHiddenAndGrantedSnapshotStaysFixed() async throws {
        let noon = Calendar.autoupdatingCurrent.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let eventDate = noon.addingTimeInterval(-86_400)
        let store = RecommendationDiagnosticStore(directory: TestIsolation.directory("ra-\(UUID())"))
        let diagnostics = RecommendationDiagnostics(store: store)
        diagnostics.setLearningAllowed(true)
        diagnostics.setEnabled(true)

        try await store.append(
            (0..<19).map { exposure(at: eventDate, index: $0) },
            now: noon,
            coverageSince: noon.addingTimeInterval(-8 * 86_400)
        )
        let hidden = await diagnostics.agentReply(.week, now: noon)
        XCTAssertEqual(hidden.status, .insufficientData)
        XCTAssertEqual(hidden.window, .week)
        XCTAssertNil(hidden.counts)

        try await store.append([exposure(at: eventDate, index: 19)], now: noon)
        let visible = await diagnostics.agentReply(.week, now: noon)
        XCTAssertEqual(visible.status, .ok)
        XCTAssertEqual(visible.counts?.qualifiedExposures, 20)
        XCTAssertTrue(diagnostics.grantAgentAccess(visible))
        XCTAssertEqual(diagnostics.agentGrant?.window, .week)

        try await store.append((20..<25).map { exposure(at: eventDate, index: $0) }, now: noon)
        let ticket = try XCTUnwrap(
            diagnostics.agentAccess.begin(.week, scope: diagnostics.agentScope).ticket
        )
        let delivered = diagnostics.agentAccess.deliver(ticket, scope: diagnostics.agentScope)
        XCTAssertEqual(delivered.counts?.qualifiedExposures, 20)
        XCTAssertEqual(delivered.availableFromDay, visible.availableFromDay)
        XCTAssertEqual(delivered.completeThroughDay, visible.completeThroughDay)
    }

    @MainActor
    func testDiagnosticsInvalidationRevokesAgentGrant() async throws {
        let noon = Calendar.autoupdatingCurrent.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let store = RecommendationDiagnosticStore(directory: TestIsolation.directory("ra-\(UUID())"))
        let diagnostics = RecommendationDiagnostics(store: store)
        diagnostics.setLearningAllowed(true)
        diagnostics.setEnabled(true)
        try await store.append(
            (0..<20).map { exposure(at: noon.addingTimeInterval(-86_400), index: $0) },
            now: noon,
            coverageSince: noon.addingTimeInterval(-8 * 86_400)
        )
        let reply = await diagnostics.agentReply(.week, now: noon)
        XCTAssertEqual(reply.status, .ok)
        XCTAssertTrue(diagnostics.grantAgentAccess(reply))
        XCTAssertNotNil(diagnostics.agentGrant)

        diagnostics.setLearningAllowed(false)
        XCTAssertNil(diagnostics.agentGrant)
        XCTAssertEqual(
            diagnostics.agentAccess.begin(.week, scope: diagnostics.agentScope).status,
            .notAuthorized
        )
    }

    @MainActor
    func testDiagnosticsAgentSwitchOffRevokesWithoutAnyRequest() async throws {
        let noon = Calendar.autoupdatingCurrent.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let store = RecommendationDiagnosticStore(directory: TestIsolation.directory("ra-\(UUID())"))
        let diagnostics = RecommendationDiagnostics(store: store)
        diagnostics.setLearningAllowed(true)
        diagnostics.setEnabled(true)
        try await store.append(
            (0..<20).map { exposure(at: noon.addingTimeInterval(-86_400), index: $0) },
            now: noon,
            coverageSince: noon.addingTimeInterval(-8 * 86_400)
        )
        let reply = await diagnostics.agentReply(.week, now: noon)
        XCTAssertEqual(reply.status, .ok)
        XCTAssertTrue(diagnostics.grantAgentAccess(reply))
        XCTAssertNotNil(diagnostics.agentGrant)

        diagnostics.setAgentAccessEnabled(false)
        diagnostics.setAgentAccessEnabled(true)
        XCTAssertNil(diagnostics.agentGrant)
        XCTAssertEqual(
            diagnostics.agentAccess.begin(.week, scope: diagnostics.agentScope).status,
            .notAuthorized
        )
        // Diagnostics themselves keep running: only the Agent gate closed.
        XCTAssertTrue(diagnostics.canCapture)
    }

    @MainActor
    func testStorageFailureIsReportedWithoutCounts() async {
        let store = RecommendationDiagnosticStore(
            directory: URL(fileURLWithPath: "/dev/null/nb-\(UUID().uuidString)")
        )
        let diagnostics = RecommendationDiagnostics(store: store)
        diagnostics.setLearningAllowed(true)
        diagnostics.setEnabled(true)
        let reply = await diagnostics.agentReply(.week)
        XCTAssertEqual(reply.status, .storageUnavailable)
        XCTAssertNil(reply.counts)
        XCTAssertFalse(diagnostics.grantAgentAccess(reply))
    }

    func testClientTimesOutWhenNoReplyArrives() throws {
        let directory = TestIsolation.directory("rt-\(UUID().uuidString.prefix(4))")
        let path = directory.appendingPathComponent("s")
        let listener = try RecommendationSummarySocket.makeDescriptor()
        defer {
            Darwin.close(listener)
            _ = path.withUnsafeFileSystemRepresentation { raw in
                raw.map { Darwin.unlink($0) }
            }
        }
        let bound: Bool = try RecommendationSummarySocket.withAddress(for: path) { address, length in
            Darwin.bind(listener, address, length) == 0
        }
        XCTAssertTrue(bound)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)

        let reply = RecommendationSummarySocket.request(
            .week,
            socket: path,
            deadline: .init(seconds: 0.3)
        )
        XCTAssertEqual(reply.status, .requestTimedOut)
        XCTAssertEqual(reply.window, .week)
    }

    func testCommandExitCodesAndReplyWhitelist() throws {
        let counts = RecommendationSummaryReply.Counts(
            qualifiedExposures: 20,
            exposuresWithEngagedRead: 3,
            clickedExposures: 4,
            clickAttempts: 5,
            attributedClickAttempts: 4,
            opens: 3
        )
        let ok = RecommendationSummaryReply(
            status: .ok,
            window: .week,
            availableFromDay: "2026-11-18",
            completeThroughDay: "2026-11-24",
            coverage: .complete,
            counts: counts
        )
        let text = RecommendationSummaryCommand.render(ok, json: false)
        XCTAssertEqual(text.exitCode, 0)
        XCTAssertTrue(text.output.contains("Qualified exposures: 20"))

        let json = try XCTUnwrap(RecommendationSummaryCommand.render(ok, json: true).output.data(using: .utf8))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["schemaVersion", "metricDefinitionVersion", "view", "status",
                                         "window", "availableFromDay", "completeThroughDay", "coverage", "counts"])
        XCTAssertEqual(Set(try XCTUnwrap(fields["counts"] as? [String: Any]).keys),
                       ["qualifiedExposures", "exposuresWithEngagedRead", "clickedExposures",
                        "clickAttempts", "attributedClickAttempts", "opens"])
        let encoded = String(decoding: json, as: UTF8.self).lowercased()
        for forbidden in ["title", "url", "source", "contentkey", "exposureid", "attemptid", "interest"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }

        let cases: [(RecommendationSummaryReply, Int32)] = [
            (.init(status: .insufficientData, window: .month), 0),
            (.init(status: .notAuthorized, window: .week), 4),
            (.init(status: .rateLimited, window: .week), 4),
            (.init(status: .appUnavailable, window: .week), 3),
            (.init(status: .storageUnavailable, window: .week), 5),
            (.init(status: .requestTimedOut, window: .week), 5),
            (.init(status: .invalidRequest), 2),
        ]
        for (reply, code) in cases {
            XCTAssertEqual(reply.status.exitCode, code)
            XCTAssertEqual(RecommendationSummaryCommand.render(reply, json: true).exitCode, code)
        }

        let denied = RecommendationSummaryCommand.render(.init(status: .notAuthorized, window: .week), json: false)
        XCTAssertTrue(denied.output.isEmpty)
        XCTAssertNotNil(denied.error)
    }

    private func exposure(at date: Date, index: Int) -> RecommendationDiagnosticEvent {
        RecommendationDiagnosticEvent(
            kind: .exposure,
            occurredAt: date,
            diagnosticSessionID: UUID(),
            snapshotID: UUID(),
            contentKey: UUID(),
            exposureID: UUID(),
            algorithmRank: index % 20 + 1,
            confidenceBand: .low,
            interestMatch: .matched,
            rankingVariant: .v4
        )
    }
}

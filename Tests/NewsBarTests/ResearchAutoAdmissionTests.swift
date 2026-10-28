import XCTest
@testable import NewsBar

final class ResearchAutoAdmissionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFailureCoolsDownFromAttemptRatherThanLastSuccess() {
        var record = researchTestRecord(title: "热点", status: .failed, origin: .burst, updatedAt: now.addingTimeInterval(-86_400))
        record.run.startedAt = now.addingTimeInterval(-60)
        record.run.finishedAt = now.addingTimeInterval(-30)
        XCTAssertFalse(ResearchAutoAdmission.allows(record, now: now))
        XCTAssertTrue(ResearchAutoAdmission.allows(record, now: now.addingTimeInterval(6 * 3_600)))
    }

    func testOldInterruptedAndCancelledRunsNeverRestartAutomatically() {
        for status in [ResearchStatus.interrupted, .cancelled] {
            var record = researchTestRecord(title: "旧热点", status: status, origin: .burst, updatedAt: now.addingTimeInterval(-86_400))
            record.lastSeenAt = now
            XCTAssertFalse(ResearchAutoAdmission.allows(record, now: now), "\(status)")
        }
    }

    func testStaleNeverStartedQueueDoesNotBecomeFreshWhenSeenAgain() {
        var record = researchTestRecord(title: "旧排队", status: .queued, origin: .keyword, updatedAt: now.addingTimeInterval(-901))
        record.run.startedAt = nil
        record.lastSeenAt = now
        XCTAssertFalse(ResearchAutoAdmission.allows(record, now: now))
        record.createdAt = now.addingTimeInterval(-30)
        XCTAssertTrue(ResearchAutoAdmission.allows(record, now: now))
    }

    func testFailedAutomaticAttemptsAreBoundedAndOldRecordDecodes() throws {
        var record = researchTestRecord(title: "热点", status: .failed, origin: .burst, updatedAt: now.addingTimeInterval(-86_400))
        record.run.startedAt = now.addingTimeInterval(-86_400)
        let data = try JSONEncoder().encode(record)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "automaticAttempts")
        json.removeValue(forKey: "lastAutomaticAttemptAt")
        let legacy = try JSONDecoder().decode(ResearchRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(ResearchAutoAdmission.allows(legacy, now: now))

        record.automaticAttempts = 3
        record.lastAutomaticAttemptAt = now.addingTimeInterval(-86_400)
        XCTAssertFalse(ResearchAutoAdmission.allows(record, now: now))
    }
}

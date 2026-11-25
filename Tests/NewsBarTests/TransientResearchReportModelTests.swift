import XCTest
@testable import NewsBar

@MainActor
final class TransientResearchReportModelTests: XCTestCase {
    func testDisplayedVersionMetadataAndTaskStatusAreIndependent() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(600)
        let old = BurstResearch(summary: "older")
        let latest = BurstResearch(summary: "newest")
        var record = researchTestRecord(title: "topic", status: .running, report: latest)
        let (model, records, versions) = try makeModel(records: [record])
        try await append(old, date: oldDate, record: record, to: versions)
        try await append(latest, date: newDate, record: record, to: versions)

        await model.open(recordID: record.id, eventID: nil)
        XCTAssertEqual(model.displayedVersionLabel, "V2")
        XCTAssertEqual(model.displayedDate, newDate)
        XCTAssertEqual(model.currentTaskStatus, .running)
        XCTAssertNil(model.copyVersionLabel, "Ordinary opens keep the existing Markdown header")

        await model.open(recordID: record.id, eventID: nil, versionID: "\(record.id)#1")
        XCTAssertTrue(model.isHistorical)
        XCTAssertEqual(model.displayedReport?.summary, "older")
        XCTAssertEqual(model.displayedVersionLabel, "V1")
        XCTAssertEqual(model.displayedDate, oldDate)
        XCTAssertEqual(model.copyVersionLabel, "V1")
        XCTAssertNil(model.currentTaskStatus)

        record.status = .failed
        try await records.save(record)
        let readingID = model.readingID
        await model.reload()
        XCTAssertEqual(model.readingID, readingID)
        XCTAssertEqual(model.displayedReport?.summary, "older")
        XCTAssertNil(model.currentTaskStatus)
    }

    func testNewVersionNeedsAnExplicitSwitchEvenForSameSummary() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(600)
        var record = researchTestRecord(
            title: "topic", status: .running, report: BurstResearch(summary: "same", generatedAt: oldDate)
        )
        let (model, records, versions) = try makeModel(records: [record])
        try await append(try XCTUnwrap(record.report), date: oldDate, record: record, to: versions)
        await model.open(recordID: record.id, eventID: nil, fallbackTitle: "initial title")
        let readingID = model.readingID

        record.run.queriesCompleted = 1
        try await records.save(record)
        await model.open(
            recordID: record.id, eventID: nil,
            fallbackSourceURL: "https://example.org/different", fallbackTitle: "fallback changed"
        )
        XCTAssertEqual(model.readingID, readingID)
        XCTAssertEqual(model.record?.run.queriesCompleted, 1)

        record.report = BurstResearch(summary: "same", generatedAt: newDate)
        record.status = .ready
        try await append(try XCTUnwrap(record.report), date: newDate, record: record, to: versions)
        try await records.save(record)
        await model.reload()
        XCTAssertEqual(model.readingID, readingID)
        XCTAssertEqual(model.displayedVersionLabel, "V1")
        XCTAssertEqual(model.displayedDate, oldDate)
        XCTAssertNotNil(model.availableRecord)

        model.showAvailableChanges()
        XCTAssertNotEqual(model.readingID, readingID)
        XCTAssertEqual(model.displayedVersionLabel, "V2")
        XCTAssertEqual(model.displayedDate, newDate)
        XCTAssertTrue(model.isShowingChanges)
        model.closeChanges()
        XCTAssertEqual(model.displayedVersionLabel, "V2")
        XCTAssertNil(model.copyVersionLabel)
    }

    func testMissingVersionDoesNotInventNumberAndDifferentFallbackURLsResetReader() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = researchTestRecord(title: "topic", updatedAt: date, report: BurstResearch(summary: "legacy"))
        let (model, _, _) = try makeModel(records: [record])
        await model.open(recordID: record.id, eventID: nil)
        XCTAssertNil(model.displayedVersionLabel)
        XCTAssertEqual(model.displayedDate, date)

        await model.open(recordID: nil, eventID: nil, fallbackSourceURL: "https://example.org/story?utm_source=one")
        let readingID = model.readingID
        await model.open(recordID: nil, eventID: nil, fallbackSourceURL: "https://example.org/story?utm_source=two")
        XCTAssertEqual(model.readingID, readingID)
        await model.open(recordID: nil, eventID: nil, fallbackSourceURL: "https://example.org/other")
        XCTAssertNotEqual(model.readingID, readingID)
        XCTAssertNil(model.displayedReport)
    }

    private func makeModel(records: [ResearchRecord]) throws
        -> (TransientResearchReportModel, ResearchFakeStore, WorkspaceSubjectStore) {
        let directory = try researchTestDirectory()
        let research = ResearchFakeStore(records: records)
        let workspace = WorkspaceSubjectStore(directoryURL: directory.appendingPathComponent("workspace"))
        let events = NewsEventStore(fileURL: directory.appendingPathComponent("events.json"))
        return (TransientResearchReportModel(researchStore: research, workspaceStore: workspace, eventStore: events),
                research, workspace)
    }

    private func append(
        _ report: BurstResearch, date: Date, record: ResearchRecord, to store: WorkspaceSubjectStore
    ) async throws {
        try await store.appendVersion(WorkspaceReportVersion(
            id: "reassigned", recordID: record.id, subjectID: "subject", sequence: 0,
            createdAt: date, trigger: .manual, report: report, digest: WorkspaceReportDigest.make(report)
        ))
    }
}

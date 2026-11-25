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
        let (model, records, versions, _) = try makeModel(records: [record])
        try await append(old, date: oldDate, record: record, to: versions)
        try await append(latest, date: newDate, record: record, to: versions)

        await model.open(recordID: record.id, eventID: nil)
        XCTAssertEqual(model.displayedVersionLabel, "V2")
        XCTAssertEqual(model.displayedDate, newDate)
        XCTAssertEqual(model.currentTaskStatus, .running)
        XCTAssertNil(model.copyVersionLabel, "Ordinary opens keep the existing Markdown header")

        await model.open(recordID: record.id, eventID: nil, versionID: "\(record.id)#2")
        XCTAssertFalse(model.isHistorical, "A notification can point at the current version")
        XCTAssertEqual(model.displayedVersionLabel, "V2")
        XCTAssertEqual(model.currentTaskStatus, .running)

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

    func testUnavailablePinnedVersionCannotMasqueradeAsTheLatestReport() async throws {
        let report = BurstResearch(summary: "not the requested version")
        let record = researchTestRecord(title: "topic", status: .running, report: report)
        let (model, _, versions, _) = try makeModel(records: [record])
        try await append(report, date: .distantPast, record: record, to: versions)

        await model.open(recordID: record.id, eventID: nil, versionID: "\(record.id)#70")
        XCTAssertNil(model.displayedReport)
        XCTAssertNil(model.displayedVersionLabel)
        XCTAssertNil(model.currentTaskStatus)
    }

    func testNewVersionNeedsAnExplicitSwitchEvenForSameSummary() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(600)
        var record = researchTestRecord(
            title: "topic", status: .running, report: BurstResearch(summary: "same", generatedAt: oldDate)
        )
        let (model, records, versions, _) = try makeModel(records: [record])
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
        let (model, _, _, _) = try makeModel(records: [record])
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

    func testStoredSequenceZeroKeepsDateButDoesNotDisplayV0() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let report = BurstResearch(summary: "archived")
        let record = researchTestRecord(title: "topic", report: report)
        let directory = try researchTestDirectory()
        let versionsDirectory = directory.appendingPathComponent("report-versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let v0 = WorkspaceReportVersion(
            id: "\(record.id)#0", recordID: record.id, subjectID: "subject", sequence: 0,
            createdAt: date, trigger: .manual, report: report, digest: WorkspaceReportDigest.make(report)
        )
        try JSONEncoder().encode([v0]).write(to: versionsDirectory.appendingPathComponent("\(record.id).json"))
        let model = TransientResearchReportModel(
            researchStore: ResearchFakeStore(records: [record]),
            workspaceStore: WorkspaceSubjectStore(directoryURL: directory),
            eventStore: NewsEventStore(fileURL: directory.appendingPathComponent("events.json"))
        )

        await model.open(recordID: record.id, eventID: nil, versionID: v0.id)
        XCTAssertEqual(model.displayedReport?.summary, "archived")
        XCTAssertEqual(model.displayedDate, date)
        XCTAssertNil(model.displayedVersionLabel)
    }

    func testReloadNeverReplacesAReadableReportWithAnEmptyFailure() async throws {
        var record = researchTestRecord(title: "topic", report: BurstResearch(summary: "still readable"))
        let (model, records, _, _) = try makeModel(records: [record])
        await model.open(recordID: record.id, eventID: nil)
        let readingID = model.readingID
        record.report = nil
        record.status = .failed
        try await records.save(record)

        await model.reload()
        XCTAssertEqual(model.readingID, readingID)
        XCTAssertEqual(model.displayedReport?.summary, "still readable")
        XCTAssertEqual(model.currentTaskStatus, .failed)
        XCTAssertNil(model.availableRecord)
    }

    func testSlowPreviousTargetCannotReplaceCurrentReading() async throws {
        let older = researchTestRecord(title: "First target", report: BurstResearch(summary: "first"))
        let current = researchTestRecord(title: "Second target", report: BurstResearch(summary: "second"))
        let (model, records, _, _) = try makeModel(records: [older, current])
        await records.setRecordDelay(id: older.id, nanoseconds: 200_000_000)
        let previousOpen = Task { await model.open(recordID: older.id, eventID: nil) }
        while model.recordID != older.id { await Task.yield() }
        XCTAssertFalse(model.didLoad)

        await model.open(recordID: current.id, eventID: nil)
        let currentID = model.readingID
        await previousOpen.value
        XCTAssertEqual(model.readingID, currentID)
        XCTAssertEqual(model.record?.topic, "Second target")
        XCTAssertEqual(model.displayedReport?.summary, "second")
    }

    func testEventOnlyAndUnfinishedRecordsDoNotBecomeReadableReports() async throws {
        let active = researchTestRecord(title: "In progress", status: .running)
        let failed = researchTestRecord(title: "Failed", status: .failed)
        let (model, _, _, events) = try makeModel(records: [active, failed])
        let event = NewsEvent(
            id: "event", title: "Event only", eventDescription: "An event summary.",
            subjectAliases: [], firstSeenAt: .distantPast, lastEvidenceAt: .distantPast
        )
        try await events.upsert(event)
        XCTAssertFalse(model.didLoad)

        await model.open(recordID: active.id, eventID: nil)
        XCTAssertTrue(model.didLoad)
        XCTAssertNil(model.displayedReport)
        XCTAssertEqual(model.currentTaskStatus, .running)
        await model.open(recordID: failed.id, eventID: nil)
        XCTAssertNil(model.displayedReport)
        XCTAssertEqual(model.currentTaskStatus, .failed)
        await model.open(recordID: nil, eventID: event.id)
        XCTAssertNil(model.displayedReport)
        XCTAssertNil(model.currentTaskStatus)
        XCTAssertEqual(model.event?.title, "Event only")
    }

    func testEmptyStatesKeepRunningFailureAndEventOnlyCopyApart() async throws {
        let active = researchTestRecord(title: "In progress", status: .running)
        let failed = researchTestRecord(title: "Failed", status: .failed)
        let readyWithoutReport = researchTestRecord(title: "Ready but unreadable", status: .ready)
        let (model, _, _, events) = try makeModel(records: [active, failed, readyWithoutReport])
        let event = NewsEvent(
            id: "event", title: "Event only", eventDescription: "An event summary.",
            subjectAliases: [], firstSeenAt: .distantPast, lastEvidenceAt: .distantPast
        )
        try await events.upsert(event)

        await model.open(recordID: active.id, eventID: nil)
        XCTAssertEqual(model.emptyState, .researching)
        XCTAssertEqual(model.emptyState.headline(language: .zh), "研究中 · 尚无可读报告")
        XCTAssertEqual(
            model.emptyState.headline(language: .en),
            "Research in progress · No readable report yet"
        )

        await model.open(recordID: failed.id, eventID: nil)
        XCTAssertEqual(model.emptyState, .ended(.failed))
        XCTAssertEqual(model.emptyState.headline(language: .zh), "研究失败 · 尚无可读报告")

        await model.open(recordID: readyWithoutReport.id, eventID: nil)
        XCTAssertEqual(model.emptyState, .unavailable, "A finished status must not claim a readable report")
        XCTAssertEqual(model.emptyState.headline(language: .zh), "尚无可读报告")

        await model.open(recordID: nil, eventID: event.id)
        XCTAssertEqual(model.emptyState, .unavailable)
        XCTAssertNil(model.currentTaskStatus)
        XCTAssertEqual(model.event?.title, "Event only")
    }

    func testDismissingAnOpenCitationConsumesAnEscapeBeforeTheWindowCanClose() {
        let citations = ResearchReportCitationPresentation()
        citations.activeChip = UUID()
        XCTAssertTrue(citations.dismiss())
        XCTAssertNil(citations.activeChip)
        XCTAssertFalse(citations.dismiss())
    }

    func testExistingMarkdownStillIncludesLimitationsAndOmitsUnstructuredLinks() {
        let report = BurstResearch(
            summary: "The archived summary", sources: ["https://example.org/original"],
            limitations: "Public records only"
        )
        XCTAssertEqual(WorkspaceReportMarkdown.make(report: report, subjectTitle: "Topic", versionLabel: "V1"),
                       "# Topic\n*V1*\n\n## Summary\nThe archived summary\n\n## Limitations\nPublic records only\n")
    }

    private func makeModel(records: [ResearchRecord]) throws
        -> (TransientResearchReportModel, ResearchFakeStore, WorkspaceSubjectStore, NewsEventStore) {
        let directory = try researchTestDirectory()
        let research = ResearchFakeStore(records: records)
        let workspace = WorkspaceSubjectStore(directoryURL: directory.appendingPathComponent("workspace"))
        let events = NewsEventStore(fileURL: directory.appendingPathComponent("events.json"))
        return (TransientResearchReportModel(researchStore: research, workspaceStore: workspace, eventStore: events),
                research, workspace, events)
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

import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class ResearchCenterRenderingTests: XCTestCase {
    private let sizes = [
        NSSize(width: 1000, height: 660),
        NSSize(width: 1120, height: 760),
    ]

    func testCenterRendersAcrossStatesThemesLanguagesAndSizes() async throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("research-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for theme in AppTheme.allCases {
            for language in AppLanguage.allCases {
                for size in sizes {
                    try await render(
                        state: "empty",
                        records: [],
                        selectFirst: false,
                        theme: theme,
                        language: language,
                        size: size,
                        output: output
                    )
                    try await render(
                        state: "ready",
                        records: [readyRecord()],
                        selectFirst: true,
                        theme: theme,
                        language: language,
                        size: size,
                        output: output
                    )
                    try await render(
                        state: "empty-timeline",
                        records: [readyWithEmptyTimelineRecord()],
                        selectFirst: true,
                        theme: theme,
                        language: language,
                        size: size,
                        output: output
                    )
                    try await render(
                        state: "unverified-timeline",
                        records: [readyWithUnverifiedTimelineRecord()],
                        selectFirst: true,
                        theme: theme,
                        language: language,
                        size: size,
                        output: output
                    )
                    try await render(
                        state: "failed",
                        records: [failedRecord()],
                        selectFirst: true,
                        theme: theme,
                        language: language,
                        size: size,
                        output: output
                    )
                    try await render(
                        state: "running",
                        records: [runningRecord()],
                        selectFirst: true,
                        theme: theme,
                        language: language,
                        size: size,
                        output: output
                    )
                }
            }
        }
    }

    private func render(
        state: String,
        records: [ResearchRecord],
        selectFirst: Bool,
        theme: AppTheme,
        language: AppLanguage,
        size: NSSize,
        output: URL
    ) async throws {
        let settings = AppSettings()
        settings.appTheme = theme
        settings.appLanguage = language

        let store = ResearchFakeStore(records: records)
        let coordinator = ResearchCoordinator(store: store, notifier: { _ in })
        let orchestrator = NewsOrchestrator()
        let model = ResearchCenterModel(
            orchestrator: orchestrator,
            settings: settings,
            store: store,
            coordinator: coordinator
        )
        await model.load()
        if selectFirst, let id = model.entries.first?.id {
            await model.select(id)
        }

        let view = ResearchCenterView(model: model)
            .environment(settings)

        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let name = "\(state)-\(theme.rawValue)-\(language.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
        try data.write(to: output.appendingPathComponent(name))

        XCTAssertGreaterThan(data.count, 2_000, name)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width), name)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height), name)

        window.contentView = nil
    }

    private func readyRecord() -> ResearchRecord {
        researchTestRecord(
            title: "两家媒体确认十月发布",
            status: .ready,
            report: BurstResearch(
                summary: "两家独立媒体确认新品将于十月发布。",
                overview: "公司发布新品，随后两家媒体分别确认了发布时间。",
                timeline: [
                    TimelineNode(
                        date: "2026-10-01",
                        title: "发布",
                        detail: "公司发布新品",
                        evidenceIDs: ["E1"],
                        confidence: .high
                    ),
                ],
                searchStatus: .succeeded
            )
        )
    }

    private func readyWithEmptyTimelineRecord() -> ResearchRecord {
        var verification = VerificationReport()
        verification.verdict = .unverified
        verification.claims = [
            ClaimCheck(claim: "公开来源不足", status: nil, evidenceIDs: [], note: ""),
        ]
        return researchTestRecord(
            title: "暂无可回溯时间线",
            status: .ready,
            report: BurstResearch(
                summary: "现有来源不足以支撑时间线。",
                overview: "只保留了摘要与核查结论。",
                timeline: [],
                searchStatus: .succeeded,
                verification: verification
            )
        )
    }

    private func readyWithUnverifiedTimelineRecord() -> ResearchRecord {
        let evidence = EvidenceItem(
            id: "E1",
            url: "https://example.com/story",
            canonicalURL: "https://example.com/story",
            domain: "example.com",
            title: "来源",
            publishedAt: Date(),
            quote: "未能在正文中找到的引文。",
            quoteVerified: false,
            stance: .supports,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: Date()
        )
        var verification = VerificationReport()
        verification.verdict = .unverified
        verification.claims = [
            ClaimCheck(claim: "待核实", status: nil, evidenceIDs: ["E1"], note: ""),
        ]
        return researchTestRecord(
            title: "未核实时间线",
            status: .ready,
            report: BurstResearch(
                summary: "有一段时间线，但引文未通过逐字校验。",
                overview: "保留节点并明确标注未核实。",
                timeline: [
                    TimelineNode(
                        date: "2026-10-01",
                        title: "待核实节点",
                        detail: "渠道消息尚未确认",
                        evidenceIDs: ["E1"],
                        confidence: .low
                    ),
                ],
                searchStatus: .succeeded,
                evidence: [evidence],
                verification: verification
            )
        )
    }

    private func failedRecord() -> ResearchRecord {
        var record = researchTestRecord(title: "一次失败的核查", status: .failed)
        record.run.lastError = "搜索服务暂时不可用，请稍后重试。"
        record.run.phase = .done
        record.run.finishedAt = Date()
        return record
    }

    private func runningRecord() -> ResearchRecord {
        var record = researchTestRecord(title: "正在核查的事件", status: .running)
        record.run.phase = .reading
        record.run.pagesRead = 3
        record.run.searchCalls = 2
        record.run.aiCalls = 2
        return record
    }
}

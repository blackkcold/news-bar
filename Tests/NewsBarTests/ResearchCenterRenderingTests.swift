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
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-render-matrix", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
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

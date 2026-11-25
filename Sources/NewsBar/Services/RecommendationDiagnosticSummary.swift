import Foundation

enum RecommendationDiagnosticWindow: String, CaseIterable, Sendable {
    case week = "7d", month = "30d"

    var days: Int { self == .week ? 7 : 30 }
}

struct RecommendationDiagnosticSummary: Sendable {
    struct Bucket: Sendable {
        var exposures = 0
        var engaged = 0
    }
    var start: Date
    var end: Date // exclusive local day boundary
    var availableFrom: Date?
    var missingDays: Int
    var exposures = 0
    var clickedExposures = 0
    var engagedExposures = 0
    var negativeExposures = 0
    var clicks = 0
    var sameSnapshot = 0
    var afterRerank = 0
    var results: [RecommendationDiagnosticEvent.Result: Int] = [:]
    var engaged = 0
    var adaptedOpens = 0
    var knownAdaptationOpens = 0
    var qualified = 0
    var deep = 0
    var undo = 0
    var rank: [Int: Bucket] = [:]
    var confidence: [DiagnosticConfidence: Bucket] = [:]
    var match: [DiagnosticInterestMatch: Bucket] = [:]

    var hasExposureSample: Bool { exposures > 0 }
    var unsettled: Int { clicks - results.values.reduce(0, +) }
    var unattributed: Int { clicks - sameSnapshot - afterRerank }

    static func make(document: RecommendationDiagnosticDocument, window: RecommendationDiagnosticWindow,
                     now: Date, calendar: Calendar = .autoupdatingCurrent) -> Self? {
        let today = calendar.startOfDay(for: now)
        // Wait a full attribution + observation window before closing a day.
        guard let end = now.timeIntervalSince(today) >= 3_600
                ? today : calendar.date(byAdding: .day, value: -1, to: today),
              let start = calendar.date(byAdding: .day, value: -window.days, to: end) else { return nil }
        let dayStarts = (0..<window.days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let available = document.coverageSince.map { max(cutoff, $0, document.truncatedThrough ?? .distantPast) }
        let completeStarts = dayStarts.filter { date in
            guard let available else { return false }
            return date >= available && date > (document.truncatedThrough ?? .distantPast)
        }
        var summary = Self(start: start, end: end, availableFrom: completeStarts.first,
                           missingDays: window.days - completeStarts.count)
        let records = document.events
        let cohort = records.filter { $0.occurredAt >= start && $0.occurredAt < end }
        let exposureIDs = Set(cohort.filter { $0.kind == .exposure }.compactMap(\.exposureID))
        let clickIDs = Set(cohort.filter { $0.kind == .click }.compactMap(\.attemptID))
        let clicked = Set(records.filter { $0.kind == .click }.compactMap(\.exposureID)).intersection(exposureIDs)
        let engagedRecords = records.filter { $0.kind == .milestone && $0.milestone == .engaged }
        let engaged = Set(engagedRecords.compactMap(\.exposureID)).intersection(exposureIDs)
        let negative = Set(records.filter { $0.kind == .feedback && $0.feedbackKind?.isNegative == true }
            .compactMap(\.exposureID)).intersection(exposureIDs)

        summary.exposures = exposureIDs.count
        summary.clickedExposures = clicked.count
        summary.engagedExposures = engaged.count
        summary.negativeExposures = negative.count
        summary.clicks = clickIDs.count
        summary.sameSnapshot = cohort.filter { $0.attributionKind == .sameSnapshot }.count
        summary.afterRerank = cohort.filter { $0.attributionKind == .afterRerank }.count
        summary.engaged = Set(engagedRecords.compactMap(\.attemptID)).intersection(clickIDs).count
        summary.undo = cohort.filter { $0.feedbackKind == .undo }.count
        var opened: Set<UUID> = []
        var adapted: Set<UUID> = []
        var knownAdaptation: Set<UUID> = []
        var qualified: Set<UUID> = []
        var deep: Set<UUID> = []
        for record in records {
            guard let id = record.attemptID, clickIDs.contains(id) else { continue }
            if let result = record.result {
                summary.results[result, default: 0] += 1
                if result == .opened { opened.insert(id) }
                if let value = record.articleAdapted {
                    knownAdaptation.insert(id)
                    if value { adapted.insert(id) }
                }
            }
            if let value = record.articleAdapted {
                knownAdaptation.insert(id)
                if value { adapted.insert(id) }
            }
            if record.milestone == .qualified || record.milestone == .deep { qualified.insert(id) }
            if record.milestone == .deep { deep.insert(id) }
        }
        summary.adaptedOpens = opened.intersection(adapted).count
        summary.knownAdaptationOpens = opened.intersection(knownAdaptation).count
        summary.qualified = qualified.intersection(opened).count
        summary.deep = deep.intersection(opened).count
        var counted: Set<UUID> = []
        for record in cohort {
            guard record.kind == .exposure, let id = record.exposureID, counted.insert(id).inserted else { continue }
            let read = engaged.contains(id) ? 1 : 0
            if let position = record.algorithmRank {
                let bucket = position <= 5 ? 0 : position <= 10 ? 1 : position <= 20 ? 2 : 3
                summary.rank[bucket, default: Bucket()].exposures += 1
                summary.rank[bucket, default: Bucket()].engaged += read
            }
            let band = record.confidenceBand ?? .unknown
            summary.confidence[band, default: Bucket()].exposures += 1
            summary.confidence[band, default: Bucket()].engaged += read
            if let match = record.interestMatch {
                summary.match[match, default: Bucket()].exposures += 1
                summary.match[match, default: Bucket()].engaged += read
            }
        }
        return summary
    }
}

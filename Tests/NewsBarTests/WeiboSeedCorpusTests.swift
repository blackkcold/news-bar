import XCTest
@testable import NewsBar

/// Golden corpus regression: 54 real posts across five tech accounts, labelled
/// by hand. The thresholds are the launch gates from the design document. This
/// is an in-sample check, not a generalisation claim; the point is to catch a
/// rule change that starts hiding on-topic posts or letting ads through.
final class WeiboSeedCorpusTests: XCTestCase {
    private struct Seed: Decodable {
        var mid: String
        var uid: String
        var screenName: String
        var text: String
        var createdAt: String
        var imageCount: Int?
    }

    private struct Label: Decodable {
        var mid: String
        var label: String
    }

    private struct Sample {
        var seed: Seed
        var label: String
        var relevance: WeiboPostRelevance
    }

    private let model = WeiboRelevanceModel()
    private let files = [
        "weibo-corpus-seed.jsonl",
        "weibo-corpus-seed-2.jsonl",
        "weibo-corpus-seed-3.jsonl",
        "weibo-corpus-seed-4.jsonl",
        "weibo-corpus-seed-5.jsonl",
        "weibo-corpus-seed-6.jsonl",
    ]

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func loadSamples() throws -> [Sample] {
        let decoder = JSONDecoder()
        var seeds: [Seed] = []
        for file in files {
            let data = try Data(contentsOf: fixtureURL(file))
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = line.data(using: .utf8),
                      let seed = try? decoder.decode(Seed.self, from: lineData) else { continue }
                seeds.append(seed)
            }
        }

        let labelData = try Data(contentsOf: fixtureURL("weibo-corpus-seed-labels.jsonl"))
        guard let labelText = String(data: labelData, encoding: .utf8) else { return [] }
        var labels: [String: String] = [:]
        for line in labelText.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let label = try? decoder.decode(Label.self, from: lineData) else { continue }
            labels[label.mid] = label.label
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        let now = seeds.compactMap { formatter.date(from: $0.createdAt) }.max() ?? Date()

        var samples: [Sample] = []
        for seed in seeds {
            guard let label = labels[seed.mid] else { continue }
            let date = formatter.date(from: seed.createdAt) ?? now
            let references = seeds
                .filter { $0.uid != seed.uid }
                .compactMap { other -> WeiboCrossPostReference? in
                    guard let otherDate = formatter.date(from: other.createdAt) else { return nil }
                    return WeiboCrossPostReference(
                        uid: other.uid,
                        text: other.text,
                        createdAt: otherDate
                    )
                }
            let index = WeiboCrossPostIndex(
                references: references,
                excludingUID: seed.uid,
                now: date
            )
            let relevance = model.evaluate(
                text: seed.text,
                imageCount: seed.imageCount ?? 0,
                accountBaseline: 0.5,
                userKeywords: [],
                crossPostIndex: index,
                mode: .balanced,
                now: date
            )
            samples.append(Sample(seed: seed, label: label, relevance: relevance))
        }
        return samples
    }

    func testSeedCorpusMeetsTheLaunchGates() throws {
        let samples = try loadSamples()
        XCTAssertEqual(samples.count, 96)

        let onTopic = samples.filter { $0.label == "onTopic" }
        let ads = samples.filter { $0.label == "ad" }
        let offTopic = samples.filter {
            $0.label == "offTopic" || $0.label == "genericNews" || $0.label == "lowInfo"
        }
        let nonAds = samples.filter { $0.label != "ad" }

        let kept = onTopic.filter { $0.relevance.verdict == .relevant }
        let adRecall = ads.filter { $0.relevance.verdict == .filtered }
        let falsePositives = nonAds.filter { $0.relevance.verdict == .filtered }
        let downgraded = offTopic.filter { $0.relevance.verdict != .relevant }

        let keptRatio = Double(kept.count) / Double(max(1, onTopic.count))
        let recallRatio = Double(adRecall.count) / Double(max(1, ads.count))
        let falsePositiveRatio = Double(falsePositives.count) / Double(max(1, nonAds.count))
        let downgradeRatio = Double(downgraded.count) / Double(max(1, offTopic.count))
        let notified = samples.filter { $0.relevance.verdict == .relevant }.count
        let reduction = 1 - Double(notified) / Double(samples.count)

        print(
            String(
                format: "SEED onTopic=%.1f%% adRecall=%.1f%% adFP=%.1f%% offTopic=%.1f%% notified=%d reduction=%.1f%%",
                keptRatio * 100,
                recallRatio * 100,
                falsePositiveRatio * 100,
                downgradeRatio * 100,
                notified,
                reduction * 100
            )
        )
        for sample in samples where sample.relevance.verdict != .relevant {
            print(
                String(
                    format: "  collapsed [%@] %@ ad=%.2f interest=%.2f %@",
                    sample.label,
                    sample.seed.mid,
                    sample.relevance.adScore,
                    sample.relevance.interestScore,
                    sample.relevance.reasons.joined(separator: ",")
                )
            )
        }

        XCTAssertGreaterThanOrEqual(keptRatio, 0.95, "on-topic posts must not be collapsed")
        XCTAssertGreaterThanOrEqual(recallRatio, 0.90, "ads must be filtered")
        XCTAssertLessThanOrEqual(falsePositiveRatio, 0.02, "non-ads must not be filtered")
        XCTAssertGreaterThanOrEqual(downgradeRatio, 0.70, "off-topic posts must be collapsed")
        XCTAssertGreaterThanOrEqual(reduction, 0.30, "the filter must reduce notifications")
        XCTAssertLessThanOrEqual(reduction, 0.60, "the filter must not hide half the feed")
    }
}

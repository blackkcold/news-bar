import Foundation

// A small, dependency-free companion to the app. It reads the JSONL produced
// by WeiboCorpusRecorder (WEIBO_CORPUS_DUMP=1), guides a human through
// labelling, and prints the gate metrics the design document requires.

struct CorpusLine: Decodable {
    var mid: String
    var uid: String
    var screenName: String
    var text: String
    var createdAt: String
    var adScore: Double?
    var interestScore: Double?
    var verdict: String?
    var reasons: [String]?
}

struct LabelLine: Codable {
    var mid: String
    var label: String
    var at: String
}

let labelOrder = ["onTopic", "offTopic", "ad", "pr", "genericNews", "lowInfo", "unsure"]
let labelTitles = [
    "onTopic": "相关（科技/数码内容）",
    "offTopic": "无关（生活/娱乐/其他）",
    "ad": "硬广（抽奖/带货/商业披露）",
    "pr": "软性推广（PR 稿/同稿）",
    "genericNews": "泛资讯（政策/行业但不相关）",
    "lowInfo": "低信息量（无实质内容）",
    "unsure": "拿不准（不计入指标）",
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(2)
}

func usage() -> Never {
    print("""
    usage:
      WeiboLabelCLI label <posts.jsonl> [--out labels.jsonl]
      WeiboLabelCLI evaluate <posts.jsonl> <labels.jsonl>

    label keys:
      1 onTopic  2 offTopic  3 ad  4 pr  5 genericNews  6 lowInfo  7 unsure
      s skip   q save & quit
    """)
    exit(0)
}

func readLines(_ path: String) -> [String] {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read \(path)")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        fail("\(path) is not UTF-8")
    }
    return text.split(whereSeparator: \.isNewline).map(String.init)
}

func decodeCorpus(_ path: String) -> [CorpusLine] {
    let decoder = JSONDecoder()
    var seen = Set<String>()
    var result: [CorpusLine] = []
    for line in readLines(path) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let data = line.data(using: .utf8),
              let item = try? decoder.decode(CorpusLine.self, from: data) else { continue }
        if seen.insert(item.mid).inserted {
            result.append(item)
        }
    }
    return result
}

func decodeLabels(_ path: String) -> [String: String] {
    guard FileManager.default.fileExists(atPath: path) else { return [:] }
    let decoder = JSONDecoder()
    var result: [String: String] = [:]
    for line in readLines(path) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let data = line.data(using: .utf8),
              let item = try? decoder.decode(LabelLine.self, from: data) else { continue }
        result[item.mid] = item.label
    }
    return result
}

func appendLabel(_ label: LabelLine, to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard var data = try? encoder.encode(label) else { return }
    data.append(0x0A)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: data)
        return
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

// MARK: - Label

func runLabel(postsPath: String, labelsPath: String) {
    let posts = decodeCorpus(postsPath)
    var labels = decodeLabels(labelsPath)
    guard !posts.isEmpty else {
        fail("no posts in \(postsPath)")
    }
    let pending = posts.filter { labels[$0.mid] == nil }
    print("corpus: \(posts.count) posts, \(pending.count) unlabelled")
    print("labels: \(labelsPath)")
    print("")

    let formatter = ISO8601DateFormatter()
    var saved = 0
    for (offset, post) in pending.enumerated() {
        print(String(repeating: "─", count: 72))
        let date = formatter.date(from: post.createdAt)
        let dateText = date.map { ISO8601DateFormatter().string(from: $0) } ?? post.createdAt
        print("[\(offset + 1)/\(pending.count)] \(post.screenName) · \(dateText)")
        if let verdict = post.verdict {
            let ad = post.adScore.map { String(format: "%.2f", $0) } ?? "?"
            let interest = post.interestScore.map { String(format: "%.2f", $0) } ?? "?"
            print("rules: \(verdict)  ad=\(ad) interest=\(interest)")
        }
        if let reasons = post.reasons, !reasons.isEmpty {
            print("why:   \(reasons.joined(separator: ", "))")
        }
        print("")
        let text = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        print(text.count > 600 ? String(text.prefix(600)) + "…" : text)
        print("")
        print("1 onTopic  2 offTopic  3 ad  4 pr  5 genericNews  6 lowInfo  7 unsure  s skip  q quit")
        print("> ", terminator: "")
        guard let raw = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            print("")
            break
        }
        if raw == "q" {
            print("")
            break
        }
        if raw == "s" || raw.isEmpty {
            continue
        }
        let index: Int?
        switch raw {
        case "1": index = 0
        case "2": index = 1
        case "3": index = 2
        case "4": index = 3
        case "5": index = 4
        case "6": index = 5
        case "7": index = 6
        default: index = nil
        }
        guard let index else {
            print("unknown key, skipped")
            continue
        }
        let label = labelOrder[index]
        labels[post.mid] = label
        appendLabel(
            LabelLine(mid: post.mid, label: label, at: ISO8601DateFormatter().string(from: Date())),
            to: labelsPath
        )
        saved += 1
        print("→ \(label)")
    }
    print("")
    print("saved \(saved) labels; total labelled \(labels.count)/\(posts.count)")
}

// MARK: - Evaluate

struct Sample {
    var uid: String
    var label: String
    var adScore: Double
    var interestScore: Double
}

func collapsed(_ verdict: String?) -> Bool {
    verdict == "filtered" || verdict == "lowConfidence" || verdict == "offTopic"
}

func runEvaluate(postsPath: String, labelsPath: String) {
    let posts = decodeCorpus(postsPath)
    let labels = decodeLabels(labelsPath)
    let samples: [Sample] = posts.compactMap { post in
        guard let label = labels[post.mid], label != "unsure" else { return nil }
        return Sample(
            uid: post.uid,
            label: label,
            adScore: post.adScore ?? 0,
            interestScore: post.interestScore ?? 0
        )
    }
    guard !samples.isEmpty else {
        fail("no labelled samples; run `label` first")
    }

    let onTopic = samples.filter { $0.label == "onTopic" }
    let ads = samples.filter { $0.label == "ad" }
    let offTopic = samples.filter {
        $0.label == "offTopic" || $0.label == "genericNews" || $0.label == "lowInfo"
    }
    let nonAds = samples.filter { $0.label != "ad" }

    let kept = onTopic.filter { $0.interestScore >= 0.45 && $0.adScore < 0.60 }
    let adRecall = ads.filter { $0.adScore >= 0.60 }
    let adFalsePositives = nonAds.filter { $0.adScore >= 0.60 }
    let downgraded = offTopic.filter { $0.interestScore < 0.25 }

    func ratio(_ value: Int, _ total: Int) -> String {
        guard total > 0 else { return "n/a" }
        return String(format: "%.1f%% (%d/%d)", 100.0 * Double(value) / Double(total), value, total)
    }

    print("samples: \(samples.count)  accounts: \(Set(samples.map(\.uid)).count)")
    let byAccount = Dictionary(grouping: samples, by: \.uid)
    for (uid, group) in byAccount.sorted(by: { $0.key < $1.key }) {
        print("  \(uid): \(group.count)")
    }
    print("")
    print("onTopic kept:      \(ratio(kept.count, onTopic.count))   gate ≥ 95%")
    print("ad recall:         \(ratio(adRecall.count, ads.count))   gate ≥ 90%")
    print("ad false positive: \(ratio(adFalsePositives.count, nonAds.count))   gate ≤ 2%")
    print("offTopic collapsed:\(ratio(downgraded.count, offTopic.count))   gate ≥ 70%")
    print("")

    // Threshold sweep. The weights are frozen in the app; the two decision
    // thresholds are what an operator can actually tune without a rebuild.
    var best: (score: Double, ad: Double, interest: Double)?
    var ad = 0.35
    while ad <= 0.90 {
        var interest = 0.20
        while interest <= 0.70 {
            let keptCount = onTopic.filter { $0.adScore < ad && $0.interestScore >= interest }.count
            let recall = ads.filter { $0.adScore >= ad }.count
            let precision = ads.isEmpty ? 1 : Double(recall) / Double(recall + nonAds.filter { $0.adScore >= ad }.count)
            let downgradedCount = offTopic.filter { $0.adScore >= ad || $0.interestScore < max(0.25, interest - 0.20) }.count
            let score = 0.5 * (onTopic.isEmpty ? 1 : Double(keptCount) / Double(onTopic.count))
                + 0.3 * (ads.isEmpty ? 1 : Double(recall) / Double(ads.count) * 0.5 + precision * 0.5)
                + 0.2 * (offTopic.isEmpty ? 1 : Double(downgradedCount) / Double(offTopic.count))
            if best == nil || score > best!.score {
                best = (score, ad, interest)
            }
            interest += 0.05
        }
        ad += 0.05
    }
    if let best {
        print(String(format: "suggested thresholds: ad ≥ %.2f, interest ≥ %.2f (objective %.3f)", best.ad, best.interest, best.score))
    }
    print("")

    let failures = samples.filter { sample in
        switch sample.label {
        case "onTopic": return sample.interestScore < 0.45 || sample.adScore >= 0.60
        case "ad": return sample.adScore < 0.60
        default: return sample.interestScore >= 0.25 && sample.adScore < 0.60
        }
    }
    if !failures.isEmpty {
        print("failures (\(failures.count)):")
        for sample in failures.prefix(40) {
            print(String(format: "  [%@] ad=%.2f interest=%.2f", sample.label, sample.adScore, sample.interestScore))
        }
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

switch command {
case "label":
    guard arguments.count >= 2 else { usage() }
    var out = "labels.jsonl"
    if let flagIndex = arguments.firstIndex(of: "--out"), arguments.count > flagIndex + 1 {
        out = arguments[flagIndex + 1]
    }
    runLabel(postsPath: arguments[1], labelsPath: out)
case "evaluate":
    guard arguments.count >= 3 else { usage() }
    runEvaluate(postsPath: arguments[1], labelsPath: arguments[2])
default:
    usage()
}

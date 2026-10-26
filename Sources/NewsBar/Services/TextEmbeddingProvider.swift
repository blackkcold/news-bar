import Foundation
import NaturalLanguage

protocol TextEmbeddingProvider: Sendable {
    var identifier: String { get }
    func vector(for text: String, language: String) async -> [Double]?
}

/// Optional system capability probe. No asset-download API is ever called.
/// This provider is evaluation-only until the bilingual quality gate passes.
actor SystemSentenceEmbeddingProvider: TextEmbeddingProvider {
    nonisolated let identifier = "apple-system-sentence-v1"
    private var models: [String: NLEmbedding] = [:]
    private var unavailable: Set<String> = []
    private var cache: [String: [Double]] = [:]

    func vector(for text: String, language: String) -> [Double]? {
        let key = ContentIdentity.digest(identifier + ":" + language + ":" + text)
        if let cached = cache[key] { return cached }
        guard !unavailable.contains(language), !text.isEmpty, text.count <= 2000 else { return nil }
        let nlLanguage: NLLanguage = language == "zh" ? .simplifiedChinese : .english
        if models[language] == nil {
            guard NLEmbedding.currentSentenceEmbeddingRevision(for: nlLanguage) > 0,
                  let model = NLEmbedding.sentenceEmbedding(for: nlLanguage) else {
                unavailable.insert(language)
                return nil
            }
            models[language] = model
        }
        guard let vector = models[language]?.vector(for: text), vector.allSatisfy(\.isFinite) else { return nil }
        if cache.count >= 1024 { cache = [:] }
        cache[key] = vector
        return vector
    }
}

struct SemanticTriplet: Sendable {
    let language: String
    let anchor: String
    let related: String
    let unrelated: String
}

struct SemanticEvaluationReport: Codable, Sendable {
    let providerID: String
    let total: Int
    let covered: Int
    let chineseCovered: Int
    let chineseTotal: Int
    let correct: Int
    let baselineCorrect: Int
    var isEligible: Bool {
        total >= 12 && covered == total && chineseCovered == chineseTotal && chineseTotal >= 6
            && Double(correct) / Double(total) >= 0.8
            && Double(correct - baselineCorrect) / Double(total) >= 0.05
    }
    var description: String {
        "provider=\(providerID), coverage=\(covered)/\(total), Chinese=\(chineseCovered)/\(chineseTotal), correct=\(correct), tagBaselineCorrect=\(baselineCorrect), eligible=\(isEligible)"
    }
}

enum SemanticEvaluation {
    static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
        let normA = sqrt(a.reduce(0) { $0 + $1 * $1 })
        let normB = sqrt(b.reduce(0) { $0 + $1 * $1 })
        guard normA.isFinite, normB.isFinite, normA > 0, normB > 0 else { return nil }
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        return max(-1, min(1, dot / normA / normB))
    }

    static func evaluate(provider: any TextEmbeddingProvider, triplets: [SemanticTriplet]) async -> SemanticEvaluationReport {
        var covered = 0, chineseCovered = 0, correct = 0, baselineCorrect = 0
        func tagSimilarity(_ a: String, _ b: String) -> Double {
            let aa = TitleFeatures.tags(a), bb = TitleFeatures.tags(b)
            let union = aa.union(bb)
            return union.isEmpty ? 0 : Double(aa.intersection(bb).count) / Double(union.count)
        }
        for triplet in triplets {
            if tagSimilarity(triplet.anchor, triplet.related) > tagSimilarity(triplet.anchor, triplet.unrelated) { baselineCorrect += 1 }
            guard let a = await provider.vector(for: triplet.anchor, language: triplet.language),
                  let positive = await provider.vector(for: triplet.related, language: triplet.language),
                  let negative = await provider.vector(for: triplet.unrelated, language: triplet.language),
                  let pos = cosine(a, positive), let neg = cosine(a, negative) else { continue }
            covered += 1
            if triplet.language == "zh" { chineseCovered += 1 }
            if pos > neg { correct += 1 }
        }
        return SemanticEvaluationReport(providerID: provider.identifier, total: triplets.count, covered: covered,
                                         chineseCovered: chineseCovered, chineseTotal: triplets.filter { $0.language == "zh" }.count,
                                         correct: correct, baselineCorrect: baselineCorrect)
    }

    /// Fixed before any model evaluation; includes synonyms and same-entity /
    /// different-event negatives. Small acceptance smoke set, not proof of quality.
    static let acceptanceTriplets: [SemanticTriplet] = [
        SemanticTriplet(language: "zh", anchor: "新款电动汽车续航提升", related: "新能源轿车一次充电行驶更远", unrelated: "足球联赛冠军出炉"),
        SemanticTriplet(language: "zh", anchor: "人工智能模型开放源代码", related: "大模型向开发者开放权重", unrelated: "暴雨导致航班取消"),
        SemanticTriplet(language: "zh", anchor: "苹果发布新款手机", related: "苹果推出下一代 iPhone", unrelated: "苹果公司季度营收下降"),
        SemanticTriplet(language: "zh", anchor: "央行下调贷款利率", related: "借贷成本因降息而降低", unrelated: "医院启用新的治疗方案"),
        SemanticTriplet(language: "zh", anchor: "火箭成功发射卫星", related: "航天运载器将卫星送入轨道", unrelated: "卫星公司股票价格下跌"),
        SemanticTriplet(language: "zh", anchor: "台风登陆沿海地区", related: "热带气旋抵达海岸带来强风", unrelated: "电影节公布获奖名单"),
        SemanticTriplet(language: "en", anchor: "Electric car battery range improves", related: "New EV travels farther on one charge", unrelated: "Football club wins league final"),
        SemanticTriplet(language: "en", anchor: "Open source language model released", related: "Developers can download the new AI model weights", unrelated: "Storm cancels flights"),
        SemanticTriplet(language: "en", anchor: "Apple launches a new iPhone", related: "Apple unveils its next smartphone", unrelated: "Apple quarterly earnings decline"),
        SemanticTriplet(language: "en", anchor: "Central bank reduces interest rates", related: "Borrowing costs fall after rate cut", unrelated: "Doctors introduce a new therapy"),
        SemanticTriplet(language: "en", anchor: "Rocket launches a satellite into orbit", related: "Space mission deploys a satellite successfully", unrelated: "Satellite company shares fall"),
        SemanticTriplet(language: "en", anchor: "Typhoon makes landfall on the coast", related: "Tropical cyclone brings strong winds ashore", unrelated: "Film festival announces award winners")
    ]
}

import Foundation

/// The synthesis prompt and the validator must agree on one evidence ID for
/// one quote. Both sides therefore derive their ordered candidate list here:
/// same URL whitelist, same normalized quote, same deduplication, same order.
enum EvidenceIdentity {
    struct Key: Hashable {
        let canonicalURL: String
        let normalizedQuote: String
    }

    static func key(for candidate: EvidenceCandidate) -> Key? {
        let canonical = ContentIdentity.canonicalURL(candidate.url)
        guard !canonical.isEmpty else { return nil }
        let quote = QuoteVerifier.normalize(candidate.quote)
        guard !quote.isEmpty else { return nil }
        return Key(canonicalURL: canonical, normalizedQuote: quote)
    }

    /// Order-preserving candidates that are eligible to become evidence.
    /// `allowedURLs` uses canonical URLs, exactly like `ReportValidationInput`.
    static func ordered(
        _ candidates: [EvidenceCandidate],
        allowedURLs: Set<String>? = nil
    ) -> [EvidenceCandidate] {
        var seen: Set<Key> = []
        var output: [EvidenceCandidate] = []
        for candidate in candidates {
            guard let key = key(for: candidate) else { continue }
            if let allowedURLs, !allowedURLs.contains(key.canonicalURL) { continue }
            guard seen.insert(key).inserted else { continue }
            output.append(candidate)
        }
        return output
    }

    /// Accepts the shapes models actually emit: `E1`, `e1`, `E01`, `1`,
    /// `[E1]`, `E1,` and `E 1`. Anything else is left unresolved.
    static func normalizedID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>\"'# .,;:"))
        guard !value.isEmpty else { return nil }

        let upper = value.uppercased()
        var digits = upper
        if upper.hasPrefix("E") {
            digits = String(upper.dropFirst())
            digits = digits.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        }
        guard !digits.isEmpty,
              digits.allSatisfy(\.isNumber),
              let number = Int(digits),
              number > 0 else { return nil }
        return "E\(number)"
    }

    /// Normalizes a whole citation array and tolerates a model that packs
    /// several IDs into one string (`"E1, E2"`).
    static func normalizedIDs(_ rawValues: [String]) -> [String] {
        var output: [String] = []
        for raw in rawValues {
            if let id = normalizedID(raw) {
                output.append(id)
                continue
            }
            for part in raw.split(whereSeparator: { ",;/、 ".contains($0) }) {
                if let id = normalizedID(String(part)) {
                    output.append(id)
                }
            }
        }
        return output
    }
}

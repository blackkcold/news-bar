import Foundation

/// Topic identity and near-duplicate detection.
///
/// Exact identity is `SHA256(normalized title)`. Fuzzy merging is deliberately
/// strict: 0.92 Jaccard similarity, a 48-hour window, the same seed domain, and
/// only between automatically-created records. A manual record is never merged
/// implicitly — the user can always delete a wrong duplicate instead.
enum TopicFingerprint {
    static let fuzzyMergeThreshold = 0.92
    static let fuzzyMergeWindow: TimeInterval = 48 * 3600

    /// Removes `#`, punctuation, symbols and emoji; folds width and case;
    /// collapses whitespace. Letters, digits, marks and inner spaces remain.
    static func normalized(_ title: String) -> String {
        let folded = title
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var output = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if isWhitespace(scalar) {
                if !output.isEmpty { pendingSpace = true }
                continue
            }
            guard isKept(scalar) else { continue }
            if pendingSpace, !output.isEmpty {
                output.append(" ")
            }
            pendingSpace = false
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    static func key(for title: String) -> String {
        ContentIdentity.digest("topic-v1\n" + normalized(title))
    }

    /// CJK bigrams plus Latin/digit word tokens, compared with Jaccard.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(in: normalized(lhs))
        let right = tokens(in: normalized(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    /// Fuzzy duplicate policy for automatically-created records only.
    static func shouldFuzzyMerge(
        title: String,
        seedURL: String?,
        source: NewsSource,
        origin: ResearchOrigin,
        with existing: ResearchRecord,
        now: Date = Date()
    ) -> Bool {
        guard origin.isAutomatic, existing.origin.isAutomatic else { return false }
        guard abs(now.timeIntervalSince(existing.lastSeenAt)) <= fuzzyMergeWindow else { return false }

        let candidateDomain = domain(for: seedURL) ?? domain(for: source)
        let existingDomain = domain(for: existing.seed.url) ?? domain(for: existing.seed.source)
        guard let candidateDomain, let existingDomain, candidateDomain == existingDomain else {
            return false
        }

        let normalizedTitle = normalized(title)
        var best = similarity(normalizedTitle, existing.topic)
        for alias in existing.aliases {
            best = max(best, similarity(normalizedTitle, alias))
        }
        return best >= fuzzyMergeThreshold
    }

    private static func tokens(in normalized: String) -> Set<String> {
        var tokens: Set<String> = []
        var latin = ""
        var cjkCharacters: [String] = []

        func flushLatin() {
            guard !latin.isEmpty else { return }
            tokens.insert("w:" + latin)
            latin = ""
        }

        func flushCJK() {
            if cjkCharacters.count == 1 {
                tokens.insert("c:" + cjkCharacters[0])
            } else if cjkCharacters.count > 1 {
                for index in 0..<(cjkCharacters.count - 1) {
                    tokens.insert("c:" + cjkCharacters[index] + cjkCharacters[index + 1])
                }
            }
            cjkCharacters.removeAll(keepingCapacity: true)
        }

        for scalar in normalized.unicodeScalars {
            if isCJK(scalar) {
                flushLatin()
                cjkCharacters.append(String(scalar))
            } else if isWhitespace(scalar) {
                flushLatin()
                flushCJK()
            } else {
                flushCJK()
                latin.unicodeScalars.append(scalar)
            }
        }
        flushLatin()
        flushCJK()
        return tokens
    }

    private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana / Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xAC00...0xD7AF:   // Hangul
            return true
        default:
            return false
        }
    }

    private static func domain(for url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        let domain = SourceTierCatalog.registrableDomain(host)
        return domain.isEmpty ? nil : domain
    }

    private static func domain(for source: NewsSource) -> String? {
        switch source {
        case .weibo:
            return "weibo.com"
        case .bilibili:
            return "bilibili.com"
        case let .rss(_, url):
            return domain(for: url)
        }
    }
}

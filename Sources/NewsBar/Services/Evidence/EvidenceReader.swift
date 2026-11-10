import Foundation

enum ReadStatus: Equatable, Sendable {
    case read(characters: Int)
    case tooShort(characters: Int)
    case failed(PageReadFailure)
    case skipped
}

struct ReadResult: Equatable, Sendable {
    var sources: [AISearchSource]
    var statuses: [ReadStatus]
    /// Successful reads before deduplication. A duplicate was still read, so
    /// "read 5 · adopted 3" is honest even when two pages repeat.
    var readCount: Int
}

/// Turns candidates into sources. Reads until `readLimit` successes, not until
/// `readLimit` attempts: a failed page must not leave a hole in the answer when
/// a later candidate is readable.
enum EvidenceReader {
    typealias ReadHandler = @Sendable (SearchHit) async throws -> PageReadOutcome

    static func read(
        candidates: [EvidencePageCandidate],
        read: ReadHandler,
        readLimit: Int,
        onRead: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> ReadResult {
        var statuses = Array(repeating: ReadStatus.skipped, count: candidates.count)
        var sources: [AISearchSource] = []
        var readCount = 0
        let limit = max(1, readLimit)
        let total = candidates.count

        for (offset, candidate) in candidates.enumerated() {
            if Task.isCancelled { break }
            if readCount >= limit { break }
            await onRead(offset + 1, total)

            let outcome: PageReadOutcome
            do {
                outcome = try await read(candidate.hit)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome = .failed(PageReader.failure(from: error))
            }

            switch outcome {
            case .document(let document):
                let text = normalizedText(document.text)
                guard text.count >= PageReader.minScrapedCharacters else {
                    statuses[offset] = .tooShort(characters: text.count)
                    continue
                }
                let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
                sources.append(
                    AISearchSource(
                        index: sources.count + 1,
                        url: document.url,
                        title: title.isEmpty ? candidate.hit.title : title,
                        text: text,
                        publishedAt: document.publishedAt ?? candidate.hit.publishedAt,
                        fetchedAt: document.fetchedAt,
                        origin: .web,
                        provider: candidate.hit.provider
                    )
                )
                readCount += 1
                statuses[offset] = .read(characters: text.count)
            case .tooShort(let characters):
                statuses[offset] = .tooShort(characters: characters)
            case .failed(let failure):
                statuses[offset] = .failed(failure)
            }
        }

        return ReadResult(
            sources: EvidenceDeduplicator.markDuplicates(sources),
            statuses: statuses,
            readCount: readCount
        )
    }

    /// Trim and collapse horizontal whitespace, but keep paragraph breaks:
    /// the answer prompt and the quote verifier both rely on line structure.
    static func normalizedText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum EvidenceDeduplicator {
    /// Keeps duplicates in the list, marked, so the reader can see why a page
    /// was not used. A duplicate never counts as independent corroboration.
    static func markDuplicates(_ sources: [AISearchSource]) -> [AISearchSource] {
        var result: [AISearchSource] = []
        for source in sources {
            if let original = result.first(where: { isDuplicate(source, of: $0) }) {
                result.append(source.markingDuplicate(of: original.id))
            } else {
                result.append(source)
            }
        }
        return result
    }

    static func isDuplicate(_ lhs: AISearchSource, of rhs: AISearchSource) -> Bool {
        if lhs.id == rhs.id { return true }

        let leftTitle = normalizedTitle(lhs.title)
        let rightTitle = normalizedTitle(rhs.title)
        if !leftTitle.isEmpty, leftTitle == rightTitle, lhs.host == rhs.host {
            return true
        }

        return jaccard(lhs.text, rhs.text) >= 0.75
    }

    /// Five-character shingles over the first 2,000 characters. Character
    /// shingles work for Chinese and English without a tokenizer; the cost is
    /// negligible for the at-most-eleven candidates of one run.
    static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = shingles(lhs)
        let right = shingles(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(union)
    }

    static func shingles(_ text: String) -> Set<String> {
        let characters = Array(text.lowercased().prefix(2_000))
        guard characters.count >= 5 else { return [] }
        var result = Set<String>()
        for index in 0...(characters.count - 5) {
            result.insert(String(characters[index..<(index + 5)]))
        }
        return result
    }

    static func normalizedTitle(_ title: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar.properties.isIdeographic {
                view.append(scalar)
            }
        }
        return String(String(view).prefix(80))
    }
}

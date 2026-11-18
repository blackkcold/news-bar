import Foundation

/// Local-only search index. It stores short snippets, never raw fetched page
/// text. The file is rebuildable from the authoritative stores.
actor WorkspaceSearchIndex {
    static let shared = WorkspaceSearchIndex()
    static let snippetLimit = 400

    private struct Snapshot: Codable {
        var version = 1
        var updatedAt: Date
        var documents: [WorkspaceSearchDocument]

        enum CodingKeys: String, CodingKey {
            case version, updatedAt, documents
        }
    }

    private let fileURL: URL
    private var documents: [String: WorkspaceSearchDocument] = [:]
    private var loaded = false
    /// Bumped by `beginRebuild` and `reset`. A rebuild started before a clear
    /// cannot publish its stale snapshot.
    private var generation = 0

    init(fileURL: URL = ResearchPaths.workspaceSearchIndexFile) {
        self.fileURL = fileURL
    }

    func beginRebuild() -> Int {
        generation += 1
        return generation
    }

    func rebuild(
        subjects: [WorkspaceSubject],
        records: [ResearchRecord],
        events: [NewsEvent],
        answers: [AISearchArchiveEntry],
        now: Date,
        generation expected: Int
    ) async -> Bool {
        var docs: [String: WorkspaceSearchDocument] = [:]

        func insert(_ doc: WorkspaceSearchDocument) {
            docs[doc.id] = doc
        }

        let subjectByRecord: [String: String] = Dictionary(
            subjects.flatMap { subject in
                subject.researchRecordIDs.map { ($0, subject.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let subjectByEvent: [String: String] = Dictionary(
            subjects.flatMap { subject in
                subject.eventIDs.map { ($0, subject.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        for subject in subjects {
            let aliasText = subject.normalizedAliases.joined(separator: " · ")
            insert(
                WorkspaceSearchDocument(
                    id: "subject:\(subject.id)",
                    subjectID: subject.id,
                    kind: .subject,
                    title: subject.title,
                    body: Self.snippet(aliasText),
                    url: nil,
                    updatedAt: subject.lastActivityAt
                )
            )
        }

        for record in records {
            guard let report = record.report else { continue }
            let subjectID = subjectByRecord[record.id]
            let body = [
                // Keep the source article discoverable from the same local
                // query as its report. The news result remains a separate,
                // higher-priority hit in the reader search surface.
                record.seed.title,
                record.aliases.joined(separator: " · "),
                report.summary,
                report.overview,
                report.limitations,
            ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            insert(
                WorkspaceSearchDocument(
                    id: "report:\(record.id)",
                    subjectID: subjectID,
                    kind: .report,
                    title: record.topic,
                    body: Self.snippet(body),
                    url: record.seed.url,
                    updatedAt: report.generatedAt ?? record.updatedAt
                )
            )

            for item in report.evidence {
                let id = "evidence:" + ContentIdentity.digest(
                    "research\n\(item.canonicalURL)\n\(QuoteVerifier.normalize(item.quote))"
                )
                insert(
                    WorkspaceSearchDocument(
                        id: id,
                        subjectID: subjectID,
                        kind: .evidence,
                        title: item.title.isEmpty ? item.domain : item.title,
                        body: Self.snippet(item.quote),
                        url: item.url,
                        updatedAt: item.publishedAt ?? item.fetchedAt
                    )
                )
            }
        }

        for event in events {
            guard let subjectID = subjectByEvent[event.id] else { continue }
            for item in event.evidence {
                let canonical = ContentIdentity.canonicalURL(item.url)
                let id = "evidence:" + ContentIdentity.digest(
                    "event\n\(canonical)\n\(QuoteVerifier.normalize(item.excerpt))"
                )
                insert(
                    WorkspaceSearchDocument(
                        id: id,
                        subjectID: subjectID,
                        kind: .evidence,
                        title: item.title.isEmpty ? item.sourceName : item.title,
                        body: Self.snippet(item.excerpt),
                        url: item.url,
                        updatedAt: item.publishedAt ?? item.fetchedAt
                    )
                )
            }
        }

        for entry in answers {
            // Selection lookups can quote a private page. They stay out of the
            // persistent local index; explicit reader searches already store
            // only the answer text in the archive.
            guard entry.origin == .readerSearch else { continue }
            let body = ([entry.answer.oneLine]
                + entry.answer.blocks.map { block in
                    [block.heading, block.body].compactMap { $0 }.joined(separator: " ")
                })
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            insert(
                WorkspaceSearchDocument(
                    id: "answer:\(entry.id.uuidString)",
                    subjectID: nil,
                    kind: .answer,
                    title: entry.query,
                    body: Self.snippet(body),
                    url: entry.pageURL,
                    updatedAt: entry.createdAt
                )
            )
        }

        guard expected == generation else { return false }
        documents = docs
        loaded = true
        persist(now: now)
        return true
    }

    func upsert(_ newDocuments: [WorkspaceSearchDocument]) async {
        loadIfNeeded()
        for document in newDocuments {
            documents[document.id] = document
        }
        persist(now: Date())
    }

    func remove(subjectID: String) async {
        loadIfNeeded()
        documents = documents.filter { $0.value.subjectID != subjectID }
        persist(now: Date())
    }

    func reset() async {
        generation += 1
        documents.removeAll()
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    func search(
        text: String,
        scopes: WorkspaceSearchScope,
        limit: Int
    ) async -> WorkspaceSearchResponse {
        loadIfNeeded()
        let query = TopicFingerprint.normalized(text)
        guard !query.isEmpty else {
            return WorkspaceSearchResponse(results: [], isLocalOnly: true, truncated: false)
        }
        let tokens = query.split(separator: " ").map(String.init)

        var matches: [(document: WorkspaceSearchDocument, score: Double)] = []
        for document in documents.values {
            guard scopes.contains(Self.scope(for: document.kind)) else { continue }
            let title = TopicFingerprint.normalized(document.title)
            let body = TopicFingerprint.normalized(document.body)
            var score: Double = 0
            if title.hasPrefix(query) {
                score = 300
            } else if title.contains(query) {
                score = 200
            } else if body.contains(query) {
                score = 100
            } else if !tokens.isEmpty,
                      tokens.allSatisfy({ title.contains($0) || body.contains($0) }) {
                score = 40
            }
            guard score > 0 else { continue }
            matches.append((document, score))
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.document.updatedAt != rhs.document.updatedAt {
                return lhs.document.updatedAt > rhs.document.updatedAt
            }
            return lhs.document.id < rhs.document.id
        }

        let capped = max(0, limit)
        let visible = matches.prefix(capped)
        let results = visible.compactMap { Self.result(from: $0.document) }
        return WorkspaceSearchResponse(
            results: results,
            isLocalOnly: true,
            truncated: matches.count > capped
        )
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            return
        }
        documents = Dictionary(
            uniqueKeysWithValues: snapshot.documents.map { ($0.id, $0) }
        )
    }

    private func persist(now: Date) {
        let snapshot = Snapshot(
            version: 1,
            updatedAt: now,
            documents: documents.values.sorted { $0.id < $1.id }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? PrivateFile.write(data, to: fileURL, durable: true)
    }

    private static func snippet(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(snippetLimit))
    }

    private static func scope(for kind: WorkspaceSearchDocumentKind) -> WorkspaceSearchScope {
        switch kind {
        case .subject: return .subjects
        case .report: return .reports
        case .evidence: return .evidence
        case .answer: return .answers
        }
    }

    private static func result(from document: WorkspaceSearchDocument) -> WorkspaceSearchResult? {
        switch document.kind {
        case .subject:
            return .subject(
                id: document.subjectID ?? document.id,
                title: document.title,
                snippet: document.body,
                isFollowed: false
            )
        case .report:
            return .report(
                recordID: String(document.id.dropFirst("report:".count)),
                subjectID: document.subjectID ?? "",
                title: document.title,
                snippet: document.body,
                generatedAt: document.updatedAt
            )
        case .evidence:
            return .evidence(
                id: document.id,
                subjectID: document.subjectID ?? "",
                title: document.title,
                snippet: document.body,
                url: document.url ?? ""
            )
        case .answer:
            return .answer(
                id: document.id,
                query: document.title,
                snippet: document.body,
                createdAt: document.updatedAt
            )
        }
    }
}

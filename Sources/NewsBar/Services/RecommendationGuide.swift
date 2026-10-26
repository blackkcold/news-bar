import Foundation

/// One localized section of the bundled recommendation guide.
struct RecommendationGuideSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
}

enum RecommendationGuideError: Error, Equatable, Sendable, CustomStringConvertible {
    case resourceMissing
    case unreadable(String)
    case invalidDocument(String)
    case missingSection(String)

    var description: String {
        switch self {
        case .resourceMissing:
            return "Bundled recommendation guide resource is missing."
        case .unreadable(let reason):
            return "Bundled recommendation guide could not be read: \(reason)"
        case .invalidDocument(let reason):
            return "Bundled recommendation guide is invalid: \(reason)"
        case .missingSection(let id):
            return "Bundled recommendation guide is missing the section \(id)."
        }
    }
}

/// The decoded, validated single source of truth for the offline guide.
/// `RecommendationGuideSection` text is shared by the native settings view and
/// the generated repository Markdown; no separate prose copy is maintained.
struct RecommendationGuideDocument: Codable, Sendable {
    static let requiredSectionIDs = [
        "overview",
        "features",
        "scoring",
        "diversity",
        "telemetry",
        "privacy",
        "controls",
        "limitations",
    ]

    let schemaVersion: Int
    let title: LocalizedText
    let notice: LocalizedText
    let sections: [LocalizedSection]

    struct LocalizedText: Codable, Equatable, Sendable {
        let zh: String
        let en: String

        func value(for language: AppLanguage) -> String {
            switch language {
            case .zh: return zh
            case .en: return en
            }
        }
    }

    struct LocalizedSection: Codable, Equatable, Sendable {
        let id: String
        let title: LocalizedText
        let body: LocalizedText
    }
}

private final class RecommendationGuideBundleFinder {}

/// Offline loader for the guide shipped as an SPM resource bundle. The same
/// bundle is copied into `Contents/Resources` of packaged apps; lookup checks
/// those directories before falling back to the SwiftPM build layout, so tests
/// exercise the packaged shape rather than only `Bundle.module`.
enum RecommendationGuide {
    static let resourceBundleName = "NewsBar_NewsBar.bundle"
    static let resourceFileName = "recommendation-guide.json"

    /// The bundle cannot change while the app is running; decode once instead of
    /// re-reading and re-validating on every settings body evaluation.
    private static let cached: Result<RecommendationGuideDocument, RecommendationGuideError> = {
        do {
            return .success(try loadDocument(searchDirectories: defaultSearchDirectories))
        } catch let error as RecommendationGuideError {
            return .failure(error)
        } catch {
            return .failure(.invalidDocument(error.localizedDescription))
        }
    }()

    /// `false` when the bundle is absent or malformed. Callers should show an
    /// unavailable state instead of inventing guide text.
    static var isAvailable: Bool {
        if case .success = cached { return true }
        return false
    }

    /// Diagnostic only; the settings UI renders its own localized unavailable copy.
    static var unavailableReason: String? {
        if case .failure(let error) = cached { return String(describing: error) }
        return nil
    }

    static func sections(language: AppLanguage) -> [RecommendationGuideSection] {
        guard case .success(let document) = cached else { return [] }
        return document.sections.map {
            RecommendationGuideSection(
                id: $0.id,
                title: $0.title.value(for: language),
                body: $0.body.value(for: language)
            )
        }
    }

    /// Deterministic Markdown rendered from the bundled JSON. Repository docs
    /// are generated from this same text by `scripts/sync-recommendation-guide.sh`.
    static func markdown(language: AppLanguage) -> String {
        guard case .success(let document) = cached else { return "" }
        var output = "# \(document.title.value(for: language))\n\n"
        output += "> \(document.notice.value(for: language))\n\n"
        for section in document.sections {
            output += "## \(section.title.value(for: language))\n\n"
            output += section.body.value(for: language)
            output += "\n\n"
        }
        return output
    }

    static func document(searchDirectories: [URL]? = nil) throws -> RecommendationGuideDocument {
        try loadDocument(searchDirectories: searchDirectories ?? defaultSearchDirectories)
    }

    static var defaultSearchDirectories: [URL] {
        var directories: [URL] = []
        func add(_ url: URL?) {
            guard let url, !directories.contains(url) else { return }
            directories.append(url)
        }
        // Packaged app: Contents/Resources holds the copied SPM bundle.
        add(Bundle.main.resourceURL)
        // SwiftPM build and test layout: bundle sits next to the executable.
        add(Bundle.main.bundleURL)
        add(Bundle.main.bundleURL.deletingLastPathComponent())
        add(Bundle.main.executableURL?.deletingLastPathComponent())
        // `swift test` runs inside the xctest host, so Bundle.main is not the
        // package build directory. Resolve the test/module bundle instead; its
        // parent is where SwiftPM places `NewsBar_NewsBar.bundle`.
        add(Bundle(for: RecommendationGuideBundleFinder.self).resourceURL)
        add(Bundle(for: RecommendationGuideBundleFinder.self).bundleURL.deletingLastPathComponent())
        return directories
    }

    static func resourceBundleURL(searchDirectories: [URL]) -> URL? {
        for directory in searchDirectories {
            let bundleURL = directory.appendingPathComponent(resourceBundleName, isDirectory: true)
            let jsonURL = bundleURL.appendingPathComponent(resourceFileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                return bundleURL
            }
        }
        return nil
    }

    private static func loadDocument(searchDirectories: [URL]) throws -> RecommendationGuideDocument {
        guard let bundleURL = resourceBundleURL(searchDirectories: searchDirectories) else {
            throw RecommendationGuideError.resourceMissing
        }
        let jsonURL = bundleURL.appendingPathComponent(resourceFileName, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw RecommendationGuideError.unreadable(error.localizedDescription)
        }
        let raw: RecommendationGuideDocument
        do {
            raw = try JSONDecoder().decode(RecommendationGuideDocument.self, from: data)
        } catch {
            throw RecommendationGuideError.invalidDocument(error.localizedDescription)
        }
        try validate(raw)
        return raw
    }

    private static func validate(_ document: RecommendationGuideDocument) throws {
        guard document.schemaVersion == 1 else {
            throw RecommendationGuideError.invalidDocument("unsupported schema version \(document.schemaVersion)")
        }
        let ids = document.sections.map(\.id)
        for id in RecommendationGuideDocument.requiredSectionIDs where !ids.contains(id) {
            throw RecommendationGuideError.missingSection(id)
        }
        guard ids == RecommendationGuideDocument.requiredSectionIDs else {
            throw RecommendationGuideError.invalidDocument(
                "section ids must be exactly \(RecommendationGuideDocument.requiredSectionIDs) in order"
            )
        }
        guard isNonBlank(document.title.zh), isNonBlank(document.title.en),
              isNonBlank(document.notice.zh), isNonBlank(document.notice.en) else {
            throw RecommendationGuideError.invalidDocument("document title/notice is not fully translated")
        }
        for section in document.sections {
            guard isNonBlank(section.title.zh), isNonBlank(section.title.en),
                  isNonBlank(section.body.zh), isNonBlank(section.body.en) else {
                throw RecommendationGuideError.invalidDocument("section \(section.id) is not fully translated")
            }
        }
    }

    private static func isNonBlank(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

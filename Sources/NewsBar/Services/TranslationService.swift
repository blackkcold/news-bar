import Foundation

enum TranslationError: LocalizedError {
    case invalidURL
    case requestFailed
    case emptyResponse
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "error.invalidURL".localized
        case .requestFailed: return "error.requestFailed".localized
        case .emptyResponse: return "error.parseFailed".localized
        case .rateLimited: return "error.rateLimited".localized
        }
    }
}

/// Free translation via the MyMemory public API (no API key required).
/// Abstraction point so the provider can be swapped later without touching callers.
enum TranslationService {

    private struct MyMemoryResponse: Decodable {
        struct Data: Decodable {
            let translatedText: String?
        }
        let responseData: Data?
        let responseStatus: Int?
    }

    private static let baseURL = "https://api.mymemory.translated.net/get"
    private static let timeout: TimeInterval = 10

    /// Translate a single text from `sourceLang` to `targetLang`.
    /// Returns the translated text, or the original when translation is not needed
    /// (same language) or fails gracefully.
    static func translate(
        _ text: String,
        from sourceLang: String,
        to targetLang: String
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard sourceLang != targetLang else { return text }

        do {
            let translated = try await request(trimmed, from: sourceLang, to: targetLang)
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? text : cleaned
        } catch {
            NSLog("[TranslationService] translate failed: %@", error.localizedDescription)
            return text
        }
    }

    private static func request(
        _ text: String,
        from sourceLang: String,
        to targetLang: String
    ) async throws -> String {
        guard var components = URLComponents(string: baseURL) else {
            throw TranslationError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(sourceLang)|\(targetLang)")
        ]
        guard let url = components.url else {
            throw TranslationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("NewsBar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.requestFailed
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                throw TranslationError.rateLimited
            }
            throw TranslationError.requestFailed
        }

        let decoded = try JSONDecoder().decode(MyMemoryResponse.self, from: data)
        guard let translated = decoded.responseData?.translatedText,
              !translated.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return translated
    }
}

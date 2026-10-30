import XCTest
@testable import NewsBar

/// Live SSE probe. Skipped unless `NEWSBAR_SSE_PROBE=1`, because it makes a
/// real (tiny) billed request. Prints timing and shape only — never the key.
final class SSEProbeTests: XCTestCase {
    func testProbeOllamaCloud() async throws {
        guard ProcessInfo.processInfo.environment["NEWSBAR_SSE_PROBE"] == "1" else {
            throw XCTSkip("set NEWSBAR_SSE_PROBE=1 to run the live probe")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.newsbar.app")
        let store = EncryptedKeyStore(directory: support)
        let key = await store.readAPIKey(account: "ai-key-ollamaCloud") ?? ""
        guard !key.isEmpty else { return XCTFail("no key for ollamaCloud") }

        let model = UserDefaults(suiteName: "com.newsbar.app")?.string(forKey: "aiModel")
            ?? "deepseek-v4.1-flash:1017"
        var request = URLRequest(url: URL(string: "https://ollama.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "Reply with the single word: ok"]],
            "max_tokens": 16,
            "temperature": 0,
            "stream": true,
            "stream_options": ["include_usage": true],
        ])

        let start = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let ttfb = Date().timeIntervalSince(start)
        let http = response as! HTTPURLResponse
        var firstDelta: TimeInterval?
        var deltas = 0
        var sawUsage = false
        var sawDone = false
        var firstChunk = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if firstChunk.isEmpty { firstChunk = String(payload.prefix(160)) }
            if payload.contains("\"usage\"") { sawUsage = true }
            if payload == "[DONE]" { sawDone = true; continue }
            if payload.contains("\"content\"") {
                deltas += 1
                if firstDelta == nil { firstDelta = Date().timeIntervalSince(start) }
            }
        }
        let total = Date().timeIntervalSince(start)
        print("""
        SSE-PROBE provider=ollamaCloud model=\(model) status=\(http.statusCode) \
        type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "-") \
        ttfb=\(Int(ttfb * 1000))ms firstDelta=\(Int((firstDelta ?? 0) * 1000))ms \
        deltas=\(deltas) usage=\(sawUsage) done=\(sawDone) total=\(Int(total * 1000))ms
        SSE-PROBE first=\(firstChunk)
        """)
        XCTAssertEqual(http.statusCode, 200)
    }
}

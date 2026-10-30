import Foundation

/// One incremental piece of a model answer. Both wire formats map onto this,
/// so the services never branch on the provider.
enum AIChatStreamEvent: Equatable, Sendable {
    case text(String)
    case usage(AIUsage)
    case finished(truncated: Bool)
}

/// One server-sent event: an optional `event:` name and the joined `data:`
/// lines. Kept separate from parsing so the framing can be tested on its own.
struct SSEFrame: Equatable {
    var event: String?
    var data: String
}

/// Splits a byte-decoded buffer into complete SSE frames.
///
/// A frame ends at a blank line. Anything after the last blank line stays in
/// the buffer, which is what makes arbitrary chunk boundaries safe: a delta can
/// arrive split in the middle of a line and nothing is lost.
enum SSEDecoder {
    static func drain(_ buffer: inout String) -> [SSEFrame] {
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
        var frames: [SSEFrame] = []
        while let boundary = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<boundary.lowerBound])
            buffer = String(buffer[boundary.upperBound...])
            if let frame = frame(from: block) { frames.append(frame) }
        }
        return frames
    }

    /// The last frame of a stream may not end with a blank line.
    static func frame(from block: String) -> SSEFrame? {
        var event: String?
        var data: [String] = []
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard !data.isEmpty || event != nil else { return nil }
        return SSEFrame(event: event, data: data.joined(separator: "\n"))
    }
}

/// Maps a frame to zero or more stream events for the provider's wire format.
enum AIStreamParser {
    static func events(from frame: SSEFrame, format: AIProvider.ResponseFormat) -> [AIChatStreamEvent] {
        switch format {
        case .openAI: return openAI(frame)
        case .anthropic: return anthropic(frame)
        }
    }

    private static func openAI(_ frame: SSEFrame) -> [AIChatStreamEvent] {
        if frame.data == "[DONE]" { return [.finished(truncated: false)] }
        guard let data = frame.data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
            return []
        }
        var events: [AIChatStreamEvent] = []
        let choice = chunk.choices?.first
        if let text = choice?.delta?.content, !text.isEmpty {
            events.append(.text(text))
        }
        if let usage = AIUsage.from(openAI: chunk.usage) {
            events.append(.usage(usage))
        }
        if let reason = choice?.finishReason {
            events.append(.finished(truncated: reason == "length"))
        }
        return events
    }

    private static func anthropic(_ frame: SSEFrame) -> [AIChatStreamEvent] {
        guard let data = frame.data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(AnthropicStreamChunk.self, from: data) else {
            return []
        }
        switch chunk.type {
        case "content_block_delta":
            guard let text = chunk.delta?.text, !text.isEmpty else { return [] }
            return [.text(text)]
        case "message_start":
            guard let usage = AIUsage.from(anthropic: chunk.message?.usage) else { return [] }
            return [.usage(usage)]
        case "message_delta":
            var events: [AIChatStreamEvent] = []
            if let usage = AIUsage.from(anthropic: chunk.usage) {
                events.append(.usage(usage))
            }
            if let reason = chunk.delta?.stopReason {
                events.append(.finished(truncated: reason == "max_tokens"))
            }
            return events
        case "message_stop":
            return [.finished(truncated: false)]
        default:
            return []
        }
    }
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]?
    let usage: OpenAIUsagePayload?
}

private struct AnthropicStreamChunk: Decodable {
    struct Message: Decodable { let usage: AnthropicUsagePayload? }
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case stopReason = "stop_reason"
        }
    }
    let type: String?
    let message: Message?
    let delta: Delta?
    let usage: AnthropicUsagePayload?
}

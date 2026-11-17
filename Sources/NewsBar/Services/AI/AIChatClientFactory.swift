import Foundation

/// One place that builds the production `HTTPAIChatClient` for every AI entry
/// point. The factory does not unify prompts, timeouts or budgets: each caller
/// still passes the values its feature needs.
///
/// The only invariant it protects is accounting ownership:
/// - `unmetered` is for a client whose caller reserves/settles itself
///   (`ResearchPipeline` owns `.research`).
/// - `metered` attaches exactly one `AIChatQuota`, so an ordinary call cannot
///   bypass the shared `AIQuotaStore` budget.
enum AIChatClientFactory {
    /// A client with no quota hook. Use only when the caller reserves and
    /// settles the budget around the whole task; attaching a second hook would
    /// double-charge every dispatch.
    static func unmetered(
        connection: ResolvedAIConnection,
        apiKey: String,
        model: String,
        disableDeepSeekThinking: Bool = false,
        thinking: AIThinkingLevel? = nil,
        timeout: TimeInterval = 60
    ) -> HTTPAIChatClient {
        HTTPAIChatClient(
            connection: connection,
            apiKey: apiKey,
            model: model,
            disableDeepSeekThinking: disableDeepSeekThinking,
            thinking: thinking,
            timeout: timeout,
            quota: nil
        )
    }

    /// A client that reserves one dispatch and settles it with the measured
    /// usage. Passing `quota` keeps a caller's hand-built hook (or a test
    /// double); omitting it uses the standard `AIQuotaStore` wiring.
    static func metered(
        origin: AIQuotaOrigin,
        policy: AIQuotaPolicy,
        price: ModelPrice?,
        connection: ResolvedAIConnection,
        apiKey: String,
        model: String,
        disableDeepSeekThinking: Bool = false,
        thinking: AIThinkingLevel? = nil,
        timeout: TimeInterval = 60,
        quota: AIChatQuota? = nil
    ) -> HTTPAIChatClient {
        HTTPAIChatClient(
            connection: connection,
            apiKey: apiKey,
            model: model,
            disableDeepSeekThinking: disableDeepSeekThinking,
            thinking: thinking,
            timeout: timeout,
            quota: quota ?? .tracked(origin: origin, policy: policy, price: price)
        )
    }
}

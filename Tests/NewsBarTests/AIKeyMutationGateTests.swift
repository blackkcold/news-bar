import XCTest
@testable import NewsBar

final class AIKeyMutationGateTests: XCTestCase {
    @MainActor
    func testCustomCachedKeyRequiresTheSameEndpointBinding() {
        let context = AIKeyContext(
            providerID: "custom:fictional", account: "custom:fictional", revision: UUID(),
            endpointIdentity: "endpoint-A"
        )
        XCTAssertTrue(AIKeyAccess.mayUseCachedKey(context: context, cachedEndpointIdentity: "endpoint-A"))
        XCTAssertFalse(AIKeyAccess.mayUseCachedKey(context: context, cachedEndpointIdentity: "endpoint-B"))
        XCTAssertFalse(AIKeyAccess.mayUseCachedKey(context: context, cachedEndpointIdentity: nil))
        let builtin = AIKeyContext(providerID: "deepseek", account: "ai-key-deepseek", revision: UUID())
        XCTAssertTrue(AIKeyAccess.mayUseCachedKey(context: builtin, cachedEndpointIdentity: nil))
    }

    @MainActor
    func testProviderBoundKeyDoesNotSurviveEndpointChange() {
        let revision = UUID()
        let oldContext = AIKeyContext(
            providerID: "custom:fictional", account: "custom:fictional", revision: revision,
            endpointIdentity: "endpoint-A"
        )
        let newContext = AIKeyContext(
            providerID: "custom:fictional", account: "custom:fictional", revision: revision,
            endpointIdentity: "endpoint-B"
        )
        let bound = ProviderBoundKey(key: "fictional-key", context: oldContext)
        XCTAssertFalse(AIKeyAccess.isCurrent(bound, context: newContext, cachedKey: "fictional-key"))
        XCTAssertNotEqual(oldContext.inputContext, newContext.inputContext)
        let newerRevision = AIKeyContext(
            providerID: oldContext.providerID, account: oldContext.account, revision: UUID(),
            endpointIdentity: oldContext.endpointIdentity
        )
        XCTAssertEqual(oldContext.inputContext, newerRevision.inputContext)
    }

    @MainActor
    func testCatalogKeyIsNotCurrentAfterSwitchingBuiltinProvider() {
        let revision = UUID()
        let old = AIKeyContext(providerID: "deepseek", account: "ai-key-deepseek", revision: revision)
        let current = AIKeyContext(providerID: "ollamaCloud", account: "ai-key-ollama", revision: revision)
        let bound = ProviderBoundKey(key: "fictional-old-key", context: old)

        XCTAssertTrue(AIKeyAccess.isCurrent(bound, context: old, cachedKey: "fictional-old-key"))
        XCTAssertFalse(AIKeyAccess.isCurrent(bound, context: current, cachedKey: "fictional-old-key"))
        XCTAssertFalse(AIKeyAccess.isCurrent(bound, context: old, cachedKey: "fictional-new-key"))
    }

    @MainActor
    func testCatalogKeyIsNotCurrentAfterChangingTheCustomEndpoint() {
        let revision = UUID()
        let old = AIKeyContext(
            providerID: "custom:fictional", account: "custom:fictional", revision: revision,
            endpointIdentity: "endpoint-A"
        )
        let current = AIKeyContext(
            providerID: old.providerID, account: old.account, revision: revision,
            endpointIdentity: "endpoint-B"
        )
        let bound = ProviderBoundKey(key: "fictional-old-key", context: old)
        XCTAssertFalse(AIKeyAccess.isCurrent(bound, context: current, cachedKey: "fictional-old-key"))
    }

    func testSameAccountRemainsBlockedUntilEveryMutationFinishes() {
        var gate = AIKeyMutationGate()
        let first = UUID()
        let second = UUID()
        gate.begin(account: "ai-key-fictional", token: first)
        gate.begin(account: "ai-key-fictional", token: second)

        XCTAssertTrue(gate.isPending(account: "ai-key-fictional"))
        XCTAssertFalse(gate.isPending(account: "ai-key-other"))
        gate.finish(account: "ai-key-fictional", token: second)
        XCTAssertTrue(gate.isPending(account: "ai-key-fictional"))
        gate.finish(account: "ai-key-fictional", token: first)
        XCTAssertFalse(gate.isPending(account: "ai-key-fictional"))
    }

    func testFinishingAnUnknownMutationDoesNotUnblockTheAccount() {
        var gate = AIKeyMutationGate()
        let token = UUID()
        gate.begin(account: "ai-key-fictional", token: token)
        gate.finish(account: "ai-key-fictional", token: UUID())
        XCTAssertTrue(gate.isPending(account: "ai-key-fictional"))
        gate.finish(account: "ai-key-other", token: token)
        XCTAssertTrue(gate.isPending(account: "ai-key-fictional"))
    }

    func testMissingCustomProviderNeverFallsBackToBuiltinCredentials() {
        let providerID = "custom:missing-fictional-provider"
        XCTAssertEqual(AIProviderAccountPolicy.account(for: providerID), providerID)
        XCTAssertFalse(AIProviderAccountPolicy.canUseConnection(providerID: providerID, customProviderExists: false))
        XCTAssertNil(AIProviderAccountPolicy.credentialAccount(for: providerID, customProviderExists: false))
        XCTAssertTrue(AIProviderAccountPolicy.canUseConnection(providerID: providerID, customProviderExists: true))
        XCTAssertEqual(AIProviderAccountPolicy.credentialAccount(for: providerID, customProviderExists: true), providerID)
        XCTAssertEqual(AIProviderAccountPolicy.account(for: AIProvider.deepseek.rawValue), AIProvider.deepseek.apiKeyAccount())
    }

    func testUnknownBuiltinAndMalformedCustomCannotAccessAnotherProvidersCredentials() {
        let unknown = "future-fictional-provider"
        XCTAssertFalse(AIProviderAccountPolicy.canUseConnection(providerID: unknown, customProviderExists: false))
        XCTAssertNil(AIProviderAccountPolicy.credentialAccount(for: unknown, customProviderExists: false))
        XCTAssertNotEqual(AIProviderAccountPolicy.account(for: unknown), AIProvider.deepseek.apiKeyAccount())
        XCTAssertFalse(AIProviderAccountPolicy.canUseConnection(providerID: "custom:", customProviderExists: true))
        XCTAssertNil(AIProviderAccountPolicy.credentialAccount(for: "custom:", customProviderExists: true))
        XCTAssertEqual(
            AIProviderAccountPolicy.credentialAccount(for: AIProvider.deepseek.rawValue, customProviderExists: false),
            AIProvider.deepseek.apiKeyAccount()
        )
    }
}

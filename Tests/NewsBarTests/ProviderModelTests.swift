import XCTest
@testable import NewsBar

final class ProviderModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let connection = ResolvedAIConnection(baseURL: "https://provider.example/anthropic/v1/messages", responseFormat: .anthropic, authHeaderName: "x-api-key", authHeaderPrefix: "", apiVersion: "2023-06-01")

    func testDerivesCatalogEndpointsWithoutChangingCredentialOrigin() throws {
        let endpoints = try ProviderModelService.endpoints(providerID: "opencodeGo", connection: connection)
        XCTAssertEqual(endpoints.map { $0.url.absoluteString }, ["https://provider.example/anthropic/v1/models", "https://provider.example/v1/models"])
        let ollama = try ProviderModelService.endpoints(providerID: "ollamaCloud", connection: AIProvider.ollamaCloud.resolvedConnection())
        XCTAssertEqual(ollama.first?.url.absoluteString, "https://ollama.com/api/tags")
        let deepseek = try ProviderModelService.endpoints(providerID: "deepseek", connection: AIProvider.deepseek.resolvedConnection())
        XCTAssertEqual(deepseek.first?.url.absoluteString, "https://api.deepseek.com/models")
        let google = try ProviderModelService.endpoints(providerID: "googleAIStudio", connection: AIProvider.googleAIStudio.resolvedConnection())
        XCTAssertEqual(google.first?.url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models")
    }

    func testOllamaUsesExactReturnedIDsAndFiltersNonCompletionModels() throws {
        let page = try ProviderModelParser.parse(Data(#"{"models":[{"name":"deepseek-v4.1-flash","capabilities":["completion","thinking"]},{"name":"clef:27b","capabilities":["decision","vision"]},{"name":"gpt-oss:20b","capabilities":["completion"]}]}"#.utf8), format: .ollama)
        XCTAssertEqual(page.models.map(\.id), ["deepseek-v4.1-flash", "gpt-oss:20b"])
        XCTAssertFalse(page.models.contains { $0.id.contains(":cloud") })
    }

    func testSelectionAlwaysPrefersAvailableDeepSeekAndReplacesRetiredID() {
        let models = [ProviderModel(id: "gpt-oss:120b"), ProviderModel(id: "deepseek-v4.1-flash:1017"), ProviderModel(id: "deepseek-v4.1-flash")]
        XCTAssertEqual(ProviderModelSelection.preferred(in: models, current: "deepseek-v4-flash:cloud"), "deepseek-v4.1-flash")
        XCTAssertEqual(ProviderModelSelection.preferred(in: models, current: "gpt-oss:120b"), "deepseek-v4.1-flash")
        XCTAssertEqual(ProviderModelSelection.preferred(in: models, current: "deepseek-v4.1-flash:1017"), "deepseek-v4.1-flash:1017")
        XCTAssertEqual(ProviderModelSelection.preferred(in: [ProviderModel(id: "gemini-new")], current: "missing"), "gemini-new")
        XCTAssertNil(ProviderModelSelection.preferred(in: [], current: "deepseek-v4-flash"))
    }

    func testNativeGoogleFiltersCapabilitiesAndNormalizesOnlyResourcePrefix() throws {
        let page = try ProviderModelParser.parse(Data(#"{"models":[{"name":"models/gemini-latest","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-new","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#.utf8), format: .google)
        XCTAssertEqual(page.models.map(\.id), ["gemini-latest"])
        XCTAssertEqual(page.nextCursor, "next")
    }

    func testExplicitlyDisabledModelsAndMalformedIDsAreNotSelected() throws {
        let page = try ProviderModelParser.parse(Data(#"{"data":[{"id":"DeepSeek/New","enabled":false},{"id":"DeepSeek/Retired","status":"retired"},{"id":"deepseek\nmalicious"},{"id":"vendor/DeepSeek-VNext","output_modalities":["text"]},{"id":"image-only","output_modalities":["image"]}]}"#.utf8), format: .openAI)
        XCTAssertEqual(page.models.map(\.id), ["vendor/DeepSeek-VNext"])
        XCTAssertThrowsError(try ProviderModelParser.parse(Data(#"{"error":"not a model list"}"#.utf8), format: .openAI))
    }

    func testIncompletePaginationFailsInsteadOfInvalidatingModelsFromMissingPages() {
        XCTAssertThrowsError(try ProviderModelParser.parse(Data(#"{"data":[{"id":"model-one"}],"has_more":true}"#.utf8), format: .anthropic))
    }

    func testCacheIdentitySeparatesProvidersEndpointsAndCredentials() {
        let a = ProviderModelService.identity(providerID: "one", connection: connection, apiKey: "unit-key-a")
        XCTAssertNotEqual(a, ProviderModelService.identity(providerID: "one", connection: connection, apiKey: "unit-key-b"))
        XCTAssertNotEqual(a, ProviderModelService.identity(providerID: "two", connection: connection, apiKey: "unit-key-a"))
        XCTAssertFalse(a.contains("unit-key"))
    }

    func testCatalogRequestIsGETAndPaginationKeepsCredentialsInHeaders() async throws {
        let fixture = ModelCatalogFixture([
            (200, #"{"data":[{"id":"general"}],"has_more":true,"last_id":"general"}"#),
            (200, #"{"data":[{"id":"DeepSeek-New"}],"has_more":false}"#)
        ])
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) })
        let result = try await service.catalog(providerID: "custom:test", connection: connection, apiKey: "unit-secret", now: now)
        XCTAssertEqual(result.snapshot.models.map(\.id), ["general", "DeepSeek-New"])
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-api-key"), "unit-secret")
        XCTAssertFalse(requests[0].url?.absoluteString.contains("unit-secret") ?? true)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "after_id" })?.value, "general")
    }

    func testCachePersistsWithoutCredentialsAndTransientFailureIsMarkedStale() async throws {
        let path = temporaryCache()
        let fixture = ModelCatalogFixture([(200, #"{"data":[{"id":"DeepSeek-New"}]}"#), (503, "unavailable")])
        let service = ProviderModelService(fileURL: path, transport: { try await fixture.send($0) })
        _ = try await service.catalog(providerID: "custom:test", connection: connection, apiKey: "unit-secret", now: now)
        let cached = try await service.catalog(providerID: "custom:test", connection: connection, apiKey: "unit-secret", now: now.addingTimeInterval(60))
        XCTAssertEqual(cached.source, .cache)
        let stale = try await service.catalog(providerID: "custom:test", connection: connection, apiKey: "unit-secret", force: true, now: now.addingTimeInterval(7 * 3600))
        XCTAssertEqual(stale.source, .stale)
        XCTAssertEqual(stale.snapshot.models.first?.id, "DeepSeek-New")
        XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains("unit-secret"))
    }

    func testAuthenticationFailureDoesNotFallBackToCachedModelOrOtherRoutes() async throws {
        let fixture = ModelCatalogFixture([(200, #"{"data":[{"id":"DeepSeek-New"}]}"#), (401, "denied")])
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) })
        _ = try await service.catalog(providerID: "custom:test", connection: connection, apiKey: "unit-secret", now: now)
        do {
            _ = try await service.catalog(providerID: "custom:test", connection: connection, apiKey: "unit-secret", force: true, now: now.addingTimeInterval(61))
            XCTFail("Revoked credentials must not use cached availability")
        } catch { XCTAssertEqual(error as? ProviderModelError, .unauthorized) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testMissingListRouteUsesSameHostOpenAICompatibilityFallback() async throws {
        let fixture = ModelCatalogFixture([(404, "missing"), (200, #"{"data":[{"id":"DeepSeek-New"}]}"#)])
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) })
        let result = try await service.catalog(providerID: "custom:test", connection: connection, apiKey: "unit-secret", now: now)
        XCTAssertEqual(result.snapshot.models.first?.id, "DeepSeek-New")
        let requests = await fixture.requests
        XCTAssertEqual(requests.last?.url?.absoluteString, "https://provider.example/v1/models")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer unit-secret")
    }

    func testExplicitRefreshRetriesImmediatelyAfterTransientFailure() async throws {
        let fixture = ModelCatalogFixture([(503, "unavailable"), (200, #"{"data":[{"id":"deepseek-current"}]}"#)])
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) })
        do {
            _ = try await service.catalog(providerID: "test", connection: connection, apiKey: "unit-key", now: now)
            XCTFail("First request must fail")
        } catch { XCTAssertEqual(error as? ProviderModelError, .server(503)) }
        let result = try await service.catalog(providerID: "test", connection: connection, apiKey: "unit-key", force: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(result.source, .live)
        XCTAssertEqual(result.snapshot.models.first?.id, "deepseek-current")
    }

    @MainActor
    func testConnectionCheckUsesMetadataWithoutActivatingUnsavedKey() async throws {
        let fixture = ModelCatalogFixture([(200, #"{"models":[{"name":"deepseek-current","capabilities":["completion"]}]}"#)])
        let settings = AppSettings(modelService: ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) }))
        let provider = settings.aiProvider, model = settings.aiModel
        defer { settings.aiProvider = provider; settings.aiModel = model }
        settings.aiProvider = "ollamaCloud"
        settings.cachedAPIKey = "saved-key"
        let attempts = AISummaryService.readGenerationAttempts(target: .popup, mode: .shared)
        let result = try await settings.checkModelConnection(apiKey: "unsaved-key")
        XCTAssertEqual(result.source, .live)
        XCTAssertEqual(settings.cachedAPIKey, "saved-key")
        XCTAssertTrue(settings.currentAIModels.isEmpty)
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: .popup, mode: .shared), attempts)
        let requests = await fixture.requests
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertNil(requests.first?.httpBody)
    }

    @MainActor
    func testConnectionCheckPreservesStaleStatusInsteadOfClaimingLiveSuccess() async throws {
        let fixture = ModelCatalogFixture([(200, #"{"models":[{"name":"deepseek-current","capabilities":["completion"]}]}"#), (503, "unavailable")])
        let settings = AppSettings(modelService: ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) }))
        let provider = settings.aiProvider, model = settings.aiModel
        defer { settings.aiProvider = provider; settings.aiModel = model }
        settings.aiProvider = "ollamaCloud"
        _ = try await settings.checkModelConnection(apiKey: "unit-key")
        let result = try await settings.checkModelConnection(apiKey: "unit-key")
        XCTAssertEqual(result.source, .stale)
        XCTAssertEqual(result.refreshError, .server(503))
    }

    func testCatalogOlderThan24HoursCannotAuthorizeGeneration() async throws {
        let fixture = ModelCatalogFixture([(200, #"{"data":[{"id":"deepseek-current"}]}"#), (503, "unavailable")])
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) })
        _ = try await service.catalog(providerID: "test", connection: connection, apiKey: "unit-key", now: now)
        do {
            _ = try await service.catalog(providerID: "test", connection: connection, apiKey: "unit-key", now: now.addingTimeInterval(24 * 3600 + 1))
            XCTFail("Expired catalogs must not mask a failed refresh")
        } catch { XCTAssertEqual(error as? ProviderModelError, .server(503)) }
    }

    @MainActor
    func testEmptyCatalogStopsSummaryRecoveryBeforeBudgetOrDispatch() async {
        let fixture = ModelCatalogFixture([(200, #"{"models":[]}"#)])
        let settings = AppSettings(modelService: ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) }))
        let provider = settings.aiProvider, model = settings.aiModel, enabled = settings.aiSummaryEnabled
        defer { settings.aiProvider = provider; settings.aiModel = model; settings.aiSummaryEnabled = enabled }
        settings.aiProvider = "ollamaCloud"
        settings.aiModel = "retired"
        settings.cachedAPIKey = "unit-key"
        settings.aiSummaryEnabled = true
        let orchestrator = NewsOrchestrator()
        orchestrator.weiboItems = [NewsItem(title: "News", url: "https://example.com", source: .weibo)]
        let attempts = AISummaryService.readGenerationAttempts(target: .dashboard, mode: .shared)
        await orchestrator.generateSharedSummaryIfNeeded(settings: settings)
        XCTAssertEqual(orchestrator.aiSummaryState, .error(ProviderModelError.emptyCatalog.message(language: settings.appLanguage)))
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: .dashboard, mode: .shared), attempts)
        XCTAssertNil(orchestrator.sharedSummaryLastHash)
        XCTAssertFalse(settings.canUseCurrentAIModel)
    }

    @MainActor
    func testValidatedGenerationFreezesActualModelAndRejectsLaterChanges() async throws {
        let fixture = ModelCatalogFixture([(200, #"{"models":[{"name":"deepseek-current","capabilities":["completion"]}]}"#)])
        let settings = AppSettings(modelService: ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) }))
        let provider = settings.aiProvider, model = settings.aiModel
        defer { settings.aiProvider = provider; settings.aiModel = model }
        settings.aiProvider = "ollamaCloud"
        settings.aiModel = "retired"
        settings.cachedAPIKey = "unit-key"
        let configuration = await settings.validatedAIConfiguration(apiKey: "unit-key")
        let frozen = try XCTUnwrap(configuration)
        XCTAssertEqual(frozen.model, "deepseek-current")
        XCTAssertTrue(settings.isCurrentAIConfiguration(frozen))
        settings.cachedAPIKey = "different-key"
        XCTAssertFalse(settings.isCurrentAIConfiguration(frozen))
        XCTAssertEqual(frozen.apiKey, "unit-key")
    }

    @MainActor
    func testSummaryRecoveryValidatesCatalogBeforeHashOrGenerationLock() async {
        let fixture = ModelCatalogFixture([(200, #"{"models":[{"name":"deepseek-current","capabilities":["completion"]}]}"#)])
        let settings = AppSettings(modelService: ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) }))
        let provider = settings.aiProvider, model = settings.aiModel, enabled = settings.aiSummaryEnabled
        defer { settings.aiProvider = provider; settings.aiModel = model; settings.aiSummaryEnabled = enabled }
        settings.aiProvider = "ollamaCloud"
        settings.aiModel = "retired"
        settings.cachedAPIKey = "unit-key"
        settings.aiSummaryEnabled = true
        let orchestrator = NewsOrchestrator()
        orchestrator.weiboItems = [NewsItem(title: "Model validation", url: "https://example.com", source: .weibo)]
        XCTAssertTrue(AISummaryService.tryAcquireGenerationLock(for: .dashboard))
        defer { AISummaryService.releaseGenerationLock(for: .dashboard) }
        await orchestrator.generateSharedSummaryIfNeeded(settings: settings)
        XCTAssertEqual(settings.aiModel, "deepseek-current")
        XCTAssertTrue(settings.canUseCurrentAIModel)
        XCTAssertNil(orchestrator.sharedSummaryLastHash)
    }

    @MainActor
    func testEditingActiveCustomEndpointInvalidatesCatalogImmediately() async {
        let fixture = ModelCatalogFixture([(200, #"{"data":[{"id":"deepseek-current"}]}"#)])
        let settings = AppSettings(modelService: ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) }))
        let provider = settings.aiProvider, model = settings.aiModel, custom = settings.customAIProviders
        defer { settings.customAIProviders = custom; settings.aiProvider = provider; settings.aiModel = model }
        settings.customAIProviders = [CustomAIProviderConfig(id: "catalog-test", name: "Test", baseURL: "https://provider.example/v1/chat/completions", models: [])]
        settings.aiProvider = "custom:catalog-test"
        settings.cachedAPIKey = "unit-key"
        let success = await settings.refreshModelCatalog()
        XCTAssertTrue(success)
        let revision = settings.modelCatalogRevision
        settings.customAIProviders[0].baseURL = "https://other.example/v1/chat/completions"
        XCTAssertNotEqual(settings.modelCatalogRevision, revision)
        XCTAssertTrue(settings.currentAIModels.isEmpty)
        XCTAssertFalse(settings.canUseCurrentAIModel)
    }

    @MainActor
    func testDelayedKeyLoadCannotActivateAfterProviderOrCredentialChange() {
        let settings = AppSettings()
        let provider = settings.aiProvider, model = settings.aiModel
        defer { settings.aiProvider = provider; settings.aiModel = model }
        settings.aiProvider = "deepseek"
        let oldRevision = settings.modelCatalogRevision
        settings.aiProvider = "ollamaCloud"
        XCTAssertFalse(settings.activateAPIKey("old-key", providerID: "deepseek", revision: oldRevision))
        XCTAssertNil(settings.cachedAPIKey)
        let currentRevision = settings.modelCatalogRevision
        settings.cachedAPIKey = "new-key"
        XCTAssertFalse(settings.activateAPIKey("late-key", providerID: "ollamaCloud", revision: currentRevision))
        XCTAssertEqual(settings.cachedAPIKey, "new-key")
        XCTAssertTrue(settings.activateAPIKey("accepted-key", providerID: "ollamaCloud", revision: settings.modelCatalogRevision))
        XCTAssertEqual(settings.cachedAPIKey, "accepted-key")
    }

    @MainActor
    func testSettingsReplaceLegacyModelWithActualCatalogAndPreferDeepSeek() async {
        let fixture = ModelCatalogFixture([(200, #"{"models":[{"name":"general-new","capabilities":["completion"]},{"name":"deepseek-v4.1-flash","capabilities":["completion"]}]}"#)])
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) })
        let settings = AppSettings(modelService: service)
        let provider = settings.aiProvider, model = settings.aiModel
        defer { settings.aiProvider = provider; settings.aiModel = model }
        settings.aiProvider = "ollamaCloud"
        settings.aiModel = "deepseek-v4-flash:cloud"
        settings.cachedAPIKey = "unit-key"
        let succeeded = await settings.refreshModelCatalog()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(settings.aiModel, "deepseek-v4.1-flash")
        XCTAssertTrue(settings.canUseCurrentAIModel)
        XCTAssertFalse(settings.currentAIModels.contains("deepseek-v4-flash:cloud"))
    }

    @MainActor
    func testEmptyCatalogDisablesOldModelRatherThanGuessingDefault() async {
        let fixture = ModelCatalogFixture([(200, #"{"models":[]}"#)])
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await fixture.send($0) })
        let settings = AppSettings(modelService: service)
        let provider = settings.aiProvider, model = settings.aiModel
        defer { settings.aiProvider = provider; settings.aiModel = model }
        settings.aiProvider = "ollamaCloud"
        settings.aiModel = "retired-model"
        settings.cachedAPIKey = "unit-key"
        let succeeded = await settings.refreshModelCatalog()
        XCTAssertFalse(succeeded)
        XCTAssertFalse(settings.canUseCurrentAIModel)
        XCTAssertTrue(settings.aiModel.isEmpty)
        XCTAssertTrue(settings.currentAIModels.isEmpty)
    }

    @MainActor
    func testChangingProviderWhileCatalogIsInFlightCannotApplyStaleResponse() async {
        let started = expectation(description: "Old provider catalog request started")
        let gate = DelayedCatalogFixture(started: started)
        let service = ProviderModelService(fileURL: temporaryCache(), transport: { try await gate.send($0) })
        let settings = AppSettings(modelService: service)
        let provider = settings.aiProvider, model = settings.aiModel
        defer { settings.aiProvider = provider; settings.aiModel = model }
        settings.aiProvider = "deepseek"
        settings.cachedAPIKey = "old-key"
        let oldTask = Task { await settings.refreshModelCatalog() }
        await fulfillment(of: [started], timeout: 3)
        settings.aiProvider = "ollamaCloud"
        settings.cachedAPIKey = "new-key"
        let newSucceeded = await settings.refreshModelCatalog()
        XCTAssertTrue(newSucceeded)
        await gate.finishOldRequest()
        let oldApplied = await oldTask.value
        XCTAssertFalse(oldApplied)
        XCTAssertEqual(settings.aiProvider, "ollamaCloud")
        XCTAssertEqual(settings.aiModel, "deepseek-current-cloud")
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.json")
    }
}

private actor DelayedCatalogFixture {
    let started: XCTestExpectation
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var oldURL: URL?
    init(started: XCTestExpectation) { self.started = started }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host == "api.deepseek.com" {
            oldURL = url
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        return (Data(#"{"models":[{"name":"deepseek-current-cloud","capabilities":["completion"]}]}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func finishOldRequest() {
        guard let pending, let oldURL else { return }
        self.pending = nil
        pending.resume(returning: (Data(#"{"data":[{"id":"deepseek-old-response"}]}"#.utf8), HTTPURLResponse(url: oldURL, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
}

private actor ModelCatalogFixture {
    let responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        guard responses.indices.contains(index), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: responses[index].0, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
        return (Data(responses[index].1.utf8), response)
    }
}

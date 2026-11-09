import WebKit
import XCTest
@testable import NewsBar

private enum CookiePersistenceTestError: Error {
    case clearFailed
}

private actor MemoryCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private let failClear: Bool

    init(failClear: Bool = false) {
        self.failClear = failClear
    }

    init(data: Data?) {
        self.data = data
        self.failClear = false
    }

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws {
        if failClear { throw CookiePersistenceTestError.clearFailed }
        data = nil
    }
}

private actor HeldClearCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private var didDelete = false
    private var deletedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws {
        data = nil
        didDelete = true
        deletedWaiter?.resume()
        deletedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilDeleted() async {
        if didDelete { return }
        await withCheckedContinuation { deletedWaiter = $0 }
    }

    func releaseClear() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor FailingSaveCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private var shouldFail = false

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws {
        if shouldFail {
            shouldFail = false
            throw CookiePersistenceTestError.clearFailed
        }
        self.data = data
    }
    func clear() async throws { data = nil }
    func failNextSave() { shouldFail = true }
}

private actor CommittedButUnsyncedCookiePersistence: ReaderCookiePersisting, ReaderCookieDurabilityConfirming {
    private var data: Data?
    private var failNextSave = false
    private var failNextClear = false
    private var syncFails = false

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws {
        self.data = data
        if failNextSave {
            failNextSave = false
            syncFails = true
            throw ReaderCookieVaultError.durabilityUnknown
        }
    }
    func clear() async throws {
        data = nil
        if failNextClear {
            failNextClear = false
            syncFails = true
            throw ReaderCookieVaultError.durabilityUnknown
        }
    }
    func failAfterNextSave() { failNextSave = true }
    func failAfterNextClear() { failNextClear = true }
    func allowSynchronization() { syncFails = false }
    func confirmDurability() async throws {
        if syncFails { throw ReaderCookieVaultError.durabilityUnknown }
    }
}

private actor UnverifiedCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private var failNextClear = false
    private var failNextSave = false
    private var failLoads = false

    init(data: Data? = nil) { self.data = data }

    func load() async throws -> Data? {
        if failLoads { throw ReaderCookieVaultError.corruptedStore }
        return data
    }
    func save(_ data: Data) async throws {
        self.data = data
        if failNextSave {
            failNextSave = false
            failLoads = true
            throw ReaderCookieVaultError.stateUnverified
        }
    }
    func clear() async throws {
        if failNextClear {
            failNextClear = false
            failLoads = true
            throw ReaderCookieVaultError.stateUnverified
        }
        data = nil
    }
    func makeNextClearUnverified() { failNextClear = true }
    func makeNextSaveUnverified() { failNextSave = true }
    func allowReads() { failLoads = false }
    func rawData() -> Data? { data }
}

private actor HeldUnverifiedSaveAndFailingClear: ReaderCookiePersisting {
    private var data: Data?
    private var holdNextSave = false
    private var saveIsHeld = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws {
        self.data = data
        if holdNextSave {
            holdNextSave = false
            saveIsHeld = true
            heldWaiter?.resume()
            heldWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
            throw ReaderCookieVaultError.stateUnverified
        }
    }
    func clear() async throws { throw CookiePersistenceTestError.clearFailed }
    func holdFollowingSave() { holdNextSave = true }
    func waitUntilSaveIsHeld() async {
        if saveIsHeld { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }
    func releaseSave() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor PausableCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private var shouldPause = false
    private var didPause = false
    private var pausedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws {
        if shouldPause {
            shouldPause = false
            didPause = true
            pausedWaiter?.resume()
            pausedWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        self.data = data
    }
    func clear() async throws { data = nil }
    func pauseNextSave() { shouldPause = true; didPause = false }
    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { pausedWaiter = $0 }
    }
    func releaseSave() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor HeldSaveCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private var didStartSave = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws {
        didStartSave = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        self.data = data
    }
    func clear() async throws { data = nil }

    func waitUntilSaveStarts() async {
        if didStartSave { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func releaseSave() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor HeldLoadCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private var didStartLoad = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(data: Data) { self.data = data }

    func load() async throws -> Data? {
        let original = data
        didStartLoad = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return original
    }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws { data = nil }
    func currentData() -> Data? { data }

    func waitUntilLoadStarts() async {
        if didStartLoad { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func releaseLoad() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor ReadFailingCookiePersistence: ReaderCookiePersisting {
    private var data: Data?
    private var failLoads = true

    init(data: Data?) { self.data = data }

    func load() async throws -> Data? {
        if failLoads { throw ReaderCookieVaultError.corruptedStore }
        return data
    }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws { data = nil }
    func allowReads() { failLoads = false }
    func currentData() -> Data? { data }
}

private actor MemoryHistoryPersistence: ReaderHistoryPersisting {
    private var data: Data?
    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws { data = nil }
}

final class EncryptedReaderCookiePersistenceTests: XCTestCase {
    func testKeychainMigrationRetriesAfterAReadFailure() {
        XCTAssertEqual(
            EncryptedKeyStore.keychainMigrationAction(.failed),
            .retry
        )
        XCTAssertEqual(
            EncryptedKeyStore.keychainMigrationAction(.missing),
            .markComplete
        )
        XCTAssertEqual(
            EncryptedKeyStore.keychainMigrationAction(.found("")),
            .markComplete
        )
        XCTAssertEqual(
            EncryptedKeyStore.keychainMigrationAction(.found("sk-test")),
            .migrate("sk-test")
        )
    }

    func testClearReportsEncryptedStoreWriteFailure() async throws {
        let directory = try researchTestDirectory()
        defer {
            PrivateFileFaults.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let account = EncryptedReaderCookiePersistence.account
        let payload = EncryptedKeyStore.EncryptedPayload(
            version: EncryptedKeyStore.currentVersion,
            entries: [EncryptedKeyStore.Entry(account: account, nonce: Data([1]), ciphertext: Data([2]))]
        )
        try PrivateFile.write(
            JSONEncoder().encode(payload),
            to: directory.appendingPathComponent("apikeys.enc"),
            durable: false
        )
        let store = EncryptedKeyStore(directory: directory)
        let persistence = EncryptedReaderCookiePersistence(store: store)
        PrivateFileFaults.failBeforeRename = true

        do {
            try await persistence.clear()
            XCTFail("Clear must report an encrypted-store write failure")
        } catch ReaderCookieVaultError.clearFailed {
            // Expected: deleting the encrypted cookie entry did not succeed.
        } catch {
            XCTFail("Unexpected clear error: \(error)")
        }

        let retained = await store.checkAPIKeyExistence(account: account)
        XCTAssertTrue(retained)
    }

    func testClearReportsCommittedButUnsyncedStateUsingIsolatedStore() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCookiePersistenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let persistence = EncryptedReaderCookiePersistence(store: store)
        try await persistence.save(Data("fictional cookie payload".utf8))

        PrivateFileFaults.failAfterRename = true
        do {
            try await persistence.clear()
            XCTFail("The directory sync did not complete")
        } catch ReaderCookieVaultError.durabilityUnknown {
            // The encrypted entry is already absent, but crash durability is unknown.
        } catch {
            XCTFail("Unexpected clear error: \(error)")
        }
        PrivateFileFaults.reset()

        let remaining = try await persistence.load()
        XCTAssertNil(remaining)
        XCTAssertNil(defaults.object(forKey: "hasAIKey-\(EncryptedReaderCookiePersistence.account)"))
    }

    @MainActor
    func testUnverifiedEncryptedClearCanReconcileWithoutRevivingCookies() async throws {
        let directory = try researchTestDirectory()
        let suiteName = "NewsBarCookieRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            PrivateFileFaults.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = EncryptedKeyStore(directory: directory, metadataDefaults: defaults)
        let persistence = EncryptedReaderCookiePersistence(store: store)
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        let testCookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "sid", .value: "fictional", .domain: "example.test", .path: "/"
        ]))
        await controller.prepare()
        let oldEpoch = controller.cookieCaptureEpoch
        let saved = await controller.capture(cookies: [testCookie], host: "example.test", title: nil, epoch: oldEpoch)
        XCTAssertEqual(saved, 1)

        PrivateFileFaults.failVerificationAfterWrite = true
        await controller.clearCookies()
        PrivateFileFaults.reset()
        XCTAssertTrue(controller.cookieRecoveryPending)
        XCTAssertTrue(controller.sites.isEmpty)
        XCTAssertNotNil(controller.storageError)
        let late = await controller.capture(cookies: [testCookie], host: "example.test", title: nil, epoch: oldEpoch)
        XCTAssertEqual(late, 0)

        await controller.retryCookieRecovery()
        XCTAssertFalse(controller.cookieRecoveryPending)
        XCTAssertTrue(controller.sites.isEmpty)
        XCTAssertTrue(controller.cookieDurabilityPending)
        await controller.retryCookieDurability()
        XCTAssertFalse(controller.cookieDurabilityPending)
        XCTAssertNil(controller.storageError)
        let persisted = try await persistence.load()
        XCTAssertNil(persisted)
    }
}

final class ReaderCookieVaultTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func waitForClearToStart(_ vault: ReaderCookieVault, after generation: UUID) async {
        let started = expectation(description: "clear invalidates the capture generation")
        let observer = Task {
            while !Task.isCancelled {
                if await vault.captureGeneration != generation {
                    started.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        observer.cancel()
    }

    private func cookie(
        _ name: String,
        value: String = "v",
        domain: String = "example.com",
        path: String = "/",
        expires: Date? = nil,
        secure: Bool = false,
        httpOnly: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: secure ? "TRUE" : "FALSE",
        ]
        if let expires { properties[.expires] = expires }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    func testOnlyFirstPartyCookiesAreStored() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)

        let count = try await vault.upsert(
            cookies: [
                cookie("sid", domain: ".example.com"),
                cookie("host", domain: "www.example.com"),
                cookie("tracker", domain: "tracker.net"),
            ],
            host: "www.example.com",
            allowEmptyRemoval: false,
            now: now
        )

        XCTAssertEqual(count, 2)
        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.map(\.host), ["www.example.com"])
        XCTAssertEqual(Set(sites.first?.cookies.map(\.name) ?? []), ["sid", "host"])
    }

    func testSavedCookiesReplayForSubdomainsButNotLookalikes() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid", domain: ".example.com")],
            host: "www.example.com",
            allowEmptyRemoval: false,
            now: now
        )

        let subdomain = await vault.cookies(matching: "news.example.com", now: now)
        XCTAssertEqual(subdomain.map(\.name), ["sid"])

        let lookalike = await vault.cookies(matching: "evil-example.com", now: now)
        XCTAssertTrue(lookalike.isEmpty)
    }

    func testExpiredCookiesAreDropped() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let count = try await vault.upsert(
            cookies: [
                cookie("old", expires: now.addingTimeInterval(-60)),
                cookie("fresh", expires: now.addingTimeInterval(3_600)),
            ],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        XCTAssertEqual(count, 1)
        let later = await vault.cookies(matching: "example.com", now: now.addingTimeInterval(7_200))
        XCTAssertTrue(later.isEmpty)
    }

    func testSessionCookiesSurviveForThirtyDays() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        let within = await vault.cookies(matching: "example.com", now: now.addingTimeInterval(29 * 86_400))
        XCTAssertEqual(within.count, 1)
        XCTAssertNotNil(within.first?.expiresDate)

        let after = await vault.cookies(matching: "example.com", now: now.addingTimeInterval(31 * 86_400))
        XCTAssertTrue(after.isEmpty)
    }

    func testPerSiteCapKeepsAuthCookies() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let cookies = (0..<(ReaderCookieVault.maxCookiesPerSite + 40)).map {
            cookie("c\($0)", value: "v\($0)")
        } + [
            cookie("SUB", value: "auth"),
            cookie("SESSDATA", value: "bili-auth"),
        ]

        let count = try await vault.upsert(
            cookies: cookies,
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        XCTAssertEqual(count, ReaderCookieVault.maxCookiesPerSite)
        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.count, ReaderCookieVault.maxCookiesPerSite)
        XCTAssertTrue(sites.first?.cookies.contains { $0.name == "SUB" } == true)
        XCTAssertTrue(sites.first?.cookies.contains { $0.name == "SESSDATA" } == true)
    }

    func testHTTPOnlyFlagSurvivesReplay() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let original = cookie(
            "SESSDATA",
            value: "auth",
            domain: ".bilibili.com",
            httpOnly: true
        )
        XCTAssertTrue(original.isHTTPOnly)
        _ = try await vault.upsert(
            cookies: [original],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let replayed = await vault.cookies(matching: "www.bilibili.com", now: now)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertTrue(replayed.first?.isHTTPOnly == true)
    }

    func testGlobalCapEvictsWholeSites() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)

        for index in 0..<10 {
            let host = "s\(index).example.com"
            let cookies = (0..<80).map { cookie("c\($0)", value: "v\($0)", domain: host) }
            _ = try await vault.upsert(
                cookies: cookies,
                host: host,
                allowEmptyRemoval: false,
                now: now.addingTimeInterval(Double(index))
            )
        }

        let total = await vault.totalCookieCount(now: now.addingTimeInterval(20))
        let sites = await vault.siteSummaries(now: now.addingTimeInterval(20))
        XCTAssertLessThanOrEqual(total, ReaderCookieVault.maxCookiesTotal)
        XCTAssertTrue(sites.allSatisfy { $0.cookies.count == 80 })
        XCTAssertEqual(Set(sites.map(\.host)), Set((3..<10).map { "s\($0).example.com" }))
    }

    func testGlobalCapKeepsAuthSiteWhenOlder() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let authCookies = [cookie("SESSDATA", value: "auth", domain: "bilibili.com")]
            + (0..<79).map { cookie("c\($0)", value: "v", domain: "bilibili.com") }
        _ = try await vault.upsert(
            cookies: authCookies,
            host: "bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        for index in 0..<10 {
            let host = "s\(index).example.com"
            let cookies = (0..<80).map { cookie("c\($0)", value: "v", domain: host) }
            _ = try await vault.upsert(
                cookies: cookies,
                host: host,
                allowEmptyRemoval: false,
                now: now.addingTimeInterval(Double(index + 1))
            )
        }

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(20))
        let total = await vault.totalCookieCount(now: now.addingTimeInterval(20))
        XCTAssertTrue(sites.contains { $0.host == "bilibili.com" })
        XCTAssertTrue(sites.first { $0.host == "bilibili.com" }?.cookies.contains { $0.name == "SESSDATA" } == true)
        XCTAssertLessThanOrEqual(total, ReaderCookieVault.maxCookiesTotal)
    }

    func testRemoveAndClear() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        try await vault.removeSite("example.com")
        let afterRemove = await vault.siteSummaries(now: now)
        XCTAssertTrue(afterRemove.isEmpty)

        _ = try await vault.upsert(
            cookies: [cookie("sid")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )
        try await vault.clear()
        let afterClear = await vault.siteSummaries(now: now)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testClearFailureKeepsSavedCookiesAvailable() async throws {
        let persistence = MemoryCookiePersistence(failClear: true)
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )
        let saved = try await persistence.load()
        XCTAssertNotNil(saved)

        do {
            try await vault.clear()
            XCTFail("Clear must report persistence failure")
        } catch CookiePersistenceTestError.clearFailed {
            // Expected: the stored and in-memory cookies must both survive.
        }

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.map(\.name), ["sid"])
        let stillSaved = try await persistence.load()
        XCTAssertEqual(stillSaved, saved)
    }

    func testCaptureDuringClearDoesNotRestoreCookiesOnReload() async throws {
        let persistence = HeldClearCookiePersistence()
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("sid", value: "before")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )

        let clear = Task { try await vault.clear() }
        await persistence.waitUntilDeleted()
        let captured = try await vault.upsert(
            cookies: [cookie("sid", value: "late")],
            host: "example.com",
            allowEmptyRemoval: false,
            now: now
        )
        await persistence.releaseClear()
        try await clear.value

        XCTAssertEqual(captured, 0)
        let stored = try await persistence.load()
        XCTAssertNil(stored)
        let reloaded = ReaderCookieVault(persistence: persistence)
        await reloaded.prepare(now: now)
        let sites = await reloaded.siteSummaries(now: now)
        XCTAssertTrue(sites.isEmpty)
    }

    func testClearWaitsForAlreadyStartedSaveBeforeDeleting() async throws {
        let persistence = HeldSaveCookiePersistence()
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)
        let generation = await vault.captureGeneration
        let capturedToken = await vault.writeToken(for: "example.com")
        let token = try XCTUnwrap(capturedToken)
        let pending = Task {
            try await vault.upsert(
                cookies: [self.cookie("sid")], host: "example.com",
                allowEmptyRemoval: false, now: self.now
            )
        }
        await persistence.waitUntilSaveStarts()
        let clear = Task { try await vault.clear() }
        await waitForClearToStart(vault, after: generation)
        await persistence.releaseSave()

        _ = try await pending.value
        try await clear.value
        let stored = try await persistence.load()
        XCTAssertNil(stored)
        let sites = await vault.siteSummaries(now: now)
        XCTAssertTrue(sites.isEmpty)
        let stale = try await vault.upsert(
            cookies: [cookie("sid")], host: "example.com", allowEmptyRemoval: false,
            now: now, writeToken: token
        )
        XCTAssertEqual(stale, 0)
    }

    func testClearWaitsForPendingLoadAndDiscardsOldSnapshot() async throws {
        let initial = MemoryCookiePersistence()
        let seed = ReaderCookieVault(persistence: initial)
        await seed.prepare(now: now)
        _ = try await seed.upsert(
            cookies: [cookie("sid")], host: "example.com", allowEmptyRemoval: false, now: now
        )
        let seedData = try await initial.load()
        let persistence = HeldLoadCookiePersistence(data: try XCTUnwrap(seedData))
        let vault = ReaderCookieVault(persistence: persistence)
        let generation = await vault.captureGeneration
        let prepare = Task { await vault.prepare(now: self.now) }
        await persistence.waitUntilLoadStarts()
        let clear = Task { try await vault.clear() }
        await waitForClearToStart(vault, after: generation)
        await persistence.releaseLoad()

        await prepare.value
        try await clear.value
        let sites = await vault.siteSummaries(now: now)
        let stored = await persistence.currentData()
        XCTAssertTrue(sites.isEmpty)
        XCTAssertNil(stored)
    }

    @MainActor
    func testControllerReportsClearFailureAndKeepsSiteAfterRefresh() async {
        let persistence = MemoryCookiePersistence(failClear: true)
        let vault = ReaderCookieVault(persistence: persistence)
        let history = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        let controller = BrowserDataController(vault: vault, historyStore: history)
        await controller.prepare()
        let count = await controller.capture(
            cookies: [cookie("sid")],
            host: "example.com",
            title: nil
        )
        XCTAssertEqual(count, 1)

        await controller.clearCookies()
        XCTAssertNotNil(controller.storageError)
        await controller.refresh()

        XCTAssertEqual(controller.sites.first?.cookies.map(\.name), ["sid"])
    }

    @MainActor
    func testClearRejectsOldSessionCaptureButAllowsNewExplicitCapture() async throws {
        let persistence = MemoryCookiePersistence()
        let vault = ReaderCookieVault(persistence: persistence)
        let history = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        let controller = BrowserDataController(vault: vault, historyStore: history)
        await controller.prepare()
        let oldEpoch = controller.cookieCaptureEpoch
        let initial = await controller.capture(
            cookies: [cookie("sid", value: "before")],
            host: "example.com", title: nil, epoch: oldEpoch
        )
        XCTAssertEqual(initial, 1)

        await controller.clearCookies()
        let late = await controller.capture(
            cookies: [cookie("sid", value: "late")],
            host: "example.com", title: nil, epoch: oldEpoch
        )
        XCTAssertEqual(late, 0)
        XCTAssertTrue(controller.sites.isEmpty)
        let cleared = try await persistence.load()
        XCTAssertNil(cleared)

        let newEpoch = controller.cookieCaptureEpoch
        XCTAssertNotEqual(newEpoch, oldEpoch)
        let explicit = await controller.capture(
            cookies: [cookie("sid", value: "new")],
            host: "example.com", title: nil, epoch: newEpoch
        )
        XCTAssertEqual(explicit, 1)
        XCTAssertEqual(controller.sites.first?.cookies.first?.value, "new")
    }

    @MainActor
    func testFailedClearKeepsSessionCaptureValid() async {
        let persistence = MemoryCookiePersistence(failClear: true)
        let vault = ReaderCookieVault(persistence: persistence)
        let history = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        let controller = BrowserDataController(vault: vault, historyStore: history)
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch

        await controller.clearCookies()
        XCTAssertNotNil(controller.storageError)
        XCTAssertEqual(controller.cookieCaptureEpoch, epoch)
        let captured = await controller.capture(
            cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch
        )
        XCTAssertEqual(captured, 1)
    }

    @MainActor
    func testUnsyncedCommittedClearDoesNotRestoreCookiesFromOldSession() async throws {
        let persistence = CommittedButUnsyncedCookiePersistence()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        let captured = await controller.capture(
            cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch
        )
        XCTAssertEqual(captured, 1)
        await persistence.failAfterNextClear()

        await controller.clearCookies()

        XCTAssertNotNil(controller.storageError, "Durability uncertainty must be visible")
        XCTAssertTrue(controller.sites.isEmpty, "The in-memory view must reflect the visible deletion")
        let late = await controller.capture(
            cookies: [cookie("sid", value: "late")], host: "example.com", title: nil, epoch: epoch
        )
        XCTAssertEqual(late, 0)
        let stored = try await persistence.load()
        XCTAssertNil(stored)
    }

    @MainActor
    func testUnsyncedCommittedSiteRemovalDoesNotRestoreForgottenCookies() async throws {
        let persistence = CommittedButUnsyncedCookiePersistence()
        let vault = ReaderCookieVault(persistence: persistence)
        let controller = BrowserDataController(
            vault: vault,
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        await persistence.failAfterNextSave()

        let removed = await controller.removeSite("example.com")

        XCTAssertFalse(removed, "The operation must not claim durable success")
        XCTAssertNotNil(controller.storageError)
        XCTAssertTrue(controller.sites.isEmpty)
        let late = await controller.capture(
            cookies: [cookie("sid", value: "late")], host: "example.com", title: nil, epoch: epoch
        )
        XCTAssertEqual(late, 0)
        let reloaded = ReaderCookieVault(persistence: persistence)
        await reloaded.prepare(now: now)
        let sites = await reloaded.siteSummaries(now: now)
        XCTAssertTrue(sites.isEmpty)
    }

    @MainActor
    func testRetryUnsyncedSiteRemovalPreservesOtherSites() async {
        let persistence = CommittedButUnsyncedCookiePersistence()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        _ = await controller.capture(
            cookies: [cookie("sid", domain: "another.test")], host: "another.test", title: nil, epoch: epoch
        )
        await persistence.failAfterNextSave()
        _ = await controller.removeSite("example.com")
        XCTAssertTrue(controller.cookieDurabilityPending)

        await controller.retryCookieDurability()
        XCTAssertTrue(controller.cookieDurabilityPending)
        XCTAssertNotNil(controller.storageError)
        XCTAssertNotNil(controller.site(for: "another.test"))

        await persistence.allowSynchronization()
        await controller.retryCookieDurability()
        XCTAssertFalse(controller.cookieDurabilityPending)
        XCTAssertNil(controller.storageError)
        XCTAssertNil(controller.site(for: "example.com"))
        XCTAssertNotNil(controller.site(for: "another.test"))
        let late = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        XCTAssertEqual(late, 0)
    }

    @MainActor
    func testUnverifiedClearBlocksWritesUntilStoredStateIsReconciled() async throws {
        let persistence = UnverifiedCookiePersistence()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let oldEpoch = controller.cookieCaptureEpoch
        _ = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: oldEpoch)
        await persistence.makeNextClearUnverified()

        await controller.clearCookies()

        XCTAssertTrue(controller.cookieRecoveryPending)
        XCTAssertNotNil(controller.storageError)
        XCTAssertTrue(controller.sites.isEmpty)
        let automatic = await controller.capture(
            cookies: [cookie("sid", value: "late")], host: "example.com", title: nil, epoch: oldEpoch
        )
        let explicit = await controller.capture(
            cookies: [cookie("sid", value: "new")], host: "example.com", title: nil,
            epoch: controller.cookieCaptureEpoch
        )
        XCTAssertEqual(automatic, 0)
        XCTAssertEqual(explicit, 0)
        let hidden = await controller.cookiesForInjection(host: "example.com")
        XCTAssertTrue(hidden.isEmpty)
        let retained = await persistence.rawData()
        XCTAssertNotNil(retained)

        await controller.retryCookieRecovery()
        XCTAssertTrue(controller.cookieRecoveryPending)
        await persistence.allowReads()
        await controller.retryCookieRecovery()
        XCTAssertFalse(controller.cookieRecoveryPending)
        XCTAssertEqual(controller.site(for: "example.com")?.cookies.first?.value, "v")
        let oldAfterRecovery = await controller.capture(
            cookies: [cookie("sid", value: "late")], host: "example.com", title: nil, epoch: oldEpoch
        )
        XCTAssertEqual(oldAfterRecovery, 0)
    }

    func testUnverifiedVaultReportsRecoveryRequiredToDirectMutators() async throws {
        let persistence = UnverifiedCookiePersistence()
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)
        _ = try await vault.upsert(cookies: [cookie("sid")], host: "example.com", allowEmptyRemoval: false, now: now)
        await persistence.makeNextClearUnverified()
        do {
            try await vault.clear()
            XCTFail("Clear should report unverified state")
        } catch ReaderCookieVaultError.stateUnverified {
            // Expected; the actual stored state is not yet known.
        }

        do {
            _ = try await vault.upsert(cookies: [cookie("sid")], host: "example.com", allowEmptyRemoval: false, now: now)
            XCTFail("A paused vault must report that recovery is required")
        } catch ReaderCookieVaultError.stateUnverified {
            // Expected.
        }
        do {
            try await vault.removeSites(forSite: "example.com")
            XCTFail("Removing a site must not appear successful while storage is unverified")
        } catch ReaderCookieVaultError.stateUnverified {
            // Expected.
        }
    }

    @MainActor
    func testUnverifiedSiteRemovalReconcilesTheWholeStoreWithoutRestoringOldSessions() async {
        let persistence = UnverifiedCookiePersistence()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        _ = await controller.capture(
            cookies: [cookie("sid", domain: "another.test")], host: "another.test", title: nil, epoch: epoch
        )
        await persistence.makeNextSaveUnverified()

        let removed = await controller.removeSite("example.com")
        XCTAssertFalse(removed)
        XCTAssertTrue(controller.cookieRecoveryPending)
        XCTAssertTrue(controller.sites.isEmpty)
        let late = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        XCTAssertEqual(late, 0)

        await persistence.allowReads()
        await controller.retryCookieRecovery()
        XCTAssertFalse(controller.cookieRecoveryPending)
        XCTAssertNil(controller.site(for: "example.com"))
        XCTAssertNotNil(controller.site(for: "another.test"))
        let oldSession = await controller.capture(
            cookies: [cookie("sid", domain: "another.test")], host: "another.test", title: nil, epoch: epoch
        )
        XCTAssertEqual(oldSession, 0)
    }

    @MainActor
    func testReadFailureDuringPrepareFailsClosedAndPreservesStoredSites() async throws {
        let seedPersistence = MemoryCookiePersistence()
        let seed = ReaderCookieVault(persistence: seedPersistence)
        await seed.prepare(now: now)
        _ = try await seed.upsert(
            cookies: [cookie("sid")], host: "example.com", allowEmptyRemoval: false, now: now
        )
        _ = try await seed.upsert(
            cookies: [cookie("sid", domain: "another.test")],
            host: "another.test",
            allowEmptyRemoval: false,
            now: now
        )
        let storedValue = try await seedPersistence.load()
        let stored = try XCTUnwrap(storedValue)

        let persistence = ReadFailingCookiePersistence(data: stored)
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let requiresReconciliation = await vault.requiresReconciliation
        XCTAssertTrue(requiresReconciliation)
        do {
            _ = try await vault.upsert(
                cookies: [cookie("sid", value: "new")],
                host: "example.com",
                allowEmptyRemoval: false,
                now: now
            )
            XCTFail("A read failure must block writes")
        } catch ReaderCookieVaultError.stateUnverified {
            // expected
        }
        let unchanged = try await persistence.currentData()
        XCTAssertEqual(unchanged, stored)

        await persistence.allowReads()
        try await vault.reconcileUnverifiedState()
        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(Set(sites.map(\.host)), Set(["example.com", "another.test"]))
    }

    @MainActor
    func testCorruptPayloadDuringPrepareFailsClosed() async throws {
        let corrupt = Data("not-a-cookie-snapshot".utf8)
        let persistence = MemoryCookiePersistence(data: corrupt)
        let vault = ReaderCookieVault(persistence: persistence)

        await vault.prepare()

        let requiresReconciliation = await vault.requiresReconciliation
        XCTAssertTrue(requiresReconciliation)
        do {
            _ = try await vault.upsert(
                cookies: [cookie("sid")],
                host: "example.com",
                allowEmptyRemoval: false,
                now: now
            )
            XCTFail("A corrupt snapshot must block writes")
        } catch ReaderCookieVaultError.stateUnverified {
            // expected
        }
        let unchanged = try await persistence.load()
        XCTAssertEqual(unchanged, corrupt)
    }

    @MainActor
    func testUnverifiedMigrationDuringPrepareOffersRecovery() async throws {
        let seedPersistence = MemoryCookiePersistence()
        let seed = ReaderCookieVault(persistence: seedPersistence)
        await seed.prepare(now: now)
        _ = try await seed.upsert(cookies: [cookie("sid")], host: "example.com", allowEmptyRemoval: false, now: now)
        let seedData = try await seedPersistence.load()
        let raw = try XCTUnwrap(seedData)
        var oldSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        oldSnapshot["version"] = 1
        let legacyData = try JSONSerialization.data(withJSONObject: oldSnapshot)
        let persistence = UnverifiedCookiePersistence(data: legacyData)
        await persistence.makeNextSaveUnverified()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )

        await controller.prepare()

        XCTAssertTrue(controller.cookieRecoveryPending)
        XCTAssertNotNil(controller.storageError)
        XCTAssertTrue(controller.sites.isEmpty)
        await persistence.allowReads()
        await controller.retryCookieRecovery()
        XCTAssertFalse(controller.cookieRecoveryPending)
        XCTAssertNotNil(controller.site(for: "example.com"))
    }

    @MainActor
    func testFailedClearAfterUnverifiedInFlightSaveStillOffersRecovery() async {
        let persistence = HeldUnverifiedSaveAndFailingClear()
        let vault = ReaderCookieVault(persistence: persistence)
        let controller = BrowserDataController(
            vault: vault,
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        await persistence.holdFollowingSave()
        let pendingSave = Task {
            await controller.capture(
                cookies: [self.cookie("sid", value: "updated")], host: "example.com", title: nil, epoch: epoch
            )
        }
        await persistence.waitUntilSaveIsHeld()
        let generation = await vault.captureGeneration
        let clear = Task { await controller.clearCookies() }
        await waitForClearToStart(vault, after: generation)
        await persistence.releaseSave()

        _ = await pendingSave.value
        await clear.value
        XCTAssertTrue(controller.cookieRecoveryPending)
        XCTAssertTrue(controller.sites.isEmpty)
        XCTAssertNotNil(controller.storageError)
        let captured = await controller.capture(
            cookies: [cookie("sid", value: "late")], host: "example.com", title: nil,
            epoch: controller.cookieCaptureEpoch
        )
        XCTAssertEqual(captured, 0)

        await controller.retryCookieRecovery()
        XCTAssertFalse(controller.cookieRecoveryPending)
        XCTAssertEqual(controller.site(for: "example.com")?.cookies.first?.value, "updated")
    }

    @MainActor
    func testForgettingSiteRejectsItsOldSessionWithoutBlockingOtherSites() async {
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: MemoryCookiePersistence()),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(
            cookies: [cookie("sid", domain: "example.test")], host: "example.test", title: nil, epoch: epoch
        )
        _ = await controller.capture(
            cookies: [cookie("sid", domain: "another.test")], host: "another.test", title: nil, epoch: epoch
        )

        await controller.removeSite("example.test")
        let forgotten = await controller.capture(
            cookies: [cookie("sid", value: "late", domain: "example.test")],
            host: "example.test", title: nil, epoch: epoch
        )
        let unaffected = await controller.capture(
            cookies: [cookie("sid", value: "updated", domain: "another.test")],
            host: "another.test", title: nil, epoch: epoch
        )
        XCTAssertEqual(forgotten, 0)
        XCTAssertEqual(unaffected, 1)
        XCTAssertNil(controller.site(for: "example.test"))
        XCTAssertEqual(controller.site(for: "another.test")?.cookies.first?.value, "updated")

        let explicit = await controller.capture(
            cookies: [cookie("sid", value: "new", domain: "example.test")],
            host: "example.test", title: nil, epoch: controller.cookieCaptureEpoch
        )
        XCTAssertEqual(explicit, 1)
    }

    @MainActor
    func testForgettingParentAlsoRejectsOldSubdomainSession() async {
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: MemoryCookiePersistence()),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(
            cookies: [cookie("sid", domain: "news.example.test")],
            host: "news.example.test", title: nil, epoch: epoch
        )

        let removed = await controller.removeSite("example.test")
        XCTAssertTrue(removed)
        let late = await controller.capture(
            cookies: [cookie("sid", value: "late", domain: "news.example.test")],
            host: "news.example.test", title: nil, epoch: epoch
        )
        XCTAssertEqual(late, 0)
        XCTAssertTrue(controller.sites.isEmpty)
        let unrelated = await controller.capture(
            cookies: [cookie("sid", domain: "another.test")],
            host: "another.test", title: nil, epoch: epoch
        )
        XCTAssertEqual(unrelated, 1)
    }

    @MainActor
    func testForgettingAliasRejectsOldSessionFromSiblingHost() async {
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: MemoryCookiePersistence()),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(
            cookies: [cookie("SUB", domain: ".weibo.com")], host: "t.cn", title: nil, epoch: epoch
        )

        let removed = await controller.removeSite("s.weibo.com")
        XCTAssertTrue(removed)
        let late = await controller.capture(
            cookies: [cookie("SUB", domain: ".weibo.com")], host: "weibo.cn", title: nil, epoch: epoch
        )
        XCTAssertEqual(late, 0)
        XCTAssertTrue(controller.sites.isEmpty)
    }

    @MainActor
    func testCaptureStartedWhileForgettingSiteCannotRestoreIt() async {
        let persistence = PausableCookiePersistence()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        await persistence.pauseNextSave()
        let removal = Task { await controller.removeSite("example.com") }
        await persistence.waitUntilPaused()
        let captureStarted = expectation(description: "late capture is scheduled")
        let late = Task {
            captureStarted.fulfill()
            return await controller.capture(
                cookies: [self.cookie("sid", value: "late")],
                host: "example.com", title: nil, epoch: epoch
            )
        }
        await fulfillment(of: [captureStarted], timeout: 3)
        await persistence.releaseSave()

        let removed = await removal.value
        let captured = await late.value
        XCTAssertTrue(removed)
        XCTAssertEqual(captured, 0)
        XCTAssertTrue(controller.sites.isEmpty)
    }

    func testSiteRemovalInvalidatesPendingSubdomainWriteToken() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let initialToken = await vault.writeToken(for: "news.example.test")
        let token = try XCTUnwrap(initialToken)
        let unrelatedToken = await vault.writeToken(for: "another.test")
        let otherToken = try XCTUnwrap(unrelatedToken)

        try await vault.removeSites(forSite: "example.test")
        let late = try await vault.upsert(
            cookies: [cookie("sid", domain: "news.example.test")],
            host: "news.example.test", allowEmptyRemoval: false, now: now, writeToken: token
        )

        XCTAssertEqual(late, 0)
        let sites = await vault.siteSummaries(now: now)
        XCTAssertTrue(sites.isEmpty)
        let unrelated = try await vault.upsert(
            cookies: [cookie("sid", domain: "another.test")],
            host: "another.test", allowEmptyRemoval: false, now: now, writeToken: otherToken
        )
        XCTAssertEqual(unrelated, 1)
    }

    @MainActor
    func testFailedSiteRemovalKeepsSavedCookiesAndOldSessionValid() async throws {
        let persistence = FailingSaveCookiePersistence()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        await controller.prepare()
        let epoch = controller.cookieCaptureEpoch
        _ = await controller.capture(cookies: [cookie("sid")], host: "example.com", title: nil, epoch: epoch)
        let before = try await persistence.load()
        await persistence.failNextSave()

        let removed = await controller.removeSite("example.com")
        XCTAssertFalse(removed)
        XCTAssertNotNil(controller.storageError)
        await controller.refresh()
        XCTAssertEqual(controller.site(for: "example.com")?.cookies.map(\.name), ["sid"])
        let after = try await persistence.load()
        XCTAssertEqual(after, before)
        let retainedSession = await controller.capture(
            cookies: [cookie("sid", value: "updated")], host: "example.com", title: nil, epoch: epoch
        )
        XCTAssertEqual(retainedSession, 1)
    }

    @MainActor
    func testOpenReaderDoesNotRestoreClearedCookiesUntilExplicitSave() async throws {
        let persistence = MemoryCookiePersistence()
        let controller = BrowserDataController(
            vault: ReaderCookieVault(persistence: persistence),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reader-cookie-test-\(UUID())"))
        let proxy = ReaderProxyController(
            defaults: defaults,
            credentials: ReaderProxyCredentialStore(read: { _ in nil }, save: { _, _ in false }),
            monitor: nil
        )
        // The reader rejects HTTP before navigation, so this uses WebKit's
        // ephemeral cookie store without making a network request.
        let request = NewsReaderRequest(
            url: "http://example.test/", title: "Offline test", item: nil,
            surface: "test", contextID: nil, consentEpoch: UUID(), privateSession: false
        )
        let model = NewsReaderModel(request: request, proxyController: proxy, browserDataController: controller)
        defer { model.stop() }
        await model.start(options: .init(cookieMemoryEnabled: true, historyEnabled: false))
        XCTAssertEqual(model.failure, .unsupportedURL)
        let web = try XCTUnwrap(model.webView)
        let cookieStore = web.configuration.websiteDataStore.httpCookieStore
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cookieStore.setCookie(cookie("sid", domain: "example.test")) { continuation.resume() }
        }
        let first = await model.captureCurrentSite()
        XCTAssertEqual(first, 1)

        await controller.clearCookies()
        let automatic = await model.captureCurrentSite()
        XCTAssertEqual(automatic, 0)
        XCTAssertTrue(controller.sites.isEmpty)
        let afterClear = try await persistence.load()
        XCTAssertNil(afterClear)

        let explicit = await model.captureCurrentSite(force: true)
        XCTAssertEqual(explicit, 1)
        XCTAssertEqual(controller.sites.first?.cookies.map(\.name), ["sid"])

        await controller.removeSite("example.test")
        let afterForgetting = await model.captureCurrentSite()
        XCTAssertEqual(afterForgetting, 0)
        XCTAssertTrue(controller.sites.isEmpty)
        let explicitAgain = await model.captureCurrentSite(force: true)
        XCTAssertEqual(explicitAgain, 1)
    }

    func testUnchangedCookiesDoNotRewriteTheVault() async throws {
        let persistence = MemoryCookiePersistence()
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let cookies = [cookie("sid")]
        _ = try await vault.upsert(cookies: cookies, host: "example.com", allowEmptyRemoval: false, now: now)
        let first = try await persistence.load()
        XCTAssertNotNil(first)

        _ = try await vault.upsert(
            cookies: cookies,
            host: "example.com",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )
        let second = try await persistence.load()
        XCTAssertEqual(first, second)
    }

    func testDomainCookieKeepsSubdomainScope() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SUB", value: "auth", domain: ".weibo.com")],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, ".weibo.com")

        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertEqual(subdomain.map(\.name), ["SUB"])
        XCTAssertEqual(subdomain.first?.domain, ".weibo.com")
    }

    func testHostOnlyCookieDoesNotReplayToSubdomains() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SUB", value: "auth", domain: "weibo.com")],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertTrue(subdomain.isEmpty)

        let sameHost = await vault.cookies(matching: "weibo.com", now: now)
        XCTAssertEqual(sameHost.map(\.name), ["SUB"])
    }

    func testLegacyV1MigrationPromotesKnownAuthCookie() async throws {
        let persistence = MemoryCookiePersistence()
        let legacyCookie = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("SUB", value: "auth", domain: "weibo.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 1,
            sites: [
                ReaderSavedSite(
                    host: "weibo.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: [legacyCookie]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, ".weibo.com")
        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertEqual(subdomain.map(\.name), ["SUB"])
    }

    func testLegacyV1MigrationLeavesUnknownHostOnlyCookie() async throws {
        let persistence = MemoryCookiePersistence()
        let legacyCookie = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("theme", value: "dark", domain: "weibo.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 1,
            sites: [
                ReaderSavedSite(
                    host: "weibo.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: [legacyCookie]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, "weibo.com")
        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertTrue(subdomain.isEmpty)
    }

    func testV2MigrationGroupsPageHostsUnderSiteKey() async throws {
        let persistence = MemoryCookiePersistence()
        let sessdata = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("SESSDATA", value: "auth", domain: ".bilibili.com"),
            now: now
        ))
        let buvid = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("buvid3", value: "device", domain: "www.bilibili.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 2,
            sites: [
                ReaderSavedSite(
                    host: "www.bilibili.com",
                    title: "B站",
                    savedAt: now,
                    updatedAt: now.addingTimeInterval(10),
                    cookies: [sessdata]
                ),
                ReaderSavedSite(
                    host: "passport.bilibili.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now.addingTimeInterval(20),
                    cookies: [buvid]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(30))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(30))
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.host, "bilibili.com")
        XCTAssertEqual(Set(sites.first?.cookies.map(\.name) ?? []), ["SESSDATA", "buvid3"])
        XCTAssertEqual(sites.first?.title, "B站")
    }

    func testV2MigrationDoesNotPromoteHostOnlyAuthCookieAgain() async throws {
        let persistence = MemoryCookiePersistence()
        let hostOnlySub = try XCTUnwrap(ReaderStoredCookie(
            cookie: cookie("SUB", value: "auth", domain: "weibo.com"),
            now: now
        ))
        let legacy = ReaderCookieSnapshot(
            version: 2,
            sites: [
                ReaderSavedSite(
                    host: "weibo.com",
                    title: nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: [hostOnlySub]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(legacy))

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now)

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.first?.cookies.first?.domain, "weibo.com")
        let subdomain = await vault.cookies(matching: "passport.weibo.com", now: now)
        XCTAssertTrue(subdomain.isEmpty)
    }

    func testEmptyCaptureKeepsSavedSite() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SUB", domain: ".weibo.com")],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let count = try await vault.upsert(
            cookies: [],
            host: "passport.weibo.com",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(count, 0)
        let hasSite = await vault.hasSite("weibo.com")
        XCTAssertTrue(hasSite)
        let subdomain = await vault.cookies(matching: "weibo.com", now: now.addingTimeInterval(60))
        XCTAssertEqual(subdomain.map(\.name), ["SUB"])
    }

    func testDuplicateIdentityIsDeduplicatedAcrossSites() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let sub = cookie("SUB", value: "auth", domain: ".weibo.com")
        _ = try await vault.upsert(
            cookies: [sub],
            host: "weibo.com",
            allowEmptyRemoval: false,
            now: now
        )
        _ = try await vault.upsert(
            cookies: [sub],
            host: "passport.weibo.com",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )

        let total = await vault.totalCookieCount(now: now.addingTimeInterval(120))
        XCTAssertEqual(total, 1)
    }

    func testAliasInjectionIncludesShortLinkSiteCookies() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SESSDATA", value: "auth", domain: ".bilibili.com")],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let hosts = ReaderCookieSiteScope.injectionHosts(for: "https://b23.tv/BV1xx")
        let injected = await vault.cookies(forInjectionHosts: hosts, now: now)
        XCTAssertEqual(injected.map(\.name), ["SESSDATA"])

        let lookalike = await vault.cookies(forInjectionHosts: ["evil-bilibili.com"], now: now)
        XCTAssertTrue(lookalike.isEmpty)
    }

    func testAliasCaptureUpdatesSiblingEntryWithoutLosingAuthCookie() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let sessdata = cookie("SESSDATA", value: "auth", domain: ".bilibili.com")
        let buvid = cookie("buvid3", value: "device", domain: "www.bilibili.com")
        _ = try await vault.upsert(
            cookies: [sessdata, buvid],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let count = try await vault.upsert(
            cookies: [sessdata, buvid],
            host: "b23.tv",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(count, 2)
        let sites = await vault.siteSummaries(now: now.addingTimeInterval(120))
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.host, "bilibili.com")
        XCTAssertEqual(Set(sites.first?.cookies.map(\.name) ?? []), ["SESSDATA", "buvid3"])
    }

    func testAliasLookupAndRemovalCoversSiblingHosts() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [cookie("SESSDATA", value: "auth", domain: ".bilibili.com")],
            host: "www.bilibili.com",
            allowEmptyRemoval: false,
            now: now
        )

        let hasSite = await vault.hasSite("b23.tv")
        XCTAssertTrue(hasSite)

        try await vault.removeSites(forSite: "b23.tv")
        let sites = await vault.siteSummaries(now: now)
        XCTAssertTrue(sites.isEmpty)
    }

    func testWeiboAliasCaptureIncludesWeiboCNCookie() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        let sub = cookie("SUB", value: "auth", domain: ".weibo.com")
        let cn = cookie("SUB", value: "auth-cn", domain: ".weibo.cn")
        _ = try await vault.upsert(
            cookies: [sub, cn],
            host: "s.weibo.com",
            allowEmptyRemoval: false,
            now: now
        )

        let sites = await vault.siteSummaries(now: now)
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.host, "weibo.com")
        XCTAssertEqual(
            Set(sites.first?.cookies.map(\.domain) ?? []),
            Set([".weibo.com", ".weibo.cn"])
        )

        let injected = await vault.cookies(forInjectionHosts: ["s.weibo.com"], now: now)
        XCTAssertEqual(Set(injected.map(\.domain)), Set([".weibo.com", ".weibo.cn"]))

        try await vault.removeSites(forSite: "t.cn")
        let afterRemoval = await vault.siteSummaries(now: now)
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    /// A site jar that fills `total` slots, optionally carrying one sign-in cookie.
    private func savedSite(
        _ host: String,
        updatedAt: Date,
        total: Int,
        signInCookie: String? = nil
    ) throws -> ReaderSavedSite {
        var cookies: [ReaderStoredCookie] = []
        if let signInCookie {
            cookies.append(try XCTUnwrap(ReaderStoredCookie(
                cookie: cookie(signInCookie, value: "auth", domain: "." + host), now: updatedAt
            )))
        }
        for index in cookies.count..<total {
            cookies.append(try XCTUnwrap(ReaderStoredCookie(
                cookie: cookie("filler\(index)", value: "v", domain: "." + host), now: updatedAt
            )))
        }
        return ReaderSavedSite(host: host, title: nil, savedAt: updatedAt, updatedAt: updatedAt, cookies: cookies)
    }

    private func save(_ snapshot: ReaderCookieSnapshot, to persistence: MemoryCookiePersistence) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await persistence.save(encoder.encode(snapshot))
    }

    /// `buvid3`/`b_nut` are handed out to anonymous visitors, so an anonymous
    /// Bilibili visit must not be promoted over sites the user is signed into.
    func testAnonymousDeviceCookiesDoNotOutrankSignInSites() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("bilibili.com", updatedAt: now.addingTimeInterval(1), total: 160, signInCookie: "buvid3"),
                try savedSite("signin.example", updatedAt: now.addingTimeInterval(10), total: 160, signInCookie: "SESSDATA"),
                try savedSite("ord1.example", updatedAt: now.addingTimeInterval(9), total: 160),
                try savedSite("ord2.example", updatedAt: now.addingTimeInterval(8), total: 160),
                try savedSite("ord3.example", updatedAt: now.addingTimeInterval(7), total: 160),
            ]),
            to: persistence
        )

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(60))
        XCTAssertFalse(sites.contains { $0.host == "bilibili.com" })
        XCTAssertTrue(sites.contains { $0.host == "signin.example" })
    }

    /// Several signed-in sites can exceed the global budget between them. Each
    /// sign-in cookie must keep a slot; only filler cookies compete for the rest.
    func testSignInCookiesSurviveTheGlobalBudgetAcrossSites() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("one.example", updatedAt: now.addingTimeInterval(4), total: 160, signInCookie: "SESSDATA"),
                try savedSite("two.example", updatedAt: now.addingTimeInterval(3), total: 160, signInCookie: "SUB"),
                try savedSite("three.example", updatedAt: now.addingTimeInterval(2), total: 160, signInCookie: "bili_jct"),
                try savedSite("four.example", updatedAt: now.addingTimeInterval(1), total: 160, signInCookie: "wbpsess"),
            ]),
            to: persistence
        )

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(60))
        let names = Set(sites.flatMap { $0.cookies.map(\.name) })
        XCTAssertTrue(
            names.isSuperset(of: ["SESSDATA", "SUB", "bili_jct", "wbpsess"]),
            "missing sign-in cookies: \(names)"
        )
        let total = await vault.totalCookieCount(now: now.addingTimeInterval(60))
        XCTAssertLessThanOrEqual(total, ReaderCookieVault.maxCookiesTotal)
    }

    /// A v3 store written before `bili2233.cn` joined the alias table can hold
    /// two entries for one sign-in site. Loading it must merge them instead of
    /// leaving two rows with the same host.
    func testPrepareMergesDuplicateHostsFromAnOlderAliasTable() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("bilibili.com", updatedAt: now.addingTimeInterval(10), total: 3, signInCookie: "SESSDATA"),
                try savedSite("bili2233.cn", updatedAt: now.addingTimeInterval(5), total: 2, signInCookie: "buvid3"),
            ]),
            to: persistence
        )

        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        let sites = await vault.siteSummaries(now: now.addingTimeInterval(60))
        XCTAssertEqual(sites.map(\.host), ["bilibili.com"])
        XCTAssertEqual(sites.first?.cookies.count, 5)
    }

    /// The number returned to the UI must be what the vault actually kept, not
    /// what was offered before the global budget trimmed the jar.
    func testUpsertReportsWhatTheBudgetActuallyKept() async throws {
        let persistence = MemoryCookiePersistence()
        try await save(
            ReaderCookieSnapshot(version: 3, sites: [
                try savedSite("ord1.example", updatedAt: now.addingTimeInterval(1), total: 160),
                try savedSite("ord2.example", updatedAt: now.addingTimeInterval(2), total: 160),
                try savedSite("ord3.example", updatedAt: now.addingTimeInterval(3), total: 160),
                try savedSite("ord4.example", updatedAt: now.addingTimeInterval(4), total: 110),
            ]),
            to: persistence
        )
        let vault = ReaderCookieVault(persistence: persistence)
        await vault.prepare(now: now.addingTimeInterval(60))

        var fresh = [cookie("SESSDATA", value: "auth", domain: ".signin.example")]
        for index in 0..<19 {
            fresh.append(cookie("filler\(index)", domain: ".signin.example"))
        }
        let returned = try await vault.upsert(
            cookies: fresh,
            host: "signin.example",
            allowEmptyRemoval: false,
            now: now.addingTimeInterval(120)
        )

        let stored = await vault.siteSummaries(now: now.addingTimeInterval(120))
            .first { $0.host == "signin.example" }?
            .cookies.count
        XCTAssertEqual(returned, stored)
    }
}

final class ReaderHistoryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCanonicalURLDeduplicatesAndCountsVisits() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)

        _ = try await store.record(
            url: "https://example.com/a?utm_source=x#top",
            title: "First",
            host: "example.com",
            now: now
        )
        _ = try await store.record(
            url: "https://example.com/a",
            title: "Second",
            host: "example.com",
            now: now.addingTimeInterval(60)
        )

        let entries = await store.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.visitCount, 2)
        XCTAssertEqual(entries.first?.title, "Second")
        XCTAssertEqual(entries.first?.host, "example.com")
    }

    func testRetentionDropsOldEntries() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)

        _ = try await store.record(
            url: "https://example.com/old",
            title: "Old",
            host: "example.com",
            now: now.addingTimeInterval(-100 * 86_400)
        )
        _ = try await store.record(
            url: "https://example.com/new",
            title: "New",
            host: "example.com",
            now: now
        )

        let entries = await store.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "New")
    }

    func testEntryCapKeepsNewestThreeHundred() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)

        for index in 0..<(ReaderHistoryStore.maxEntries + 5) {
            _ = try await store.record(
                url: "https://example.com/story/\(index)",
                title: "Story \(index)",
                host: "example.com",
                now: now.addingTimeInterval(Double(index))
            )
        }

        let entries = await store.all()
        XCTAssertEqual(entries.count, ReaderHistoryStore.maxEntries)
        XCTAssertEqual(entries.first?.title, "Story \(ReaderHistoryStore.maxEntries + 4)")
    }

    func testRemoveAndClear() async throws {
        let store = ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        await store.prepare(now: now)
        let entry = try await store.record(
            url: "https://example.com/story",
            title: "Story",
            host: "example.com",
            now: now
        )

        try await store.remove(id: entry.id)
        let afterRemove = await store.all()
        XCTAssertTrue(afterRemove.isEmpty)

        _ = try await store.record(
            url: "https://example.com/story",
            title: "Story",
            host: "example.com",
            now: now
        )
        try await store.clear()
        let afterClear = await store.all()
        XCTAssertTrue(afterClear.isEmpty)
    }
}

/// Sign-out cleanup: an empty capture must not erase a saved sign-in unless the
/// page is the site's own log-out destination.
@MainActor
final class BrowserDataControllerCookieTests: XCTestCase {
    private func cookie(
        _ name: String,
        value: String = "v",
        domain: String = "example.com"
    ) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "FALSE",
        ])!
    }

    private func makeController() -> BrowserDataController {
        BrowserDataController(
            vault: ReaderCookieVault(persistence: MemoryCookiePersistence()),
            historyStore: ReaderHistoryStore(persistence: MemoryHistoryPersistence())
        )
    }

    func testEmptyCaptureKeepsSavedSiteByDefault() async {
        let controller = makeController()
        _ = await controller.capture(
            cookies: [cookie("SUB", domain: ".weibo.com")],
            host: "s.weibo.com",
            title: nil
        )
        XCTAssertTrue(controller.hasSite("s.weibo.com"))

        _ = await controller.capture(cookies: [], host: "s.weibo.com", title: nil)

        XCTAssertTrue(controller.hasSite("s.weibo.com"))
    }

    func testEmptyCaptureRemovesSavedSiteWhenLogoutIsExplicit() async {
        let controller = makeController()
        _ = await controller.capture(
            cookies: [cookie("SUB", domain: ".weibo.com")],
            host: "s.weibo.com",
            title: nil
        )
        XCTAssertTrue(controller.hasSite("s.weibo.com"))

        _ = await controller.capture(
            cookies: [],
            host: "s.weibo.com",
            title: nil,
            allowEmptyRemoval: true
        )

        XCTAssertFalse(controller.hasSite("s.weibo.com"))
        XCTAssertTrue(controller.sites.isEmpty)
    }

    func testLogoutDestinationRecognisesSignOutPaths() {
        XCTAssertTrue(ReaderNavigationPolicy.isLogoutDestination("https://passport.bilibili.com/login/exit?vmid=1"))
        XCTAssertTrue(ReaderNavigationPolicy.isLogoutDestination("https://passport.weibo.com/sso/signout"))
        XCTAssertTrue(ReaderNavigationPolicy.isLogoutDestination("https://weibo.com/logout"))
    }

    func testLogoutDestinationIgnoresOrdinaryPages() {
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination("https://www.bilibili.com/video/BV1xx"))
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination("https://passport.weibo.com/sso/signin"))
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination("https://example.com/exitpoll"))
        XCTAssertFalse(ReaderNavigationPolicy.isLogoutDestination(nil))
    }
}

/// Boundary guard: the cookies the vault builds must be accepted by WebKit's
/// ephemeral store, including a domain cookie and an HTTP-only cookie. A silent
/// drop here would look exactly like a failed sign-in replay.
final class ReaderCookieInjectionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(
        _ name: String,
        value: String,
        domain: String,
        httpOnly: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "TRUE",
        ]
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    func testVaultCookiesSurviveInjectionIntoAnEphemeralStore() async throws {
        let vault = ReaderCookieVault(persistence: MemoryCookiePersistence())
        await vault.prepare(now: now)
        _ = try await vault.upsert(
            cookies: [
                cookie("SESSDATA", value: "auth", domain: ".bilibili.com", httpOnly: true),
                cookie("buvid3", value: "device", domain: "www.bilibili.com"),
            ],
            host: "b23.tv",
            allowEmptyRemoval: false,
            now: now
        )

        let hosts = ReaderCookieSiteScope.injectionHosts(for: "https://b23.tv/BV1xx")
        let cookies = await vault.cookies(forInjectionHosts: hosts, now: now)
        XCTAssertEqual(cookies.count, 2)

        let store = WKWebsiteDataStore.nonPersistent()
        let cookieStore = store.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.setCookie(cookie) { continuation.resume() }
            }
        }

        let installed = await cookieStore.allCookies()
        let identities = Set(installed.map { "\($0.name)|\($0.domain)|\($0.path)" })
        XCTAssertTrue(identities.contains("SESSDATA|.bilibili.com|/"), "\(identities)")
        XCTAssertTrue(identities.contains("buvid3|www.bilibili.com|/"), "\(identities)")
    }
}

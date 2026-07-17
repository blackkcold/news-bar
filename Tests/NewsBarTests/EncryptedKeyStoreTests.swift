import XCTest
@testable import NewsBar

final class EncryptedKeyStoreTests: XCTestCase {

    var store = EncryptedKeyStore()

    override func setUp() {
        super.setUp()
        store = EncryptedKeyStore()
    }

    // MARK: - 基本 CRUD

    func testSaveAndRead_RoundTrip_Success() async {
        let account = "test-account-\(UUID().uuidString)"
        let key = "sk-test-key-12345"
        let saved = await store.saveAPIKey(key, account: account)
        XCTAssertTrue(saved)
        let read = await store.readAPIKey(account: account)
        XCTAssertEqual(read, key)
        await store.deleteAPIKey(account: account)
    }

    func testRead_NonExistent_ReturnsNil() async {
        let read = await store.readAPIKey(account: "non-existent-\(UUID().uuidString)")
        XCTAssertNil(read)
    }

    func testDelete_RemovesEntry() async {
        let account = "test-delete-\(UUID().uuidString)"
        _ = await store.saveAPIKey("key-to-delete", account: account)
        let beforeDelete = await store.readAPIKey(account: account)
        XCTAssertNotNil(beforeDelete)
        await store.deleteAPIKey(account: account)
        let afterDelete = await store.readAPIKey(account: account)
        XCTAssertNil(afterDelete)
    }

    // MARK: - 多 account

    func testSave_MultipleAccounts_AllReadable() async {
        let acc1 = "test-multi-1-\(UUID().uuidString)"
        let acc2 = "test-multi-2-\(UUID().uuidString)"
        _ = await store.saveAPIKey("key-one", account: acc1)
        _ = await store.saveAPIKey("key-two", account: acc2)
        let read1 = await store.readAPIKey(account: acc1)
        let read2 = await store.readAPIKey(account: acc2)
        XCTAssertEqual(read1, "key-one")
        XCTAssertEqual(read2, "key-two")
        await store.deleteAPIKey(account: acc1)
        await store.deleteAPIKey(account: acc2)
    }

    func testDelete_OneAccount_OthersPreserved() async {
        let acc1 = "test-preserve-1-\(UUID().uuidString)"
        let acc2 = "test-preserve-2-\(UUID().uuidString)"
        _ = await store.saveAPIKey("key-a", account: acc1)
        _ = await store.saveAPIKey("key-b", account: acc2)
        await store.deleteAPIKey(account: acc1)
        let read1 = await store.readAPIKey(account: acc1)
        let read2 = await store.readAPIKey(account: acc2)
        XCTAssertNil(read1)
        XCTAssertEqual(read2, "key-b")
        await store.deleteAPIKey(account: acc2)
    }

    // MARK: - Nonce 唯一性

    func testSave_SameKeySameAccount_MultipleWrites_AllReadable() async {
        let account = "test-overwrite-\(UUID().uuidString)"
        for i in 0..<5 {
            let key = "sk-key-v\(i)"
            _ = await store.saveAPIKey(key, account: account)
        }
        let read = await store.readAPIKey(account: account)
        XCTAssertEqual(read, "sk-key-v4")
        await store.deleteAPIKey(account: account)
    }

    // MARK: - 存在性检查

    func testCheckExistence_Found_True() async {
        let account = "test-exist-\(UUID().uuidString)"
        _ = await store.saveAPIKey("some-key", account: account)
        let exists = await store.checkAPIKeyExistence(account: account)
        XCTAssertTrue(exists)
        await store.deleteAPIKey(account: account)
    }

    func testCheckExistence_NotFound_False() async {
        let exists = await store.checkAPIKeyExistence(account: "no-such-\(UUID().uuidString)")
        XCTAssertFalse(exists)
    }

    // MARK: - 过期检查

    func testIsKeyStale_Recent_False() async {
        let account = "test-stale-recent-\(UUID().uuidString)"
        _ = await store.saveAPIKey("fresh-key", account: account)
        let stale = await store.isKeyStale(account: account)
        XCTAssertFalse(stale)
        await store.deleteAPIKey(account: account)
    }

    func testIsKeyStale_NoTimestamp_True() async {
        let stale = await store.isKeyStale(account: "never-saved-\(UUID().uuidString)")
        XCTAssertTrue(stale)
    }

    // MARK: - 1Password ref

    func testSaveAndReadOnePasswordRef_RoundTrip() async {
        let ref = "op://Private/TestItem/credential"
        _ = await store.saveOnePasswordRef(ref)
        let read = await store.readOnePasswordRef()
        XCTAssertEqual(read, ref)
        await store.deleteOnePasswordRef()
    }

    func testDeleteOnePasswordRef_RemovesEntry() async {
        _ = await store.saveOnePasswordRef("op://Private/X/Y")
        await store.deleteOnePasswordRef()
        let read = await store.readOnePasswordRef()
        XCTAssertNil(read)
    }

    // MARK: - 并发

    func testConcurrent_ReadWrite_NoDataCorruption() async {
        let account = "test-concurrent-\(UUID().uuidString)"
        let writeCount = 20

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<writeCount {
                group.addTask { [self] in
                    _ = await store.saveAPIKey("concurrent-key-\(i)", account: account)
                }
            }
        }

        let finalKey = await store.readAPIKey(account: account)
        XCTAssertNotNil(finalKey)
        XCTAssertTrue(finalKey?.hasPrefix("concurrent-key-") == true)
        await store.deleteAPIKey(account: account)
    }

    // MARK: - 空 key 防御

    func testSave_EmptyKey_ReturnsFalse() async {
        let result = await store.saveAPIKey("", account: "empty-test")
        XCTAssertFalse(result)
    }

    // MARK: - UserDefaults flag 同步

    func testSave_SetsHasAIKeyFlag() async {
        let account = "test-flag-\(UUID().uuidString)"
        _ = await store.saveAPIKey("flagged-key", account: account)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasAIKey-\(account)"))
        await store.deleteAPIKey(account: account)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasAIKey-\(account)"))
    }
}
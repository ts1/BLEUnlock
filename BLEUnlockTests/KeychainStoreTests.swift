import XCTest
@testable import BLEUnlock

final class KeychainStoreTests: XCTestCase {
    private let account = "test-credential"
    private lazy var store = KeychainStore(service: "jp.sone.BLEUnlockTests.\(UUID().uuidString)")

    override func tearDown() {
        try? store.removeValue(for: account)
        super.tearDown()
    }

    func testSaveReadReplaceAndDelete() throws {
        try store.set("first", for: account)
        XCTAssertEqual(try store.string(for: account), "first")
        try store.set("second", for: account)
        XCTAssertEqual(try store.string(for: account), "second")
        try store.removeValue(for: account)
        XCTAssertNil(try store.string(for: account))
    }
}

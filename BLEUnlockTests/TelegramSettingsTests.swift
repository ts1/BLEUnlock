import XCTest
@testable import BLEUnlock

final class TelegramSettingsTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var secrets: MemorySecretStore!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "jp.sone.BLEUnlockTests.TelegramSettings.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        secrets = MemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        secrets = nil
        super.tearDown()
    }

    func testDefaultsAreDisabledWithApprovedEventChoices() throws {
        let settings = TelegramSettings(defaults: defaults, secrets: secrets)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.isEventEnabled(.away))
        XCTAssertTrue(settings.isEventEnabled(.lost))
        XCTAssertFalse(settings.isEventEnabled(.unlocked))
        XCTAssertTrue(settings.isEventEnabled(.intruded))
        XCTAssertTrue(settings.takePhotoOnIntruded)
        XCTAssertFalse(try settings.isConfigured())
    }

    func testPersistsSwitchesAndCredentials() throws {
        let settings = TelegramSettings(defaults: defaults, secrets: secrets)
        settings.isEnabled = true
        settings.setEvent(.away, enabled: false)
        settings.takePhotoOnIntruded = false
        try settings.saveCredentials(replacementToken: "token-123", chatID: "987654")

        let reloaded = TelegramSettings(defaults: defaults, secrets: secrets)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertFalse(reloaded.isEventEnabled(.away))
        XCTAssertFalse(reloaded.takePhotoOnIntruded)
        XCTAssertEqual(try reloaded.credentials(),
                       TelegramCredentials(token: "token-123", chatID: "987654"))
    }

    func testAttachMacLocationDefaultsOffAndPersists() {
        let settings = TelegramSettings(defaults: defaults, secrets: secrets)

        XCTAssertFalse(settings.attachMacLocation)
        settings.attachMacLocation = true
        XCTAssertTrue(settings.attachMacLocation)
    }

    func testBlankOrNilReplacementPreservesStoredToken() throws {
        let settings = TelegramSettings(defaults: defaults, secrets: secrets)
        try settings.saveCredentials(replacementToken: "original", chatID: "old-chat")

        try settings.saveCredentials(replacementToken: "  \n", chatID: "new-chat")
        XCTAssertEqual(try settings.credentials(),
                       TelegramCredentials(token: "original", chatID: "new-chat"))

        try settings.saveCredentials(replacementToken: nil, chatID: "newest-chat")
        XCTAssertEqual(try settings.credentials(),
                       TelegramCredentials(token: "original", chatID: "newest-chat"))
    }
}

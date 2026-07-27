import AppKit
import XCTest
@testable import BLEUnlock

final class TelegramMenuControllerTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var settings: TelegramSettings!
    private var service: RecordingTelegramNotificationService!
    private var dialogs: RecordingTelegramDialogPresenter!
    private var locationAuthorization: RecordingLocationAuthorizationRequester!
    private var controller: TelegramMenuController!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "jp.sone.BLEUnlockTests.TelegramMenuController.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        settings = TelegramSettings(defaults: defaults, secrets: MemorySecretStore())
        service = RecordingTelegramNotificationService()
        dialogs = RecordingTelegramDialogPresenter()
        locationAuthorization = RecordingLocationAuthorizationRequester()
        controller = TelegramMenuController(settings: settings,
                                            service: service,
                                            dialogs: dialogs,
                                            locationAuthorization: locationAuthorization,
                                            hostName: { "Fred-Mac" })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        settings = nil
        service = nil
        dialogs = nil
        locationAuthorization = nil
        controller = nil
        super.tearDown()
    }

    func testUnconfiguredMenuDisablesEnableAndTestAndShowsNotConfigured() {
        controller.menuWillOpen(controller.menu)

        XCTAssertFalse(controller.enableItem.isEnabled)
        XCTAssertFalse(controller.testItem.isEnabled)
        XCTAssertEqual(controller.statusItem.title, t("telegram_status_not_configured"))
    }

    func testConfiguredMenuCanEnableTelegram() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        controller.menuWillOpen(controller.menu)

        XCTAssertTrue(controller.enableItem.isEnabled)
        XCTAssertEqual(controller.enableItem.state, .off)

        controller.toggleEnabled(controller.enableItem)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(controller.enableItem.state, .on)
    }

    func testEventAndPhotoItemsReflectAndPersistSettings() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        controller.menuWillOpen(controller.menu)

        XCTAssertEqual(controller.eventItems[.away]?.state, .on)
        XCTAssertEqual(controller.eventItems[.unlocked]?.state, .off)
        XCTAssertEqual(controller.photoItem.state, .on)

        controller.toggleEvent(controller.eventItems[.unlocked]!)
        controller.togglePhoto(controller.photoItem)

        XCTAssertTrue(settings.isEventEnabled(.unlocked))
        XCTAssertFalse(settings.takePhotoOnIntruded)
    }

    func testConfigureLeavesExistingTokenWhenTokenFieldIsBlank() throws {
        try settings.saveCredentials(replacementToken: "original", chatID: "old-chat")
        dialogs.credentialInput = .init(replacementToken: nil, chatID: "new-chat")

        controller.configure()

        XCTAssertTrue(dialogs.requestWasOnMainThread)
        XCTAssertEqual(dialogs.hasStoredTokenValues, [true])
        XCTAssertEqual(try settings.credentials(),
                       .init(token: "original", chatID: "new-chat"))
    }

    func testConfigureReplacesTokenWhenNewValueIsEntered() throws {
        try settings.saveCredentials(replacementToken: "original", chatID: "old-chat")
        dialogs.credentialInput = .init(replacementToken: " replacement ",
                                        chatID: "new-chat")

        controller.configure()

        XCTAssertEqual(try settings.credentials(),
                       .init(token: "replacement", chatID: "new-chat"))
    }

    func testSendTestCallsServiceAndPresentsResult() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        let presented = expectation(description: "Result presented")
        dialogs.onShowResult = { presented.fulfill() }

        controller.sendTest()

        wait(for: [presented], timeout: 2)
        XCTAssertEqual(service.hostNames, ["Fred-Mac"])
        XCTAssertEqual(dialogs.results.count, 1)
        XCTAssertEqual(dialogs.results.first?.title, t("telegram_test_success"))
        XCTAssertTrue(dialogs.showResultWasOnMainThread)
    }

    func testCameraPrivacyExplanationIsVisibleAdjacentToPhotoToggle() {
        let photoIndex = controller.menu.index(of: controller.photoItem)
        let privacyIndex = controller.menu.index(of: controller.privacyItem)

        XCTAssertEqual(privacyIndex, photoIndex + 1)
        XCTAssertEqual(controller.privacyItem.title, t("telegram_camera_privacy"))
        XCTAssertFalse(controller.privacyItem.isEnabled)
    }

    func testLocationItemIsBelowPrivacyTextAndDisabledWhenPhotoIsOff() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        settings.takePhotoOnIntruded = false
        controller.menuWillOpen(controller.menu)

        XCTAssertEqual(controller.menu.index(of: controller.locationItem),
                       controller.menu.index(of: controller.privacyItem) + 1)
        XCTAssertFalse(controller.locationItem.isEnabled)
        XCTAssertEqual(controller.locationItem.state, .off)
    }

    func testTurningPhotoOffDisablesLocationItem() {
        controller.menuWillOpen(controller.menu)

        controller.togglePhoto(controller.photoItem)

        XCTAssertFalse(controller.locationItem.isEnabled)
    }

    func testEnablingLocationPersistsAndRequestsAuthorizationOnce() {
        controller.toggleLocation(controller.locationItem)

        XCTAssertTrue(settings.attachMacLocation)
        XCTAssertEqual(locationAuthorization.requestCalls, 1)
        XCTAssertEqual(controller.locationItem.state, .on)

        controller.toggleLocation(controller.locationItem)

        XCTAssertFalse(settings.attachMacLocation)
        XCTAssertEqual(locationAuthorization.requestCalls, 1)
    }

    func testControllerDoesNotReadOrRetainTelegramCredentials() throws {
        let repository = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent(
            "BLEUnlock/TelegramMenuController.swift"
        ))

        XCTAssertFalse(source.contains("settings.credentials()"))
        XCTAssertFalse(source.contains("TelegramCredentials"))
        XCTAssertTrue(source.contains("saveCredentials(replacementToken:"))
    }
}

private final class RecordingLocationAuthorizationRequester: LocationAuthorizationRequesting {
    private(set) var requestCalls = 0

    func requestAuthorization() {
        requestCalls += 1
    }
}

private final class RecordingTelegramNotificationService: TelegramNotificationHandling {
    private let lock = NSLock()
    private var recordedHostNames: [String] = []
    var result: Result<Void, Error> = .success(())

    var hostNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedHostNames
    }

    func handle(_ context: TelegramEventContext) {}

    func sendTest(hostName: String,
                  completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        recordedHostNames.append(hostName)
        lock.unlock()
        completion(result)
    }
}

private final class RecordingTelegramDialogPresenter: TelegramDialogPresenting {
    struct PresentedResult {
        let title: String
        let message: String
    }

    var credentialInput: TelegramCredentialInput?
    private(set) var hasStoredTokenValues: [Bool] = []
    private(set) var results: [PresentedResult] = []
    private(set) var requestWasOnMainThread = false
    private(set) var showResultWasOnMainThread = false
    var onShowResult: (() -> Void)?

    func requestCredentials(hasStoredToken: Bool,
                            completion: (TelegramCredentialInput?) -> Void) {
        requestWasOnMainThread = Thread.isMainThread
        hasStoredTokenValues.append(hasStoredToken)
        completion(credentialInput)
    }

    func showResult(title: String, message: String) {
        showResultWasOnMainThread = Thread.isMainThread
        results.append(.init(title: title, message: message))
        onShowResult?()
    }
}

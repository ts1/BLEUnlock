import AppKit
import Foundation
import XCTest
@testable import BLEUnlock

final class TelegramNotificationServiceTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var settings: TelegramSettings!
    private var sender: RecordingTelegramSender!
    private var camera: StubPhotoCapturer!
    private var location: StubMacLocationProvider!
    private var reporter: RecordingFailureReporter!
    private var remover: RecordingFileRemover!
    private var service: TelegramNotificationService!
    private let photoURL = URL(fileURLWithPath: "/private/tmp/BLEUnlock-test-photo.jpg")

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "jp.sone.BLEUnlockTests.TelegramNotificationService.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        settings = TelegramSettings(defaults: defaults, secrets: MemorySecretStore())
        sender = RecordingTelegramSender()
        camera = StubPhotoCapturer()
        location = StubMacLocationProvider()
        reporter = RecordingFailureReporter()
        remover = RecordingFileRemover()
        service = TelegramNotificationService(
            settings: settings,
            sender: sender,
            camera: camera,
            location: location,
            removeFile: remover.remove,
            reporter: reporter
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        settings = nil
        sender = nil
        camera = nil
        location = nil
        reporter = nil
        remover = nil
        service = nil
        super.tearDown()
    }

    func testDisabledTelegramDoesNothing() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")

        service.handle(context(event: .intruded))

        assertNoCameraOrNetworkCalls()
    }

    func testUnconfiguredTelegramDoesNothing() {
        settings.isEnabled = true

        service.handle(context(event: .intruded))

        assertNoCameraOrNetworkCalls()
    }

    func testKeychainReadFailureIsReportedWithoutLeakingUnderlyingError() {
        let secret = "token-SECRET"
        let failure = NSError(domain: secret,
                              code: 17,
                              userInfo: [NSLocalizedDescriptionKey: "Could not read \(secret)"])
        settings = TelegramSettings(defaults: defaults,
                                    secrets: ThrowingSecretStore(error: failure))
        settings.isEnabled = true
        service = TelegramNotificationService(
            settings: settings,
            sender: sender,
            camera: camera,
            location: location,
            removeFile: remover.remove,
            reporter: reporter
        )

        service.handle(context(event: .intruded))

        assertNoCameraOrNetworkCalls()
        XCTAssertEqual(reporter.categories, ["settings"])
        XCTAssertEqual(reporter.messages, [t("telegram_error_settings_unavailable")])
        XCTAssertFalse(reporter.messages.joined().contains(secret))
    }

    func testDisabledEventDoesNothing() throws {
        try configure()
        settings.setEvent(.intruded, enabled: false)

        service.handle(context(event: .intruded))

        assertNoCameraOrNetworkCalls()
    }

    func testAwaySendsHostTimeEventAndRSSIAsText() throws {
        try configure()

        service.handle(context(event: .away, rssi: -47))

        XCTAssertEqual(camera.captureCalls, 0)
        XCTAssertEqual(sender.photoCalls.count, 0)
        XCTAssertEqual(sender.textCalls.count, 1)
        let call = try XCTUnwrap(sender.textCalls.first)
        XCTAssertEqual(call.credentials, .init(token: "token", chatID: "chat"))
        let lines = call.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        let eventDescription = NSLocalizedString("telegram_event_away",
                                                 value: "Device Away",
                                                 comment: "")
        XCTAssertEqual(lines[0], "Fred-Mac — \(eventDescription)")
        XCTAssertTrue(lines[1].hasPrefix("\(t("telegram_message_time")): "))
        XCTAssertEqual(lines[2], "\(t("telegram_message_rssi")): -47 dBm")
    }

    func testIntrudedWithPhotoSendsPhotoAndDeletesFileOnSuccess() throws {
        try configure()
        camera.result = .success(photoURL)

        service.handle(context(event: .intruded))

        XCTAssertEqual(camera.captureCalls, 1)
        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertEqual(sender.photoCalls.first?.photoURL, photoURL)
        XCTAssertEqual(sender.textCalls.count, 0)
        XCTAssertEqual(remover.calls, [photoURL])
        XCTAssertTrue(reporter.categories.isEmpty)
    }

    func testIntrudedDeletesPhotoWhenUploadFailsWithoutTextRetry() throws {
        try configure()
        camera.result = .success(photoURL)
        sender.photoResult = .failure(.transport)

        service.handle(context(event: .intruded))

        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertEqual(sender.textCalls.count, 0)
        XCTAssertEqual(remover.calls, [photoURL])
        XCTAssertEqual(reporter.categories, ["telegram"])
    }

    func testCancelledPhotoUploadDeletesPhotoWithoutTextRetry() throws {
        try configure()
        camera.result = .success(photoURL)
        sender.photoResult = .failure(.transport)

        service.handle(context(event: .intruded))

        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertEqual(sender.textCalls.count, 0)
        XCTAssertEqual(remover.calls, [photoURL])
        XCTAssertEqual(reporter.categories, ["telegram"])
    }

    func testCaptureFailureFallsBackToTextAndReportsFailure() throws {
        try configure()
        camera.result = .failure(.denied)

        service.handle(context(event: .intruded, rssi: -47))

        XCTAssertEqual(sender.photoCalls.count, 0)
        XCTAssertEqual(sender.textCalls.count, 1)
        XCTAssertEqual(reporter.categories, ["camera"])
    }

    func testRequestConstructionFailureDeletesPhoto() throws {
        try configure()
        camera.result = .success(photoURL)
        sender.photoResult = .failure(.invalidRequest)

        service.handle(context(event: .intruded))

        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertEqual(sender.textCalls.count, 0)
        XCTAssertEqual(remover.calls, [photoURL])
        XCTAssertEqual(reporter.categories, ["telegram"])
    }

    func testLocationEnabledSendsCaptionedPhotoThenNativeMap() throws {
        try configure()
        settings.attachMacLocation = true
        camera.result = .success(photoURL)
        let validLocation = TelegramLocation(latitude: 25.033,
                                             longitude: 121.5654,
                                             horizontalAccuracy: 18,
                                             timestamp: Date(timeIntervalSince1970: 100))
        location.result = .success(validLocation)

        service.handle(context(event: .intruded))

        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertTrue(sender.photoCalls[0].caption.contains("25.033000, 121.565400"))
        XCTAssertEqual(sender.locationCalls.map(\.location), [validLocation])
        XCTAssertEqual(sender.callOrder, [.photo, .location])
    }

    func testLocationDisabledNeverCallsProviderOrSendsMap() throws {
        try configure()
        settings.attachMacLocation = false
        camera.result = .success(photoURL)

        service.handle(context(event: .intruded))

        XCTAssertTrue(location.requestedDates.isEmpty)
        XCTAssertTrue(sender.locationCalls.isEmpty)
        XCTAssertEqual(sender.callOrder, [.photo])
    }

    func testLocationFailureSendsPhotoWithUnavailableCaptionAndNoMap() throws {
        try configure()
        settings.attachMacLocation = true
        camera.result = .success(photoURL)
        location.result = .failure(.timeout)

        service.handle(context(event: .intruded))

        XCTAssertTrue(sender.photoCalls[0].caption.contains(t("telegram_location_unavailable")))
        XCTAssertTrue(sender.locationCalls.isEmpty)
        XCTAssertEqual(reporter.categories, ["location"])
        XCTAssertEqual(reporter.messages, [t("telegram_location_error")])
    }

    func testLocatedCameraFailureCancelsLocationAndUsesTextFallbackWithoutCoordinates() throws {
        try configure()
        settings.attachMacLocation = true
        camera.result = .failure(.denied)
        location.result = .success(.init(latitude: 25.033,
                                         longitude: 121.5654,
                                         horizontalAccuracy: 18,
                                         timestamp: Date(timeIntervalSince1970: 100)))

        service.handle(context(event: .intruded))

        XCTAssertEqual(location.token.cancelCalls, 1)
        XCTAssertEqual(sender.textCalls.count, 1)
        XCTAssertFalse(sender.textCalls[0].text.contains("25.033000"))
        XCTAssertTrue(sender.photoCalls.isEmpty)
        XCTAssertTrue(sender.locationCalls.isEmpty)
        XCTAssertEqual(sender.callOrder, [.text])
    }

    func testPhotoUploadFailureDoesNotSendNativeMapAndCleansFile() throws {
        try configure()
        settings.attachMacLocation = true
        camera.result = .success(photoURL)
        location.result = .success(.init(latitude: 25.033,
                                         longitude: 121.5654,
                                         horizontalAccuracy: 18,
                                         timestamp: Date(timeIntervalSince1970: 100)))
        sender.photoResult = .failure(.transport)

        service.handle(context(event: .intruded))

        XCTAssertTrue(sender.locationCalls.isEmpty)
        XCTAssertEqual(sender.callOrder, [.photo])
        XCTAssertEqual(remover.calls, [photoURL])
    }

    func testNativeMapFailureReportsWithoutResendingPhoto() throws {
        try configure()
        settings.attachMacLocation = true
        camera.result = .success(photoURL)
        location.result = .success(.init(latitude: 25.033,
                                         longitude: 121.5654,
                                         horizontalAccuracy: 18,
                                         timestamp: Date(timeIntervalSince1970: 100)))
        sender.locationResult = .failure(.transport)

        service.handle(context(event: .intruded))

        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertEqual(sender.locationCalls.count, 1)
        XCTAssertEqual(sender.callOrder, [.photo, .location])
        XCTAssertEqual(reporter.categories.last, "telegram-location")
        XCTAssertEqual(reporter.messages.last, t("telegram_location_send_error"))
    }

    func testLocatedTestNotificationUsesOneTimestampForCaptionAndLocation() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        settings.attachMacLocation = true
        camera.result = .success(photoURL)
        location.result = .success(.init(latitude: 25.033,
                                         longitude: 121.5654,
                                         horizontalAccuracy: 18,
                                         timestamp: Date()))
        let formatter = RecordingTelegramMessageFormatter()
        service = TelegramNotificationService(
            settings: settings,
            sender: sender,
            camera: camera,
            location: location,
            removeFile: remover.remove,
            reporter: reporter,
            formatter: formatter
        )
        var result: Result<Void, Error>?

        service.sendTest(hostName: "Fred-Mac") { result = $0 }

        assertSuccess(result)
        XCTAssertEqual(formatter.photoCaptionContexts.count, 1)
        XCTAssertEqual(location.requestedDates, [formatter.photoCaptionContexts[0].timestamp])
    }

    func testTestNotificationUsesPhotoSetting() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        camera.result = .success(photoURL)
        var photoResult: Result<Void, Error>?

        service.sendTest(hostName: "Fred-Mac") { photoResult = $0 }

        assertSuccess(photoResult)
        XCTAssertEqual(camera.captureCalls, 1)
        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertEqual(sender.textCalls.count, 0)
        XCTAssertEqual(remover.calls, [photoURL])

        settings.takePhotoOnIntruded = false
        var textResult: Result<Void, Error>?
        service.sendTest(hostName: "Fred-Mac") { textResult = $0 }

        assertSuccess(textResult)
        XCTAssertEqual(camera.captureCalls, 1)
        XCTAssertEqual(sender.photoCalls.count, 1)
        XCTAssertEqual(sender.textCalls.count, 1)
    }

    func testPhotoEnabledTestSurfacesCaptureFailureAfterTextFallback() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        camera.result = .failure(.denied)
        var result: Result<Void, Error>?

        service.sendTest(hostName: "Fred-Mac") { result = $0 }

        guard case .failure(let error)? = result else {
            return XCTFail("Expected camera failure, got \(String(describing: result))")
        }
        XCTAssertEqual(error as? CameraCaptureError, .denied)
        XCTAssertEqual(sender.textCalls.count, 1,
                       "The test alert may still fall back to text")
        XCTAssertEqual(sender.photoCalls.count, 0)
        XCTAssertEqual(reporter.categories, ["camera"])
    }

    func testUserNotificationDeliveryCreatesAndDeliversOnMainThread() {
        let delivered = expectation(description: "notification delivered")
        let center = RecordingUserNotificationCenter()
        center.onDeliver = { delivered.fulfill() }
        var factoryWasOnMainThread = false
        let delivery = UserNotificationFailureDelivery(
            notificationCenter: center,
            notificationFactory: {
                factoryWasOnMainThread = Thread.isMainThread
                return NSUserNotification()
            }
        )

        DispatchQueue.global(qos: .utility).async {
            delivery.deliver(message: "Offline")
        }

        wait(for: [delivered], timeout: 1)
        XCTAssertTrue(factoryWasOnMainThread)
        XCTAssertTrue(center.deliveryWasOnMainThread)
        XCTAssertEqual(center.notifications.first?.subtitle,
                       t("telegram_failure_notification_subtitle"))
        XCTAssertEqual(center.notifications.first?.informativeText, "Offline")
    }

    func testFailureReporterRateLimitsSameFailureForFiveMinutes() {
        var now = Date(timeIntervalSince1970: 100)
        let delivery = RecordingFailureNotificationDelivery()
        let rateLimitedReporter = RateLimitedFailureReporter(
            now: { now },
            interval: 300,
            notificationDelivery: delivery
        )

        rateLimitedReporter.report(category: "camera", message: "Denied")
        rateLimitedReporter.report(category: "camera", message: "Denied again")
        rateLimitedReporter.report(category: "telegram", message: "Offline")
        now.addTimeInterval(299)
        rateLimitedReporter.report(category: "camera", message: "Still denied")

        XCTAssertEqual(delivery.messages, ["Denied", "Offline"])

        now.addTimeInterval(1)
        rateLimitedReporter.report(category: "camera", message: "Denied after interval")

        XCTAssertEqual(delivery.messages, ["Denied", "Offline", "Denied after interval"])
    }

    func testProductionAppWiresCoreLocationIntoTelegramMenuAndService() throws {
        let repository = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent(
            "BLEUnlock/AppDelegate.swift"
        ))
        XCTAssertTrue(source.contains("CoreMacLocationProvider"))
        XCTAssertTrue(source.contains("location: macLocationProvider"))
        XCTAssertTrue(source.contains("locationAuthorization: macLocationProvider"))
    }

    func testPhotoCaptionIncludesCoordinatesAccuracyAndEscapedAppleMapsLink() {
        let formatter = TelegramMessageFormatter()
        let context = TelegramEventContext(event: .intruded,
                                           hostName: "Fred-Mac",
                                           timestamp: Date(timeIntervalSince1970: 1_000),
                                           rssi: nil)
        let location = TelegramLocation(latitude: 25.033,
                                        longitude: 121.5654,
                                        horizontalAccuracy: 18.4,
                                        timestamp: context.timestamp)

        let caption = formatter.photoCaption(for: context, location: location)

        XCTAssertTrue(caption.contains("25.033000, 121.565400"))
        XCTAssertTrue(caption.contains("±18 m"))
        XCTAssertTrue(caption.contains("https://maps.apple.com/?ll=25.033000,121.565400"))
    }

    func testPhotoCaptionMarksLocationUnavailableWithoutCoordinates() {
        let formatter = TelegramMessageFormatter()
        let context = TelegramEventContext(event: .intruded,
                                           hostName: "Fred-Mac",
                                           timestamp: Date(timeIntervalSince1970: 1_000),
                                           rssi: nil)

        let caption = formatter.photoCaption(for: context, location: nil)

        XCTAssertTrue(caption.contains(t("telegram_location_unavailable")))
        XCTAssertFalse(caption.contains("maps.apple.com"))
    }

    private func configure() throws {
        try settings.saveCredentials(replacementToken: "token", chatID: "chat")
        settings.isEnabled = true
    }

    private func context(event: TelegramEvent, rssi: Int? = nil) -> TelegramEventContext {
        .init(event: event,
              hostName: "Fred-Mac",
              timestamp: Date(timeIntervalSince1970: 100),
              rssi: rssi)
    }

    private func assertNoCameraOrNetworkCalls(file: StaticString = #filePath,
                                              line: UInt = #line) {
        XCTAssertEqual(camera.captureCalls, 0, file: file, line: line)
        XCTAssertTrue(location.requestedDates.isEmpty, file: file, line: line)
        XCTAssertEqual(sender.textCalls.count, 0, file: file, line: line)
        XCTAssertEqual(sender.photoCalls.count, 0, file: file, line: line)
        XCTAssertEqual(sender.locationCalls.count, 0, file: file, line: line)
    }

    private func assertSuccess(_ result: Result<Void, Error>?,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        guard case .success? = result else {
            return XCTFail("Expected success, got \(String(describing: result))",
                           file: file,
                           line: line)
        }
    }
}

private final class RecordingTelegramMessageFormatter: TelegramMessageFormatting {
    private(set) var messageContexts: [TelegramEventContext] = []
    private(set) var photoCaptionContexts: [TelegramEventContext] = []

    func message(for context: TelegramEventContext) -> String {
        messageContexts.append(context)
        return "message"
    }

    func photoCaption(for context: TelegramEventContext,
                      location: TelegramLocation?) -> String {
        photoCaptionContexts.append(context)
        return "caption"
    }
}

private final class RecordingUserNotificationCenter: UserNotificationCenterDelivering {
    private(set) var notifications: [NSUserNotification] = []
    private(set) var deliveryWasOnMainThread = false
    var onDeliver: (() -> Void)?

    func deliver(_ notification: NSUserNotification) {
        deliveryWasOnMainThread = Thread.isMainThread
        notifications.append(notification)
        onDeliver?()
    }
}

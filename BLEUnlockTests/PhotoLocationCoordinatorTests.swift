import Foundation
import XCTest
@testable import BLEUnlock

final class PhotoLocationCoordinatorTests: XCTestCase {
    private var camera: ControlledPhotoCapturer!
    private var location: ControlledMacLocationProvider!
    private var coordinator: PhotoLocationCoordinator!
    private let capturedAt = Date(timeIntervalSince1970: 100)
    private let photoURL = URL(fileURLWithPath: "/private/tmp/location-test.jpg")
    private let validLocation = TelegramLocation(latitude: 25.033,
                                                 longitude: 121.5654,
                                                 horizontalAccuracy: 18,
                                                 timestamp: Date(timeIntervalSince1970: 100))

    override func setUp() {
        super.setUp()
        camera = ControlledPhotoCapturer()
        location = ControlledMacLocationProvider()
        coordinator = PhotoLocationCoordinator(camera: camera, location: location)
    }

    override func tearDown() {
        coordinator = nil
        location = nil
        camera = nil
        super.tearDown()
    }

    func testStartsPhotoAndLocationImmediatelyAndWaitsForBoth() {
        var outputs: [PhotoLocationOutcome] = []
        coordinator.capture(capturedAt: capturedAt) { outputs.append($0) }

        XCTAssertEqual(camera.captureCalls, 1)
        XCTAssertEqual(location.requestedDates, [capturedAt])
        camera.complete(.success(photoURL))
        XCTAssertTrue(outputs.isEmpty)
        location.complete(.success(validLocation))
        XCTAssertEqual(outputs, [.photo(photoURL, .success(validLocation))])
    }

    func testLocationFailureStillReturnsPhotoWithoutLocation() {
        var outcome: PhotoLocationOutcome?
        coordinator.capture(capturedAt: capturedAt) { outcome = $0 }

        location.complete(.failure(.timeout))
        camera.complete(.success(photoURL))

        XCTAssertEqual(outcome, .photo(photoURL, .failure(.timeout)))
    }

    func testCameraFailureCancelsLocationAndCompletesImmediatelyOnce() {
        var outcomes: [PhotoLocationOutcome] = []
        coordinator.capture(capturedAt: capturedAt) { outcomes.append($0) }

        camera.complete(.failure(.captureFailed))
        camera.complete(.failure(.denied))
        location.complete(.success(validLocation))

        XCTAssertEqual(location.token.cancelCalls, 1)
        XCTAssertEqual(outcomes, [.cameraFailure(.captureFailed)])
    }

    func testDuplicatePhotoFailureDoesNotReplaceFirstPhotoSuccessBeforeLocationArrives() {
        var outcomes: [PhotoLocationOutcome] = []
        coordinator.capture(capturedAt: capturedAt) { outcomes.append($0) }

        camera.complete(.success(photoURL))
        camera.complete(.failure(.captureFailed))

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(location.token.cancelCalls, 0)

        location.complete(.success(validLocation))

        XCTAssertEqual(outcomes, [.photo(photoURL, .success(validLocation))])
        XCTAssertEqual(location.token.cancelCalls, 0)
    }

    func testDuplicateLocationSuccessDoesNotReplaceFirstFailureBeforePhotoArrives() {
        var outcomes: [PhotoLocationOutcome] = []
        coordinator.capture(capturedAt: capturedAt) { outcomes.append($0) }

        location.complete(.failure(.timeout))
        location.complete(.success(validLocation))
        camera.complete(.success(photoURL))

        XCTAssertEqual(outcomes, [.photo(photoURL, .failure(.timeout))])
        XCTAssertEqual(location.token.cancelCalls, 0)
    }

    func testSynchronousCallbacksCompleteExactlyOnce() {
        let immediateLocation = ImmediateMacLocationProvider(result: .success(validLocation))
        let immediateCamera = ImmediatePhotoCapturer(result: .success(photoURL))
        let coordinator = PhotoLocationCoordinator(camera: immediateCamera,
                                                   location: immediateLocation)
        var outcomes: [PhotoLocationOutcome] = []

        coordinator.capture(capturedAt: capturedAt) { outcomes.append($0) }

        XCTAssertEqual(immediateLocation.requestedDates, [capturedAt])
        XCTAssertEqual(immediateCamera.captureCalls, 1)
        XCTAssertEqual(outcomes, [.photo(photoURL, .success(validLocation))])
    }

    func testConcurrentPhotoAndLocationCallbacksCompleteExactlyOnce() {
        let lock = NSLock()
        var outcomes: [PhotoLocationOutcome] = []
        coordinator.capture(capturedAt: capturedAt) { outcome in
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
        }

        DispatchQueue.concurrentPerform(iterations: 2) { iteration in
            if iteration == 0 {
                camera.complete(.success(photoURL))
            } else {
                location.complete(.success(validLocation))
            }
        }

        lock.lock()
        let recordedOutcomes = outcomes
        lock.unlock()
        XCTAssertEqual(recordedOutcomes, [.photo(photoURL, .success(validLocation))])
    }
}

private final class ControlledPhotoCapturer: PhotoCapturing {
    private let lock = NSLock()
    private var completion: ((Result<URL, CameraCaptureError>) -> Void)?
    private var storedCaptureCalls = 0

    var captureCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCaptureCalls
    }

    func capture(completion: @escaping (Result<URL, CameraCaptureError>) -> Void) {
        lock.lock()
        storedCaptureCalls += 1
        self.completion = completion
        lock.unlock()
    }

    func complete(_ result: Result<URL, CameraCaptureError>) {
        lock.lock()
        let completion = completion
        lock.unlock()
        completion?(result)
    }
}

private final class RecordingLocationToken: LocationRequestCancelling {
    private let lock = NSLock()
    private var storedCancelCalls = 0

    var cancelCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCancelCalls
    }

    func cancel() {
        lock.lock()
        storedCancelCalls += 1
        lock.unlock()
    }
}

private final class ControlledMacLocationProvider: MacLocationProviding {
    let token = RecordingLocationToken()
    private let lock = NSLock()
    private var storedRequestedDates: [Date] = []
    private var completion: ((Result<TelegramLocation, MacLocationError>) -> Void)?

    var requestedDates: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestedDates
    }

    @discardableResult
    func requestLocation(
        capturedAt: Date,
        completion: @escaping (Result<TelegramLocation, MacLocationError>) -> Void
    ) -> LocationRequestCancelling {
        lock.lock()
        storedRequestedDates.append(capturedAt)
        self.completion = completion
        lock.unlock()
        return token
    }

    func complete(_ result: Result<TelegramLocation, MacLocationError>) {
        lock.lock()
        let completion = completion
        lock.unlock()
        completion?(result)
    }
}

private final class ImmediatePhotoCapturer: PhotoCapturing {
    let result: Result<URL, CameraCaptureError>
    private(set) var captureCalls = 0

    init(result: Result<URL, CameraCaptureError>) {
        self.result = result
    }

    func capture(completion: @escaping (Result<URL, CameraCaptureError>) -> Void) {
        captureCalls += 1
        completion(result)
    }
}

private final class ImmediateMacLocationProvider: MacLocationProviding {
    let result: Result<TelegramLocation, MacLocationError>
    let token = RecordingLocationToken()
    private(set) var requestedDates: [Date] = []

    init(result: Result<TelegramLocation, MacLocationError>) {
        self.result = result
    }

    @discardableResult
    func requestLocation(
        capturedAt: Date,
        completion: @escaping (Result<TelegramLocation, MacLocationError>) -> Void
    ) -> LocationRequestCancelling {
        requestedDates.append(capturedAt)
        completion(result)
        return token
    }
}

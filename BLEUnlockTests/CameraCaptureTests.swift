import AVFoundation
import Foundation
import XCTest
@testable import BLEUnlock

final class StubCameraAuthorization: CameraAuthorizationProviding {
    var authorizationStatus: AVAuthorizationStatus = .authorized
    var requestResult = true
    private(set) var requestAccessCalls = 0

    func requestAccess(completion: @escaping (Bool) -> Void) {
        requestAccessCalls += 1
        completion(requestResult)
    }
}

final class StubPhotoSession: PhotoSessionProviding {
    var result: Result<Data, CameraCaptureError>?
    private(set) var stopped = false
    private(set) var captureCalls = 0
    private var completion: ((Result<Data, CameraCaptureError>) -> Void)?

    func captureJPEG(completion: @escaping (Result<Data, CameraCaptureError>) -> Void) {
        captureCalls += 1
        self.completion = completion
        if let result = result {
            completion(result)
        }
    }

    func complete(with result: Result<Data, CameraCaptureError>) {
        completion?(result)
    }

    func stop() {
        stopped = true
    }
}

final class StubScheduledCancellation: ScheduledCancellation {
    private(set) var cancelCalls = 0

    func cancel() {
        cancelCalls += 1
    }
}

final class StubCameraScheduler: CameraScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private(set) var blocks: [() -> Void] = []
    private(set) var cancellations: [StubScheduledCancellation] = []

    @discardableResult
    func schedule(after interval: TimeInterval,
                  _ block: @escaping () -> Void) -> ScheduledCancellation {
        let cancellation = StubScheduledCancellation()
        scheduledIntervals.append(interval)
        blocks.append(block)
        cancellations.append(cancellation)
        return cancellation
    }
}

final class StubAVCaptureSession: CaptureSessionRunning {
    private(set) var startRunningCalls = 0
    private(set) var stopRunningCalls = 0
    var isRunning = false

    func startRunning() {
        startRunningCalls += 1
        isRunning = true
    }

    func stopRunning() {
        stopRunningCalls += 1
        isRunning = false
    }
}

final class StubAVCapturePhotoOutput: PhotoOutputCapturing {
    private(set) var capturePhotoCalls = 0

    func capturePhoto(with settings: AVCapturePhotoSettings,
                      delegate: AVCapturePhotoCaptureDelegate) {
        capturePhotoCalls += 1
    }
}

struct ImmediateCameraTeardownScheduler: CameraTeardownScheduling {
    func schedule(_ block: @escaping () -> Void) {
        block()
    }
}

final class StubCameraTeardownScheduler: CameraTeardownScheduling {
    private(set) var blocks: [() -> Void] = []

    func schedule(_ block: @escaping () -> Void) {
        blocks.append(block)
    }
}

final class LifetimeTrackingPhotoSession: PhotoSessionProviding {
    var result: Result<Data, CameraCaptureError>?
    var onDeinit: (() -> Void)?

    func captureJPEG(completion: @escaping (Result<Data, CameraCaptureError>) -> Void) {
        if let result = result {
            completion(result)
        }
    }

    func stop() {}

    deinit {
        onDeinit?()
    }
}

final class RetainingCompletionPhotoSession: PhotoSessionProviding {
    var onDeinit: (() -> Void)?
    private var completion: ((Result<Data, CameraCaptureError>) -> Void)?

    func captureJPEG(completion: @escaping (Result<Data, CameraCaptureError>) -> Void) {
        self.completion = completion
    }

    func stop() {}

    deinit {
        onDeinit?()
    }
}

final class BlockingStopPhotoSession: PhotoSessionProviding {
    let stopStarted = DispatchSemaphore(value: 0)
    let allowStopToReturn = DispatchSemaphore(value: 0)

    func captureJPEG(completion: @escaping (Result<Data, CameraCaptureError>) -> Void) {}

    func stop() {
        stopStarted.signal()
        allowStopToReturn.wait()
    }
}

final class LifecycleBackedPhotoSession: PhotoSessionProviding {
    private let lifecycle: PhotoSessionLifecycle
    private(set) weak var captureDelegate: StubAbandonablePhotoDelegate?

    init(retirementScheduler: CameraScheduling,
         retirementTimeout: TimeInterval = 30) {
        lifecycle = PhotoSessionLifecycle(retirementScheduler: retirementScheduler,
                                          retirementTimeout: retirementTimeout)
    }

    func captureJPEG(completion: @escaping (Result<Data, CameraCaptureError>) -> Void) {
        let delegate = StubAbandonablePhotoDelegate()
        delegate.completion = {
            completion(.success(Data([0xFF, 0xD8, 0xFF, 0xD9])))
        }
        guard lifecycle.install(delegate: delegate) else { return }
        captureDelegate = delegate
    }

    func stop() {
        lifecycle.cancel()
    }

    func deliverLateCallback() {
        guard let delegate = captureDelegate else { return }
        delegate.deliverCallback()
        lifecycle.didFinishCallback(for: delegate)
    }

    func finishTeardown() {
        lifecycle.teardownDidFinish()
    }
}

final class LifetimeToken {}

final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

final class StubAbandonablePhotoDelegate: AbandonablePhotoCaptureDelegate {
    var completion: (() -> Void)?
    private(set) var abandonCalls = 0

    func deliverCallback() {
        completion?()
    }

    func abandon() {
        abandonCalls += 1
        completion = nil
    }
}

final class CameraCaptureTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var scheduler: StubCameraScheduler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BLEUnlock-CameraCaptureTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        scheduler = StubCameraScheduler()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        scheduler = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testAVPhotoSessionStartsSessionAndWaitsOneSecondBeforeRequestingPhoto() throws {
        let captureSession = StubAVCaptureSession()
        let photoOutput = StubAVCapturePhotoOutput()
        let queue = DispatchQueue(label: "CameraCaptureTests.AVPhotoSession")
        let photoSession = AVPhotoSession(session: captureSession,
                                          output: photoOutput,
                                          queue: queue,
                                          warmupScheduler: scheduler)

        photoSession.captureJPEG { _ in }
        queue.sync {}

        XCTAssertEqual(captureSession.startRunningCalls, 1)
        XCTAssertEqual(photoOutput.capturePhotoCalls, 0)
        XCTAssertEqual(scheduler.scheduledIntervals, [1])

        try XCTUnwrap(scheduler.blocks.first)()

        XCTAssertEqual(photoOutput.capturePhotoCalls, 1)
    }

    func testAVPhotoSessionCancellationDuringWarmupDoesNotRequestPhoto() throws {
        let captureSession = StubAVCaptureSession()
        let photoOutput = StubAVCapturePhotoOutput()
        let queue = DispatchQueue(label: "CameraCaptureTests.AVPhotoSession.cancel")
        let photoSession = AVPhotoSession(session: captureSession,
                                          output: photoOutput,
                                          queue: queue,
                                          warmupScheduler: scheduler)

        photoSession.captureJPEG { _ in }
        queue.sync {}
        photoSession.stop()

        try XCTUnwrap(scheduler.blocks.first)()

        XCTAssertEqual(photoOutput.capturePhotoCalls, 0)
    }

    func testAuthorizedCaptureWritesReturnedJPEGToUniqueTemporaryURL() throws {
        let session = StubPhotoSession()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        session.result = .success(jpeg)
        let done = expectation(description: "capture")

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { result in
            do {
                let url = try result.get()
                XCTAssertEqual(try Data(contentsOf: url), jpeg)
                XCTAssertEqual(url.deletingLastPathComponent(), self.temporaryDirectory)
                XCTAssertTrue(url.lastPathComponent.hasPrefix("BLEUnlock-intruded-"))
                XCTAssertEqual(url.pathExtension, "jpg")
                try FileManager.default.removeItem(at: url)
            } catch {
                XCTFail("\(error)")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        XCTAssertTrue(session.stopped)
        XCTAssertEqual(scheduler.scheduledIntervals, [10])
        XCTAssertEqual(scheduler.cancellations.first?.cancelCalls, 1)
    }

    func testNotDeterminedRequestsAccessBeforeCapture() {
        let authorization = StubCameraAuthorization()
        authorization.authorizationStatus = .notDetermined
        authorization.requestResult = true
        let session = StubPhotoSession()
        session.result = .success(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        var factoryObservedAccessRequest = false
        let done = expectation(description: "capture")

        CameraCapture(authorization: authorization,
                      sessionFactory: {
                          factoryObservedAccessRequest = authorization.requestAccessCalls == 1
                          return .success(session)
                      },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { result in
            if case .success(let url) = result {
                try? FileManager.default.removeItem(at: url)
            } else {
                XCTFail("Expected successful capture, got \(result)")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        XCTAssertEqual(authorization.requestAccessCalls, 1)
        XCTAssertTrue(factoryObservedAccessRequest)
        XCTAssertEqual(session.captureCalls, 1)
        XCTAssertTrue(session.stopped)
    }

    func testDeniedPermissionReturnsDeniedWithoutStartingSession() {
        let authorization = StubCameraAuthorization()
        authorization.authorizationStatus = .denied
        var factoryCalls = 0
        let done = expectation(description: "capture")

        CameraCapture(authorization: authorization,
                      sessionFactory: {
                          factoryCalls += 1
                          return .failure(.setupFailed)
                      },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { result in
            XCTAssertEqual(try? result.get(), nil)
            if case .failure(let error) = result {
                XCTAssertEqual(error, .denied)
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertTrue(scheduler.blocks.isEmpty)
    }

    func testMissingCameraReturnsNoCamera() {
        let done = expectation(description: "capture")

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .failure(.noCamera) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure, got \(result)")
            }
            XCTAssertEqual(error, .noCamera)
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        XCTAssertTrue(scheduler.blocks.isEmpty)
    }

    func testCaptureTimeoutStopsSessionAndReturnsTimeout() throws {
        let session = StubPhotoSession()
        var results: [Result<URL, CameraCaptureError>] = []

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture {
            results.append($0)
        }

        XCTAssertEqual(session.captureCalls, 1)
        XCTAssertFalse(session.stopped)
        let timeout = try XCTUnwrap(scheduler.blocks.first)
        timeout()
        session.complete(with: .success(Data([0xFF, 0xD8, 0xFF, 0xD9])))

        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results[0] else {
            return XCTFail("Expected timeout, got \(results[0])")
        }
        XCTAssertEqual(error, .timeout)
        XCTAssertTrue(session.stopped)
        XCTAssertEqual(scheduler.cancellations.first?.cancelCalls, 1)
    }

    func testCaptureFailureStopsSessionAndReturnsCaptureFailed() {
        let session = StubPhotoSession()
        session.result = .failure(.captureFailed)
        let done = expectation(description: "capture")

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure, got \(result)")
            }
            XCTAssertEqual(error, .captureFailed)
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        XCTAssertTrue(session.stopped)
        XCTAssertEqual(scheduler.cancellations.first?.cancelCalls, 1)
    }

    func testSynchronousSuccessReleasesSessionStateWithDispatchScheduler() {
        let released = expectation(description: "session released")
        var session: LifetimeTrackingPhotoSession? = LifetimeTrackingPhotoSession()
        session?.result = .success(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        session?.onDeinit = { released.fulfill() }
        let weakSession = WeakBox(session)

        let capture = CameraCapture(authorization: StubCameraAuthorization(),
                                    sessionFactory: { .success(session!) },
                                    temporaryDirectory: temporaryDirectory,
                                    scheduler: DispatchCameraScheduler(),
                                    teardownScheduler: ImmediateCameraTeardownScheduler(),
                                    timeout: 0.01)
        capture.capture { result in
            if case .success(let url) = result {
                try? FileManager.default.removeItem(at: url)
            } else {
                XCTFail("Expected successful capture, got \(result)")
            }
        }
        session = nil

        wait(for: [released], timeout: 1)
        XCTAssertNil(weakSession.value)
    }

    func testTimeoutReleasesSessionStateWithDispatchScheduler() {
        let timedOut = expectation(description: "capture timed out")
        let released = expectation(description: "session released")
        var session: LifetimeTrackingPhotoSession? = LifetimeTrackingPhotoSession()
        session?.onDeinit = { released.fulfill() }
        let weakSession = WeakBox(session)

        let capture = CameraCapture(authorization: StubCameraAuthorization(),
                                    sessionFactory: { .success(session!) },
                                    temporaryDirectory: temporaryDirectory,
                                    scheduler: DispatchCameraScheduler(),
                                    teardownScheduler: ImmediateCameraTeardownScheduler(),
                                    timeout: 0)
        capture.capture { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected timeout, got \(result)")
            }
            XCTAssertEqual(error, .timeout)
            timedOut.fulfill()
        }
        session = nil

        wait(for: [timedOut, released], timeout: 1)
        XCTAssertNil(weakSession.value)
    }

    func testCancellingLifecycleDoesNotWaitForBlockedActionAndReleasesPendingCompletion() {
        let lifecycle = PhotoSessionLifecycle()
        var deliveredCompletions = 0
        var completionOwner: LifetimeToken? = LifetimeToken()
        let weakCompletionOwner = WeakBox(completionOwner)
        XCTAssertTrue(lifecycle.prepare(completion: retainedResultCompletion(
            owner: completionOwner!
        ) {
            deliveredCompletions += 1
        }))
        completionOwner = nil
        XCTAssertNotNil(weakCompletionOwner.value)

        let actionStarted = DispatchSemaphore(value: 0)
        let allowActionToReturn = DispatchSemaphore(value: 0)
        let actionReturned = expectation(description: "action returned")
        DispatchQueue.global(qos: .utility).async {
            _ = lifecycle.performIfActive {
                actionStarted.signal()
                allowActionToReturn.wait()
            }
            actionReturned.fulfill()
        }
        XCTAssertEqual(actionStarted.wait(timeout: .now() + 1), .success)

        let cancelReturned = expectation(description: "cancel returned")
        DispatchQueue.global(qos: .utility).async {
            lifecycle.cancel()
            cancelReturned.fulfill()
        }
        let cancelResult = XCTWaiter.wait(for: [cancelReturned], timeout: 0.2)
        allowActionToReturn.signal()
        wait(for: [actionReturned], timeout: 1)

        XCTAssertEqual(cancelResult, .completed,
                       "Cancellation must not wait for startRunning to return")
        XCTAssertNil(weakCompletionOwner.value)
        XCTAssertEqual(deliveredCompletions, 0)
    }

    func testLateCallbackAfterTimeoutRetainsDelegateSuppressesClientAndThenReleases() throws {
        let retirementScheduler = StubCameraScheduler()
        let session = LifecycleBackedPhotoSession(retirementScheduler: retirementScheduler)
        var results: [Result<URL, CameraCaptureError>] = []

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture {
            results.append($0)
        }
        let weakDelegate = WeakBox(session.captureDelegate)

        try XCTUnwrap(scheduler.blocks.first)()

        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results[0] else {
            return XCTFail("Expected timeout, got \(results[0])")
        }
        XCTAssertEqual(error, .timeout)
        XCTAssertNotNil(weakDelegate.value,
                        "AVFoundation's in-flight delegate must survive cancellation")

        session.deliverLateCallback()

        XCTAssertEqual(results.count, 1,
                       "A callback after timeout must not complete the client again")
        XCTAssertNil(weakDelegate.value,
                     "The final capture callback is a safe delegate release point")
        XCTAssertEqual(retirementScheduler.cancellations.first?.cancelCalls, 1)
    }

    func testNoCallbackReleasesRetiredDelegateAfterTeardownCompletes() throws {
        let retirementScheduler = StubCameraScheduler()
        let session = LifecycleBackedPhotoSession(retirementScheduler: retirementScheduler)

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { _ in }
        let weakDelegate = WeakBox(session.captureDelegate)

        try XCTUnwrap(scheduler.blocks.first)()
        XCTAssertNotNil(weakDelegate.value)

        session.finishTeardown()

        XCTAssertNil(weakDelegate.value,
                     "Completed session teardown must release a delegate with no callback")
        XCTAssertEqual(retirementScheduler.cancellations.first?.cancelCalls, 1)
    }

    func testBlockedTeardownUsesBoundedFallbackToReleaseRetiredDelegate() throws {
        let retirementScheduler = StubCameraScheduler()
        let session = LifecycleBackedPhotoSession(retirementScheduler: retirementScheduler,
                                                  retirementTimeout: 3)

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { _ in }
        let weakDelegate = WeakBox(session.captureDelegate)

        try XCTUnwrap(scheduler.blocks.first)()
        XCTAssertNotNil(weakDelegate.value)
        XCTAssertEqual(retirementScheduler.scheduledIntervals, [3])

        try XCTUnwrap(retirementScheduler.blocks.first)()

        XCTAssertNil(weakDelegate.value,
                     "The independent fallback bounds retention if teardown never returns")
    }

    func testCancelledLifecycleSkipsQueuedStartAndPhotoCapture() {
        let cancelledBeforeStart = PhotoSessionLifecycle()
        var starts = 0
        var photoCaptures = 0
        cancelledBeforeStart.cancel()

        XCTAssertFalse(cancelledBeforeStart.performIfActive { starts += 1 })
        XCTAssertFalse(cancelledBeforeStart.performIfActive { photoCaptures += 1 })
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(photoCaptures, 0)

        let cancelledAfterStart = PhotoSessionLifecycle()
        XCTAssertTrue(cancelledAfterStart.performIfActive { starts += 1 })
        cancelledAfterStart.cancel()
        XCTAssertFalse(cancelledAfterStart.performIfActive { photoCaptures += 1 })
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(photoCaptures, 0)
    }

    func testTimeoutCompletesBeforePotentiallyBlockedTeardown() throws {
        let session = BlockingStopPhotoSession()
        let teardownScheduler = StubCameraTeardownScheduler()
        var results: [Result<URL, CameraCaptureError>] = []

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: teardownScheduler).capture {
            results.append($0)
        }

        try XCTUnwrap(scheduler.blocks.first)()

        XCTAssertEqual(results.count, 1,
                       "Timeout completion and text fallback must precede teardown")
        guard case .failure(let error) = results[0] else {
            return XCTFail("Expected timeout, got \(results[0])")
        }
        XCTAssertEqual(error, .timeout)
        XCTAssertEqual(teardownScheduler.blocks.count, 1)

        let teardownReturned = expectation(description: "teardown returned")
        DispatchQueue.global(qos: .utility).async {
            teardownScheduler.blocks[0]()
            teardownReturned.fulfill()
        }
        XCTAssertEqual(session.stopStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(results.count, 1)
        session.allowStopToReturn.signal()
        wait(for: [teardownReturned], timeout: 1)
    }

    func testTimeoutReleasesNeverCompletingSessionAfterTeardown() throws {
        let released = expectation(description: "session released")
        var session: RetainingCompletionPhotoSession? = RetainingCompletionPhotoSession()
        session?.onDeinit = { released.fulfill() }
        let weakSession = WeakBox(session)

        CameraCapture(authorization: StubCameraAuthorization(),
                      sessionFactory: { .success(session!) },
                      temporaryDirectory: temporaryDirectory,
                      scheduler: scheduler,
                      teardownScheduler: ImmediateCameraTeardownScheduler()).capture { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected timeout, got \(result)")
            }
            XCTAssertEqual(error, .timeout)
        }
        session = nil

        try XCTUnwrap(scheduler.blocks.first)()

        wait(for: [released], timeout: 1)
        XCTAssertNil(weakSession.value)
    }

    private func retainedResultCompletion(
        owner: LifetimeToken,
        completion: @escaping () -> Void
    ) -> (Result<Data, CameraCaptureError>) -> Void {
        return { _ in
            _ = owner
            completion()
        }
    }

}

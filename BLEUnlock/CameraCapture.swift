import AVFoundation
import Foundation

protocol PhotoCapturing {
    func capture(completion: @escaping (Result<URL, CameraCaptureError>) -> Void)
}

enum CameraCaptureError: LocalizedError, Equatable {
    case denied
    case restricted
    case noCamera
    case setupFailed
    case captureFailed
    case timeout
    case fileWriteFailed

    var errorDescription: String? {
        switch self {
        case .denied:
            return t("telegram_camera_error_denied")
        case .restricted:
            return t("telegram_camera_error_restricted")
        case .noCamera:
            return t("telegram_camera_error_no_camera")
        case .setupFailed:
            return t("telegram_camera_error_setup_failed")
        case .captureFailed:
            return t("telegram_camera_error_capture_failed")
        case .timeout:
            return t("telegram_camera_error_timeout")
        case .fileWriteFailed:
            return t("telegram_camera_error_file_write_failed")
        }
    }
}

protocol CameraAuthorizationProviding {
    var authorizationStatus: AVAuthorizationStatus { get }
    func requestAccess(completion: @escaping (Bool) -> Void)
}

protocol PhotoSessionProviding {
    func captureJPEG(completion: @escaping (Result<Data, CameraCaptureError>) -> Void)
    func stop()
}

protocol CaptureSessionRunning: AnyObject {
    var isRunning: Bool { get }
    func startRunning()
    func stopRunning()
}

protocol PhotoOutputCapturing: AnyObject {
    func capturePhoto(with settings: AVCapturePhotoSettings,
                      delegate: AVCapturePhotoCaptureDelegate)
}

extension AVCaptureSession: CaptureSessionRunning {}
extension AVCapturePhotoOutput: PhotoOutputCapturing {}

protocol ScheduledCancellation {
    func cancel()
}

protocol CameraScheduling {
    @discardableResult
    func schedule(after interval: TimeInterval,
                  _ block: @escaping () -> Void) -> ScheduledCancellation
}

protocol CameraTeardownScheduling {
    func schedule(_ block: @escaping () -> Void)
}

protocol AbandonablePhotoCaptureDelegate: AnyObject {
    func abandon()
}

final class PhotoSessionLifecycle {
    private let stateLock = NSLock()
    private let retirementScheduler: CameraScheduling
    private let retirementTimeout: TimeInterval
    private var cancelled = false
    private var pendingCompletion: ((Result<Data, CameraCaptureError>) -> Void)?
    private var activeDelegates: [ObjectIdentifier: AbandonablePhotoCaptureDelegate] = [:]
    private var retiredDelegates: [ObjectIdentifier: AbandonablePhotoCaptureDelegate] = [:]
    private var retirementCancellation: ScheduledCancellation?
    private var retirementGeneration = 0

    init(retirementScheduler: CameraScheduling = DispatchCameraScheduler(),
         retirementTimeout: TimeInterval = 30) {
        self.retirementScheduler = retirementScheduler
        self.retirementTimeout = retirementTimeout
    }

    func prepare(completion: @escaping (Result<Data, CameraCaptureError>) -> Void) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled else { return false }
        pendingCompletion = completion
        return true
    }

    func takePreparedCompletion() -> ((Result<Data, CameraCaptureError>) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled else { return nil }
        let completion = pendingCompletion
        pendingCompletion = nil
        return completion
    }

    func install(delegate: AbandonablePhotoCaptureDelegate) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled,
              activeDelegates.isEmpty,
              retiredDelegates.isEmpty else { return false }
        activeDelegates[ObjectIdentifier(delegate)] = delegate
        return true
    }

    @discardableResult
    func performIfActive(_ action: () -> Void) -> Bool {
        stateLock.lock()
        let isActive = !cancelled
        stateLock.unlock()
        guard isActive else { return false }

        action()
        return true
    }

    func cancel() {
        stateLock.lock()
        guard !cancelled else {
            stateLock.unlock()
            return
        }
        cancelled = true
        pendingCompletion = nil
        let delegates = Array(activeDelegates.values)
        retiredDelegates = activeDelegates
        activeDelegates.removeAll()
        retirementGeneration += 1
        let generation = retirementGeneration
        let shouldScheduleRetirement = !retiredDelegates.isEmpty
        stateLock.unlock()

        delegates.forEach { $0.abandon() }
        if shouldScheduleRetirement {
            scheduleRetiredDelegateRelease(generation: generation)
        }
    }

    func didFinishCallback(for delegate: AbandonablePhotoCaptureDelegate) {
        stateLock.lock()
        let identifier = ObjectIdentifier(delegate)
        activeDelegates[identifier] = nil
        retiredDelegates[identifier] = nil
        let cancellation: ScheduledCancellation?
        if retiredDelegates.isEmpty {
            retirementGeneration += 1
            cancellation = retirementCancellation
            retirementCancellation = nil
        } else {
            cancellation = nil
        }
        stateLock.unlock()
        cancellation?.cancel()
    }

    func teardownDidFinish() {
        releaseAllRetiredDelegates()
    }

    private func scheduleRetiredDelegateRelease(generation: Int) {
        let cancellation = retirementScheduler.schedule(after: retirementTimeout) { [weak self] in
            self?.releaseRetiredDelegates(generation: generation)
        }

        stateLock.lock()
        let shouldKeepCancellation = retirementGeneration == generation
            && !retiredDelegates.isEmpty
            && retirementCancellation == nil
        if shouldKeepCancellation {
            retirementCancellation = cancellation
        }
        stateLock.unlock()

        if !shouldKeepCancellation {
            cancellation.cancel()
        }
    }

    private func releaseRetiredDelegates(generation: Int) {
        stateLock.lock()
        guard retirementGeneration == generation else {
            stateLock.unlock()
            return
        }
        retiredDelegates.removeAll()
        retirementGeneration += 1
        let cancellation = retirementCancellation
        retirementCancellation = nil
        stateLock.unlock()
        cancellation?.cancel()
    }

    private func releaseAllRetiredDelegates() {
        stateLock.lock()
        retiredDelegates.removeAll()
        retirementGeneration += 1
        let cancellation = retirementCancellation
        retirementCancellation = nil
        stateLock.unlock()
        cancellation?.cancel()
    }
}

struct CameraWarmup {
    let scheduler: CameraScheduling
    let interval: TimeInterval

    @discardableResult
    func schedule(lifecycle: PhotoSessionLifecycle,
                  _ action: @escaping () -> Void) -> ScheduledCancellation {
        scheduler.schedule(after: interval) {
            _ = lifecycle.performIfActive(action)
        }
    }
}

final class CameraCapture: PhotoCapturing {
    private let authorization: CameraAuthorizationProviding
    private let sessionFactory: () -> Result<PhotoSessionProviding, CameraCaptureError>
    private let temporaryDirectory: URL
    private let scheduler: CameraScheduling
    private let teardownScheduler: CameraTeardownScheduling
    private let timeout: TimeInterval

    init(authorization: CameraAuthorizationProviding = AVCameraAuthorization(),
         sessionFactory: @escaping () -> Result<PhotoSessionProviding, CameraCaptureError> = AVPhotoSession.make,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         scheduler: CameraScheduling = DispatchCameraScheduler(),
         teardownScheduler: CameraTeardownScheduling = DispatchCameraTeardownScheduler(),
         timeout: TimeInterval = 10) {
        self.authorization = authorization
        self.sessionFactory = sessionFactory
        self.temporaryDirectory = temporaryDirectory
        self.scheduler = scheduler
        self.teardownScheduler = teardownScheduler
        self.timeout = timeout
    }

    func capture(completion: @escaping (Result<URL, CameraCaptureError>) -> Void) {
        switch authorization.authorizationStatus {
        case .authorized:
            captureAuthorized(completion: completion)
        case .notDetermined:
            authorization.requestAccess { granted in
                guard granted else {
                    completion(.failure(.denied))
                    return
                }
                self.captureAuthorized(completion: completion)
            }
        case .denied:
            completion(.failure(.denied))
        case .restricted:
            completion(.failure(.restricted))
        @unknown default:
            completion(.failure(.restricted))
        }
    }

    private func captureAuthorized(
        completion: @escaping (Result<URL, CameraCaptureError>) -> Void
    ) {
        let session: PhotoSessionProviding
        switch sessionFactory() {
        case .success(let createdSession):
            session = createdSession
        case .failure(let error):
            completion(.failure(error))
            return
        }

        CameraCaptureAttempt(session: session,
                             temporaryDirectory: temporaryDirectory,
                             teardownScheduler: teardownScheduler,
                             completion: completion)
            .start(scheduler: scheduler, timeout: timeout)
    }
}

private final class CameraCaptureAttempt {
    private let lock = NSLock()
    private let temporaryDirectory: URL
    private let teardownScheduler: CameraTeardownScheduling
    private var session: PhotoSessionProviding?
    private var completion: ((Result<URL, CameraCaptureError>) -> Void)?
    private var timeoutCancellation: ScheduledCancellation?
    private var didFinish = false

    init(session: PhotoSessionProviding,
         temporaryDirectory: URL,
         teardownScheduler: CameraTeardownScheduling,
         completion: @escaping (Result<URL, CameraCaptureError>) -> Void) {
        self.session = session
        self.temporaryDirectory = temporaryDirectory
        self.teardownScheduler = teardownScheduler
        self.completion = completion
    }

    func start(scheduler: CameraScheduling, timeout: TimeInterval) {
        let cancellation = scheduler.schedule(after: timeout) { [self] in
            finish(.failure(.timeout))
        }

        lock.lock()
        let activeSession: PhotoSessionProviding?
        if didFinish {
            activeSession = nil
        } else {
            timeoutCancellation = cancellation
            activeSession = session
        }
        lock.unlock()

        guard let activeSession = activeSession else {
            cancellation.cancel()
            return
        }
        activeSession.captureJPEG { [weak self] result in
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<Data, CameraCaptureError>) {
        lock.lock()
        guard !didFinish,
              let session = session,
              let completion = completion else {
            lock.unlock()
            return
        }
        didFinish = true
        self.session = nil
        self.completion = nil
        let cancellation = timeoutCancellation
        timeoutCancellation = nil
        lock.unlock()

        cancellation?.cancel()

        let finalResult: Result<URL, CameraCaptureError>
        switch result {
        case .success(let jpeg):
            let url = temporaryDirectory
                .appendingPathComponent("BLEUnlock-intruded-\(UUID().uuidString)")
                .appendingPathExtension("jpg")
            do {
                try jpeg.write(to: url, options: .atomic)
                finalResult = .success(url)
            } catch {
                finalResult = .failure(.fileWriteFailed)
            }
        case .failure(let error):
            finalResult = .failure(error)
        }

        completion(finalResult)
        teardownScheduler.schedule {
            session.stop()
        }
    }
}

final class AVCameraAuthorization: CameraAuthorizationProviding {
    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }
}

private final class DispatchScheduledCancellation: ScheduledCancellation {
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        lock.lock()
        let item = workItem
        workItem = nil
        lock.unlock()
        item?.cancel()
    }
}

final class DispatchCameraScheduler: CameraScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue.global(qos: .utility)) {
        self.queue = queue
    }

    @discardableResult
    func schedule(after interval: TimeInterval,
                  _ block: @escaping () -> Void) -> ScheduledCancellation {
        let workItem = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
        return DispatchScheduledCancellation(workItem: workItem)
    }
}

final class DispatchCameraTeardownScheduler: CameraTeardownScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue.global(qos: .utility)) {
        self.queue = queue
    }

    func schedule(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }
}

final class AVPhotoSession: PhotoSessionProviding {
    private let session: CaptureSessionRunning
    private let output: PhotoOutputCapturing
    private let queue: DispatchQueue
    private let warmup: CameraWarmup
    private let lifecycle = PhotoSessionLifecycle()

    init(session: CaptureSessionRunning,
         output: PhotoOutputCapturing,
         queue: DispatchQueue = DispatchQueue(
            label: "jp.sone.BLEUnlock.camera-capture"
         ),
         warmupScheduler: CameraScheduling? = nil,
         warmupInterval: TimeInterval = 1) {
        self.session = session
        self.output = output
        self.queue = queue
        self.warmup = CameraWarmup(
            scheduler: warmupScheduler ?? DispatchCameraScheduler(queue: queue),
            interval: warmupInterval
        )
    }

    static func make() -> Result<PhotoSessionProviding, CameraCaptureError> {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            return .failure(.noCamera)
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            return .failure(.setupFailed)
        }

        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input), session.canAddOutput(output) else {
            return .failure(.setupFailed)
        }
        session.addInput(input)
        session.addOutput(output)
        return .success(AVPhotoSession(session: session, output: output))
    }

    func captureJPEG(completion: @escaping (Result<Data, CameraCaptureError>) -> Void) {
        guard lifecycle.prepare(completion: completion) else { return }
        queue.async { [session, output, lifecycle] in
            guard lifecycle.performIfActive({ session.startRunning() }) else {
                return
            }
            self.warmup.schedule(lifecycle: lifecycle) { [output, lifecycle] in
                guard let completion = lifecycle.takePreparedCompletion() else { return }
                let proxy = AVPhotoCaptureDelegateProxy(completion: completion) { [weak lifecycle] proxy in
                    lifecycle?.didFinishCallback(for: proxy)
                }
                guard lifecycle.install(delegate: proxy) else {
                    proxy.abandon()
                    return
                }
                guard lifecycle.performIfActive({
                    output.capturePhoto(with: AVCapturePhotoSettings(), delegate: proxy)
                }) else {
                    proxy.abandon()
                    lifecycle.didFinishCallback(for: proxy)
                    return
                }
            }
        }
    }

    func stop() {
        lifecycle.cancel()
        queue.async { [session, lifecycle] in
            defer { lifecycle.teardownDidFinish() }
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

private final class AVPhotoCaptureDelegateProxy: NSObject,
                                                 AVCapturePhotoCaptureDelegate,
                                                 AbandonablePhotoCaptureDelegate {
    private let lock = NSLock()
    private var didComplete = false
    private var completion: ((Result<Data, CameraCaptureError>) -> Void)?
    private let callbackFinished: (AVPhotoCaptureDelegateProxy) -> Void

    init(completion: @escaping (Result<Data, CameraCaptureError>) -> Void,
         callbackFinished: @escaping (AVPhotoCaptureDelegateProxy) -> Void) {
        self.completion = completion
        self.callbackFinished = callbackFinished
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let result: Result<Data, CameraCaptureError>
        if error != nil {
            result = .failure(.captureFailed)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(data)
        } else {
            result = .failure(.captureFailed)
        }
        finish(result)
    }

    private func finish(_ result: Result<Data, CameraCaptureError>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(result)
        callbackFinished(self)
    }

    func abandon() {
        lock.lock()
        completion = nil
        lock.unlock()
    }
}

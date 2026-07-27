import Foundation

enum PhotoLocationOutcome: Equatable {
    case photo(URL, Result<TelegramLocation, MacLocationError>)
    case cameraFailure(CameraCaptureError)
}

final class PhotoLocationCoordinator {
    private let camera: PhotoCapturing
    private let location: MacLocationProviding
    private let lock = NSLock()
    private var photo: Result<URL, CameraCaptureError>?
    private var position: Result<TelegramLocation, MacLocationError>?
    private var locationToken: LocationRequestCancelling?
    private var didComplete = false

    init(camera: PhotoCapturing, location: MacLocationProviding) {
        self.camera = camera
        self.location = location
    }

    func capture(capturedAt: Date,
                 completion: @escaping (PhotoLocationOutcome) -> Void) {
        let token = location.requestLocation(capturedAt: capturedAt) { [weak self] result in
            self?.record(location: result, completion: completion)
        }
        lock.lock()
        locationToken = token
        let cancelImmediately = didComplete
        lock.unlock()
        if cancelImmediately {
            token.cancel()
        }

        camera.capture { [weak self] result in
            self?.record(photo: result, completion: completion)
        }
    }

    private func record(photo result: Result<URL, CameraCaptureError>,
                        completion: @escaping (PhotoLocationOutcome) -> Void) {
        var action: (() -> Void)?
        lock.lock()
        if !didComplete, photo == nil {
            photo = result
            switch result {
            case .failure(let error):
                didComplete = true
                let token = locationToken
                locationToken = nil
                action = {
                    token?.cancel()
                    completion(.cameraFailure(error))
                }
            case .success:
                action = finishPhotoIfReady(completion: completion)
            }
        }
        lock.unlock()
        action?()
    }

    private func record(location result: Result<TelegramLocation, MacLocationError>,
                        completion: @escaping (PhotoLocationOutcome) -> Void) {
        var action: (() -> Void)?
        lock.lock()
        if !didComplete, position == nil {
            position = result
            action = finishPhotoIfReady(completion: completion)
        }
        lock.unlock()
        action?()
    }

    private func finishPhotoIfReady(
        completion: @escaping (PhotoLocationOutcome) -> Void
    ) -> (() -> Void)? {
        guard case .success(let url)? = photo,
              let position = position else { return nil }
        didComplete = true
        locationToken = nil
        return { completion(.photo(url, position)) }
    }
}

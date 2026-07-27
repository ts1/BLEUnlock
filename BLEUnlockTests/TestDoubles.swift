import Foundation
@testable import BLEUnlock

enum TelegramCallKind: Equatable {
    case text
    case photo
    case location
}

final class MemorySecretStore: SecretStoring {
    var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func removeValue(for account: String) throws { values.removeValue(forKey: account) }
}

final class ThrowingSecretStore: SecretStoring {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func string(for account: String) throws -> String? { throw error }
    func set(_ value: String, for account: String) throws { throw error }
    func removeValue(for account: String) throws { throw error }
}

final class RecordingHTTPTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var result: Result<(Data, HTTPURLResponse), Error>!

    func perform(_ request: URLRequest,
                 completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        requests.append(request)
        completion(result)
    }
}

final class RecordingTelegramSender: TelegramSending {
    struct TextCall {
        let credentials: TelegramCredentials
        let text: String
    }

    struct PhotoCall {
        let credentials: TelegramCredentials
        let photoURL: URL
        let caption: String
    }

    struct LocationCall {
        let credentials: TelegramCredentials
        let location: TelegramLocation
    }

    var textResult: Result<Void, TelegramError> = .success(())
    var photoResult: Result<Void, TelegramError> = .success(())
    var locationResult: Result<Void, TelegramError> = .success(())
    private(set) var textCalls: [TextCall] = []
    private(set) var photoCalls: [PhotoCall] = []
    private(set) var locationCalls: [LocationCall] = []
    private(set) var callOrder: [TelegramCallKind] = []

    func sendText(credentials: TelegramCredentials,
                  text: String,
                  completion: @escaping (Result<Void, TelegramError>) -> Void) {
        callOrder.append(.text)
        textCalls.append(.init(credentials: credentials, text: text))
        completion(textResult)
    }

    func sendPhoto(credentials: TelegramCredentials,
                   photoURL: URL,
                   caption: String,
                   completion: @escaping (Result<Void, TelegramError>) -> Void) {
        callOrder.append(.photo)
        photoCalls.append(.init(credentials: credentials,
                                photoURL: photoURL,
                                caption: caption))
        completion(photoResult)
    }

    func sendLocation(credentials: TelegramCredentials,
                      location: TelegramLocation,
                      completion: @escaping (Result<Void, TelegramError>) -> Void) {
        callOrder.append(.location)
        locationCalls.append(.init(credentials: credentials, location: location))
        completion(locationResult)
    }
}

final class StubPhotoCapturer: PhotoCapturing {
    var result: Result<URL, CameraCaptureError> = .failure(.captureFailed)
    private(set) var captureCalls = 0

    func capture(completion: @escaping (Result<URL, CameraCaptureError>) -> Void) {
        captureCalls += 1
        completion(result)
    }
}

final class StubLocationRequestToken: LocationRequestCancelling {
    private(set) var cancelCalls = 0

    func cancel() {
        cancelCalls += 1
    }
}

final class StubMacLocationProvider: MacLocationProviding {
    var result: Result<TelegramLocation, MacLocationError> = .failure(.unavailable)
    private(set) var requestedDates: [Date] = []
    let token = StubLocationRequestToken()

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

final class RecordingFailureReporter: FailureReporting {
    private(set) var categories: [String] = []
    private(set) var messages: [String] = []

    func report(category: String, message: String) {
        categories.append(category)
        messages.append(message)
    }
}

final class RecordingFileRemover {
    private(set) var calls: [URL] = []
    var error: Error?

    func remove(_ url: URL) throws {
        calls.append(url)
        if let error = error {
            throw error
        }
    }
}

final class RecordingFailureNotificationDelivery: FailureNotificationDelivering {
    private(set) var messages: [String] = []

    func deliver(message: String) {
        messages.append(message)
    }
}

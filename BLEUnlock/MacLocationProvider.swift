import CoreLocation
import Foundation

struct TelegramLocation: Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: CLLocationAccuracy
    let timestamp: Date
}

enum MacLocationError: Error, Equatable {
    case servicesDisabled
    case denied
    case restricted
    case unavailable
    case invalidLocation
    case timeout
    case cancelled
}

protocol LocationRequestCancelling: AnyObject {
    func cancel()
}

protocol LocationAuthorizationRequesting {
    func requestAuthorization()
}

protocol MacLocationProviding {
    @discardableResult
    func requestLocation(
        capturedAt: Date,
        completion: @escaping (Result<TelegramLocation, MacLocationError>) -> Void
    ) -> LocationRequestCancelling
}

protocol CoreLocationClient: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func stop()
}

final class CLLocationClient: NSObject, CoreLocationClient, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onError: ((Error) -> Void)?
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestLocation() { manager.requestLocation() }
    func stop() { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onError?(error)
    }
}

final class CoreMacLocationProvider: MacLocationProviding, LocationAuthorizationRequesting {
    typealias ClientFactory = () -> CoreLocationClient
    typealias TimeoutScheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    private let makeClient: ClientFactory
    private let servicesEnabled: () -> Bool
    private let scheduleTimeout: TimeoutScheduler
    private var authorizationClient: CoreLocationClient?
    private var activeRequests: [CoreMacLocationRequest] = []

    init(makeClient: @escaping ClientFactory = CLLocationClient.init,
         servicesEnabled: @escaping () -> Bool = CLLocationManager.locationServicesEnabled,
         scheduleTimeout: @escaping TimeoutScheduler = CoreMacLocationProvider.dispatchTimeout) {
        self.makeClient = makeClient
        self.servicesEnabled = servicesEnabled
        self.scheduleTimeout = scheduleTimeout
    }

    func requestAuthorization() {
        DispatchQueue.main.async {
            guard self.servicesEnabled() else { return }
            let client = self.makeClient()
            self.authorizationClient = client
            if client.authorizationStatus == .notDetermined {
                client.requestWhenInUseAuthorization()
            }
        }
    }

    @discardableResult
    func requestLocation(
        capturedAt: Date,
        completion: @escaping (Result<TelegramLocation, MacLocationError>) -> Void
    ) -> LocationRequestCancelling {
        let request = CoreMacLocationRequest(makeClient: makeClient,
                                             servicesEnabled: servicesEnabled,
                                             scheduleTimeout: scheduleTimeout,
                                             capturedAt: capturedAt,
                                             completion: completion)
        request.onFinish = { [weak self, weak request] in
            guard let request = request else { return }
            self?.release(request)
        }
        if Thread.isMainThread {
            retainAndStart(request)
        } else {
            DispatchQueue.main.async {
                self.retainAndStart(request)
            }
        }
        return request
    }

    private func retainAndStart(_ request: CoreMacLocationRequest) {
        dispatchPrecondition(condition: .onQueue(.main))
        activeRequests.append(request)
        request.start()
    }

    private func release(_ request: CoreMacLocationRequest) {
        dispatchPrecondition(condition: .onQueue(.main))
        activeRequests.removeAll { $0 === request }
    }

    static func dispatchTimeout(after interval: TimeInterval,
                                action: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
        return { item.cancel() }
    }
}

private final class CoreMacLocationRequest: LocationRequestCancelling {
    private let makeClient: () -> CoreLocationClient
    private let servicesEnabled: () -> Bool
    private let scheduleTimeout: CoreMacLocationProvider.TimeoutScheduler
    private let capturedAt: Date
    private var completion: ((Result<TelegramLocation, MacLocationError>) -> Void)?
    private var client: CoreLocationClient?
    private var cancelTimeout: (() -> Void)?
    private var didRequestAuthorization = false
    private var didRequestLocation = false
    private var didFinish = false
    var onFinish: (() -> Void)?

    init(makeClient: @escaping () -> CoreLocationClient,
         servicesEnabled: @escaping () -> Bool,
         scheduleTimeout: @escaping CoreMacLocationProvider.TimeoutScheduler,
         capturedAt: Date,
         completion: @escaping (Result<TelegramLocation, MacLocationError>) -> Void) {
        self.makeClient = makeClient
        self.servicesEnabled = servicesEnabled
        self.scheduleTimeout = scheduleTimeout
        self.capturedAt = capturedAt
        self.completion = completion
    }

    func start() {
        if Thread.isMainThread { startOnMain() }
        else { DispatchQueue.main.async { self.startOnMain() } }
    }

    func cancel() {
        if Thread.isMainThread { finish(.failure(.cancelled)) }
        else { DispatchQueue.main.async { self.finish(.failure(.cancelled)) } }
    }

    private func startOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !didFinish else { return }
        guard servicesEnabled() else {
            finish(.failure(.servicesDisabled))
            return
        }
        let client = makeClient()
        self.client = client
        client.onAuthorizationChange = { [weak self] in self?.handleAuthorization($0) }
        client.onLocations = { [weak self] in self?.accept($0) }
        client.onError = { [weak self] _ in self?.finish(.failure(.unavailable)) }
        cancelTimeout = scheduleTimeout(5) { [weak self] in
            self?.finish(.failure(.timeout))
        }
        handleAuthorization(client.authorizationStatus)
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        guard !didFinish, let client = client else { return }
        switch status {
        case .authorizedAlways:
            guard !didRequestLocation else { return }
            didRequestLocation = true
            client.requestLocation()
        case .denied:
            finish(.failure(.denied))
        case .restricted:
            finish(.failure(.restricted))
        case .notDetermined:
            guard !didRequestAuthorization else { return }
            didRequestAuthorization = true
            client.requestWhenInUseAuthorization()
        @unknown default:
            finish(.failure(.unavailable))
        }
    }

    private func accept(_ locations: [CLLocation]) {
        guard !didFinish else { return }
        guard let value = locations.reversed().first(where: { location in
            CLLocationCoordinate2DIsValid(location.coordinate) &&
                location.horizontalAccuracy >= 0 &&
                abs(location.timestamp.timeIntervalSince(capturedAt)) <= 60
        }) else {
            finish(.failure(.invalidLocation))
            return
        }
        finish(.success(.init(latitude: value.coordinate.latitude,
                              longitude: value.coordinate.longitude,
                              horizontalAccuracy: value.horizontalAccuracy,
                              timestamp: value.timestamp)))
    }

    private func finish(_ result: Result<TelegramLocation, MacLocationError>) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !didFinish, let completion = completion else { return }
        didFinish = true
        self.completion = nil
        cancelTimeout?()
        cancelTimeout = nil
        client?.stop()
        client?.onAuthorizationChange = nil
        client?.onLocations = nil
        client?.onError = nil
        client = nil
        onFinish?()
        onFinish = nil
        completion(result)
    }
}

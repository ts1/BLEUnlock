import CoreLocation
import Foundation
import XCTest
@testable import BLEUnlock

final class MacLocationProviderTests: XCTestCase {
    private var client: RecordingCoreLocationClient!
    private var scheduler: ControlledLocationTimeoutScheduler!

    override func setUp() {
        super.setUp()
        client = RecordingCoreLocationClient()
        scheduler = ControlledLocationTimeoutScheduler()
    }

    func testFreshValidLocationCompletesOnce() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let provider = makeProvider()
        var results: [Result<TelegramLocation, MacLocationError>] = []

        let token = provider.requestLocation(capturedAt: capturedAt) { results.append($0) }
        client.sendAuthorization(.authorizedAlways)
        client.sendLocations([
            CLLocation(coordinate: .init(latitude: 25.0330, longitude: 121.5654),
                       altitude: 0,
                       horizontalAccuracy: 18,
                       verticalAccuracy: -1,
                       timestamp: capturedAt.addingTimeInterval(2))
        ])
        client.sendLocations([])

        XCTAssertNotNil(token)
        XCTAssertEqual(results, [.success(.init(latitude: 25.0330,
                                                longitude: 121.5654,
                                                horizontalAccuracy: 18,
                                                timestamp: capturedAt.addingTimeInterval(2)))])
        XCTAssertEqual(client.requestLocationCalls, 1)
        XCTAssertEqual(client.stopCalls, 1)
    }

    func testRejectsStaleAndInvalidLocations() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let provider = makeProvider()
        var result: Result<TelegramLocation, MacLocationError>?

        _ = provider.requestLocation(capturedAt: capturedAt) { result = $0 }
        client.sendAuthorization(.authorizedAlways)
        client.sendLocations([
            CLLocation(coordinate: .init(latitude: 25, longitude: 121),
                       altitude: 0,
                       horizontalAccuracy: 10,
                       verticalAccuracy: -1,
                       timestamp: capturedAt.addingTimeInterval(-61))
        ])

        XCTAssertEqual(result, .failure(.invalidLocation))
    }

    func testRejectsInvalidCoordinates() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let provider = makeProvider()
        var result: Result<TelegramLocation, MacLocationError>?

        _ = provider.requestLocation(capturedAt: capturedAt) { result = $0 }
        client.sendAuthorization(.authorizedAlways)
        client.sendLocations([location(latitude: 100,
                                      longitude: 121,
                                      horizontalAccuracy: 10,
                                      timestamp: capturedAt)])

        XCTAssertEqual(result, .failure(.invalidLocation))
    }

    func testRejectsNegativeHorizontalAccuracy() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let provider = makeProvider()
        var result: Result<TelegramLocation, MacLocationError>?

        _ = provider.requestLocation(capturedAt: capturedAt) { result = $0 }
        client.sendAuthorization(.authorizedAlways)
        client.sendLocations([location(horizontalAccuracy: -1, timestamp: capturedAt)])

        XCTAssertEqual(result, .failure(.invalidLocation))
    }

    func testRejectsLocationMoreThanSixtySecondsAfterCapture() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let provider = makeProvider()
        var result: Result<TelegramLocation, MacLocationError>?

        _ = provider.requestLocation(capturedAt: capturedAt) { result = $0 }
        client.sendAuthorization(.authorizedAlways)
        client.sendLocations([location(timestamp: capturedAt.addingTimeInterval(61))])

        XCTAssertEqual(result, .failure(.invalidLocation))
    }

    func testAcceptsLocationsExactlySixtySecondsFromCapture() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)

        for offset in [-60.0, 60.0] {
            client = RecordingCoreLocationClient()
            scheduler = ControlledLocationTimeoutScheduler()
            let provider = makeProvider()
            var result: Result<TelegramLocation, MacLocationError>?
            let timestamp = capturedAt.addingTimeInterval(offset)

            _ = provider.requestLocation(capturedAt: capturedAt) { result = $0 }
            client.sendAuthorization(.authorizedAlways)
            client.sendLocations([location(timestamp: timestamp)])

            XCTAssertEqual(result, .success(.init(latitude: 25.033,
                                                   longitude: 121.5654,
                                                   horizontalAccuracy: 18,
                                                   timestamp: timestamp)))
        }
    }

    func testTimesOutAfterFiveSecondsAndIgnoresLateCallback() {
        let provider = makeProvider()
        var results: [Result<TelegramLocation, MacLocationError>] = []

        _ = provider.requestLocation(capturedAt: Date()) { results.append($0) }
        XCTAssertEqual(scheduler.intervals, [5])
        scheduler.fireFirst()
        client.sendLocations([freshLocation])

        XCTAssertEqual(results, [.failure(.timeout)])
        XCTAssertEqual(client.stopCalls, 1)
    }

    func testServicesDisabledCompletesOnceWithoutCreatingAClient() {
        var makeClientCalls = 0
        let provider = CoreMacLocationProvider(makeClient: {
            makeClientCalls += 1
            return self.client
        },
                                               servicesEnabled: { false },
                                               scheduleTimeout: scheduler.schedule)
        var results: [Result<TelegramLocation, MacLocationError>] = []

        _ = provider.requestLocation(capturedAt: Date()) { results.append($0) }

        XCTAssertEqual(results, [.failure(.servicesDisabled)])
        XCTAssertEqual(makeClientCalls, 0)
        XCTAssertEqual(scheduler.intervals, [])
    }

    func testClientErrorCompletesOnceAndStopsTheRequest() {
        client.authorizationStatus = .authorizedAlways
        let provider = makeProvider()
        var results: [Result<TelegramLocation, MacLocationError>] = []

        _ = provider.requestLocation(capturedAt: Date()) { results.append($0) }
        client.send(error: NSError(domain: "test", code: 1))
        client.send(error: NSError(domain: "test", code: 2))
        client.sendLocations([freshLocation])

        XCTAssertEqual(results, [.failure(.unavailable)])
        XCTAssertEqual(client.stopCalls, 1)
    }

    func testNotDeterminedRequestsAuthorizationOnlyOnceForRepeatedCallbacks() {
        let provider = makeProvider()

        let token = provider.requestLocation(capturedAt: Date()) { _ in }
        client.sendAuthorization(.notDetermined)
        client.sendAuthorization(.notDetermined)

        XCTAssertEqual(client.authorizationCalls, 1)
        XCTAssertEqual(client.requestLocationCalls, 0)
        token.cancel()
    }

    func testClientConstructionMovesToMainThreadWhenRequestedOffMain() {
        client.authorizationStatus = .authorizedAlways
        let clientCreated = expectation(description: "Client created")
        let completed = expectation(description: "Request completed")
        var madeClientOnMainThread = false
        let provider = CoreMacLocationProvider(makeClient: {
            madeClientOnMainThread = Thread.isMainThread
            clientCreated.fulfill()
            return self.client
        },
                                               servicesEnabled: { true },
                                               scheduleTimeout: scheduler.schedule)

        DispatchQueue.global().async {
            _ = provider.requestLocation(capturedAt: Date()) { _ in completed.fulfill() }
        }

        wait(for: [clientCreated], timeout: 1)
        XCTAssertTrue(madeClientOnMainThread)
        client.send(error: NSError(domain: "test", code: 1))
        wait(for: [completed], timeout: 1)
    }

    func testDeniedRestrictedAndCancelledRequestsCompleteWithoutCoordinates() {
        assertAuthorization(.denied, produces: .denied)
        assertAuthorization(.restricted, produces: .restricted)

        client.authorizationStatus = .notDetermined
        let provider = makeProvider()
        var result: Result<TelegramLocation, MacLocationError>?
        let token = provider.requestLocation(capturedAt: Date()) { result = $0 }
        token.cancel()
        XCTAssertEqual(result, .failure(.cancelled))
    }

    private func makeProvider() -> CoreMacLocationProvider {
        CoreMacLocationProvider(makeClient: { self.client },
                                servicesEnabled: { true },
                                scheduleTimeout: self.scheduler.schedule)
    }

    private var freshLocation: CLLocation {
        location(timestamp: Date())
    }

    private func location(latitude: CLLocationDegrees = 25.033,
                          longitude: CLLocationDegrees = 121.5654,
                          horizontalAccuracy: CLLocationAccuracy = 18,
                          timestamp: Date) -> CLLocation {
        CLLocation(coordinate: .init(latitude: latitude, longitude: longitude),
                   altitude: 0,
                   horizontalAccuracy: horizontalAccuracy,
                   verticalAccuracy: -1,
                   timestamp: timestamp)
    }

    private func assertAuthorization(_ status: CLAuthorizationStatus,
                                     produces expected: MacLocationError) {
        client.authorizationStatus = .notDetermined
        let provider = makeProvider()
        var result: Result<TelegramLocation, MacLocationError>?
        _ = provider.requestLocation(capturedAt: Date()) { result = $0 }
        client.sendAuthorization(status)
        XCTAssertEqual(result, .failure(expected))
    }
}

private final class RecordingCoreLocationClient: CoreLocationClient {
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var authorizationCalls = 0
    private(set) var requestLocationCalls = 0
    private(set) var stopCalls = 0

    func requestWhenInUseAuthorization() { authorizationCalls += 1 }
    func requestLocation() { requestLocationCalls += 1 }
    func stop() { stopCalls += 1 }

    func sendAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        onAuthorizationChange?(status)
    }

    func sendLocations(_ locations: [CLLocation]) { onLocations?(locations) }
    func send(error: Error) { onError?(error) }
}

private final class ControlledLocationTimeoutScheduler {
    private(set) var intervals: [TimeInterval] = []
    private var actions: [() -> Void] = []

    func schedule(after interval: TimeInterval,
                  action: @escaping () -> Void) -> () -> Void {
        intervals.append(interval)
        actions.append(action)
        let index = actions.count - 1
        return { [weak self] in self?.actions[index] = {} }
    }

    func fireFirst() { actions[0]() }
}

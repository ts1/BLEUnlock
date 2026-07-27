import Foundation
import XCTest
@testable import BLEUnlock

final class TelegramNotifierTests: XCTestCase {
    private var transport: RecordingHTTPTransport!
    private var notifier: TelegramNotifier!

    override func setUp() {
        super.setUp()
        transport = RecordingHTTPTransport()
        notifier = TelegramNotifier(transport: transport)
    }

    func testSendTextBuildsFormRequestAndAcceptsOKResponse() throws {
        transport.result = .success((Data(#"{"ok":true}"#.utf8), response(status: 200)))
        let done = expectation(description: "completion")

        notifier.sendText(credentials: .init(token: "token-SECRET", chatID: "987654"),
                          text: "Fred & Mac") { result in
            guard case .success = result else {
                return XCTFail("Expected success, got \(result)")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/bottoken-SECRET/sendMessage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("chat_id=987654"))
        XCTAssertTrue(body.contains("text=Fred%20%26%20Mac"))
    }

    func testSendTextPercentEncodesLiteralPlusForFormBody() throws {
        transport.result = .success((Data(#"{"ok":true}"#.utf8), response(status: 200)))
        let done = expectation(description: "completion")

        notifier.sendText(credentials: .init(token: "token-SECRET", chatID: "987654"),
                          text: "A+B") { result in
            guard case .success = result else {
                return XCTFail("Expected success, got \(result)")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        let request = try XCTUnwrap(transport.requests.first)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("text=A%2BB"))
    }

    func testSendLocationUsesTelegramEndpointAndFormFields() throws {
        transport.result = .success((Data(#"{"ok":true}"#.utf8), response(status: 200)))
        let credentials = TelegramCredentials(token: "token-SECRET", chatID: "987654")
        let location = TelegramLocation(latitude: 25.0330,
                                        longitude: 121.5654,
                                        horizontalAccuracy: 18,
                                        timestamp: Date())
        let done = expectation(description: "completion")

        notifier.sendLocation(credentials: credentials, location: location) { result in
            guard case .success = result else {
                return XCTFail("Expected success, got \(result)")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/bottoken-SECRET/sendLocation")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("chat_id=987654"))
        XCTAssertTrue(body.contains("latitude=25.033"))
        XCTAssertTrue(body.contains("longitude=121.5654"))
    }

    func testSendLocationRedactsCredentialsFromRejectedResponse() {
        let payload = #"{"ok":false,"description":"token-SECRET 987654 rejected"}"#
        transport.result = .success((Data(payload.utf8), response(status: 200)))
        let done = expectation(description: "completion")
        let location = TelegramLocation(latitude: 25.033,
                                        longitude: 121.5654,
                                        horizontalAccuracy: 18,
                                        timestamp: Date())

        notifier.sendLocation(credentials: .init(token: "token-SECRET", chatID: "987654"),
                              location: location) { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected rejection, got \(result)")
            }
            XCTAssertEqual(error, .rejected("[redacted] [redacted] rejected"))
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
    }

    func testSendPhotoBuildsMultipartWithJPEGAndCaption() throws {
        let photoBytes = Data([0xFF, 0xD8, 0x00, 0x7F, 0xD9])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photoURL = directory.appendingPathComponent("capture.jpg")
        try photoBytes.write(to: photoURL)
        transport.result = .success((Data(#"{"ok":true}"#.utf8), response(status: 200)))
        let done = expectation(description: "completion")

        notifier.sendPhoto(credentials: .init(token: "token-SECRET", chatID: "987654"),
                           photoURL: photoURL,
                           caption: "Door opened") { result in
            guard case .success = result else {
                return XCTFail("Expected success, got \(result)")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/bottoken-SECRET/sendPhoto")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertFalse(boundary.isEmpty)
        var expectedBody = Data()
        expectedBody.append(Data("--\(boundary)\r\n".utf8))
        expectedBody.append(Data("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".utf8))
        expectedBody.append(Data("987654\r\n".utf8))
        expectedBody.append(Data("--\(boundary)\r\n".utf8))
        expectedBody.append(Data("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".utf8))
        expectedBody.append(Data("Door opened\r\n".utf8))
        expectedBody.append(Data("--\(boundary)\r\n".utf8))
        expectedBody.append(Data("Content-Disposition: form-data; name=\"photo\"; filename=\"capture.jpg\"\r\n".utf8))
        expectedBody.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        expectedBody.append(photoBytes)
        expectedBody.append(Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertEqual(request.httpBody, expectedBody)
    }

    func testSendPhotoInvalidCredentialsReturnInvalidRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photoURL = directory.appendingPathComponent("capture.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: photoURL)
        transport.result = .success((Data(#"{"ok":true}"#.utf8), response(status: 200)))
        let done = expectation(description: "completion")

        notifier.sendPhoto(credentials: .init(token: "", chatID: "987654"),
                           photoURL: photoURL,
                           caption: "Door opened") { result in
            defer { done.fulfill() }
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure")
            }
            XCTAssertEqual(error, .invalidRequest)
        }

        wait(for: [done], timeout: 1)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTelegramOKFalseReturnsSanitizedDescription() {
        transport.result = .success((Data(#"{"ok":false,"description":"Forbidden"}"#.utf8),
                                     response(status: 200)))
        let done = expectation(description: "completion")

        notifier.sendText(credentials: .init(token: "token-SECRET", chatID: "987654"),
                          text: "x") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure")
            }
            XCTAssertEqual(error, .rejected("Forbidden"))
            self.assertSanitized(error)
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
    }

    func testTelegramOKFalseRedactsCredentialsFromDescription() {
        let serverDescription = "Forbidden token-SECRET chat 987654 path /bottoken-SECRET/"
        let payload = #"{"ok":false,"description":"\#(serverDescription)"}"#
        transport.result = .success((Data(payload.utf8), response(status: 200)))
        let done = expectation(description: "completion")

        notifier.sendText(credentials: .init(token: "token-SECRET", chatID: "987654"),
                          text: "x") { result in
            defer { done.fulfill() }
            guard case .failure(let error) = result,
                  case .rejected(let description) = error else {
                return XCTFail("Expected rejected failure")
            }
            XCTAssertTrue(description.contains("Forbidden"))
            for secret in ["token-SECRET", "987654", "/bottoken-SECRET/"] {
                XCTAssertFalse(description.contains(secret))
                XCTAssertFalse(String(describing: error).contains(secret))
            }
        }

        wait(for: [done], timeout: 1)
    }

    func testTransportErrorDoesNotExposeTokenOrRequestURL() {
        let secretURL = "https://api.telegram.org/bottoken-SECRET/sendMessage"
        transport.result = .failure(NSError(domain: secretURL,
                                             code: -1,
                                             userInfo: [NSLocalizedDescriptionKey: secretURL]))
        let done = expectation(description: "completion")

        notifier.sendText(credentials: .init(token: "token-SECRET", chatID: "987654"),
                          text: "x") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure")
            }
            XCTAssertEqual(error, .transport)
            self.assertSanitized(error)
            XCTAssertFalse(String(describing: error).contains(secretURL))
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
    }

    func testCancelledPhotoTransportMapsToSanitizedTransportError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photoURL = directory.appendingPathComponent("capture.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: photoURL)
        let requestURL = "https://api.telegram.org/bottoken-SECRET/sendPhoto"
        transport.result = .failure(URLError(
            .cancelled,
            userInfo: [NSLocalizedDescriptionKey: requestURL]
        ))
        let done = expectation(description: "completion")

        notifier.sendPhoto(credentials: .init(token: "token-SECRET", chatID: "987654"),
                           photoURL: photoURL,
                           caption: "Door opened") { result in
            defer { done.fulfill() }
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure")
            }
            XCTAssertEqual(error, .transport)
            let errorOutput = "\(String(describing: error)) \(error.localizedDescription)"
            for secret in ["token-SECRET", "987654", requestURL] {
                XCTAssertFalse(errorOutput.contains(secret))
            }
        }

        wait(for: [done], timeout: 1)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, requestURL)
    }

    func testMalformedResponseFails() {
        transport.result = .success((Data(#"{"unexpected":true}"#.utf8), response(status: 200)))
        let done = expectation(description: "completion")

        notifier.sendText(credentials: .init(token: "token-SECRET", chatID: "987654"),
                          text: "x") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure")
            }
            XCTAssertEqual(error, .invalidResponse)
            self.assertSanitized(error)
            done.fulfill()
        }

        wait(for: [done], timeout: 1)
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.telegram.org")!,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: nil)!
    }

    private func assertSanitized(_ error: TelegramError,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let description = String(describing: error)
        XCTAssertFalse(description.contains("token-SECRET"), file: file, line: line)
        XCTAssertFalse(description.contains("bot token-SECRET"), file: file, line: line)
    }
}

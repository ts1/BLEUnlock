import Foundation

protocol HTTPTransport {
    func perform(_ request: URLRequest,
                 completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void)
}

protocol TelegramSending {
    func sendText(credentials: TelegramCredentials,
                  text: String,
                  completion: @escaping (Result<Void, TelegramError>) -> Void)
    func sendPhoto(credentials: TelegramCredentials,
                   photoURL: URL,
                   caption: String,
                   completion: @escaping (Result<Void, TelegramError>) -> Void)
    func sendLocation(credentials: TelegramCredentials,
                      location: TelegramLocation,
                      completion: @escaping (Result<Void, TelegramError>) -> Void)
}

enum TelegramError: LocalizedError, Equatable {
    case invalidRequest
    case unreadablePhoto
    case transport
    case httpStatus(Int)
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return t("telegram_error_invalid_request")
        case .unreadablePhoto:
            return t("telegram_error_unreadable_photo")
        case .transport:
            return t("telegram_error_transport")
        case .httpStatus(let code):
            return String(format: t("telegram_error_http_status"), code)
        case .rejected(let description):
            return description
        case .invalidResponse:
            return t("telegram_error_invalid_response")
        }
    }
}

final class TelegramNotifier: TelegramSending {
    private let transport: HTTPTransport

    init(transport: HTTPTransport) {
        self.transport = transport
    }

    func sendText(credentials: TelegramCredentials,
                  text: String,
                  completion: @escaping (Result<Void, TelegramError>) -> Void) {
        guard let request = makeTextRequest(credentials: credentials, text: text) else {
            completion(.failure(.invalidRequest))
            return
        }
        perform(request, credentials: credentials, completion: completion)
    }

    func sendPhoto(credentials: TelegramCredentials,
                   photoURL: URL,
                   caption: String,
                   completion: @escaping (Result<Void, TelegramError>) -> Void) {
        guard let url = endpointURL(token: credentials.token, method: "sendPhoto") else {
            completion(.failure(.invalidRequest))
            return
        }
        guard let data = try? Data(contentsOf: photoURL) else {
            completion(.failure(.unreadablePhoto))
            return
        }
        let request = makePhotoRequest(credentials: credentials,
                                       url: url,
                                       photoURL: photoURL,
                                       caption: caption,
                                       data: data)
        perform(request, credentials: credentials, completion: completion)
    }

    func sendLocation(credentials: TelegramCredentials,
                      location: TelegramLocation,
                      completion: @escaping (Result<Void, TelegramError>) -> Void) {
        guard let url = endpointURL(token: credentials.token, method: "sendLocation") else {
            completion(.failure(.invalidRequest))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            ("chat_id", credentials.chatID),
            ("latitude", String(location.latitude)),
            ("longitude", String(location.longitude))
        ])
        perform(request, credentials: credentials, completion: completion)
    }

    private func makeTextRequest(credentials: TelegramCredentials, text: String) -> URLRequest? {
        guard let url = endpointURL(token: credentials.token, method: "sendMessage") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            ("chat_id", credentials.chatID),
            ("text", text)
        ])
        return request
    }

    private func makePhotoRequest(credentials: TelegramCredentials,
                                  url: URL,
                                  photoURL: URL,
                                  caption: String,
                                  data: Data) -> URLRequest {
        let boundary = "BLEUnlock-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(name: "chat_id", value: credentials.chatID, boundary: boundary)
        body.appendMultipartField(name: "caption", value: caption, boundary: boundary)
        body.appendMultipartFile(name: "photo",
                                 filename: photoURL.lastPathComponent,
                                 mimeType: "image/jpeg",
                                 bytes: data,
                                 boundary: boundary)
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func perform(_ request: URLRequest,
                         credentials: TelegramCredentials,
                         completion: @escaping (Result<Void, TelegramError>) -> Void) {
        transport.perform(request) { result in
            switch result {
            case .failure:
                completion(.failure(.transport))
            case .success(let (data, response)):
                guard (200..<300).contains(response.statusCode) else {
                    completion(.failure(.httpStatus(response.statusCode)))
                    return
                }
                guard let decoded = try? JSONDecoder().decode(TelegramResponse.self, from: data) else {
                    completion(.failure(.invalidResponse))
                    return
                }
                decoded.ok
                    ? completion(.success(()))
                    : completion(.failure(.rejected(
                        self.sanitized(decoded.description ?? t("telegram_error_rejected"),
                                       credentials: credentials)
                    )))
            }
        }
    }

    private func endpointURL(token: String, method: String) -> URL? {
        guard !token.isEmpty else { return nil }
        return URL(string: "https://api.telegram.org/bot\(token)/\(method)")
    }

    private func formEncoded(_ fields: [(String, String)]) -> Data {
        let body = fields
            .map { "\(formPercentEncoded($0.0))=\(formPercentEncoded($0.1))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func formPercentEncoded(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private func sanitized(_ description: String,
                           credentials: TelegramCredentials) -> String {
        [credentials.token, credentials.chatID].reduce(description) { result, credential in
            guard !credential.isEmpty else { return result }
            return result.replacingOccurrences(of: credential, with: "[redacted]")
        }
    }
}

private struct TelegramResponse: Decodable {
    let ok: Bool
    let description: String?
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendMultipartFile(name: String,
                                      filename: String,
                                      mimeType: String,
                                      bytes: Data,
                                      boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        append(bytes)
        append(Data("\r\n".utf8))
    }
}

final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func perform(_ request: URLRequest,
                 completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(TelegramError.transport))
                return
            }
            guard let data = data, let response = response as? HTTPURLResponse else {
                completion(.failure(TelegramError.invalidResponse))
                return
            }
            completion(.success((data, response)))
        }.resume()
    }
}

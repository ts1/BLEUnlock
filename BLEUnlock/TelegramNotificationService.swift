import AppKit
import Foundation

protocol TelegramNotificationHandling {
    func handle(_ context: TelegramEventContext)
    func sendTest(hostName: String,
                  completion: @escaping (Result<Void, Error>) -> Void)
}

protocol TelegramMessageFormatting {
    func message(for context: TelegramEventContext) -> String
    func photoCaption(for context: TelegramEventContext,
                      location: TelegramLocation?) -> String
}

protocol FailureReporting {
    func report(category: String, message: String)
}

protocol FailureNotificationDelivering {
    func deliver(message: String)
}

protocol UserNotificationCenterDelivering {
    func deliver(_ notification: NSUserNotification)
}

extension NSUserNotificationCenter: UserNotificationCenterDelivering {}

protocol MainThreadScheduling {
    func perform(_ action: @escaping () -> Void)
}

final class DispatchMainThreadScheduler: MainThreadScheduling {
    func perform(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}

final class UserNotificationFailureDelivery: FailureNotificationDelivering {
    private let notificationCenter: UserNotificationCenterDelivering
    private let scheduler: MainThreadScheduling
    private let notificationFactory: () -> NSUserNotification

    init(notificationCenter: UserNotificationCenterDelivering = NSUserNotificationCenter.default,
         scheduler: MainThreadScheduling = DispatchMainThreadScheduler(),
         notificationFactory: @escaping () -> NSUserNotification = NSUserNotification.init) {
        self.notificationCenter = notificationCenter
        self.scheduler = scheduler
        self.notificationFactory = notificationFactory
    }

    func deliver(message: String) {
        scheduler.perform { [notificationCenter, notificationFactory] in
            let notification = notificationFactory()
            notification.title = "BLEUnlock"
            notification.subtitle = t("telegram_failure_notification_subtitle")
            notification.informativeText = message
            notificationCenter.deliver(notification)
        }
    }
}

final class TelegramMessageFormatter: TelegramMessageFormatting {
    func message(for context: TelegramEventContext) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        var lines = [
            "\(context.hostName) — \(localizedDescription(for: context.event))",
            "\(t("telegram_message_time")): \(dateFormatter.string(from: context.timestamp))"
        ]
        if let rssi = context.rssi {
            lines.append("\(t("telegram_message_rssi")): \(rssi) dBm")
        }
        return lines.joined(separator: "\n")
    }

    func photoCaption(for context: TelegramEventContext,
                      location: TelegramLocation?) -> String {
        var lines = [message(for: context)]
        guard let location = location else {
            lines.append(t("telegram_location_unavailable"))
            return lines.joined(separator: "\n")
        }

        let latitude = posixDecimal(location.latitude)
        let longitude = posixDecimal(location.longitude)
        lines.append("\(t("telegram_message_coordinates")): \(latitude), \(longitude)")
        lines.append(String(format: "%@: ±%.0f m",
                            t("telegram_message_accuracy"),
                            location.horizontalAccuracy))
        lines.append("\(t("telegram_message_map")): https://maps.apple.com/?ll=\(latitude),\(longitude)")
        return lines.joined(separator: "\n")
    }

    private func posixDecimal(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func localizedDescription(for event: TelegramEvent) -> String {
        let key: String
        let fallback: String
        switch event {
        case .away:
            key = "telegram_event_away"
            fallback = "Device Away"
        case .lost:
            key = "telegram_event_lost"
            fallback = "Signal Lost"
        case .unlocked:
            key = "telegram_event_unlocked"
            fallback = "Unlocked by BLEUnlock"
        case .intruded:
            key = "telegram_event_intruded"
            fallback = "Manually Unlocked"
        }
        return NSLocalizedString(key, value: fallback, comment: "Telegram event description")
    }
}

final class RateLimitedFailureReporter: FailureReporting {
    private let now: () -> Date
    private let interval: TimeInterval
    private let notificationDelivery: FailureNotificationDelivering
    private let lock = NSLock()
    private var lastShown: [String: Date] = [:]

    convenience init(now: @escaping () -> Date = Date.init,
                     interval: TimeInterval = 300,
                     notificationCenter: NSUserNotificationCenter = .default) {
        self.init(now: now,
                  interval: interval,
                  notificationDelivery: UserNotificationFailureDelivery(
                      notificationCenter: notificationCenter
                  ))
    }

    init(now: @escaping () -> Date,
         interval: TimeInterval,
         notificationDelivery: FailureNotificationDelivering) {
        self.now = now
        self.interval = interval
        self.notificationDelivery = notificationDelivery
    }

    func report(category: String, message: String) {
        let category = sanitizedCategory(category)
        NSLog("BLEUnlock Telegram notification failure category: %@", category)

        let current = now()
        lock.lock()
        if let previous = lastShown[category],
           current.timeIntervalSince(previous) < interval {
            lock.unlock()
            return
        }
        lastShown[category] = current
        lock.unlock()

        notificationDelivery.deliver(message: message)
    }

    private func sanitizedCategory(_ category: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = category.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        return String((sanitized.isEmpty ? "unknown" : sanitized).prefix(64))
    }
}

private enum TelegramNotificationServiceError: LocalizedError {
    case notConfigured
    case settingsUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return t("telegram_error_not_configured")
        case .settingsUnavailable:
            return t("telegram_error_settings_unavailable")
        }
    }
}

final class TelegramNotificationService: TelegramNotificationHandling {
    private let settings: TelegramSettings
    private let sender: TelegramSending
    private let camera: PhotoCapturing
    private let location: MacLocationProviding
    private let removeFile: (URL) throws -> Void
    private let reporter: FailureReporting
    private let formatter: TelegramMessageFormatting

    init(settings: TelegramSettings,
         sender: TelegramSending,
         camera: PhotoCapturing,
         location: MacLocationProviding = CoreMacLocationProvider(),
         removeFile: @escaping (URL) throws -> Void = {
             try FileManager.default.removeItem(at: $0)
         },
         reporter: FailureReporting,
         formatter: TelegramMessageFormatting = TelegramMessageFormatter()) {
        self.settings = settings
        self.sender = sender
        self.camera = camera
        self.location = location
        self.removeFile = removeFile
        self.reporter = reporter
        self.formatter = formatter
    }

    func handle(_ context: TelegramEventContext) {
        guard settings.isEnabled, settings.isEventEnabled(context.event) else {
            return
        }

        let credentials: TelegramCredentials
        do {
            guard let storedCredentials = try settings.credentials() else { return }
            credentials = storedCredentials
        } catch {
            reporter.report(category: "settings",
                            message: t("telegram_error_settings_unavailable"))
            return
        }

        if context.event == .intruded && settings.takePhotoOnIntruded {
            if settings.attachMacLocation {
                sendLocatedPhotoOrFallback(credentials: credentials,
                                           context: context,
                                           completion: nil)
            } else {
                sendPhotoOrFallback(credentials: credentials,
                                    message: formatter.message(for: context),
                                    completion: nil)
            }
        } else {
            sendText(credentials: credentials,
                     message: formatter.message(for: context),
                     completion: nil)
        }
    }

    func sendTest(hostName: String,
                  completion: @escaping (Result<Void, Error>) -> Void) {
        let credentials: TelegramCredentials
        do {
            guard let storedCredentials = try settings.credentials() else {
                completion(.failure(TelegramNotificationServiceError.notConfigured))
                return
            }
            credentials = storedCredentials
        } catch {
            completion(.failure(TelegramNotificationServiceError.settingsUnavailable))
            return
        }

        let context = TelegramEventContext(event: .intruded,
                                           hostName: hostName,
                                           timestamp: Date(),
                                           rssi: nil)
        if settings.takePhotoOnIntruded {
            if settings.attachMacLocation {
                sendLocatedPhotoOrFallback(credentials: credentials,
                                           context: context,
                                           completion: completion)
            } else {
                sendPhotoOrFallback(credentials: credentials,
                                    message: formatter.message(for: context),
                                    completion: completion)
            }
        } else {
            sendText(credentials: credentials,
                     message: formatter.message(for: context),
                     completion: completion)
        }
    }

    private func sendLocatedPhotoOrFallback(
        credentials: TelegramCredentials,
        context: TelegramEventContext,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        let coordinator = PhotoLocationCoordinator(camera: camera, location: location)
        coordinator.capture(capturedAt: context.timestamp) { [coordinator] outcome in
            _ = coordinator
            self.deliver(outcome,
                         credentials: credentials,
                         context: context,
                         completion: completion)
        }
    }

    private func deliver(
        _ outcome: PhotoLocationOutcome,
        credentials: TelegramCredentials,
        context: TelegramEventContext,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        switch outcome {
        case .cameraFailure(let error):
            reporter.report(category: "camera", message: error.localizedDescription)
            completion?(.failure(error))
            sendText(credentials: credentials,
                     message: formatter.message(for: context),
                     completion: nil)
        case .photo(let photoURL, let positionResult):
            let position = try? positionResult.get()
            if case .failure = positionResult {
                reporter.report(category: "location", message: t("telegram_location_error"))
            }
            let caption = formatter.photoCaption(for: context, location: position)
            sender.sendPhoto(credentials: credentials,
                             photoURL: photoURL,
                             caption: caption) { [sender, removeFile, reporter] result in
                do {
                    try removeFile(photoURL)
                } catch {
                    reporter.report(category: "file",
                                    message: t("telegram_error_file_cleanup"))
                }
                switch (result, position) {
                case (.success, .some(let position)):
                    sender.sendLocation(credentials: credentials,
                                        location: position) { mapResult in
                        if case .failure = mapResult {
                            reporter.report(category: "telegram-location",
                                            message: t("telegram_location_send_error"))
                        }
                        completion?(mapResult.mapError { $0 as Error })
                    }
                default:
                    if case .failure(let error) = result {
                        reporter.report(category: "telegram",
                                        message: error.localizedDescription)
                    }
                    completion?(result.mapError { $0 as Error })
                }
            }
        }
    }

    private func sendPhotoOrFallback(credentials: TelegramCredentials,
                                     message: String,
                                     completion: ((Result<Void, Error>) -> Void)?) {
        camera.capture { [sender, removeFile, reporter] captureResult in
            switch captureResult {
            case .failure(let error):
                reporter.report(category: "camera", message: error.localizedDescription)
                completion?(.failure(error))
                self.sendText(credentials: credentials,
                              message: message,
                              completion: nil)
            case .success(let photoURL):
                sender.sendPhoto(credentials: credentials,
                                 photoURL: photoURL,
                                 caption: message) { result in
                    do {
                        try removeFile(photoURL)
                    } catch {
                        reporter.report(category: "file",
                                        message: t("telegram_error_file_cleanup"))
                    }
                    if case .failure(let error) = result {
                        reporter.report(category: "telegram", message: error.localizedDescription)
                    }
                    completion?(result.mapError { $0 as Error })
                }
            }
        }
    }

    private func sendText(credentials: TelegramCredentials,
                          message: String,
                          completion: ((Result<Void, Error>) -> Void)?) {
        sender.sendText(credentials: credentials, text: message) { [reporter] result in
            if case .failure(let error) = result {
                reporter.report(category: "telegram", message: error.localizedDescription)
            }
            completion?(result.mapError { $0 as Error })
        }
    }
}

import Foundation

protocol SecretStoring {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func removeValue(for account: String) throws
}

final class TelegramSettings {
    private enum Key {
        static let enabled = "telegram.enabled"
        static let takePhoto = "telegram.takePhotoOnIntruded"
        static let attachMacLocation = "telegram.attachMacLocation"
        static let token = "botToken"
        static let chatID = "chatID"
    }

    private let defaults: UserDefaults
    private let secrets: SecretStoring

    init(defaults: UserDefaults = .standard, secrets: SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var takePhotoOnIntruded: Bool {
        get { defaults.object(forKey: Key.takePhoto) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.takePhoto) }
    }

    var attachMacLocation: Bool {
        get { defaults.object(forKey: Key.attachMacLocation) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.attachMacLocation) }
    }

    func isEventEnabled(_ event: TelegramEvent) -> Bool {
        defaults.object(forKey: event.defaultsKey) as? Bool ?? event.defaultEnabled
    }

    func setEvent(_ event: TelegramEvent, enabled: Bool) {
        defaults.set(enabled, forKey: event.defaultsKey)
    }

    func credentials() throws -> TelegramCredentials? {
        guard let token = try secrets.string(for: Key.token), !token.isEmpty,
              let chatID = try secrets.string(for: Key.chatID), !chatID.isEmpty else { return nil }
        return TelegramCredentials(token: token, chatID: chatID)
    }

    func isConfigured() throws -> Bool { try credentials() != nil }

    func saveCredentials(replacementToken: String?, chatID: String) throws {
        let replacement = replacementToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let replacement = replacement, !replacement.isEmpty {
            try secrets.set(replacement, for: Key.token)
        }
        try secrets.set(chatID.trimmingCharacters(in: .whitespacesAndNewlines), for: Key.chatID)
    }
}

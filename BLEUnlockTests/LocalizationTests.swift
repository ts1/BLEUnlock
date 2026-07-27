import Foundation
import XCTest
@testable import BLEUnlock

final class LocalizationTests: XCTestCase {
    private let telegramKeys: Set<String> = [
        "telegram", "telegram_enable", "telegram_configure", "telegram_test",
        "telegram_events", "telegram_event_away", "telegram_event_lost",
        "telegram_event_unlocked", "telegram_event_intruded",
        "telegram_take_photo", "telegram_attach_mac_location", "telegram_status_not_configured",
        "telegram_status_enabled", "telegram_status_disabled",
        "telegram_bot_token", "telegram_chat_id", "telegram_save",
        "telegram_setup_help", "telegram_test_success", "telegram_test_failed",
        "telegram_camera_privacy", "telegram_error_not_configured",
        "telegram_camera_error_denied", "telegram_camera_error_restricted",
        "telegram_camera_error_no_camera", "telegram_camera_error_setup_failed",
        "telegram_camera_error_capture_failed", "telegram_camera_error_timeout",
        "telegram_camera_error_file_write_failed",
        "telegram_error_invalid_request", "telegram_error_unreadable_photo",
        "telegram_error_transport", "telegram_error_http_status",
        "telegram_error_rejected", "telegram_error_invalid_response",
        "telegram_error_settings_unavailable", "telegram_error_file_cleanup",
        "telegram_error_keychain_status", "telegram_failure_notification_subtitle",
        "telegram_message_time", "telegram_message_rssi",
        "telegram_message_coordinates", "telegram_message_accuracy",
        "telegram_message_map", "telegram_location_unavailable",
        "telegram_location_error", "telegram_location_send_error"
    ]

    private let localizationDirectories = ["Base", "da", "de", "ja", "nb", "sv", "tr", "zh-Hans"]
    private let concreteTelegramEventKeys: Set<String> = [
        "telegram_event_away", "telegram_event_lost",
        "telegram_event_unlocked", "telegram_event_intruded"
    ]
    private let dynamicTelegramEventReference = #"telegram_event_\(event.rawValue)"#

    private var repository: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEveryLocalizationContainsAllTelegramKeys() throws {
        for name in localizationDirectories {
            let url = repository.appendingPathComponent("BLEUnlock/\(name).lproj/Localizable.strings")
            let values = try strings(at: url)
            XCTAssertTrue(telegramKeys.subtracting(values.keys).isEmpty, "Missing keys in \(name)")
            for key in telegramKeys {
                let value = try XCTUnwrap(values[key], "Missing \(key) in \(name)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "Empty \(key) in \(name)")
                XCTAssertNotEqual(value, key, "Raw localization key in \(name)")
            }
        }
    }

    func testCameraPrivacyTextStatesTheCompleteDataFlow() throws {
        let values = try strings(at: repository.appendingPathComponent(
            "BLEUnlock/Base.lproj/Localizable.strings"
        ))
        let privacy = try XCTUnwrap(values["telegram_camera_privacy"]).lowercased()

        for phrase in ["system default camera", "upload", "telegram", "deleted", "text"] {
            XCTAssertTrue(privacy.contains(phrase),
                          "Camera privacy text must mention \(phrase)")
        }
    }

    func testEveryLocalizationContainsCameraUsageDescription() throws {
        for name in localizationDirectories {
            let url = repository.appendingPathComponent("BLEUnlock/\(name).lproj/InfoPlist.strings")
            let values = try strings(at: url)
            let description = try XCTUnwrap(values["NSCameraUsageDescription"],
                                            "Missing NSCameraUsageDescription in \(name)")
            XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(description, "NSCameraUsageDescription")
        }
    }

    func testEveryLocalizationContainsExactLocationUsageDescription() throws {
        let expectedDescriptions = [
            "Base": "BLEUnlock gets this Mac's location at capture time and attaches the coordinates and map to the Telegram security notification.",
            "da": "BLEUnlock henter denne Macs placering på optagelsestidspunktet og vedhæfter koordinater og kort til Telegram-sikkerhedsmeddelelsen.",
            "de": "BLEUnlock ermittelt den Standort dieses Macs zum Aufnahmezeitpunkt und fügt Koordinaten und Karte der Telegram-Sicherheitsmeldung hinzu.",
            "ja": "BLEUnlockは撮影時のこのMacの位置情報を取得し、座標と地図をTelegramのセキュリティ通知に添付します。",
            "nb": "BLEUnlock henter posisjonen til denne Macen på opptakstidspunktet og legger ved koordinater og kart i Telegram-sikkerhetsvarslet.",
            "sv": "BLEUnlock hämtar den här Mac-datorns plats när fotot tas och bifogar koordinater och karta till Telegram-säkerhetsnotisen.",
            "tr": "BLEUnlock fotoğraf çekildiğinde bu Mac'in konumunu alır ve koordinatlarla haritayı Telegram güvenlik bildirimine ekler.",
            "zh-Hans": "BLEUnlock 获取这台 Mac 拍照时的位置，并将坐标和地图附加到 Telegram 安全通知。"
        ]

        for name in localizationDirectories {
            let url = repository.appendingPathComponent("BLEUnlock/\(name).lproj/InfoPlist.strings")
            let values = try strings(at: url)
            let description = try XCTUnwrap(values["NSLocationUsageDescription"],
                                            "Missing NSLocationUsageDescription in \(name)")
            XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(description, expectedDescriptions[name])
        }
    }

    func testBaseInfoPlistContainsMacLocationUsageDescriptionOnly() throws {
        let url = repository.appendingPathComponent("BLEUnlock/Info.plist")
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url),
                                                   options: [],
                                                   format: nil) as? [String: Any]
        )

        XCTAssertEqual(values["NSLocationUsageDescription"] as? String,
                       "BLEUnlock gets this Mac's location at capture time and attaches the coordinates and map to the Telegram security notification.")
        XCTAssertNil(values["NSLocationAlwaysUsageDescription"])
        XCTAssertNil(values["NSLocationAlwaysAndWhenInUseUsageDescription"])
        XCTAssertNil(values["NSLocationWhenInUseUsageDescription"])
    }

    func testProductionEntitlementsAllowMacLocation() throws {
        let url = repository.appendingPathComponent("BLEUnlock/BLEUnlock.entitlements")
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url),
                                                   options: [],
                                                   format: nil) as? [String: Any]
        )
        XCTAssertEqual(values["com.apple.security.personal-information.location"] as? Bool,
                       true)
    }

    func testOnlyAppBuildConfigurationsEnableLocationResourceAccess() throws {
        let source = try String(contentsOf: repository.appendingPathComponent(
            "BLEUnlock.xcodeproj/project.pbxproj"
        ))
        let appConfigurations = ["3DD4B65F226C1C3400451B7B", "3DD4B660226C1C3400451B7B"]
        let otherTargetConfigurations = [
            "3D600A4C22701A5C0068FB7B", "3D600A4D22701A5C0068FB7B",
            "7E1000193000000000000001", "7E1000203000000000000001"
        ]

        XCTAssertEqual(source.components(separatedBy: "ENABLE_RESOURCE_ACCESS_LOCATION = YES;").count - 1,
                       2)
        for identifier in appConfigurations {
            XCTAssertTrue(try buildConfiguration(identifier, in: source)
                .contains("ENABLE_RESOURCE_ACCESS_LOCATION = YES;"))
        }
        for identifier in otherTargetConfigurations {
            XCTAssertFalse(try buildConfiguration(identifier, in: source)
                .contains("ENABLE_RESOURCE_ACCESS_LOCATION"))
        }
    }

    func testProductionTelegramLocalizationReferencesAreCovered() throws {
        let generatedEventKeys = Set(TelegramEvent.allCases.map {
            "telegram_event_\($0.rawValue)"
        })
        XCTAssertEqual(generatedEventKeys, concreteTelegramEventKeys,
                       "Every finite TelegramEvent value must have an explicit localization key")
        XCTAssertTrue(generatedEventKeys.isSubset(of: telegramKeys))

        let sourceFiles = [
            "CameraCapture.swift", "KeychainStore.swift", "TelegramMenuController.swift",
            "TelegramNotificationService.swift", "TelegramNotifier.swift"
        ]
        let expression = try NSRegularExpression(
            pattern: #"(?:t|NSLocalizedString)\(\"(telegram_[^\"]+)\""#
        )
        var referencedKeys: Set<String> = []

        for name in sourceFiles {
            let source = try String(contentsOf: repository.appendingPathComponent("BLEUnlock/\(name)"))
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                if key == dynamicTelegramEventReference {
                    referencedKeys.formUnion(generatedEventKeys)
                } else {
                    XCTAssertFalse(key.contains(#"\("#),
                                   "Unrecognized dynamic localization reference: \(key)")
                    referencedKeys.insert(key)
                }
            }
        }

        XCTAssertTrue(referencedKeys.isSubset(of: telegramKeys),
                      "Production keys missing from completeness set: \(referencedKeys.subtracting(telegramKeys))")
    }

    func testTelegramSourcesDoNotContainHardCodedEnglishErrorsOrLabels() throws {
        let files = ["CameraCapture.swift", "KeychainStore.swift",
                     "TelegramNotificationService.swift", "TelegramNotifier.swift"]
        let source = try files.map {
            try String(contentsOf: repository.appendingPathComponent("BLEUnlock/\($0)"))
        }.joined(separator: "\n")
        let forbidden = [
            "Camera access was denied.", "Camera access is restricted.",
            "No camera is available.", "The camera could not be configured.",
            "The camera could not capture a photo.", "The camera capture timed out.",
            "The captured photo could not be saved.",
            "The Telegram request could not be created.",
            "The captured photo could not be read.", "Telegram could not be reached.",
            "Telegram returned HTTP status", "Telegram returned an invalid response.",
            "Telegram notification failed", "Telegram settings could not be read.",
            "The captured photo could not be deleted.", "Keychain operation failed"
        ]

        for text in forbidden {
            XCTAssertFalse(source.contains(text), "Hard-coded user-visible text: \(text)")
        }
    }

    private func strings(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data,
                                                               options: [],
                                                               format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func buildConfiguration(_ identifier: String, in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "\(identifier) /*"))
        let suffix = source[start.lowerBound...]
        let end = try XCTUnwrap(suffix.range(of: "\n\t\t};"))
        return suffix[..<end.upperBound]
    }
}

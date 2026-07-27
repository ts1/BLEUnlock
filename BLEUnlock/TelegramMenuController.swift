import AppKit
import Foundation

protocol TelegramDialogPresenting {
    func requestCredentials(hasStoredToken: Bool,
                            completion: (TelegramCredentialInput?) -> Void)
    func showResult(title: String, message: String)
}

struct TelegramCredentialInput {
    let replacementToken: String?
    let chatID: String
}

final class TelegramMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let enableItem: NSMenuItem
    let testItem: NSMenuItem
    let statusItem: NSMenuItem
    let eventItems: [TelegramEvent: NSMenuItem]
    let photoItem: NSMenuItem
    let privacyItem: NSMenuItem
    let locationItem: NSMenuItem

    private let settings: TelegramSettings
    private let service: TelegramNotificationHandling
    private let dialogs: TelegramDialogPresenting
    private let locationAuthorization: LocationAuthorizationRequesting
    private let hostName: () -> String
    private let serviceQueue = DispatchQueue(label: "jp.sone.BLEUnlock.telegram.menu",
                                             qos: .utility)

    init(settings: TelegramSettings,
         service: TelegramNotificationHandling,
         dialogs: TelegramDialogPresenting,
         locationAuthorization: LocationAuthorizationRequesting = CoreMacLocationProvider(),
         hostName: @escaping () -> String = { Host.current().localizedName ?? "Mac" }) {
        self.settings = settings
        self.service = service
        self.dialogs = dialogs
        self.locationAuthorization = locationAuthorization
        self.hostName = hostName

        enableItem = NSMenuItem(title: t("telegram_enable"),
                                action: #selector(toggleEnabled(_:)),
                                keyEquivalent: "")
        let configureItem = NSMenuItem(title: t("telegram_configure"),
                                       action: #selector(configure),
                                       keyEquivalent: "")
        testItem = NSMenuItem(title: t("telegram_test"),
                              action: #selector(sendTest),
                              keyEquivalent: "")

        let eventsMenu = NSMenu()
        eventsMenu.autoenablesItems = false
        var items: [TelegramEvent: NSMenuItem] = [:]
        for event in TelegramEvent.allCases {
            let item = NSMenuItem(title: t("telegram_event_\(event.rawValue)"),
                                  action: #selector(toggleEvent(_:)),
                                  keyEquivalent: "")
            items[event] = item
            eventsMenu.addItem(item)
        }
        eventItems = items

        let eventsItem = NSMenuItem(title: t("telegram_events"),
                                    action: nil,
                                    keyEquivalent: "")
        eventsItem.submenu = eventsMenu
        photoItem = NSMenuItem(title: t("telegram_take_photo"),
                               action: #selector(togglePhoto(_:)),
                               keyEquivalent: "")
        privacyItem = NSMenuItem(title: t("telegram_camera_privacy"),
                                 action: nil,
                                 keyEquivalent: "")
        privacyItem.isEnabled = false
        locationItem = NSMenuItem(title: t("telegram_attach_mac_location"),
                                  action: #selector(toggleLocation(_:)),
                                  keyEquivalent: "")
        statusItem = NSMenuItem(title: t("telegram_status_not_configured"),
                                action: nil,
                                keyEquivalent: "")
        statusItem.isEnabled = false

        super.init()

        enableItem.target = self
        configureItem.target = self
        testItem.target = self
        eventItems.values.forEach { $0.target = self }
        photoItem.target = self
        locationItem.target = self

        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(enableItem)
        menu.addItem(configureItem)
        menu.addItem(testItem)
        menu.addItem(.separator())
        menu.addItem(eventsItem)
        menu.addItem(photoItem)
        menu.addItem(privacyItem)
        menu.addItem(locationItem)
        menu.addItem(.separator())
        menu.addItem(statusItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let configured = (try? settings.isConfigured()) == true
        enableItem.isEnabled = configured
        testItem.isEnabled = configured
        enableItem.state = configured && settings.isEnabled ? .on : .off
        for (event, item) in eventItems {
            item.state = settings.isEventEnabled(event) ? .on : .off
        }
        photoItem.state = settings.takePhotoOnIntruded ? .on : .off
        locationItem.state = settings.attachMacLocation ? .on : .off
        locationItem.isEnabled = settings.takePhotoOnIntruded

        if !configured {
            statusItem.title = t("telegram_status_not_configured")
        } else if settings.isEnabled {
            statusItem.title = t("telegram_status_enabled")
        } else {
            statusItem.title = t("telegram_status_disabled")
        }
    }

    @objc internal func toggleEnabled(_ item: NSMenuItem) {
        guard (try? settings.isConfigured()) == true else {
            menuWillOpen(menu)
            return
        }
        settings.isEnabled.toggle()
        menuWillOpen(menu)
    }

    @objc internal func toggleEvent(_ item: NSMenuItem) {
        guard let event = eventItems.first(where: { $0.value === item })?.key else { return }
        settings.setEvent(event, enabled: !settings.isEventEnabled(event))
        item.state = settings.isEventEnabled(event) ? .on : .off
    }

    @objc internal func togglePhoto(_ item: NSMenuItem) {
        settings.takePhotoOnIntruded.toggle()
        menuWillOpen(menu)
    }

    @objc internal func toggleLocation(_ item: NSMenuItem) {
        guard settings.takePhotoOnIntruded else {
            menuWillOpen(menu)
            return
        }
        settings.attachMacLocation.toggle()
        if settings.attachMacLocation {
            locationAuthorization.requestAuthorization()
        }
        menuWillOpen(menu)
    }

    @objc internal func configure() {
        let configured: Bool
        do {
            configured = try settings.isConfigured()
        } catch {
            dialogs.showResult(title: t("telegram_configure"),
                               message: t("telegram_error_settings_unavailable"))
            return
        }

        dialogs.requestCredentials(hasStoredToken: configured) { input in
            guard let input = input else { return }

            do {
                try self.settings.saveCredentials(replacementToken: input.replacementToken,
                                                  chatID: input.chatID)
                guard try self.settings.isConfigured() else {
                    self.dialogs.showResult(
                        title: t("telegram_configure"),
                        message: t("telegram_error_not_configured")
                    )
                    return
                }
                self.menuWillOpen(self.menu)
            } catch {
                self.dialogs.showResult(title: t("telegram_configure"),
                                        message: error.localizedDescription)
            }
        }
    }

    @objc internal func sendTest() {
        let service = self.service
        let resolvedHostName = hostName()
        serviceQueue.async { [weak self] in
            service.sendTest(hostName: resolvedHostName) { result in
                self?.showTestResult(result)
            }
        }
    }

    private func showTestResult(_ result: Result<Void, Error>) {
        onMain { [weak self] in
            guard let self = self else { return }
            switch result {
            case .success:
                self.dialogs.showResult(title: t("telegram_test_success"), message: "")
            case .failure(let error):
                self.dialogs.showResult(title: t("telegram_test_failed"),
                                        message: error.localizedDescription)
            }
        }
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}

final class AppKitTelegramDialogPresenter: TelegramDialogPresenting {
    func requestCredentials(hasStoredToken: Bool,
                            completion: (TelegramCredentialInput?) -> Void) {
        precondition(Thread.isMainThread)

        let alert = NSAlert()
        alert.window.title = "BLEUnlock"
        alert.messageText = t("telegram_configure")
        alert.addButton(withTitle: t("telegram_save"))
        alert.addButton(withTitle: t("cancel"))

        let explanation = NSTextField(wrappingLabelWithString: t("telegram_setup_help"))
        explanation.preferredMaxLayoutWidth = 360
        let privacy = NSTextField(wrappingLabelWithString: t("telegram_camera_privacy"))
        privacy.preferredMaxLayoutWidth = 360

        let tokenLabel = NSTextField(labelWithString: t("telegram_bot_token"))
        let tokenField = NSSecureTextField()
        tokenField.stringValue = ""
        tokenField.placeholderString = hasStoredToken ? nil : t("telegram_bot_token")

        let chatIDLabel = NSTextField(labelWithString: t("telegram_chat_id"))
        let chatIDField = NSTextField()

        let stack = NSStackView(views: [explanation,
                                        privacy,
                                        tokenLabel,
                                        tokenField,
                                        chatIDLabel,
                                        chatIDField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 190)
        tokenField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        chatIDField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            completion(nil)
            return
        }

        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        completion(.init(replacementToken: token.isEmpty ? nil : token,
                         chatID: chatIDField.stringValue))
    }

    func showResult(title: String, message: String) {
        precondition(Thread.isMainThread)
        let alert = NSAlert()
        alert.window.title = "BLEUnlock"
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

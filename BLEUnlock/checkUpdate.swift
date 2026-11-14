import Cocoa

private let KEY = "lastUpdateCheck"
private let INTERVAL = 24.0 * 60 * 60
private var notified = false
private var lastCheckAt = UserDefaults.standard.double(forKey: KEY)
private let releasesURL = URL(string: "https://api.github.com/repos/Skyearn/BLEUnlock/releases/latest")!
private let autoCheckUpdatesKey = "autoCheckUpdates"
private let pendingUpdateVersionKey = "pendingUpdateVersion"
private let pendingUpdateDownloadURLKey = "pendingUpdateDownloadURL"
private let pendingUpdateReleaseURLKey = "pendingUpdateReleaseURL"

enum UpdateCheckResult {
    case available(version: String, downloadURL: URL?, releaseURL: URL)
    case upToDate
    case failure(String)
}

struct PendingUpdate {
    let version: String
    let downloadURL: URL?
    let releaseURL: URL
}

private struct ReleaseAsset {
    let name: String
    let downloadURL: URL
}

private struct ReleaseInfo {
    let version: String
    let releaseURL: URL
    let assets: [ReleaseAsset]
}

func checkUpdate(force: Bool = false, completion: ((UpdateCheckResult) -> Void)? = nil) {
    if !force {
        guard automaticUpdateChecksEnabled() else { return }
        guard !notified else { return }
        let now = NSDate().timeIntervalSince1970
        guard now - lastCheckAt >= INTERVAL else { return }
    }
    doCheckUpdate(force: force, completion: completion)
}

func automaticUpdateChecksEnabled() -> Bool {
    let prefs = UserDefaults.standard
    if prefs.object(forKey: autoCheckUpdatesKey) == nil {
        return true
    }
    return prefs.bool(forKey: autoCheckUpdatesKey)
}

func pendingUpdate() -> PendingUpdate? {
    let prefs = UserDefaults.standard
    guard automaticUpdateChecksEnabled(),
          let version = prefs.string(forKey: pendingUpdateVersionKey),
          let releaseURLString = prefs.string(forKey: pendingUpdateReleaseURLKey),
          let releaseURL = URL(string: releaseURLString) else {
        return nil
    }

    if let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       normalizedVersion(currentVersion) == normalizedVersion(version) {
        clearPendingUpdate()
        return nil
    }

    let downloadURL = prefs.string(forKey: pendingUpdateDownloadURLKey).flatMap(URL.init(string:))
    return PendingUpdate(version: version, downloadURL: downloadURL, releaseURL: releaseURL)
}

func savePendingUpdate(version: String, downloadURL: URL?, releaseURL: URL) {
    let prefs = UserDefaults.standard
    prefs.set(version, forKey: pendingUpdateVersionKey)
    prefs.set(releaseURL.absoluteString, forKey: pendingUpdateReleaseURLKey)
    if let downloadURL {
        prefs.set(downloadURL.absoluteString, forKey: pendingUpdateDownloadURLKey)
    } else {
        prefs.removeObject(forKey: pendingUpdateDownloadURLKey)
    }
}

func clearPendingUpdate() {
    let prefs = UserDefaults.standard
    prefs.removeObject(forKey: pendingUpdateVersionKey)
    prefs.removeObject(forKey: pendingUpdateDownloadURLKey)
    prefs.removeObject(forKey: pendingUpdateReleaseURLKey)
}

private func doCheckUpdate(force: Bool, completion: ((UpdateCheckResult) -> Void)? = nil) {
    var request = URLRequest(url: releasesURL)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let task = URLSession.shared.dataTask(with: request) { data, _, error in
        if let error {
            completion?(.failure(error.localizedDescription))
            return
        }

        guard let data else {
            completion?(.failure("No response data"))
            return
        }

        guard let releaseInfo = parseReleaseInfo(from: data) else {
            completion?(.failure("Invalid GitHub release response"))
            return
        }

        lastCheckAt = NSDate().timeIntervalSince1970
        UserDefaults.standard.set(lastCheckAt, forKey: KEY)
        let result = compareVersions(releaseInfo: releaseInfo, shouldNotify: !force)
        completion?(result)
    }
    task.resume()
}

private func parseReleaseInfo(from data: Data) -> ReleaseInfo? {
    guard let json = try? JSONSerialization.jsonObject(with: data),
          let dict = json as? [String: Any],
          let version = dict["tag_name"] as? String,
          let htmlURLString = dict["html_url"] as? String,
          let releaseURL = URL(string: htmlURLString) else {
        return nil
    }

    let assets = (dict["assets"] as? [[String: Any]] ?? []).compactMap { assetDict -> ReleaseAsset? in
        guard let name = assetDict["name"] as? String,
              let downloadURLString = assetDict["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            return nil
        }
        return ReleaseAsset(name: name, downloadURL: downloadURL)
    }

    return ReleaseInfo(version: version, releaseURL: releaseURL, assets: assets)
}

private func normalizedVersion(_ version: String) -> String {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("v") {
        return String(trimmed.dropFirst())
    }
    return trimmed
}

private func compareVersions(releaseInfo: ReleaseInfo, shouldNotify: Bool) -> UpdateCheckResult {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
        return .failure("Missing app version")
    }

    if normalizedVersion(version) != normalizedVersion(releaseInfo.version) {
        if shouldNotify {
            notifyUpdateAvailable()
            notified = true
        }
        return .available(version: releaseInfo.version,
                          downloadURL: latestDMGDownloadURL(from: releaseInfo.assets),
                          releaseURL: releaseInfo.releaseURL)
    }

    return .upToDate
}

private func latestDMGDownloadURL(from assets: [ReleaseAsset]) -> URL? {
    assets.first {
        $0.name.lowercased().hasSuffix(".dmg")
    }?.downloadURL
}

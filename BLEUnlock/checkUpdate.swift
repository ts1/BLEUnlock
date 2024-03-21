import Cocoa

private let KEY = "lastUpdateCheck"
private let INTERVAL = 24.0 * 60 * 60
private var notified = false
private var lastCheckAt = UserDefaults.standard.double(forKey: KEY)

/// 检查更新，此作者看起来是做C的，很多全局函数
func checkUpdate() {
    guard !notified else { return }
    let now = NSDate().timeIntervalSince1970
    guard now - lastCheckAt >= INTERVAL else { return }
    doCheckUpdate()
}

/// 版本检查网络请求
private func doCheckUpdate() {
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/ts1/BLEUnlock/releases/latest")!)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
        if let jsondata = data {
            if let json = try? JSONSerialization.jsonObject(with: jsondata) {
                if let dict = json as? [String:Any] {
                    if let version = dict["tag_name"] as? String {
                        lastCheckAt = NSDate().timeIntervalSince1970
                        UserDefaults.standard.set(lastCheckAt, forKey: KEY)
                        compareVersionsAndNotify(version)
                    }
                }
            }
        }
    })
    task.resume()
}

/// 进行比较网络返回的版本
private func compareVersionsAndNotify(_ latestVersion: String) {
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
        if version != latestVersion {
            notify()
            notified = true
        }
    }
}

/// 进行通知出来有新版本
private func notify() {
    let un = NSUserNotification()
    un.title = "BLEUnlock"
    un.subtitle = t("notification_update_available")
    NSUserNotificationCenter.default.deliver(un)
}

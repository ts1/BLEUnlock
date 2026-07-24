import Foundation

let logURL = URL(fileURLWithPath: "/tmp/BLEUnlock-diagnostics-\(ProcessInfo.processInfo.processIdentifier).log")
let logger = DiagnosticsLogger(logURL: logURL)
logger.log("presence_timeout", fields: ["reason": "away", "rssi": "-95"])

guard let contents = try? String(contentsOf: logURL, encoding: .utf8),
      contents.contains("event=presence_timeout"),
      contents.contains("reason=away"),
      contents.contains("rssi=-95") else {
    fputs("Diagnostics logger test failed\n", stderr)
    exit(1)
}

try? FileManager.default.removeItem(at: logURL)
print("Diagnostics logger test passed")

import Foundation

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    private let lock = NSLock()
    private let fileURL: URL
    private let formatter = ISO8601DateFormatter()

    init(logURL: URL? = nil) {
        if let logURL {
            fileURL = logURL
        } else {
            let libraryURL = FileManager.default.urls(for: .libraryDirectory,
                                                       in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
            let logsURL = libraryURL.appendingPathComponent("Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logsURL,
                                                       withIntermediateDirectories: true)
            fileURL = logsURL.appendingPathComponent("BLEUnlock.log")
        }
    }

    func log(_ event: String, fields: [String: String] = [:]) {
        var line = "\(formatter.string(from: Date())) event=\(event)"
        for key in fields.keys.sorted() {
            line += " \(key)=\(fields[key] ?? "")"
        }
        line += "\n"

        lock.lock()
        defer { lock.unlock() }

        // Keep terminal/Xcode output for interactive debugging.
        print(line, terminator: "")

        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

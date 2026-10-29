import Foundation

// Appends timestamped lines to ~/Library/Logs/WifiAutoLogin.log. The file
// rotates to a single ".1" backup once it passes a size cap, so the log can
// never grow without bound (total disk use stays ~2× the cap).
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WifiAutoLogin.log")
    }()

    // WifiAutoLogin.log.1 — the single rotated-out generation.
    private static let backupURL = fileURL.appendingPathExtension("1")
    private static let maxBytes = 256 * 1024   // rotate past ~256 KB

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        rotateIfNeeded()

        // First write creates the file; later writes append.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try? data.write(to: fileURL)
            return
        }
        // Modern throwing API: a write error (disk full, unmounted volume) is
        // caught as a Swift error instead of raising an uncatchable NSException.
        // Logging must never crash the app, so any failure is swallowed.
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Ignore: a failed log write must not take the app down.
        }
    }

    // Once the log passes the cap, replace the previous backup with it and start
    // a fresh log. Keeps at most the two most recent generations.
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > maxBytes else { return }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }
}

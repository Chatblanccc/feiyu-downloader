import Darwin
import Foundation

enum TaskHistoryStorage {
    /// Complete all fallible writes and permission changes before replacing history.
    static func write(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".task-history-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let pending = staging.appendingPathComponent("history.json")
        try data.write(to: pending)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        // Both paths have the same parent filesystem. A failed rename leaves the
        // previous history untouched; a successful rename is the final commit.
        guard rename(pending.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

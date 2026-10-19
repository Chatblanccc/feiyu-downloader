import Darwin
import DownloadCore
import Foundation

/// A small durable receipt written after an engine returns a verified final file.
/// All operations are synchronous and serialized, so the writer may run off the main actor.
final class DownloadCompletionStore: @unchecked Sendable {
    private struct Receipt: Codable {
        let id: UUID
        let source: String
        let finalFileURL: URL
        let size: Int64
    }

    private let lock = NSLock()
    private let directory: URL
    private let validLocation: Bool
    private static let maximumReceiptBytes = 8 * 1_024

    init(historyURL: URL) {
        validLocation = historyURL.isFileURL && !historyURL.path.contains("\0")
        directory = historyURL.deletingLastPathComponent()
            .appendingPathComponent("completion-receipts", isDirectory: true)
    }

    /// Call only with the successful result of DownloadServing.download.
    func record(id: UUID, source: String, result: DownloadResult) throws {
        lock.lock(); defer { lock.unlock() }
        guard validLocation else { throw ReceiptError.storage }
        guard let size = Self.regularFileSize(result.fileURL), size > 0 else { throw ReceiptError.invalidFile }
        let receipt = Receipt(id: id, source: source, finalFileURL: result.fileURL, size: size)
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= Self.maximumReceiptBytes else { throw ReceiptError.tooLarge }
        try prepareDirectory()
        let target = receiptURL(id)
        let temporary = directory.appendingPathComponent("." + id.uuidString + "." + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReceiptError.storage }
        defer { close(fd); unlink(temporary.path) }
        guard fchmod(fd, 0o600) == 0 else { throw ReceiptError.storage }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw ReceiptError.storage }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ReceiptError.storage }
                offset += written
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, target.path) == 0 else { throw ReceiptError.storage }
    }

    /// Reads one known UUID only. It never scans downloads or trusts a filename alone.
    func recover(id: UUID, source: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard validLocation, Self.isPrivateDirectory(directory) else { return nil }
        let fd = open(receiptURL(id).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= Self.maximumReceiptBytes else { return nil }
        var data = Data(count: Int(info.st_size))
        let readAll = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let received = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { return false }
                offset += received
            }
            return true
        }
        guard readAll, let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.id == id, receipt.source == source, receipt.size > 0,
              Self.regularFileSize(receipt.finalFileURL) == receipt.size else { return nil }
        return receipt.finalFileURL
    }

    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard validLocation, Self.isPrivateDirectory(directory) else { return }
        unlink(receiptURL(id).path)
    }

    private func receiptURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json", isDirectory: false)
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ReceiptError.storage }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw ReceiptError.storage }
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    private static func regularFileSize(_ url: URL) -> Int64? {
        guard url.isFileURL, !url.path.contains("\0"), url.user == nil, url.password == nil,
              url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else { return nil }
        return info.st_size
    }

    private enum ReceiptError: LocalizedError {
        case invalidFile, tooLarge, storage
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "完成的视频文件不存在或为空，无法保存完成记录。"
            case .tooLarge: return "下载完成记录过大，无法安全保存。"
            case .storage: return "下载文件已保存，但完成记录暂时无法写入本机。"
            }
        }
    }
}

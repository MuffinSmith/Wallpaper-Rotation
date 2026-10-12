import Foundation
import Darwin

/// Best-effort diagnostics. No caller, including recovery, waits for disk I/O.
final class RecoveryEventLog: @unchecked Sendable {
    static let shared = RecoveryEventLog(directory: AppStorage.directory)
    static let currentFilename = "recovery-events.jsonl"
    static let previousFilename = "recovery-events.1.jsonl"

    private let directory: URL
    private let maximumFileSize: Int
    private let queue = DispatchQueue(label: "WallpaperRotation.recovery-log", qos: .utility)
    private let pending: DispatchSemaphore
    private let formatter = ISO8601DateFormatter()

    init(directory: URL, maximumFileSize: Int = 256 * 1024, maximumPendingRecords: Int = 64) {
        self.directory = directory
        self.maximumFileSize = max(256, min(maximumFileSize, 256 * 1024))
        pending = DispatchSemaphore(value: max(1, min(maximumPendingRecords, 64)))
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        guard Self.events.contains(event), pending.wait(timeout: .now()) == .success else { return }
        let safeFields = Self.sanitize(fields)
        queue.async { [self] in
            defer { pending.signal() }
            let record = Record(schemaVersion: 1, timestamp: formatter.string(from: Date()),
                                event: event, fields: safeFields)
            guard var data = try? JSONEncoder().encode(record) else { return }
            data.append(0x0a)
            guard data.count <= maximumFileSize else { return }
            append(data)
        }
    }

    /// Waits only for records already accepted; intended for deterministic fixtures.
    func flush() { queue.sync {} }

    private struct Record: Codable {
        let schemaVersion: Int
        let timestamp: String
        let event: String
        let fields: [String: String]
    }

    private static let events: Set<String> = [
        "startup", "shutdown", "reconcile", "recovery_attempt", "recovery_result",
        "recovery_backoff", "pause", "native_failure"
    ]
    private static let reasons: Set<String> = [
        "manual", "outside_change", "native_state", "setup", "persistence", "cancellation",
        "unavailable", "waiting", "download_failed", "success"
    ]
    private static let triggers: Set<String> = ["refresh", "lifecycle", "transition", "retry"]

    private static func sanitize(_ fields: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        // Look up a fixed set of keys instead of copying arbitrary caller data.
        for key in ["phase", "setID", "assetIDs", "attempt", "retryAt", "reason", "error",
                    "count", "trigger", "version", "build"] {
            guard let value = fields[key], value.utf8.prefix(513).count <= 512 else { continue }
            let valid: Bool
            switch key {
            case "phase": valid = ["day", "sunset", "evening", "night"].contains(value)
            case "reason", "error": valid = reasons.contains(value)
            case "trigger": valid = triggers.contains(value)
            case "attempt", "count":
                valid = !value.isEmpty && value.utf8.count <= 10 && value.utf8.allSatisfy { (48...57).contains($0) }
            case "retryAt":
                valid = value.utf8.count <= 32 && ISO8601DateFormatter().date(from: value) != nil
            case "assetIDs":
                let ids = value.split(separator: ",", omittingEmptySubsequences: false)
                valid = !ids.isEmpty && ids.count <= 8 && ids.allSatisfy { UUID(uuidString: String($0)) != nil }
            case "setID", "build":
                valid = token(value, maximum: 80)
            case "version":
                valid = !value.isEmpty && value.utf8.count <= 24 && value.utf8.allSatisfy {
                    (48...57).contains($0) || $0 == 46
                }
            default: valid = false
            }
            if valid { result[key] = value }
        }
        return result
    }

    private static func token(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private func append(_ data: Data) {
        let directoryFD = openDirectory()
        guard directoryFD >= 0 else { return }
        defer { close(directoryFD) }
        let current = Self.currentFilename
        let previous = Self.previousFilename
        var fd = openat(directoryFD, current, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT {
            fd = openat(directoryFD, current, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        guard let currentInfo = knownFile(fd, allowEmpty: true), fchmod(fd, 0o600) == 0 else { return }
        if currentInfo.st_size + off_t(data.count) > maximumFileSize {
            // Never replace a symlink, directory, hard link, or unrelated regular file.
            let oldFD = openat(directoryFD, previous, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if oldFD >= 0 {
                defer { close(oldFD) }
                guard let previousInfo = knownFile(oldFD, allowEmpty: false),
                      matches(directoryFD, name: previous, info: previousInfo) else { return }
            } else if errno != ENOENT { return }
            guard matches(directoryFD, name: current, info: currentInfo),
                  renameat(directoryFD, current, directoryFD, previous) == 0 else { return }
            let replacement = openat(directoryFD, current,
                                     O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard replacement >= 0 else { return }
            defer { close(replacement) }
            write(data, to: replacement)
        } else {
            write(data, to: fd)
        }
    }

    private func write(_ data: Data, to fd: Int32) {
        // Roll back a short write so a disk-full failure does not poison future JSONL.
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if written != data.count { _ = ftruncate(fd, info.st_size) }
    }

    private func knownFile(_ fd: Int32, allowEmpty: Bool) -> stat? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximumFileSize else { return nil }
        // A crash or short write can leave our reserved current file empty. Appending
        // is safe only for an owned, single-link, already-private regular file.
        if info.st_size == 0 { return allowEmpty && info.st_mode & 0o777 == 0o600 ? info : nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard pread(fd, &bytes, bytes.count, 0) == bytes.count, bytes.last == 0x0a else { return nil }
        for line in bytes.split(separator: 0x0a, omittingEmptySubsequences: false).dropLast() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  Set(object.keys) == ["schemaVersion", "timestamp", "event", "fields"],
                  let record = try? JSONDecoder().decode(Record.self, from: Data(line)),
                  record.schemaVersion == 1, Self.events.contains(record.event),
                  formatter.date(from: record.timestamp) != nil,
                  Self.sanitize(record.fields) == record.fields else { return nil }
        }
        return info
    }

    private func matches(_ directoryFD: Int32, name: String, info: stat) -> Bool {
        var current = stat()
        return fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFREG && current.st_dev == info.st_dev && current.st_ino == info.st_ino
    }

    private func openDirectory() -> Int32 {
        guard directory.isFileURL else { return -1 }
        // Open every component relative to a checked descriptor, never following symlinks.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        let components = directory.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, !components.contains("..") else { close(fd); return -1 }
        for component in components {
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                if mkdirat(fd, component, 0o700) == 0 {
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
            close(fd); return -1
        }
        return fd
    }
}

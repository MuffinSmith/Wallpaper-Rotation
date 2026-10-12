import Foundation
import Testing
import Darwin
@testable import WallpaperRotation

@Suite("Bounded private recovery diagnostics")
struct RecoveryEventLogTests {
    private func folder() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("recovery-log-tests-\(UUID().uuidString)", isDirectory: true)
    }
    private func records(_ url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0a)
        return try data.split(separator: 0x0a).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }
    private func current(_ root: URL) -> URL { root.appendingPathComponent(RecoveryEventLog.currentFilename) }
    private func previous(_ root: URL) -> URL { root.appendingPathComponent(RecoveryEventLog.previousFilename) }

    @Test func emitsParseablePrivateJSONLWithOnlyAllowlistedValues() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = RecoveryEventLog(directory: root)
        let id = "9F77B2B9-AD96-4D4B-B37C-DB4D0B7C1185"
        logger.record("recovery_attempt", fields: ["phase": "day", "setID": "Tahoe", "assetIDs": id,
            "attempt": "2", "retryAt": "2026-10-12T18:00:00Z", "reason": "unavailable", "count": "3",
            "trigger": "refresh", "version": "0.3.6", "build": "11", "latitude": "37.12345",
            "receipt": "private-original-wallpaper", "url": "https://private.invalid/movie",
            "error": "https://private.invalid/movie"])
        logger.record("secret-event-37.12345", fields: ["count": "1"])
        logger.flush()
        let entries = try records(current(root))
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry["schemaVersion"] as? Int == 1)
        #expect(entry["event"] as? String == "recovery_attempt")
        let timestamp = try #require(entry["timestamp"] as? String)
        #expect(ISO8601DateFormatter().date(from: timestamp) != nil)
        let fields = try #require(entry["fields"] as? [String: String])
        #expect(fields == ["phase": "day", "setID": "Tahoe", "assetIDs": id, "attempt": "2",
            "retryAt": "2026-10-12T18:00:00Z", "reason": "unavailable", "count": "3", "trigger": "refresh",
            "version": "0.3.6", "build": "11"])
        for (url, mode) in [(root, 0o700), (current(root), 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
        }
    }

    @Test func rejectsFreeformValuesAndCapsInputBeforeEnqueueing() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = RecoveryEventLog(directory: root)
        logger.record("recovery_result", fields: ["reason": "failed for user /Users/private",
            "setID": "../private", "assetIDs": "not-an-asset", "phase": "37.12345", "retryAt": "tomorrow",
            "attempt": "-1", "count": String(repeating: "9", count: 100_000), "trigger": "https://private.invalid",
            "build": String(repeating: "A", count: 100_000), "version": "private-user"])
        logger.flush()
        let entry = try #require(try records(current(root)).first)
        #expect((entry["fields"] as? [String: String])?.isEmpty == true)
    }

    @Test func rotatesOnlyTwoBoundedFilesAndRetainsNewestRecordsAcrossRestart() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = RecoveryEventLog(directory: root, maximumFileSize: 512)
        for index in 0..<40 {
            logger.record("recovery_attempt", fields: ["attempt": String(index)])
            logger.flush()
        }
        let restarted = RecoveryEventLog(directory: root, maximumFileSize: 512)
        restarted.record("shutdown", fields: ["count": "40"])
        restarted.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(Set(names) == [RecoveryEventLog.currentFilename, RecoveryEventLog.previousFilename])
        for url in [current(root), previous(root)] {
            #expect(try Data(contentsOf: url).count <= 512)
            #expect(try !records(url).isEmpty)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let last = try #require(try records(current(root)).last)
        #expect(last["event"] as? String == "shutdown")
    }

    @Test func preservesFileAndSymlinkAtDirectoryAndEveryAncestor() throws {
        let root = folder()
        let target = folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let original = Data("unrelated file".utf8)
        try original.write(to: root)
        var logger = RecoveryEventLog(directory: root)
        logger.record("startup"); logger.flush()
        #expect(try Data(contentsOf: root) == original)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        for path in [root, root.appendingPathComponent("nested")] {
            logger = RecoveryEventLog(directory: path)
            logger.record("startup"); logger.flush()
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func preservesUnexpectedCurrentFilesIncludingHardLinks() throws {
        let root = folder()
        let target = folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("unrelated private data".utf8)
        try original.write(to: target)
        for kind in ["symlink", "hardlink", "regular", "directory"] {
            let url = current(root)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            case "hardlink": try FileManager.default.linkItem(at: target, to: url)
            case "regular": try original.write(to: url)
            default: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            let logger = RecoveryEventLog(directory: root)
            logger.record("startup"); logger.flush()
            #expect(try Data(contentsOf: target) == original)
            if kind == "regular" || kind == "hardlink" { #expect(try Data(contentsOf: url) == original) }
            if kind == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [RecoveryEventLog.currentFilename])
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test func preservesUnexpectedArchiveDuringRotationAndRecoversAfterObstructionRemoved() throws {
        let root = folder()
        let target = folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let logger = RecoveryEventLog(directory: root, maximumFileSize: 256)
        logger.record("startup"); logger.flush()
        let original = Data("do not replace".utf8)
        try original.write(to: target)
        for symlink in [false, true] {
            if symlink { try FileManager.default.createSymbolicLink(at: previous(root), withDestinationURL: target) }
            else { try original.write(to: previous(root)) }
            for _ in 0..<10 { logger.record("reconcile"); logger.flush() }
            #expect(try Data(contentsOf: target) == original)
            #expect(try Data(contentsOf: previous(root)) == original)
            #expect(try Data(contentsOf: current(root)).count <= 256)
            try FileManager.default.removeItem(at: previous(root))
        }
        logger.record("shutdown"); logger.flush()
        #expect(try records(current(root)).last?["event"] as? String == "shutdown")
    }

    @Test func burstEmptyFileAndFilesystemFailureDoNotPreventLaterAcceptedRecords() throws {
        let root = folder()
        let blocked = folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: blocked)
        }
        try Data("blocked".utf8).write(to: blocked)
        let failed = RecoveryEventLog(directory: blocked, maximumPendingRecords: 1)
        for _ in 0..<1_000 { failed.record("startup") }
        failed.flush()
        #expect(try Data(contentsOf: blocked) == Data("blocked".utf8))
        // A process interruption after file creation must not disable logging forever.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: current(root).path, contents: Data(),
                                               attributes: [.posixPermissions: 0o600]))
        let logger = RecoveryEventLog(directory: root, maximumFileSize: 512, maximumPendingRecords: 1)
        logger.record("startup"); logger.flush()
        #expect(try records(current(root)).last?["event"] as? String == "startup")
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in logger.record("reconcile") }
        logger.flush()
        logger.record("shutdown"); logger.flush()
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(name)
            #expect(try Data(contentsOf: url).count <= 512)
            #expect(try !records(url).isEmpty)
        }
        #expect(try records(current(root)).last?["event"] as? String == "shutdown")
    }
}

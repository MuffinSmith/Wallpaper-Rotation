import Foundation
import Testing
import AppleWallpaper
@testable import WallpaperRotation

@Suite("Private ownership persistence")
struct AppStorageTests {
    private func fixtureFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-storage-tests-\(UUID().uuidString)")
    }
    private func receipt() -> OwnershipReceipt {
        OwnershipReceipt(originalValues: ["/fixture": Data("original user setup".utf8)],
                         appliedValues: ["/fixture": Data("rotation scene".utf8)],
                         assetID: "9F77B2B9-AD96-4D4B-B37C-DB4D0B7C1185", osBuild: "fixture-build")
    }

    @Test func preparedJournalIsPrivateAndHasNoInventedReceipt() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pending-apply.json")
        #expect(try AppStorage.loadPendingApply(at: url) == nil)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_123)
        try AppStorage.savePendingApply(PendingVisualVerification(schemaVersion: 1, assetID: receipt().assetID,
                                                                  startedAt: startedAt, receipt: nil), to: url)
        let reloaded = try #require(try AppStorage.loadPendingApply(at: url))
        #expect(reloaded.assetID == receipt().assetID)
        #expect(reloaded.startedAt == startedAt)
        #expect(reloaded.receipt == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["pending-apply.json"])
    }

    @Test func interruptedApplyRetainsOriginalBaselineAcrossRestartPersistence() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let configURL = folder.appendingPathComponent("config.json")
        let pendingURL = folder.appendingPathComponent("pending-apply.json")
        var beforeCrash = AppConfiguration()
        beforeCrash.rotationEnabled = true
        try AppStorage.save(beforeCrash, to: configURL)
        let committedReceipt = receipt()
        try AppStorage.savePendingApply(PendingVisualVerification(schemaVersion: 1, assetID: committedReceipt.assetID,
                                                                  startedAt: Date(), receipt: committedReceipt), to: pendingURL)
        var restarted = try AppStorage.load(from: configURL)
        #expect(restarted.receipt == nil)
        let recovery = try #require(try AppStorage.loadPendingApply(at: pendingURL)?.receipt)
        #expect(recovery.originalValues == ["/fixture": Data("original user setup".utf8)])
        #expect(recovery.appliedValues == ["/fixture": Data("rotation scene".utf8)])
        restarted.receipt = recovery
        restarted.rotationEnabled = false
        restarted.pauseReason = "Interrupted update recovered"
        try AppStorage.save(restarted, to: configURL)
        // The journal is cleared only after the new config can be read back.
        let durable = try AppStorage.load(from: configURL)
        #expect(durable.receipt?.originalValues == committedReceipt.originalValues)
        #expect(durable.rotationEnabled == false)
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try AppStorage.removePendingApply(at: pendingURL)
        #expect(try AppStorage.loadPendingApply(at: pendingURL) == nil)
        #expect(try AppStorage.load(from: configURL).receipt?.originalValues == committedReceipt.originalValues)
    }

    @Test func unknownOrCorruptPendingJournalFailsClosed() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pending-apply.json")
        try AppStorage.savePendingApply(PendingVisualVerification(schemaVersion: 2, assetID: receipt().assetID,
                                                                  startedAt: Date(), receipt: receipt()), to: url)
        do {
            _ = try AppStorage.loadPendingApply(at: url)
            Issue.record("Unknown recovery schema was accepted")
        } catch { #expect((error as? AppStorage.StorageError) == .unsupportedVersion) }
        try Data("not JSON".utf8).write(to: url)
        do {
            _ = try AppStorage.loadPendingApply(at: url)
            Issue.record("Corrupt recovery data was accepted")
        } catch { #expect(error is DecodingError) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private var compatibilityInspection: StoreInspection {
        StoreInspection(fingerprint: "fixture-fingerprint", selections: [:], schemaDescription: "fixture-store-v1")
    }

    private func writeSmokeReport(to url: URL, schema: Int = 1, osBuild: String? = nil,
                                  storeSchema: String = "fixture-store-v1", passed: Bool = true,
                                  checkedAt: String = "2026-10-08T18:00:00Z") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A hand-authored fixture verifies the persisted record boundary rather
        // than using the production encoder to construct its own expected data.
        let record: [String: Any] = ["schemaVersion": schema, "osBuild": osBuild ?? AppStorage.osBuild,
                                     "storeSchema": storeSchema, "passed": passed, "checkedAt": checkedAt]
        try JSONSerialization.data(withJSONObject: record).write(to: url)
    }

    @Test func passingCompatibilityReportNeedsNoVisualVerificationMarker() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reportURL = folder.appendingPathComponent("native-smoke-report.json")
        let build = AppStorage.osBuild
        try #require(!build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && build.lowercased() != "unknown")
        try writeSmokeReport(to: reportURL, osBuild: build)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("native-verification.json").path))
        #expect(AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["native-smoke-report.json"])
    }

    @Test func missingOrCorruptCompatibilityReportFailsClosed() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reportURL = folder.appendingPathComponent("native-smoke-report.json")
        #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        // Create the private fixture folder without creating any app marker.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for corrupt in ["not JSON", "{", "{}", "[]"] {
            try Data(corrupt.utf8).write(to: reportURL)
            #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
            #expect(FileManager.default.fileExists(atPath: reportURL.path))
        }
    }

    @Test func incompatibleOrMalformedCompatibilityReportsFailClosed() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reportURL = folder.appendingPathComponent("native-smoke-report.json")
        try writeSmokeReport(to: reportURL, osBuild: AppStorage.osBuild + "-different-build")
        #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        for unknown in ["unknown", "", " "] {
            try writeSmokeReport(to: reportURL, osBuild: unknown)
            #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        }
        try writeSmokeReport(to: reportURL, storeSchema: "fixture-store-v2")
        #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        try writeSmokeReport(to: reportURL, schema: 2)
        #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        try writeSmokeReport(to: reportURL, checkedAt: "not-a-date")
        #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
    }

    @Test func failedNativeRecheckRevokesPreviouslyPassingCompatibility() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reportURL = folder.appendingPathComponent("native-smoke-report.json")
        try writeSmokeReport(to: reportURL)
        #expect(AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        try writeSmokeReport(to: reportURL, passed: false, checkedAt: "2026-10-08T18:02:00Z")
        #expect(!AppStorage.smokePassed(for: compatibilityInspection, reportURL: reportURL))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["native-smoke-report.json"])
    }
}

import Foundation
import AppleWallpaper
import RotationCore
import Darwin

struct AppConfiguration: Codable {
    var schemaVersion = 1
    var selectedSetID: String?
    var mappings: [String: [WallpaperPhase: String]] = [:]
    var receipt: OwnershipReceipt?
    var lastFix: LocationFix?
    var rotationEnabled = false
    var pauseReason: String? = "Not enabled"
}

typealias NativeVerification = NativeVerificationRecord
typealias NativeSmokeReport = NativeSmokeRecord

typealias PendingVisualVerification = PendingWallpaperOperation

enum AppStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wallpaper Rotation", isDirectory: true)
    }
    static var configurationURL: URL { directory.appendingPathComponent("config.json") }
    static var verificationURL: URL { directory.appendingPathComponent("native-verification.json") }
    static var smokeReportURL: URL { directory.appendingPathComponent("native-smoke-report.json") }
    static var pendingVerificationURL: URL { directory.appendingPathComponent("pending-verification.json") }
    static var pendingSmokeURL: URL { directory.appendingPathComponent("pending-smoke.json") }
    static var pendingApplyURL: URL { directory.appendingPathComponent("pending-apply.json") }
    static func loadPendingVerification() throws -> PendingVisualVerification? {
        try loadPending(at: pendingVerificationURL)
    }
    static func loadPendingApply(at url: URL = pendingApplyURL) throws -> PendingVisualVerification? {
        try loadPending(at: url)
    }
    private static func loadPending(at url: URL) throws -> PendingVisualVerification? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(PendingVisualVerification.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw StorageError.unsupportedVersion }
        return value
    }
    static func savePendingVerification(_ value: PendingVisualVerification) throws {
        try savePending(value, to: pendingVerificationURL)
    }
    static func savePendingApply(_ value: PendingVisualVerification, to url: URL = pendingApplyURL) throws {
        try savePending(value, to: url)
    }
    private static func savePending(_ value: PendingVisualVerification, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = folder.appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: try JSONEncoder().encode(value), attributes: [.posixPermissions: 0o600]),
              rename(staging.path, url.path) == 0 else { throw StorageError.cannotWrite }
    }
    static func removePendingVerification() throws {
        if FileManager.default.fileExists(atPath: pendingVerificationURL.path) { try FileManager.default.removeItem(at: pendingVerificationURL) }
    }
    static func removePendingApply(at url: URL = pendingApplyURL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func invalidateVerification() throws {
        if FileManager.default.fileExists(atPath: verificationURL.path) { try FileManager.default.removeItem(at: verificationURL) }
    }
    static func load(from url: URL = configurationURL) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfiguration() }
        let value = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw StorageError.unsupportedVersion }
        return value
    }
    static func save(_ configuration: AppConfiguration, to url: URL = configurationURL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(configuration)
        // A private staging file prevents exposing coordinates/receipts before chmod.
        let staging = folder.appendingPathComponent(".config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw StorageError.cannotWrite
        }
        guard rename(staging.path, url.path) == 0 else { throw StorageError.cannotWrite }
    }
    static var osBuild: String {
        var count = 0
        guard sysctlbyname("kern.osversion", nil, &count, nil, 0) == 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.osversion", &bytes, &count, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func verified(for inspection: StoreInspection) -> Bool {
        guard let data = try? Data(contentsOf: verificationURL),
              let value = try? JSONDecoder().decode(NativeVerification.self, from: data),
              let reportData = try? Data(contentsOf: smokeReportURL),
              let report = try? JSONDecoder().decode(NativeSmokeReport.self, from: reportData) else { return false }
        return NativeVerificationPolicy.isVerified(record: value, smoke: report,
            currentOSBuild: osBuild, currentStoreSchema: inspection.schemaDescription)
    }
    static func smokePassed(for inspection: StoreInspection, reportURL: URL = smokeReportURL) -> Bool {
        guard let data = try? Data(contentsOf: reportURL),
              let value = try? JSONDecoder().decode(NativeSmokeReport.self, from: data) else { return false }
        return NativeVerificationPolicy.smokePassed(smoke: value,
            currentOSBuild: osBuild, currentStoreSchema: inspection.schemaDescription)
    }
    static func recordVerification(for inspection: StoreInspection) throws {
        let value = NativeVerification(schemaVersion: 1, osBuild: osBuild, storeSchema: inspection.schemaDescription,
                                       verifiedAt: ISO8601DateFormatter().string(from: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".verification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: try JSONEncoder().encode(value),
                                             attributes: [.posixPermissions: 0o600]),
              rename(staging.path, verificationURL.path) == 0 else { throw StorageError.cannotWrite }
    }
    enum StorageError: LocalizedError, Equatable {
        case unsupportedVersion, cannotWrite
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "This configuration was saved by an unsupported app version."
            case .cannotWrite: "Could not save Wallpaper Rotation’s private configuration."
            }
        }
    }
}

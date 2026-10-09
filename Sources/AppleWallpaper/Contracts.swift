import Foundation
import RotationCore

public struct WallpaperAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let shotID: String
    public let name: String
    public let previewURL: URL?
    public let videoURL: URL
    public var isDownloaded: Bool {
        let movie = videoURL.resolvingSymlinksInPath()
        guard let values = try? movie.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
    public init(id: String, shotID: String, name: String, previewURL: URL?, videoURL: URL) {
        self.id = id; self.shotID = shotID; self.name = name
        self.previewURL = previewURL; self.videoURL = videoURL
    }
}

public struct WallpaperSet: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let assets: [WallpaperAsset]
    public let suggestedMapping: [WallpaperPhase: String]
    public let requiresReview: Bool
    public init(id: String, name: String, assets: [WallpaperAsset], suggestedMapping: [WallpaperPhase: String], requiresReview: Bool) {
        self.id = id; self.name = name; self.assets = assets
        self.suggestedMapping = suggestedMapping; self.requiresReview = requiresReview
    }
    public func asset(for phase: WallpaperPhase, mapping: [WallpaperPhase: String]? = nil) -> WallpaperAsset? {
        guard let id = (mapping ?? suggestedMapping)[phase] else { return nil }
        return assets.first { $0.id == id }
    }
}

public struct StoreInspection: Sendable {
    public let fingerprint: String
    public let selections: [String: String]
    public let schemaDescription: String
    public init(fingerprint: String, selections: [String: String], schemaDescription: String) {
        self.fingerprint = fingerprint; self.selections = selections; self.schemaDescription = schemaDescription
    }
}

public struct OwnershipReceipt: Codable, Sendable {
    public let originalValues: [String: Data]
    public let appliedValues: [String: Data]
    public let assetID: String
    public let osBuild: String
    public init(originalValues: [String: Data], appliedValues: [String: Data], assetID: String, osBuild: String) {
        self.originalValues = originalValues; self.appliedValues = appliedValues
        self.assetID = assetID; self.osBuild = osBuild
    }
}

public struct RestoreResult: Sendable {
    public let restoredCount: Int
    public let skippedCount: Int
    public init(restoredCount: Int, skippedCount: Int) { self.restoredCount = restoredCount; self.skippedCount = skippedCount }
}

public protocol NativeWallpaperApplying {
    func inspect() throws -> StoreInspection
    func apply(assetID: String, previous: OwnershipReceipt?) throws -> OwnershipReceipt
    func hasExternalChange(since receipt: OwnershipReceipt) throws -> Bool
    func restore(_ receipt: OwnershipReceipt) throws -> RestoreResult
}

/// Written before any native operation, so startup can recover its original
/// baseline even if the process stops before normal configuration is saved.
public struct PendingWallpaperOperation: Codable, Sendable {
    public let schemaVersion: Int
    public let assetID: String
    public let startedAt: Date
    public let receipt: OwnershipReceipt?
    public let previousReceipt: OwnershipReceipt?
    public init(schemaVersion: Int = 1, assetID: String, startedAt: Date, receipt: OwnershipReceipt?, previousReceipt: OwnershipReceipt? = nil) {
        self.schemaVersion = schemaVersion; self.assetID = assetID
        self.startedAt = startedAt; self.receipt = receipt; self.previousReceipt = previousReceipt
    }
}

import Foundation
import RotationCore

public struct WallpaperAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let shotID: String
    public let name: String
    public let previewURL: URL?
    public let videoURL: URL
    public let downloadURL: URL?
    public var isDownloaded: Bool {
        NativeMovieReadiness.isComplete(at: videoURL)
    }
    public init(id: String, shotID: String, name: String, previewURL: URL?, videoURL: URL, downloadURL: URL? = nil) {
        self.id = id; self.shotID = shotID; self.name = name
        self.previewURL = previewURL; self.videoURL = videoURL; self.downloadURL = downloadURL
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

/// Transient download presentation; never part of saved wallpaper ownership.
public struct WallpaperDownloadProgress: Sendable {
    public let completedCount: Int
    public let totalCount: Int
    public let fractionCompleted: Double?
    public init(completedCount: Int, totalCount: Int, fractionCompleted: Double? = nil) {
        self.completedCount = completedCount; self.totalCount = totalCount
        self.fractionCompleted = fractionCompleted
    }
}

@MainActor
public protocol WallpaperDownloading: AnyObject {
    func download(assets: [WallpaperAsset], onProgress: @escaping @MainActor @Sendable (WallpaperDownloadProgress) -> Void) async throws
    func cancel()
}

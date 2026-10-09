import Foundation
import RotationCore

public enum AppleWallpaperError: Error, LocalizedError {
    case unsupportedSchema(String)
    case externalInterference
    case invalidAssetID
    case assetUnavailable
    case verificationFailed
    case reloadFailed(String)
    case transactionBusy

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let detail): return "Unsupported Apple wallpaper schema: \(detail). Rotation stopped."
        case .externalInterference: return "Wallpaper settings changed during the transaction. Rotation stopped."
        case .invalidAssetID: return "The aerial asset identifier is invalid."
        case .assetUnavailable: return "This aerial is not in Apple's current catalog or its movie is not downloaded. Download it in Apple's Wallpaper Settings first."
        case .verificationFailed: return "Apple wallpaper settings did not match the verified transaction. Rotation stopped."
        case .reloadFailed(let detail): return "WallpaperAgent reload failed: \(detail). Rotation stopped; the recovery receipt is retained."
        case .transactionBusy: return "Another Wallpaper Rotation transaction is active. Try again after it finishes."
        }
    }
}

/// Reads Apple's native catalog. It never fetches URLs or manages Apple's media.
public struct AppleSetCatalog {
    public let manifestURL: URL
    public let fallbackManifestURL: URL
    public let videosDirectory: URL
    public let previewDirectory: URL

    public init(
        manifestURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"),
        fallbackManifestURL: URL = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json"),
        videosDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos"),
        previewDirectory: URL = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources")
    ) {
        self.manifestURL = manifestURL; self.fallbackManifestURL = fallbackManifestURL
        self.videosDirectory = videosDirectory; self.previewDirectory = previewDirectory
    }

    public func discover() throws -> [WallpaperSet] {
        // An invalid preferred manifest is a compatibility error, not grounds to silently use stale data.
        let data: Data
        do { data = try Data(contentsOf: manifestURL) }
        catch { data = try Data(contentsOf: fallbackManifestURL) }
        let catalog: Manifest
        do { catalog = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw AppleWallpaperError.unsupportedSchema("invalid aerial manifest: \(error.localizedDescription)") }
        guard catalog.version == 1,
              Set(catalog.assets.map(\.id)).count == catalog.assets.count,
              catalog.assets.allSatisfy({ UUID(uuidString: $0.id) != nil }) else {
            throw AppleWallpaperError.unsupportedSchema("manifest version or identifiers")
        }
        var seen = Set<String>()
        var sets: [WallpaperSet] = []
        for category in catalog.categories {
            for group in category.subcategories {
                guard seen.insert(group.id).inserted else { continue }
                let members = catalog.assets.filter { $0.subcategories.contains(group.id) }
                guard members.count >= 4 else { continue }
                let assets = members.map { entry in
                    let localPreview = previewDirectory.appendingPathComponent(entry.id + ".png")
                    return WallpaperAsset(id: entry.id, shotID: entry.shotID, name: readableName(entry),
                        previewURL: FileManager.default.fileExists(atPath: localPreview.path) ? localPreview : nil,
                        videoURL: videosDirectory.appendingPathComponent(entry.id + ".mov"))
                }
                var mapping: [WallpaperPhase: String] = [:]
                var review = false
                for phase in WallpaperPhase.allCases {
                    let candidates = members.filter { role(of: $0) == phase }
                    if candidates.count == 1 { mapping[phase] = candidates[0].id }
                    else { review = true }
                }
                if mapping[.sunset] == nil {
                    let morning = members.filter { $0.accessibilityLabel.lowercased().contains("morning") }
                    if morning.count == 1 { mapping[.sunset] = morning[0].id }
                    review = true
                }
                // Show families with a usable phase suggestion, including ambiguous ones for review.
                sets.append(WallpaperSet(id: group.id, name: groupName(group, members: members),
                    assets: assets, suggestedMapping: mapping,
                    requiresReview: review || mapping.count != WallpaperPhase.allCases.count))
            }
        }
        return sets
    }

    private func role(of asset: Entry) -> WallpaperPhase? {
        let text = (asset.shotID + " " + asset.localizedNameKey + " " + asset.accessibilityLabel).uppercased()
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return WallpaperPhase.allCases.first { tokens.contains($0.rawValue.uppercased()) }
    }

    private func readableName(_ asset: Entry) -> String {
        // Some accessibility labels are codec filenames; avoid presenting those as friendly names.
        if asset.accessibilityLabel.contains("_") { return asset.shotID.replacingOccurrences(of: "_", with: " ") }
        return asset.accessibilityLabel
    }

    private func groupName(_ group: Group, members: [Entry]) -> String {
        let key = group.localizedNameKey
        let prefix = "AerialSubcategory"
        let suffix = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        if suffix == "GoldenGate" { return "Golden Gate" }
        if suffix == "Tahoe" { return "Tahoe" }
        let spaced = suffix.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.isEmpty ? (members.first?.accessibilityLabel ?? group.id) : spaced
    }

    private struct Manifest: Decodable { let version: Int; let assets: [Entry]; let categories: [Category] }
    private struct Category: Decodable { let subcategories: [Group] }
    private struct Group: Decodable { let id: String; let localizedNameKey: String }
    private struct Entry: Decodable {
        let id: String; let shotID: String; let accessibilityLabel: String
        let localizedNameKey: String; let subcategories: [String]
    }
}

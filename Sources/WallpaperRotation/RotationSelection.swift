import Foundation
import AppleWallpaper
import RotationCore

/// The exact set and four visible scene choices accepted by an Enable action.
struct RotationSelection {
    let setID: String
    let mapping: [WallpaperPhase: String]

    func problem(in sets: [WallpaperSet]) -> String? {
        guard let set = sets.first(where: { $0.id == setID }) else {
            return "Choose an available wallpaper set before enabling rotation."
        }
        guard WallpaperPhase.allCases.allSatisfy({ set.asset(for: $0, mapping: mapping) != nil }) else {
            return "Choose a scene for all four times of day in \(set.name) before enabling rotation."
        }
        guard WallpaperPhase.allCases.allSatisfy({ set.asset(for: $0, mapping: mapping)?.isDownloaded == true }) else {
            return "Download every chosen scene in \(set.name) before enabling rotation."
        }
        return nil
    }

    /// Save first, then expose the accepted selection. A failed save keeps the old selection intact.
    func commit(to current: AppConfiguration, sets: [WallpaperSet],
                save: (AppConfiguration) throws -> Void) throws -> AppConfiguration {
        if let problem = problem(in: sets) { throw SelectionError.invalid(problem) }
        var accepted = current
        accepted.selectedSetID = setID
        accepted.mappings[setID] = mapping
        try save(accepted)
        return accepted
    }

    enum SelectionError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): message } }
    }
}

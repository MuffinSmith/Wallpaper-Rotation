import AppKit
import Foundation
import Testing
import AppleWallpaper
import RotationCore
@testable import WallpaperRotation

@Suite(.serialized)
@MainActor
struct NativeObservationTests {
    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private func dictionary(_ data: Data) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "The actual directory watcher did not process the native store change")
    }

    @Test func delayedEquivalentNormalizationStaysEnabledButRealAssetEditPersistsPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-observation-\(UUID().uuidString)")
        let storeDirectory = root.appendingPathComponent("Store")
        let privateDirectory = root.appendingPathComponent("Application")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = storeDirectory.appendingPathComponent("Index.plist")
        let configURL = privateDirectory.appendingPathComponent("config.json")
        let backupDirectory = privateDirectory.appendingPathComponent("Backups")
        let oldID = "00000000-0000-0000-0000-000000000001"
        let goldenGateID = "00000000-0000-0000-0000-000000000002"
        let outsideID = "00000000-0000-0000-0000-000000000003"
        let displayID = "00000000-0000-0000-0000-000000000004"
        let branch: [String: Any] = [
            "Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [String](),
                                      "Configuration": try plist(["assetID": oldID, "retainedConfiguration": "keep"])]],
                        "Shuffle": "$null", "EncodedOptionValues": try plist(["placement": "Crop"]),
                        "retainedContent": "keep"],
            "LastSet": Date(timeIntervalSince1970: 100), "LastUse": Date(timeIntervalSince1970: 200),
            "retainedBranchMetadata": 7]
        try plist(["AllSpacesAndDisplays": "$null", "SystemDefault": ["Type": "linked", "Linked": branch],
                   "Spaces": [String: Any](), "Displays": [displayID: ["Type": "linked", "Linked": branch]]]).write(to: storeURL)
        let movie = root.appendingPathComponent("complete.mov")
        try Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(repeating: 0, count: 8)
                 + [0, 0, 0, 9] + Array("moov".utf8) + [0]
                 + [0, 0, 0, 9] + Array("mdat".utf8) + [0]).write(to: movie)
        let goldenGate = WallpaperSet(id: "golden-gate", name: "Golden Gate",
            assets: [.init(id: goldenGateID, shotID: "GG_A_NIGHT", name: "Golden Gate Night", previewURL: nil, videoURL: movie)],
            suggestedMapping: Dictionary(uniqueKeysWithValues: WallpaperPhase.allCases.map { ($0, goldenGateID) }), requiresReview: false)
        var initial = AppConfiguration()
        initial.selectedSetID = goldenGate.id
        initial.lastFix = .init(coordinate: .init(latitude: 37, longitude: -122), capturedAt: Date(), source: "Manual coordinates")
        let worker = NativeApplyWorker(directory: privateDirectory, adapterFactory: {
            NativeWallpaperAdapter(storeURL: storeURL, backupDir: backupDirectory, reload: {}, assetAvailable: { _ in true })
        })
        let coordinator = AppCoordinator(configuration: initial, sets: [goldenGate], enableEnvironment: .init(
            isReady: { true }, saveConfiguration: { try AppStorage.save($0, to: configURL) },
            applyAsset: nil, checkCompatibility: { _ in }, showSettings: {}), nativeWorker: worker,
            nativeAdapter: NativeWallpaperAdapter(storeURL: storeURL, backupDir: backupDirectory, reload: {}, assetAvailable: { _ in true }))
        coordinator.startNativeObservation()
        defer {
            coordinator.stopNativeObservation()
            if coordinator.configuration.rotationEnabled { coordinator.toggleRotation() }
        }
        coordinator.toggleRotation()
        try await waitUntil { !coordinator.nativeOperationRunning }
        try #require(coordinator.configuration.rotationEnabled)
        #expect(coordinator.configuration.receipt?.assetID == goldenGateID)

        // Apple later copies the whole Linked branch into separate Desktop/Idle branches.
        var normalized = try dictionary(Data(contentsOf: storeURL))
        var displays = try #require(normalized["Displays"] as? [String: Any])
        var display = try #require(displays[displayID] as? [String: Any])
        let linked = try #require(display.removeValue(forKey: "Linked") as? [String: Any])
        display["Type"] = "individual"; display["Desktop"] = linked; display["Idle"] = linked
        displays[displayID] = display; normalized["Displays"] = displays
        try plist(normalized).write(to: storeURL, options: .atomic)
        let desktopPath = "/Displays/\(displayID)/Desktop/Content/Choices/0/Configuration"
        let idlePath = "/Displays/\(displayID)/Idle/Content/Choices/0/Configuration"
        // Inspection's new keys prove the production notification and debounce actually ran.
        try await waitUntil { coordinator.inspection?.selections[desktopPath] == goldenGateID && coordinator.inspection?.selections[idlePath] == goldenGateID }
        try #require(coordinator.configuration.rotationEnabled, "Equivalent Apple branch normalization paused ordinary rotation")
        #expect(try AppStorage.load(from: configURL).rotationEnabled)

        var desktop = try #require(display["Desktop"] as? [String: Any])
        var content = try #require(desktop["Content"] as? [String: Any])
        var choices = try #require(content["Choices"] as? [[String: Any]])
        var configuration = try dictionary(try #require(choices[0]["Configuration"] as? Data))
        configuration["assetID"] = outsideID
        choices[0]["Configuration"] = try plist(configuration)
        content["Choices"] = choices; desktop["Content"] = content; display["Desktop"] = desktop
        displays[displayID] = display; normalized["Displays"] = displays
        try plist(normalized).write(to: storeURL, options: .atomic)
        try await waitUntil { !coordinator.configuration.rotationEnabled }
        #expect(coordinator.inspection?.selections[desktopPath] == outsideID)
        let durable = try AppStorage.load(from: configURL)
        #expect(!durable.rotationEnabled)
        #expect(durable.pauseReason == "Wallpaper changed outside Wallpaper Rotation")
        #expect(durable.receipt?.assetID == goldenGateID)
    }
}

import AppKit
import Testing
import AppleWallpaper
import RotationCore
@testable import WallpaperRotation

@Suite(.serialized)
@MainActor
struct RotationSelectionTests {
    @MainActor
    private final class Fixture {
        let directory: URL
        let sets: [WallpaperSet]
        var saved: [AppConfiguration] = []
        var applied: [String] = []
        var failSave = false
        var failSaveAt: Int?
        var saveAttempts = 0
        var compatible = true
        var compatibilityCompletion: (() -> Void)?
        var settingsPresented = 0

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rotation-selection-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let movie = directory.appendingPathComponent("complete.mov")
            // Independent structural movie fixture; no Apple media or decoded video.
            try Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(repeating: 0, count: 8)
                     + [0, 0, 0, 9] + Array("moov".utf8) + [0]
                     + [0, 0, 0, 9] + Array("mdat".utf8) + [0]).write(to: movie)
            let missingMovie = directory.appendingPathComponent("absent.mov")
            sets = ["Golden Gate", "Tahoe", "Missing"].map { name in
                let assets = WallpaperPhase.allCases.map { phase in
                    WallpaperAsset(id: "\(name)-\(phase.rawValue)", shotID: phase.rawValue,
                                   name: phase == .sunset && name == "Tahoe" ? "Tahoe Morning" : "\(name) \(phase.title)",
                                   previewURL: nil,
                                   videoURL: name == "Missing" ? missingMovie : movie)
                }
                return WallpaperSet(id: name, name: name, assets: assets,
                                    suggestedMapping: Dictionary(uniqueKeysWithValues: zip(WallpaperPhase.allCases, assets.map(\.id))),
                                    requiresReview: name != "Golden Gate")
            }
        }
        func coordinator(reviewTahoe: Bool = false) -> AppCoordinator {
            var configuration = AppConfiguration()
            configuration.selectedSetID = "Golden Gate"
            if reviewTahoe { configuration.mappings["Tahoe"] = sets[1].suggestedMapping }
            configuration.lastFix = LocationFix(coordinate: Coordinate(latitude: 37, longitude: -122), capturedAt: Date(), source: "Manual coordinates")
            return AppCoordinator(configuration: configuration, sets: sets, enableEnvironment: .init(
                isReady: { [self] in compatible }, saveConfiguration: { [self] value in
                    saveAttempts += 1
                    if failSave || saveAttempts == failSaveAt { throw CocoaError(.fileWriteNoPermission) }
                    saved.append(value)
                }, applyAsset: { [self] asset in
                    #expect(saved.last?.rotationEnabled == true)
                    #expect(saved.last?.selectedSetID == "Tahoe" || saved.last?.selectedSetID == "Golden Gate")
                    applied.append(asset)
                }, checkCompatibility: { [self] completion in compatibilityCompletion = completion },
                showSettings: { [self] in settingsPresented += 1 }))
        }
    }
    private func controls(in view: NSView) -> [NSControl] {
        ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap { controls(in: $0) }
    }
    private func control<T: NSControl>(_ type: T.Type, label: String, in controller: SettingsWindowController) throws -> T {
        let root = try #require(controller.window?.contentView)
        return try #require(controls(in: root).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label })
    }
    private func invoke(_ control: NSControl) throws {
        #expect(control.sendAction(try #require(control.action), to: control.target))
    }
    private func stop(_ coordinator: AppCoordinator) {
        if coordinator.configuration.rotationEnabled { coordinator.toggleRotation() }
    }

    @Test func nativePickerSelectionSurvivesRenderingAndEnableUsesVisibleTahoeDraft() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator()
        defer { stop(coordinator) }
        let settings = SettingsWindowController(coordinator: coordinator)
        settings.render()
        let picker = try control(NSPopUpButton.self, label: "Wallpaper set", in: settings)
        picker.selectItem(at: 1)
        try invoke(picker)
        settings.render(); settings.render()
        #expect(picker.indexOfSelectedItem == 1)
        #expect(picker.selectedItem?.representedObject as? String == "Tahoe")
        #expect(picker.selectedItem?.title == "Tahoe")
        #expect(coordinator.selectedSet?.id == "Golden Gate")
        #expect(coordinator.canEnable) // Committed Golden Gate remains ready while Tahoe is reviewed.
        let night = try control(NSPopUpButton.self, label: "Scene for Night", in: settings)
        night.selectItem(at: 3) // Explicitly customize Night to the visible Tahoe Evening scene.
        try invoke(night)
        settings.render(); settings.render()
        #expect(night.indexOfSelectedItem == 3)
        #expect(night.selectedItem?.representedObject as? String == "Tahoe-evening")
        let movie = fixture.sets[1].assets[0].videoURL
        let movieBytes = try Data(contentsOf: movie)
        try FileManager.default.removeItem(at: movie)
        settings.render()
        #expect(picker.indexOfSelectedItem == 1)
        #expect(picker.selectedItem?.representedObject as? String == "Tahoe")
        #expect(night.indexOfSelectedItem == 3)
        #expect(night.selectedItem?.representedObject as? String == "Tahoe-evening")
        #expect(night.selectedItem?.title.contains("Download required") == true)
        try movieBytes.write(to: movie)
        settings.render()
        let rotation = try control(NSSwitch.self, label: "Automatic wallpaper rotation", in: settings)
        #expect(rotation.isEnabled)
        try invoke(rotation)
        #expect(coordinator.configuration.rotationEnabled)
        #expect(coordinator.selectedSet?.id == "Tahoe")
        #expect(coordinator.configuration.mappings["Tahoe"]?[.night] == "Tahoe-evening")
        #expect(fixture.saved.first?.selectedSetID == "Tahoe")
        #expect(fixture.saved.first?.rotationEnabled == false)
        #expect(fixture.saved.first?.mappings["Tahoe"]?[.sunset] == "Tahoe-sunset")
        let phase = try #require(coordinator.schedule?.phase)
        #expect(fixture.applied == [try #require(coordinator.configuration.mappings["Tahoe"]?[phase])])
    }

    @Test(arguments: [false, true]) func menuEnableAcceptsBrowsedReviewSetAndNeverFallsBackToGoldenGate(reviewed: Bool) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator(reviewTahoe: reviewed)
        defer { stop(coordinator) }
        coordinator.select("Tahoe")
        #expect(coordinator.selectedSet?.id == (reviewed ? "Tahoe" : "Golden Gate"))
        #expect(fixture.applied.isEmpty)
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(coordinator.canEnableRequestedRotation)
        coordinator.toggleRotation()
        #expect(coordinator.selectedSet?.id == "Tahoe")
        #expect(coordinator.configuration.mappings["Tahoe"] == fixture.sets[1].suggestedMapping)
        #expect(fixture.applied.count == 1)
        #expect(fixture.applied.allSatisfy { $0.hasPrefix("Tahoe-") })
    }

    @Test func incompleteDraftAndUndownloadedSetBlockWithoutApplyingOldSet() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator()
        var incomplete = fixture.sets[1].suggestedMapping
        incomplete[.night] = nil
        let draft = RotationSelection(setID: "Tahoe", mapping: incomplete)
        #expect(!coordinator.canEnableRotation(using: draft))
        coordinator.requestRotationToggle(using: draft)
        #expect(coordinator.message.contains("all four"))
        #expect(coordinator.selectedSet?.id == "Golden Gate")
        coordinator.select("Missing")
        #expect(coordinator.canEnable) // Browsing cannot invalidate the active committed set.
        #expect(!coordinator.canEnableRequestedRotation)
        coordinator.toggleRotation()
        #expect(coordinator.message.contains("Download"))
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(fixture.saved.isEmpty)
        #expect(fixture.applied.isEmpty)
    }

    @Test func persistenceFailureBlocksSelectionAndNativeApply() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.failSave = true
        let coordinator = fixture.coordinator()
        coordinator.select("Tahoe")
        coordinator.toggleRotation()
        #expect(coordinator.selectedSet?.id == "Golden Gate")
        #expect(coordinator.configuration.mappings["Tahoe"] == nil)
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(!coordinator.message.isEmpty)
        #expect(fixture.saved.isEmpty)
        #expect(fixture.applied.isEmpty)
    }

    @Test func asyncCompatibilityResumesCapturedTahoeDespiteLaterBrowse() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.compatible = false
        let coordinator = fixture.coordinator()
        defer { stop(coordinator) }
        coordinator.select("Tahoe")
        coordinator.toggleRotation()
        #expect(coordinator.selectedSet?.id == "Tahoe")
        #expect(fixture.saved.first?.mappings["Tahoe"] == fixture.sets[1].suggestedMapping)
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(fixture.applied.isEmpty)
        coordinator.select("Golden Gate")
        #expect(coordinator.selectedSet?.id == "Golden Gate")
        fixture.compatible = true
        let complete = try #require(fixture.compatibilityCompletion)
        complete()
        #expect(coordinator.configuration.rotationEnabled)
        #expect(coordinator.selectedSet?.id == "Tahoe")
        #expect(fixture.applied.count == 1)
        #expect(fixture.applied.allSatisfy { $0.hasPrefix("Tahoe-") })
    }

    @Test func finalEnableSaveFailureNeverReachesNativeApply() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.failSaveAt = 2
        let coordinator = fixture.coordinator()
        coordinator.select("Tahoe")
        coordinator.toggleRotation()
        #expect(fixture.saved.count == 1)
        #expect(fixture.saved.first?.selectedSetID == "Tahoe")
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(fixture.applied.isEmpty)
    }

    @Test func activeRotationSurvivesMissingBrowseAndExplicitReadySelectionStillApplies() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = fixture.coordinator(reviewTahoe: true)
        defer { stop(coordinator) }
        coordinator.toggleRotation()
        #expect(coordinator.configuration.rotationEnabled)
        coordinator.select("Missing")
        #expect(coordinator.configuration.rotationEnabled)
        #expect(coordinator.canEnable)
        #expect(coordinator.selectedSet?.id == "Golden Gate")
        #expect(fixture.applied.count == 1)
        coordinator.select("Tahoe")
        #expect(coordinator.configuration.rotationEnabled)
        #expect(coordinator.selectedSet?.id == "Tahoe")
        #expect(fixture.applied.count == 2)
        #expect(fixture.applied.last?.hasPrefix("Tahoe-") == true)
    }

}

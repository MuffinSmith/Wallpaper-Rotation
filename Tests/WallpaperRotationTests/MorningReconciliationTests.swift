import AppKit
import Foundation
import Testing
import RotationCore
import AppleWallpaper
@testable import WallpaperRotation

@Suite(.serialized)
@MainActor
struct MorningReconciliationTests {
    @Test func publicRefreshCatchesUpEnabledRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("morning-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("complete.mov")
        try Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(repeating: 0, count: 8)
                 + [0, 0, 0, 9] + Array("moov".utf8) + [0]
                 + [0, 0, 0, 9] + Array("mdat".utf8) + [0]).write(to: movie)
        // Every phase has this independently chosen target, so this regression
        // does not derive its expected result from the implementation's clock.
        let dayID = "00000000-0000-0000-0000-000000000002"
        let set = WallpaperSet(id: "fixture", name: "Fixture", assets: [
            .init(id: dayID, shotID: "DAY", name: "Day", previewURL: nil, videoURL: movie)
        ], suggestedMapping: Dictionary(uniqueKeysWithValues: WallpaperPhase.allCases.map { ($0, dayID) }), requiresReview: false)
        var initial = AppConfiguration()
        initial.rotationEnabled = true
        initial.selectedSetID = set.id
        initial.lastFix = .init(coordinate: .init(latitude: 42.32, longitude: -71.09), capturedAt: Date(), source: "Manual coordinates")
        var applied: [String] = []
        let coordinator = AppCoordinator(configuration: initial, sets: [set], enableEnvironment: .init(
            isReady: { true }, saveConfiguration: { _ in }, applyAsset: { applied.append($0) },
            checkCompatibility: { _ in }, showSettings: {}))
        defer { if coordinator.configuration.rotationEnabled { coordinator.toggleRotation() } }
        coordinator.refreshAvailability()
        #expect(applied == [dayID], "Public refresh must reconcile an enabled current scene before replacing its transition timer")
    }
}

@MainActor
private final class MorningFixture {
    final class ReloadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func reload() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    let root: URL
    let store: URL
    let adapter: NativeWallpaperAdapter
    let reloads = ReloadCounter()
    let coordinator: AppCoordinator
    static let dayID = "00000000-0000-0000-0000-000000000002"
    static let nightID = "00000000-0000-0000-0000-000000000005"
    static let outsideID = "00000000-0000-0000-0000-000000000006"

    private final class State {
        var clock = ISO8601DateFormatter().date(from: "2026-10-08T07:00:00Z")!
        var saved: [AppConfiguration] = []
    }
    private let state = State()
    var date: Date { get { state.clock } set { state.clock = newValue } }
    var durable: AppConfiguration? { state.saved.last }
    init(enabled: Bool = false, runtimeReady: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("morning-native-\(UUID().uuidString)")
        store = root.appendingPathComponent("Store/Index.plist")
        let directory = root.appendingPathComponent("Application")
        let backups = directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let branch: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [String](),
            "Configuration": try Self.plist(["assetID": Self.outsideID])]], "Shuffle": "$null", "EncodedOptionValues": try Self.plist(["placement": "Crop"])]]
        try Self.plist(["AllSpacesAndDisplays": "$null", "SystemDefault": ["Type": "linked", "Linked": branch],
                        "Spaces": [String: Any](), "Displays": [String: Any]()]).write(to: store)
        let movie = root.appendingPathComponent("complete.mov")
        try Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(repeating: 0, count: 8)
                 + [0, 0, 0, 9] + Array("moov".utf8) + [0]
                 + [0, 0, 0, 9] + Array("mdat".utf8) + [0]).write(to: movie)
        let ids = [Self.dayID, "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004", Self.nightID]
        let set = WallpaperSet(id: "fixture", name: "Fixture", assets: zip(WallpaperPhase.allCases, ids).map { phase, id in
            .init(id: id, shotID: phase.rawValue, name: phase.title, previewURL: nil, videoURL: movie)
        }, suggestedMapping: Dictionary(uniqueKeysWithValues: zip(WallpaperPhase.allCases, ids)), requiresReview: false)
        let storeURL = store
        let reloads = reloads
        adapter = NativeWallpaperAdapter(storeURL: storeURL, backupDir: backups, reload: { reloads.reload() }, assetAvailable: { _ in true })
        let worker = NativeApplyWorker(directory: directory, adapterFactory: {
            NativeWallpaperAdapter(storeURL: storeURL, backupDir: backups, reload: { reloads.reload() }, assetAvailable: { _ in true })
        })
        var initial = AppConfiguration()
        initial.rotationEnabled = enabled
        initial.selectedSetID = set.id
        initial.lastFix = .init(coordinate: .init(latitude: 42.32, longitude: -71.09), capturedAt: state.clock, source: "Manual coordinates")
        let state = state
        let environment = AppCoordinator.EnableEnvironment(isReady: { true }, saveConfiguration: { state.saved.append($0) },
            applyAsset: nil, checkCompatibility: { _ in }, showSettings: {}, runtimeReconciliationReady: runtimeReady)
        coordinator = AppCoordinator(configuration: initial, sets: [set], enableEnvironment: environment,
                                     nativeWorker: worker, nativeAdapter: adapter, now: { state.clock })
    }
    static func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    func advanceToDay() { state.clock = ISO8601DateFormatter().date(from: "2026-10-08T20:00:00Z")! }
    func cleanup() {
        if coordinator.configuration.rotationEnabled { coordinator.toggleRotation() }
        coordinator.stopNativeObservation()
        try? FileManager.default.removeItem(at: root)
    }
    func settle() async throws {
        let deadline = Date().addingTimeInterval(5)
        while coordinator.nativeOperationRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!coordinator.nativeOperationRunning, "Fixture native transaction did not settle within five seconds")
    }
    func enableNight() async throws {
        coordinator.toggleRotation()
        try await settle()
        try #require(coordinator.configuration.rotationEnabled)
        #expect(coordinator.configuration.receipt?.assetID == Self.nightID)
        #expect(reloads.value == 1)
    }
    func manuallyChangeOwnedScene() throws {
        var root = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: store), options: [], format: nil) as? [String: Any])
        var node = try #require(root["SystemDefault"] as? [String: Any])
        var branch = try #require(node["Linked"] as? [String: Any])
        var content = try #require(branch["Content"] as? [String: Any])
        var choices = try #require(content["Choices"] as? [[String: Any]])
        choices[0]["Configuration"] = try Self.plist(["assetID": Self.outsideID])
        content["Choices"] = choices; branch["Content"] = content; node["Linked"] = branch; root["SystemDefault"] = node
        try Self.plist(root).write(to: store, options: .atomic)
    }
}

extension MorningReconciliationTests {
    @Test func overdueMenuRefreshAppliesOnlyCurrentDaySceneAndRepeatedRefreshDoesNotWrite() async throws {
        let fixture = try MorningFixture()
        defer { fixture.cleanup() }
        try await fixture.enableNight()
        fixture.advanceToDay()
        fixture.coordinator.menuWillOpen(NSMenu())
        try await fixture.settle()
        #expect(fixture.coordinator.configuration.receipt?.assetID == MorningFixture.dayID)
        #expect(fixture.reloads.value == 2, "Catch-up must skip Dawn and Sunrise instead of replaying missed phases")
        let dayBytes = try Data(contentsOf: fixture.store)
        for _ in 0..<3 { fixture.coordinator.refreshAvailability(); try await fixture.settle() }
        #expect(fixture.reloads.value == 2)
        #expect(try Data(contentsOf: fixture.store) == dayBytes)
    }
    @Test func sessionActivationCatchesUpAndRepeatedWakeIsIdempotent() async throws {
        let fixture = try MorningFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startLifecycleObservation()
        try await fixture.enableNight()
        fixture.advanceToDay()
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await fixture.settle()
        #expect(fixture.coordinator.configuration.receipt?.assetID == MorningFixture.dayID)
        let bytes = try Data(contentsOf: fixture.store)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await fixture.settle()
        #expect(fixture.reloads.value == 2)
        #expect(try Data(contentsOf: fixture.store) == bytes)
    }
    @Test func pausedRefreshAndSessionKeepManualWallpaperUntouched() async throws {
        let fixture = try MorningFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startLifecycleObservation()
        try await fixture.enableNight()
        fixture.coordinator.toggleRotation()
        fixture.advanceToDay()
        let bytes = try Data(contentsOf: fixture.store)
        fixture.coordinator.refreshAvailability()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await fixture.settle()
        #expect(!fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.reloads.value == 1)
        #expect(try Data(contentsOf: fixture.store) == bytes)
    }
    @Test func realOwnedSceneEditPausesBeforeRefreshOrSessionCanApply() async throws {
        let fixture = try MorningFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startLifecycleObservation()
        try await fixture.enableNight()
        try fixture.manuallyChangeOwnedScene()
        let outsideBytes = try Data(contentsOf: fixture.store)
        fixture.advanceToDay()
        fixture.coordinator.menuWillOpen(NSMenu())
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await fixture.settle()
        #expect(!fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.durable?.pauseReason == "Wallpaper changed outside Wallpaper Rotation")
        #expect(fixture.reloads.value == 1)
        #expect(try Data(contentsOf: fixture.store) == outsideBytes)
    }
    @Test func discoveryBeforeStartupGatesDoesNotApplyOrPauseSavedIntent() throws {
        let fixture = try MorningFixture(enabled: true, runtimeReady: false)
        defer { fixture.coordinator.stopNativeObservation(); try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = try Data(contentsOf: fixture.store)
        fixture.coordinator.refreshAvailability()
        #expect(fixture.coordinator.configuration.rotationEnabled)
        #expect(!fixture.coordinator.nativeOperationRunning)
        #expect(fixture.reloads.value == 0)
        #expect(try Data(contentsOf: fixture.store) == bytes)
    }
    @Test func trackedMenuUpdatesActionStateAndPauseReasonWithoutReplacingItems() async throws {
        let fixture = try MorningFixture()
        defer { fixture.cleanup() }
        let menu = NSMenu()
        fixture.coordinator.renderMenuContents(menu)
        let toggle = try #require(menu.items.first { $0.identifier?.rawValue == "rotation-toggle" })
        #expect(toggle.title == "Resume Rotation")
        #expect(toggle.state == .off)
        try await fixture.enableNight()
        fixture.coordinator.menuWillOpen(menu)
        fixture.coordinator.renderMenuContents(menu)
        #expect(menu.items.contains { $0 === toggle })
        #expect(toggle.title == "Pause Rotation")
        #expect(toggle.state == .on)
        #expect(toggle.isEnabled)
        try await fixture.settle()
        fixture.coordinator.toggleRotation()
        fixture.coordinator.renderMenuContents(menu)
        #expect(menu.items.contains { $0 === toggle })
        #expect(toggle.title == "Resume Rotation")
        #expect(toggle.state == .off)
        #expect(menu.items[1].title == "Paused: By you")
    }
}

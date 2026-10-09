import AppKit
import Testing
import AppleWallpaper
import RotationCore
@testable import WallpaperRotation

@Suite(.serialized)
@MainActor
struct SettingsInterfaceTests {
    private final class ReloadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var total = 0
        private var maximum = 0
        let fails: Bool
        init(fails: Bool) { self.fails = fails }
        func reload() throws {
            lock.lock(); active += 1; total += 1; maximum = max(maximum, active); lock.unlock()
            Thread.sleep(forTimeInterval: 1)
            lock.lock(); active -= 1; lock.unlock()
            if fails { throw AppleWallpaperError.reloadFailed("fixture timeout") }
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return total }
        var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    }
    @MainActor private final class Heartbeat: NSObject {
        var ticks = 0
        @objc func tick() { ticks += 1 }
    }
    @MainActor private final class Fixture {
        let root: URL
        let sets: [WallpaperSet]
        let probe: ReloadProbe
        let worker: NativeApplyWorker
        var coordinator: AppCoordinator!
        var saved: [AppConfiguration] = []
        var terminationReplies: [Bool] = []
        var failSave = false
        var beforeSave: ((AppConfiguration) -> Void)?
        var fakeDownload: ControlledDownload?

        init(failsReload: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("interface-audit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let movie = root.appendingPathComponent("complete.mov")
            try Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(repeating: 0, count: 8)
                     + [0, 0, 0, 9] + Array("moov".utf8) + [0]
                     + [0, 0, 0, 9] + Array("mdat".utf8) + [0]).write(to: movie)
            let missingMovie = root.appendingPathComponent("absent.mov")
            sets = ["Old", "New", "Missing"].enumerated().map { index, name in
                let assets = WallpaperPhase.allCases.enumerated().map { phaseIndex, phase in
                    WallpaperAsset(id: String(format: "00000000-0000-0000-0000-%012d", index * 10 + phaseIndex + 1),
                                   shotID: phase.rawValue, name: "\(name) \(phase.title)", previewURL: nil,
                                   videoURL: name == "Missing" ? missingMovie : movie,
                                   downloadURL: name == "Missing" ? URL(string: "https://invalid.example/fixture.mov") : nil)
                }
                return WallpaperSet(id: name, name: name, assets: assets,
                                    suggestedMapping: Dictionary(uniqueKeysWithValues: zip(WallpaperPhase.allCases, assets.map(\.id))),
                                    requiresReview: name == "Missing")
            }
            func plist(_ value: Any) throws -> Data {
                try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            }
            let branch: [String: Any] = ["Content": [
                "Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [String](),
                             "Configuration": try plist(["assetID": sets[0].assets[0].id])]], "Shuffle": "$null"]]
            let store: [String: Any] = ["AllSpacesAndDisplays": "$null", "SystemDefault": ["Type": "linked", "Linked": branch],
                                       "Spaces": [String: Any](), "Displays": [String: Any]()]
            let storeURL = root.appendingPathComponent("Index.plist")
            try plist(store).write(to: storeURL)
            probe = ReloadProbe(fails: failsReload)
            let backups = root.appendingPathComponent("Backups")
            let reloadProbe = probe
            worker = NativeApplyWorker(directory: root, adapterFactory: {
                NativeWallpaperAdapter(storeURL: storeURL, backupDir: backups,
                                       reload: { try reloadProbe.reload() }, assetAvailable: { _ in true })
            })
            var configuration = AppConfiguration()
            configuration.selectedSetID = "Old"; configuration.rotationEnabled = true
            configuration.lastFix = .init(coordinate: .init(latitude: 37, longitude: -122), capturedAt: Date(), source: "Manual coordinates")
            coordinator = AppCoordinator(configuration: configuration, sets: sets, enableEnvironment: .init(
                isReady: { true }, saveConfiguration: { [self] value in
                    if failSave { throw CocoaError(.fileWriteNoPermission) }
                    beforeSave?(value)
                    saved.append(value)
                }, applyAsset: nil, checkCompatibility: { _ in }, showSettings: {},
                replyToTermination: { [self] in terminationReplies.append($0) },
                makeDownloader: { [self] in let value = ControlledDownload(); fakeDownload = value; return value }), nativeWorker: worker)
        }
        func settings() -> SettingsWindowController {
            let controller = SettingsWindowController(coordinator: coordinator)
            controller.render()
            return controller
        }
        func cleanup() {
            if coordinator.configuration.rotationEnabled { coordinator.toggleRotation() }
            try? FileManager.default.removeItem(at: root)
        }
    }
    @MainActor private final class ControlledDownload: WallpaperDownloading {
        var started = false
        var cancelled = false
        var cleanupCompleted = false
        private var continuation: CheckedContinuation<Void, any Error>?
        func download(assets: [WallpaperAsset], onProgress: @escaping @MainActor @Sendable (WallpaperDownloadProgress) -> Void) async throws {
            started = true
            onProgress(.init(completedCount: 0, totalCount: assets.count, fractionCompleted: 0.25))
            defer { cleanupCompleted = true }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func cancel() { cancelled = true }
        func finishCancellation() { continuation?.resume(throwing: CancellationError()); continuation = nil }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func control<T: NSControl>(_ type: T.Type, label: String, in settings: SettingsWindowController) throws -> T {
        let view = try #require(settings.window?.contentView)
        return try #require(descendants(view).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label })
    }
    private func button(action: String, in settings: SettingsWindowController) throws -> NSButton {
        let view = try #require(settings.window?.contentView)
        return try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.action.map(NSStringFromSelector) == action })
    }
    private func invoke(_ control: NSControl) throws {
        let action = try #require(control.action)
        #expect(control.sendAction(action, to: control.target))
    }
    private func choose(_ index: Int, in settings: SettingsWindowController) throws {
        let picker = try control(NSPopUpButton.self, label: "Wallpaper set", in: settings)
        picker.selectItem(at: index); try invoke(picker)
    }
    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "Timed out waiting for the native operation or UI callback")
    }

    @Test func activeSetChangeKeepsRunLoopAndSettingsResponsiveAndPauseWinsCompletion() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = try #require(fixture.coordinator)
        let settings = fixture.settings()
        let heartbeat = Heartbeat()
        let timer = Timer(timeInterval: 0.01, target: heartbeat, selector: #selector(Heartbeat.tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let start = Date()
        try choose(1, in: settings)
        #expect(Date().timeIntervalSince(start) < 0.2)
        #expect(coordinator.nativeOperationRunning)
        #expect(coordinator.readiness == "Updating wallpaper…")
        try await waitUntil { fixture.probe.calls > 0 }
        var dispatchedRender = false
        DispatchQueue.main.async { settings.render(); dispatchedRender = true }
        try await waitUntil { dispatchedRender && heartbeat.ticks >= 3 }
        #expect(coordinator.nativeOperationRunning)
        // All of these call public AppKit actions while the adapter is waiting in reload.
        try invoke(try button(action: "toggleCustomization", in: settings))
        coordinator.refreshAvailability()
        coordinator.menuWillOpen(NSMenu()); coordinator.menuDidClose(NSMenu())
        #expect(coordinator.nativeOperationRunning)
        try choose(0, in: settings)
        try choose(1, in: settings)
        let rotation = try control(NSSwitch.self, label: "Automatic wallpaper rotation", in: settings)
        try invoke(rotation)
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(fixture.saved.last?.rotationEnabled == false)
        #expect(coordinator.nativeOperationRunning)
        settings.close()
        let reopened = fixture.settings()
        #expect(try control(NSPopUpButton.self, label: "Wallpaper set", in: reopened).selectedItem?.representedObject as? String == "New")
        #expect(!((try control(NSSwitch.self, label: "Automatic wallpaper rotation", in: reopened)).isEnabled))
        try await waitUntil { !coordinator.nativeOperationRunning }
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(coordinator.configuration.pauseReason == "By you")
        #expect(coordinator.configuration.receipt != nil)
        #expect(coordinator.selectedSet?.id == "New")
        #expect(fixture.probe.maxConcurrent == 1)
        #expect(fixture.probe.calls == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pending-apply.json").path))
    }

    @Test func repeatedActiveChoicesAndSceneSaveCoalesceToLatestIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = try #require(fixture.coordinator)
        let settings = fixture.settings()
        try choose(1, in: settings)
        try await waitUntil { fixture.probe.calls > 0 }
        for _ in 0..<4 { try choose(0, in: settings); try choose(1, in: settings) }
        try invoke(try button(action: "toggleCustomization", in: settings))
        let role = try control(NSPopUpButton.self, label: "Scene for Night", in: settings)
        role.selectItem(at: 1); try invoke(role)
        try invoke(try button(action: "confirmMapping", in: settings))
        #expect(coordinator.configuration.mappings["New"]?[.night] == fixture.sets[1].assets[0].id)
        try await waitUntil { !coordinator.nativeOperationRunning }
        #expect(coordinator.configuration.rotationEnabled)
        #expect(coordinator.selectedSet?.id == "New")
        #expect(fixture.probe.maxConcurrent == 1)
        #expect(fixture.probe.calls <= 2)
        let phase = try #require(coordinator.schedule?.phase)
        #expect(coordinator.configuration.receipt?.assetID == coordinator.mapping(for: fixture.sets[1])[phase])
    }

    @Test func reloadFailureRetainsRecoveryAndPausedState() async throws {
        let fixture = try Fixture(failsReload: true)
        defer { fixture.cleanup() }
        let coordinator = try #require(fixture.coordinator)
        try choose(1, in: fixture.settings())
        try await waitUntil { !coordinator.nativeOperationRunning }
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(coordinator.message.contains("fixture timeout"))
        #expect(coordinator.configuration.receipt?.originalValues.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Backups/ownership-recovery.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pending-apply.json").path))
    }

    @Test func restoreRunsOffMainAndRestoresFixtureBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = try #require(fixture.coordinator)
        try choose(1, in: fixture.settings())
        try await waitUntil { !coordinator.nativeOperationRunning }
        let receipt = try #require(coordinator.configuration.receipt)
        var restoreLeaseHeldDuringSave = false
        fixture.beforeSave = { value in
            if value.receipt == nil && fixture.probe.calls == 2 {
                do {
                    let lease = try NativeOperationLease(directory: fixture.root)
                    lease.release()
                    Issue.record("Restore released the native operation lease before ownership persistence")
                } catch AppleWallpaperError.transactionBusy { restoreLeaseHeldDuringSave = true }
                catch { Issue.record(error) }
            }
        }
        let start = Date()
        coordinator.beginRestore(receipt)
        #expect(Date().timeIntervalSince(start) < 0.2)
        #expect(coordinator.nativeOperationRunning)
        var callbackRan = false
        DispatchQueue.main.async { callbackRan = true }
        try await waitUntil { callbackRan }
        #expect(coordinator.nativeOperationRunning)
        try await waitUntil { !coordinator.nativeOperationRunning }
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(coordinator.configuration.receipt == nil)
        #expect(coordinator.currentTitle.contains("Old"))
        #expect(fixture.probe.calls == 2)
        #expect(restoreLeaseHeldDuringSave)
        let restored = try await fixture.worker.inspect()
        #expect(restored.selections.values.allSatisfy { $0 == fixture.sets[0].assets[0].id })
    }

    @Test func quitWaitsForNativeFinalizationAndDownloadCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = try #require(fixture.coordinator)
        let settings = fixture.settings()
        try choose(1, in: settings)
        coordinator.downloadSet("Missing")
        try await waitUntil { fixture.fakeDownload?.started == true && fixture.probe.calls > 0 }
        #expect(coordinator.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(fixture.fakeDownload?.cancelled == true)
        #expect(coordinator.configuration.rotationEnabled) // Quit preserves the restart preference.
        try await waitUntil { !coordinator.nativeOperationRunning }
        #expect(fixture.terminationReplies.isEmpty)
        fixture.fakeDownload?.finishCancellation()
        try await waitUntil { fixture.terminationReplies == [true] }
        #expect(fixture.fakeDownload?.cleanupCompleted == true)
        #expect(!coordinator.downloadRunning)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pending-apply.json").path))
    }

    @Test func saveFailureAfterNativeChangeRestoresAndRetainsPendingJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = try #require(fixture.coordinator)
        try choose(1, in: fixture.settings())
        try await waitUntil { fixture.probe.calls > 0 }
        fixture.failSave = true
        try await waitUntil { !coordinator.nativeOperationRunning }
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(fixture.probe.calls == 2)
        let restored = try await fixture.worker.inspect()
        #expect(restored.selections.values.allSatisfy { $0 == fixture.sets[0].assets[0].id })
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pending-apply.json").path))
    }

    @Test func sameAssetSaveFailureDoesNotRestoreAnEarlierNativeChange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = try #require(fixture.coordinator)
        let settings = fixture.settings()
        try choose(1, in: settings)
        try await waitUntil { !coordinator.nativeOperationRunning }
        let before = try await fixture.worker.inspect()
        try choose(1, in: settings)
        fixture.failSave = true
        try await waitUntil { !coordinator.nativeOperationRunning }
        let after = try await fixture.worker.inspect()
        #expect(before.selections == after.selections)
        #expect(fixture.probe.calls == 1)
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pending-apply.json").path))
    }


    @Test func finalizationFailurePausesDurablyAndRetainsJournalForReview() async throws {
        let fixture = try Fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
            fixture.cleanup()
        }
        fixture.beforeSave = { value in
            // The completed journal exists now; deny its deletion at the real filesystem boundary.
            if value.receipt != nil && value.rotationEnabled {
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
            }
        }
        let coordinator = try #require(fixture.coordinator)
        try choose(1, in: fixture.settings())
        try await waitUntil { !coordinator.nativeOperationRunning }
        #expect(!coordinator.configuration.rotationEnabled)
        #expect(fixture.saved.last?.rotationEnabled == false)
        #expect(coordinator.configuration.pauseReason == "Native recovery needs review")
        #expect(coordinator.message.contains("Recovery needs attention"))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pending-apply.json").path))
        #expect(coordinator.configuration.receipt != nil)
    }

}

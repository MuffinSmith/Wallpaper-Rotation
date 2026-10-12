import AppKit
import Foundation
import Testing
import AppleWallpaper
import RotationCore
@testable import WallpaperRotation

@Suite(.serialized)
@MainActor
struct AutomaticRecoveryTests {
    @MainActor final class Download: WallpaperDownloading {
        var batches: [[WallpaperAsset]] = []
        var cancelled = false
        var finish: CheckedContinuation<Void, Error>?
        func download(assets: [WallpaperAsset], onProgress: @escaping @MainActor @Sendable (WallpaperDownloadProgress) -> Void) async throws {
            batches.append(assets)
            try await withCheckedThrowingContinuation { finish = $0 }
        }
        func cancel() { cancelled = true }
        func complete(_ error: Error? = nil) {
            if let error { finish?.resume(throwing: error) } else { finish?.resume() }
            finish = nil
        }
    }
    @MainActor final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purge-recovery-\(UUID().uuidString)")
        let download = Download()
        var coordinator: AppCoordinator!
        var durable: AppConfiguration?
        var applied: [String] = []
        var date = ISO8601DateFormatter().date(from: "2026-10-12T19:00:00Z")!
        var compatible = true
        var events: [(String, [String: String])] = []
        var failSave = false
        let set: WallpaperSet
        init(enabled: Bool = true, runtimeReady: Bool = true, downloadAvailable: Bool = true) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let movieRoot = root
            let assets = (1...5).map { number in
                WallpaperAsset(id: String(format: "00000000-0000-0000-0000-%012d", number), shotID: "SCENE\(number)", name: "Scene \(number)", previewURL: nil, videoURL: movieRoot.appendingPathComponent("\(number).mov"), downloadURL: downloadAvailable ? URL(string: "https://sylvan.apple.com/itunes-assets/fixture\(number).mov") : nil)
            }
            set = WallpaperSet(id: "mapped", name: "Mapped", assets: assets,
                suggestedMapping: [.evening: assets[0].id, .sunset: assets[1].id, .day: assets[2].id, .night: assets[3].id], requiresReview: false)
            var configuration = AppConfiguration()
            configuration.selectedSetID = set.id
            configuration.rotationEnabled = enabled
            configuration.lastFix = .init(coordinate: .init(latitude: 37, longitude: -122), capturedAt: date, source: "Manual coordinates")
            replaceCoordinator(configuration, runtimeReady: runtimeReady)
        }
        func replaceCoordinator(_ configuration: AppConfiguration, runtimeReady: Bool = true, sets: [WallpaperSet]? = nil, adapter: NativeWallpaperAdapter = NativeWallpaperAdapter(), readOnly: Bool = false) {
            coordinator = AppCoordinator(configuration: configuration, sets: sets ?? [set], enableEnvironment: .init(
                isReady: { [self] in compatible }, saveConfiguration: { [self] in if failSave { throw CocoaError(.fileWriteNoPermission) }; durable = $0 },
                applyAsset: { [self] in applied.append($0) }, checkCompatibility: { _ in }, showSettings: {}, replyToTermination: { _ in },
                makeDownloader: { [self] in download }, runtimeReconciliationReady: runtimeReady, recordEvent: { [self] in events.append(($0, $1)) }), nativeAdapter: adapter, now: { [self] in date }, readOnly: readOnly)
        }
        func install(_ assets: [WallpaperAsset]) throws {
            let bytes = Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(repeating: 0, count: 8)
                + [0, 0, 0, 9] + Array("moov".utf8) + [0] + [0, 0, 0, 9] + Array("mdat".utf8) + [0])
            for asset in assets { try bytes.write(to: asset.videoURL) }
        }
        func settle() async throws { for _ in 0..<10 { try await Task.sleep(for: .milliseconds(5)) } }
        func cleanup() {
            if coordinator.configuration.rotationEnabled { coordinator.toggleRotation() }
            download.complete(CancellationError())
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func missingMappedMoviesPreserveIntentAndStartOneRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.download.batches.count == 1)
        #expect(fixture.download.batches.first?.count == 4)
        #expect(fixture.applied.isEmpty)
    }
    @Test func completedRecoveryUsesActualNowAndOnlyMappedMissingAssets() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install([fixture.set.assets[3], fixture.set.assets[4]])
        let existing = try Data(contentsOf: fixture.set.assets[3].videoURL)
        fixture.date = ISO8601DateFormatter().date(from: "2026-10-12T07:00:00Z")!
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.download.batches[0].map(\.id) == [fixture.set.assets[2].id, fixture.set.assets[1].id, fixture.set.assets[0].id])
        #expect(fixture.coordinator.downloadIsAutomatic)
        fixture.date = ISO8601DateFormatter().date(from: "2026-10-12T19:00:00Z")!
        try fixture.install(fixture.download.batches[0])
        fixture.download.complete()
        try await fixture.settle()
        #expect(fixture.applied == [fixture.set.assets[2].id], "Completion must catch up directly to Day, without replaying sunrise")
        #expect(fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.coordinator.automaticRecoveryStatus == nil)
        #expect(!fixture.coordinator.downloadIsAutomatic)
        #expect(try Data(contentsOf: fixture.set.assets[3].videoURL) == existing)
    }

    @Test func failurePersistsBudgetAndRepeatedEventsAndRestartCannotRetryEarly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        fixture.download.complete(URLError(.notConnectedToInternet))
        try await fixture.settle()
        let saved = try #require(fixture.durable)
        #expect(saved.rotationEnabled)
        #expect(saved.automaticRecovery?.nextEligibleAt == fixture.date.addingTimeInterval(300))
        for _ in 0..<20 { fixture.coordinator.refreshAvailability(); fixture.coordinator.retryAutomaticRecovery() }
        #expect(fixture.download.batches.count == 1)
        #expect(fixture.events.filter { $0.0 == "recovery_backoff" }.count == 1)
        fixture.coordinator.toggleRotation()
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(saved))
        fixture.replaceCoordinator(restored)
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.download.batches.count == 1)
        fixture.date.addTimeInterval(300)
        fixture.coordinator.retryAutomaticRecovery()
        try await fixture.settle()
        #expect(fixture.download.batches.count == 2)
        #expect(fixture.durable?.automaticRecovery?.nextEligibleAt == fixture.date.addingTimeInterval(900))
    }

    @Test func immediatePurgeAfterSuccessStillWaitsBeforeAnotherAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        try fixture.install(fixture.download.batches[0])
        fixture.download.complete()
        try await fixture.settle()
        for asset in fixture.download.batches[0] { try FileManager.default.removeItem(at: asset.videoURL) }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.download.batches.count == 1)
        #expect(fixture.coordinator.automaticRecoveryStatus?.contains("retry") == true)
        #expect(fixture.durable?.automaticRecovery?.healthySince == nil)
        fixture.date.addTimeInterval(3600) // Missing backoff time is never a healthy hour.
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.download.batches.count == 2)
        #expect(fixture.durable?.automaticRecovery?.attemptCount == 2)
    }

    @Test(arguments: [false, true]) func manualPauseOrCancelWinsEvenIfDownloadCompletesSuccessfully(cancel: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        if cancel { fixture.coordinator.cancelDownload() } else { fixture.coordinator.toggleRotation() }
        #expect(fixture.download.cancelled)
        try fixture.install(fixture.download.batches[0])
        fixture.download.complete()
        try await fixture.settle()
        #expect(!fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.durable?.rotationEnabled == false)
        #expect(fixture.coordinator.automaticRecoveryStatus == nil)
        #expect(fixture.applied.isEmpty)
    }

    @Test func selectedSetChangeCancelsOldRecoveryAndNeverAppliesCapturedSet() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let extra = fixture.set.assets[4]
        try fixture.install([extra])
        let other = WallpaperSet(id: "other", name: "Other", assets: [extra], suggestedMapping: Dictionary(uniqueKeysWithValues: WallpaperPhase.allCases.map { ($0, extra.id) }), requiresReview: false)
        fixture.replaceCoordinator(fixture.coordinator.configuration, sets: [fixture.set, other])
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        fixture.coordinator.select(other.id)
        #expect(fixture.download.cancelled)
        try fixture.install(fixture.download.batches[0])
        fixture.download.complete()
        try await fixture.settle()
        #expect(fixture.coordinator.selectedSet?.id == other.id)
        #expect(fixture.applied.allSatisfy { $0 == extra.id })
        #expect(fixture.coordinator.browsedSet?.id == other.id)
    }

    @Test func mappingChangeDuringRecoveryUsesLatestCommittedMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        let extra = fixture.set.assets[4]
        try fixture.install([extra])
        fixture.coordinator.confirmMapping(setID: fixture.set.id, value: Dictionary(uniqueKeysWithValues: WallpaperPhase.allCases.map { ($0, extra.id) }))
        #expect(fixture.download.cancelled)
        try fixture.install(fixture.download.batches[0])
        fixture.download.complete()
        try await fixture.settle()
        #expect(!fixture.applied.isEmpty)
        #expect(fixture.applied.allSatisfy { $0 == extra.id })
    }

    @Test func partiallyReadyRecoveryWaitsForAllMappedScenesAndLeavesUnmappedExtraMissing() async throws {
        let fixture = try Fixture(downloadAvailable: false)
        defer { fixture.cleanup() }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.download.batches.isEmpty)
        #expect(fixture.coordinator.automaticRecoveryStatus?.contains("Apple") == true)
        try fixture.install(Array(fixture.set.assets.prefix(3)))
        fixture.coordinator.refreshAvailability()
        #expect(fixture.applied.isEmpty)
        try fixture.install([fixture.set.assets[3]])
        fixture.coordinator.refreshAvailability()
        #expect(fixture.applied == [fixture.set.assets[2].id])
        #expect(!fixture.set.assets[4].isDownloaded)
    }

    @Test func pausedOrUnestablishedRuntimeNeverStartsRecovery() async throws {
        let paused = try Fixture(enabled: false)
        let pending = try Fixture(runtimeReady: false)
        defer { paused.cleanup(); pending.cleanup() }
        paused.coordinator.refreshAvailability()
        pending.coordinator.refreshAvailability()
        try await paused.settle()
        #expect(paused.download.batches.isEmpty)
        #expect(pending.download.batches.isEmpty)
        #expect(!paused.coordinator.configuration.rotationEnabled)
        #expect(pending.coordinator.configuration.rotationEnabled)
    }

    @Test func incompatibleStoreAndFailedBudgetSaveNeverStartDownload() async throws {
        let incompatible = try Fixture()
        let failedSave = try Fixture()
        defer { incompatible.cleanup(); failedSave.cleanup() }
        incompatible.compatible = false
        failedSave.failSave = true
        incompatible.coordinator.refreshAvailability()
        failedSave.coordinator.refreshAvailability()
        try await incompatible.settle()
        #expect(incompatible.download.batches.isEmpty)
        #expect(failedSave.download.batches.isEmpty)
        #expect(!incompatible.coordinator.configuration.rotationEnabled)
        #expect(!failedSave.coordinator.configuration.rotationEnabled)
    }

    @Test func quietHourResetsBudgetButSuccessAloneDoesNot() throws {
        let date = Date(timeIntervalSince1970: 1000)
        var policy = AutomaticRecoveryPolicy()
        policy.beginAttempt(at: date)
        policy.finishAttempt(at: date)
        policy.beginAttempt(at: date.addingTimeInterval(300))
        #expect(policy.attemptCount == 2)
        #expect(policy.nextEligibleAt == date.addingTimeInterval(1200))
        policy.finishAttempt(at: date.addingTimeInterval(300))
        policy.beginAttempt(at: date.addingTimeInterval(1200))
        #expect(policy.attemptCount == 3)
        #expect(policy.nextEligibleAt == date.addingTimeInterval(4800))
        policy.finishAttempt(at: date.addingTimeInterval(1200))
        policy.beginAttempt(at: date.addingTimeInterval(4800))
        #expect(policy.attemptCount == 3, "An hour of network failure cannot reset the ladder")
        #expect(policy.nextEligibleAt == date.addingTimeInterval(8400))
        policy.finishAttempt(at: date.addingTimeInterval(4800))
        policy.markReady(at: date.addingTimeInterval(4800))
        policy.noteMissing(at: date.addingTimeInterval(8400))
        policy.beginAttempt(at: date.addingTimeInterval(8400))
        #expect(policy.attemptCount == 1)
        #expect(policy.nextEligibleAt == date.addingTimeInterval(8700))
    }

    @Test(arguments: [false, true]) func outsideWallpaperEditBeforeOrDuringRecoveryPreservesUserScene(during: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        func plist(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
        let store = fixture.root.appendingPathComponent("Index.plist")
        let initialID = "00000000-0000-0000-0000-000000000099"
        let branch: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [String](), "Configuration": try plist(["assetID": initialID])]], "Shuffle": "$null"]]
        try plist(["AllSpacesAndDisplays": "$null", "SystemDefault": ["Type": "linked", "Linked": branch], "Spaces": [String: Any](), "Displays": [String: Any]()]).write(to: store)
        let adapter = NativeWallpaperAdapter(storeURL: store, backupDir: fixture.root.appendingPathComponent("Backups"), reload: {}, assetAvailable: { _ in true })
        var config = fixture.coordinator.configuration
        config.receipt = try adapter.apply(assetID: fixture.set.assets[3].id, previous: nil)
        fixture.replaceCoordinator(config, adapter: adapter)
        if during { fixture.coordinator.refreshAvailability(); try await fixture.settle() }
        _ = try adapter.apply(assetID: initialID, previous: nil)
        let bytes = try Data(contentsOf: store)
        fixture.coordinator.refreshAvailability()
        if during {
            #expect(fixture.download.cancelled)
            try fixture.install(fixture.download.batches[0])
            fixture.download.complete()
        }
        try await fixture.settle()
        #expect(!fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.durable?.pauseReason == "Wallpaper changed outside Wallpaper Rotation")
        #expect(fixture.download.batches.count == (during ? 1 : 0))
        #expect(fixture.applied.isEmpty)
        #expect(try Data(contentsOf: store) == bytes)
    }

    @Test func readOnlyRuntimeNeverDownloadsPersistsOrLogs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.replaceCoordinator(fixture.coordinator.configuration, readOnly: true)
        fixture.coordinator.refreshAvailability()
        fixture.coordinator.retryAutomaticRecovery()
        try await fixture.settle()
        #expect(fixture.download.batches.isEmpty)
        #expect(fixture.durable == nil)
        #expect(fixture.events.isEmpty)
        #expect(fixture.applied.isEmpty)
    }

    @Test func manualDownloadStillIncludesUnmappedCollectionMoviesAndDoesNotEnableRotation() async throws {
        let fixture = try Fixture(enabled: false)
        defer { fixture.cleanup() }
        fixture.coordinator.downloadSet(fixture.set.id)
        try await fixture.settle()
        #expect(fixture.download.batches[0].count == 5)
        #expect(!fixture.coordinator.downloadIsAutomatic)
        #expect(fixture.coordinator.browsedSet?.id == fixture.set.id)
        try fixture.install(fixture.download.batches[0])
        fixture.download.complete()
        try await fixture.settle()
        #expect(!fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.applied.isEmpty)
    }

    @Test func automaticDownloadPreservesBrowsedCollectionAndQuitPreservesEnabledIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let extra = fixture.set.assets[4]
        let other = WallpaperSet(id: "other", name: "Other", assets: [extra], suggestedMapping: Dictionary(uniqueKeysWithValues: WallpaperPhase.allCases.map { ($0, extra.id) }), requiresReview: false)
        fixture.replaceCoordinator(fixture.coordinator.configuration, sets: [fixture.set, other])
        fixture.coordinator.select(other.id) // Browse the incomplete collection without committing it.
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.coordinator.browsedSet?.id == other.id)
        #expect(fixture.coordinator.selectedSet?.id == fixture.set.id)
        #expect(fixture.coordinator.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(fixture.download.cancelled)
        #expect(fixture.coordinator.configuration.rotationEnabled)
        fixture.download.complete(CancellationError())
        try await fixture.settle()
        #expect(fixture.durable?.rotationEnabled == true)
        #expect(fixture.applied.isEmpty)
    }

    @Test func continuedFailureRemainsHourlyAfterFourthAndFifthAttempts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let delays: [TimeInterval] = [300, 900, 3600, 3600, 3600]
        for (index, delay) in delays.enumerated() {
            fixture.coordinator.refreshAvailability()
            try await fixture.settle()
            #expect(fixture.download.batches.count == index + 1)
            fixture.download.complete(URLError(.notConnectedToInternet))
            try await fixture.settle()
            #expect(fixture.durable?.automaticRecovery?.nextEligibleAt == fixture.date.addingTimeInterval(delay))
            #expect(fixture.durable?.automaticRecovery?.healthySince == nil)
            fixture.date.addTimeInterval(delay)
            if index == 2 || index == 3 {
                let saved = try #require(fixture.durable)
                fixture.coordinator.toggleRotation()
                fixture.replaceCoordinator(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(saved)))
            }
        }
    }

    @Test func duplicateMappedMovieIsTransferredOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var config = fixture.coordinator.configuration
        config.mappings[fixture.set.id] = Dictionary(uniqueKeysWithValues: WallpaperPhase.allCases.map { ($0, fixture.set.assets[0].id) })
        fixture.replaceCoordinator(config)
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.download.batches[0].map(\.id) == [fixture.set.assets[0].id])
    }

    @Test func legacyGenericPauseNeverMigratesToEnabledIntent() throws {
        let data = Data(#"{"schemaVersion":1,"mappings":{},"rotationEnabled":false,"pauseReason":"Scene or compatibility check unavailable"}"#.utf8)
        let config = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(config.automaticRecovery == nil)
        #expect(!config.rotationEnabled)
        #expect(config.pauseReason == "Scene or compatibility check unavailable")
    }

    @Test func missingCatalogDoesNotCountAsHealthyTimeOrApplyStaleSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        try fixture.install(fixture.download.batches[0])
        fixture.download.complete()
        try await fixture.settle()
        #expect(fixture.applied.count == 1)
        let enabled = fixture.coordinator.configuration
        fixture.coordinator.toggleRotation()
        fixture.replaceCoordinator(enabled, sets: [])
        fixture.coordinator.refreshAvailability()
        #expect(fixture.coordinator.configuration.automaticRecovery?.healthySince == nil)
        #expect(fixture.coordinator.configuration.rotationEnabled)
        #expect(fixture.download.batches.count == 1)
        #expect(fixture.applied.count == 1)
        for asset in fixture.download.batches[0] { try FileManager.default.removeItem(at: asset.videoURL) }
        fixture.date.addTimeInterval(3600)
        let current = fixture.coordinator.configuration
        fixture.coordinator.toggleRotation()
        fixture.replaceCoordinator(current)
        fixture.coordinator.refreshAvailability()
        try await fixture.settle()
        #expect(fixture.download.batches.count == 2)
        #expect(fixture.durable?.automaticRecovery?.attemptCount == 2)
    }

}

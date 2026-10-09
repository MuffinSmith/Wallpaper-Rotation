import Foundation
import Testing
@testable import WallpaperRotation

@Suite(.serialized)
@MainActor
struct AssetAvailabilityObserverTests {
    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("asset-observer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "A filesystem change was not reported within four seconds")
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    @Test func startupReportsAlreadyExistingAssetsWithoutManualRefresh() async throws {
        let root = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("existing.mov")
        try Data("existing fixture bytes".utf8).write(to: movie)
        var seen = false
        let observer = AssetAvailabilityObserver(directories: [root, root]) {
            seen = (try? Data(contentsOf: movie)) == Data("existing fixture bytes".utf8)
        }
        defer { observer.stop() }
        observer.start()
        observer.start()
        try await waitUntil { seen }
    }

    @Test func newFileAndAtomicRenameRefreshTheObservedContents() async throws {
        let root = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let videos = root.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        var contents = Set<String>()
        var changes = 0
        let observer = AssetAvailabilityObserver(directories: [videos]) {
            changes += 1
            contents = Set((try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? [])
        }
        defer { observer.stop() }
        observer.start()
        try await waitUntil { changes > 0 }
        try Data("new fixture".utf8).write(to: videos.appendingPathComponent("new.mov"))
        try await waitUntil { contents.contains("new.mov") }
        let incoming = root.appendingPathComponent("incoming.partial")
        try Data("renamed fixture".utf8).write(to: incoming)
        try FileManager.default.moveItem(at: incoming, to: videos.appendingPathComponent("renamed.mov"))
        try await waitUntil { contents.contains("renamed.mov") }
    }

    @Test func completingAnExistingNonemptyMovieInPlaceRefreshesAvailability() async throws {
        let root = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("partial.mov")
        try Data("partial fixture header".utf8).write(to: movie)
        let originalIdentity = try FileManager.default.attributesOfItem(atPath: movie.path)[.systemFileNumber] as? NSNumber
        var changes = 0
        var completed = false
        let observer = AssetAvailabilityObserver(directories: [root]) {
            changes += 1
            completed = (try? Data(contentsOf: movie))?.suffix(8) == Data("complete".utf8)
        }
        defer { observer.stop() }
        observer.start()
        try await waitUntil { changes > 0 }
        #expect(!completed)
        try append(Data("complete".utf8), to: movie)
        try await waitUntil { completed }
        #expect((try FileManager.default.attributesOfItem(atPath: movie.path)[.systemFileNumber] as? NSNumber) == originalIdentity)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["partial.mov"])
    }

    @Test func missingAncestorsPromoteToCreatedAssetAndManifestDirectories() async throws {
        let root = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let aerials = root.appendingPathComponent("new/aerials", isDirectory: true)
        let videos = aerials.appendingPathComponent("videos", isDirectory: true)
        let manifest = aerials.appendingPathComponent("manifest", isDirectory: true)
        var changes = 0
        var assetSeen = false
        var manifestSeen = false
        let observer = AssetAvailabilityObserver(directories: [videos, manifest]) {
            changes += 1
            assetSeen = FileManager.default.fileExists(atPath: videos.appendingPathComponent("download.mov").path)
            manifestSeen = (try? Data(contentsOf: manifest.appendingPathComponent("entries.json"))) == Data("updated fixture".utf8)
        }
        defer { observer.stop() }
        observer.start()
        try await waitUntil { changes > 0 }
        let before = changes
        try FileManager.default.createDirectory(at: aerials, withIntermediateDirectories: true)
        try await waitUntil { changes > before }
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try Data("fixture movie".utf8).write(to: videos.appendingPathComponent("download.mov"))
        try Data("initial fixture".utf8).write(to: manifest.appendingPathComponent("entries.json"))
        try await waitUntil { assetSeen }
        // Also covers content-only replacement of an existing manifest file.
        let handle = try FileHandle(forWritingTo: manifest.appendingPathComponent("entries.json"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("updated fixture".utf8))
        try handle.close()
        try await waitUntil { manifestSeen }
    }

    @Test func deletedAndReplacedDirectoryRearmsForNewContents() async throws {
        let root = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let videos = root.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        var changes = 0
        var missing = false
        var contents = Set<String>()
        var completed = false
        let observer = AssetAvailabilityObserver(directories: [videos]) {
            changes += 1
            missing = !FileManager.default.fileExists(atPath: videos.path)
            contents = Set((try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? [])
            completed = (try? Data(contentsOf: videos.appendingPathComponent("replacement.mov"))) == Data("replacement complete".utf8)
        }
        defer { observer.stop() }
        observer.start()
        try await waitUntil { changes > 0 }
        try FileManager.default.removeItem(at: videos)
        try await waitUntil { missing }
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try Data("recreated fixture".utf8).write(to: videos.appendingPathComponent("recreated.mov"))
        try await waitUntil { contents.contains("recreated.mov") }
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacement.appendingPathComponent("replacement.mov"))
        try FileManager.default.moveItem(at: videos, to: root.appendingPathComponent("old-videos"))
        try FileManager.default.moveItem(at: replacement, to: videos)
        try await waitUntil { contents == ["replacement.mov"] }
        try append(Data(" complete".utf8), to: videos.appendingPathComponent("replacement.mov"))
        try await waitUntil { completed }
    }

    @Test func stopCancelsPendingAndFutureCallbacksAndCanRestart() async throws {
        let root = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        let observer = AssetAvailabilityObserver(directories: [root]) { changes += 1 }
        observer.start()
        // Stop before the initial debounce fires as well as before any events.
        observer.stop()
        observer.stop()
        try Data("stopped fixture".utf8).write(to: root.appendingPathComponent("stopped.mov"))
        try await Task.sleep(for: .milliseconds(650))
        #expect(changes == 0)
        observer.start()
        try await waitUntil { changes > 0 }
        observer.stop()
        let stoppedCount = changes
        try Data("later fixture".utf8).write(to: root.appendingPathComponent("later.mov"))
        try await Task.sleep(for: .milliseconds(650))
        #expect(changes == stoppedCount)
    }

    @Test func observerDeinitializesWithLiveStreamAndNoFurtherCallbacks() async throws {
        let root = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        var observer: AssetAvailabilityObserver? = AssetAvailabilityObserver(directories: [root]) { changes += 1 }
        weak let releasedObserver = observer
        observer?.start()
        try await waitUntil { changes > 0 }
        observer = nil
        #expect(releasedObserver == nil)
        let stoppedCount = changes
        try Data("after deinit fixture".utf8).write(to: root.appendingPathComponent("later.mov"))
        try await Task.sleep(for: .milliseconds(650))
        #expect(changes == stoppedCount)
    }
}

import Testing
import Darwin
import Foundation
import RotationCore
@testable import AppleWallpaper

@Suite(.serialized)
final class AppleWallpaperTests {
    private var directories: [URL] = []
    deinit { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
    private let day = "6511D2B5-E185-4886-9505-B4004E920D27"
    private let night = "86E89C23-C39B-44C8-A985-E56EEA6456FE"
    private let sunset = "4207734D-74FE-4F92-B5E1-6EC8DEE24A15"

    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        return dir
    }

    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func decoded(_ data: Data) throws -> [String: Any] {
        try unwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private func node(_ asset: String, individual: Bool = false, option: String = "Crop") throws -> [String: Any] {
        let content: [String: Any] = [
            "Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [String](),
                         "Configuration": try plist(["assetID": asset, "preservedConfiguration": "keep"]) ]],
            "Shuffle": "$null", "EncodedOptionValues": try plist(["placement": option]),
            "preservedContent": "keep"]
        let branch: [String: Any] = ["Content": content, "LastSet": Date(timeIntervalSince1970: 100),
                                     "LastUse": Date(timeIntervalSince1970: 200), "preservedMetadata": 7]
        return individual ? ["Type": "individual", "Desktop": branch, "Idle": branch] : ["Type": "linked", "Linked": branch]
    }

    private func store() throws -> [String: Any] {
        ["AllSpacesAndDisplays": "$null", "SystemDefault": try node(day),
         "Spaces": ["": ["Default": try node(day), "Displays": ["display": try node(day, individual: true)]]],
         "Displays": ["display": try node(day, individual: true)]]
    }

    private func setup(reload: @escaping () throws -> Void = {}, beforeCommit: @escaping () throws -> Void = {}) throws -> (NativeWallpaperAdapter, URL) {
        let dir = try temporary(); let file = dir.appendingPathComponent("Index.plist")
        try plist(store()).write(to: file)
        return (NativeWallpaperAdapter(storeURL: file, backupDir: dir.appendingPathComponent("Backups"),
                                      reload: reload, beforeCommit: beforeCommit, assetAvailable: { _ in true }), file)
    }

    private func updateNode(_ root: inout [String: Any], path: [String], transform: ([String: Any]) throws -> [String: Any]) throws {
        func update(_ current: [String: Any], _ remaining: ArraySlice<String>) throws -> [String: Any] {
            if remaining.isEmpty { return try transform(current) }
            var result = current
            let key = remaining.first!
            result[key] = try update(try unwrap(current[key] as? [String: Any]), remaining.dropFirst())
            return result
        }
        root = try update(root, path[...])
    }

    private func assetChanged(_ node: [String: Any], asset: String) throws -> [String: Any] {
        var node = node
        for name in ["Linked", "Desktop", "Idle"] {
            guard var branch = node[name] as? [String: Any], var content = branch["Content"] as? [String: Any],
                  var choices = content["Choices"] as? [[String: Any]], let data = choices[0]["Configuration"] as? Data else { continue }
            var configuration = try decoded(data); configuration["assetID"] = asset
            choices[0]["Configuration"] = try plist(configuration); content["Choices"] = choices
            branch["Content"] = content; node[name] = branch
        }
        return node
    }

    @Test func testScopedPatchPreservesGraphOptionsAndMetadata() throws {
        let (adapter, file) = try setup(); let original = try decoded(Data(contentsOf: file))
        let receipt = try adapter.apply(assetID: night, previous: nil)
        expectEqual(try adapter.inspect().selections.count, 6)
        expectTrue(try adapter.inspect().selections.values.allSatisfy { $0 == night })
        var expected = original
        try updateNode(&expected, path: ["SystemDefault"]) { try assetChanged($0, asset: night) }
        try updateNode(&expected, path: ["Spaces", "", "Default"]) { try assetChanged($0, asset: night) }
        try updateNode(&expected, path: ["Spaces", "", "Displays", "display"]) { try assetChanged($0, asset: night) }
        try updateNode(&expected, path: ["Displays", "display"]) { try assetChanged($0, asset: night) }
        let actual = try decoded(Data(contentsOf: file))
        expectEqual(actual["AllSpacesAndDisplays"] as? String, "$null")
        expectTrue(semanticEqual(actual, expected))
        expectFalse(try adapter.hasExternalChange(since: receipt))
        let files = try FileManager.default.contentsOfDirectory(atPath: adapter.backupDir.path)
        expectEqual(files.filter { $0.hasSuffix(".plist") }.count, 1)
        expectTrue(files.contains("ownership-recovery.json"))
    }

    @Test func testTransitionsRetainOriginalAndRestore() throws {
        let (adapter, file) = try setup(); let original = try decoded(Data(contentsOf: file))
        let first = try adapter.apply(assetID: night, previous: nil)
        let second = try adapter.apply(assetID: sunset, previous: first)
        expectEqual(second.originalValues, first.originalValues)
        let restored = try adapter.restore(second)
        expectEqual(restored.restoredCount, 6); expectEqual(restored.skippedCount, 0)
        expectTrue(NSDictionary(dictionary: try decoded(Data(contentsOf: file))).isEqual(to: original))
    }

    @Test func testConditionalRestorePreservesManualEdit() throws {
        let (adapter, file) = try setup(); let receipt = try adapter.apply(assetID: night, previous: nil)
        var edited = try decoded(Data(contentsOf: file))
        try updateNode(&edited, path: ["SystemDefault"]) { try assetChanged($0, asset: sunset) }
        try plist(edited).write(to: file)
        expectTrue(try adapter.hasExternalChange(since: receipt))
        expectThrows(try adapter.apply(assetID: day, previous: receipt))
        let restored = try adapter.restore(receipt)
        expectEqual(restored.restoredCount, 5); expectEqual(restored.skippedCount, 1)
        let inspection = try adapter.inspect()
        expectEqual(inspection.selections["/SystemDefault/Linked/Content/Choices/0/Configuration"], sunset)
        expectEqual(inspection.selections.values.filter { $0 == day }.count, 5)
    }

    @Test func testOptionsEditPausesAndRestoreSkipsThatSelector() throws {
        let (adapter, file) = try setup(); let receipt = try adapter.apply(assetID: night, previous: nil)
        var edited = try decoded(Data(contentsOf: file))
        try updateNode(&edited, path: ["SystemDefault", "Linked", "Content"]) { content in
            var result = content; result["EncodedOptionValues"] = try plist(["placement": "Fit"]); return result
        }
        try plist(edited).write(to: file)
        expectTrue(try adapter.hasExternalChange(since: receipt))
        expectEqual(try adapter.restore(receipt).skippedCount, 1)
        let result = try decoded(Data(contentsOf: file))
        let node = try unwrap(result["SystemDefault"] as? [String: Any])
        expectTrue(NSDictionary(dictionary: node).isEqual(to: edited["SystemDefault"] as! [String: Any]))
    }

    @Test func testTopologyAndVolatileMetadataAreNotExternalChanges() throws {
        let (adapter, file) = try setup(); let first = try adapter.apply(assetID: night, previous: nil)
        var edited = try decoded(Data(contentsOf: file))
        try updateNode(&edited, path: ["SystemDefault", "Linked"]) { branch in
            var result = branch; result["LastSet"] = Date(); result["LastUse"] = Date(); return result
        }
        try updateNode(&edited, path: ["Displays"]) { displays in
            var result = displays; result["new-monitor"] = try node(day); return result
        }
        try plist(edited).write(to: file)
        expectFalse(try adapter.hasExternalChange(since: first))
        let second = try adapter.apply(assetID: sunset, previous: first)
        expectEqual(try adapter.inspect().selections.count, 7)
        expectEqual(try adapter.restore(second).restoredCount, 7)
    }

    @Test func testLinkedToIndividualIsExternalChange() throws {
        let (adapter, file) = try setup(); let receipt = try adapter.apply(assetID: night, previous: nil)
        var edited = try decoded(Data(contentsOf: file)); edited["SystemDefault"] = try node(night, individual: true)
        try plist(edited).write(to: file)
        expectTrue(try adapter.hasExternalChange(since: receipt))
    }

    @Test func testUnknownProviderStopsEntireTransactionWithoutWrite() throws {
        let (adapter, file) = try setup(); var bad = try decoded(Data(contentsOf: file))
        try updateNode(&bad, path: ["SystemDefault", "Linked", "Content"]) { content in
            var result = content; var choices = result["Choices"] as! [[String: Any]]
            choices[0]["Provider"] = "unknown.provider"; result["Choices"] = choices; return result
        }
        let bytes = try plist(bad); try bytes.write(to: file)
        expectThrows(try adapter.apply(assetID: night, previous: nil))
        expectEqual(try Data(contentsOf: file), bytes)
        expectFalse(FileManager.default.fileExists(atPath: adapter.backupDir.path))
    }

    @Test func testRaceBeforeRenameAbortsAndPreservesExternalBytes() throws {
        let dir = try temporary(); let file = dir.appendingPathComponent("Index.plist")
        try plist(store()).write(to: file)
        var external = try store(); external["SystemDefault"] = try node(sunset)
        let externalBytes = try plist(external)
        let adapter = NativeWallpaperAdapter(storeURL: file, backupDir: dir.appendingPathComponent("Backups"),
            reload: {}, beforeCommit: { try externalBytes.write(to: file) }, assetAvailable: { _ in true })
        expectThrows(try adapter.apply(assetID: night, previous: nil))
        expectEqual(try Data(contentsOf: file), externalBytes)
    }

    @Test func testReloadInterferenceFailsReadbackAndRetainsRecovery() throws {
        let dir = try temporary(); let file = dir.appendingPathComponent("Index.plist")
        try plist(store()).write(to: file)
        var external = try store(); external["SystemDefault"] = try node(sunset)
        let bytes = try plist(external)
        let adapter = NativeWallpaperAdapter(storeURL: file, backupDir: dir.appendingPathComponent("Backups"),
            reload: { try bytes.write(to: file) }, assetAvailable: { _ in true })
        expectThrows(try adapter.apply(assetID: night, previous: nil))
        expectEqual(try Data(contentsOf: file), bytes)
        expectTrue(FileManager.default.fileExists(atPath: adapter.backupDir.appendingPathComponent("ownership-recovery.json").path))
    }

    @Test func testReloadFailureCanRecoverFirstCommittedTransactionFromDisk() throws {
        let dir = try temporary(); let file = dir.appendingPathComponent("Index.plist")
        let original = try store(); try plist(original).write(to: file)
        let backups = dir.appendingPathComponent("Backups")
        let failing = NativeWallpaperAdapter(storeURL: file, backupDir: backups,
            reload: { throw AppleWallpaperError.reloadFailed("fixture") }, assetAvailable: { _ in true })
        expectThrows(try failing.apply(assetID: night, previous: nil))
        let recovery = try unwrap(failing.recoveryReceipt())
        expectEqual(recovery.osBuild, NativeWallpaperAdapter.osBuild())
        let resumed = NativeWallpaperAdapter(storeURL: file, backupDir: backups, reload: {}, assetAvailable: { _ in true })
        expectEqual(try resumed.restore(recovery).restoredCount, 6)
        expectTrue(semanticEqual(try decoded(Data(contentsOf: file)), original))
    }

    @Test func testUnknownRootAndMultipleChoicesRejectWholeStore() throws {
        let (adapter, file) = try setup()
        var malformed = try store(); malformed["NewAppleTopology"] = "future"
        try plist(malformed).write(to: file)
        expectThrows(try adapter.inspect())
        malformed = try store()
        try updateNode(&malformed, path: ["SystemDefault", "Linked", "Content"]) { content in
            var content = content; let choices = content["Choices"] as! [[String: Any]]
            content["Choices"] = choices + choices; return content
        }
        let bytes = try plist(malformed); try bytes.write(to: file)
        expectThrows(try adapter.apply(assetID: night, previous: nil))
        expectEqual(try Data(contentsOf: file), bytes)
    }

    @Test func testUnavailableAssetNeverWritesOrReloads() throws {
        let dir = try temporary(); let file = dir.appendingPathComponent("Index.plist")
        let bytes = try plist(store()); try bytes.write(to: file)
        var reloaded = false
        let adapter = NativeWallpaperAdapter(storeURL: file, backupDir: dir.appendingPathComponent("Backups"),
            reload: { reloaded = true }, assetAvailable: { _ in false })
        expectThrows(try adapter.apply(assetID: night, previous: nil))
        expectEqual(try Data(contentsOf: file), bytes); expectFalse(reloaded)
        expectFalse(FileManager.default.fileExists(atPath: adapter.backupDir.path))
    }

    @Test func testCooperativeLockRejectsAnotherWriterWithoutReplacingJournal() throws {
        let dir = try temporary(); let file = dir.appendingPathComponent("Index.plist")
        let bytes = try plist(store()); try bytes.write(to: file)
        let backups = dir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let journal = backups.appendingPathComponent("ownership-recovery.json")
        let journalBytes = Data("existing recovery journal".utf8); try journalBytes.write(to: journal)
        let fd = open(backups.appendingPathComponent("transaction.lock").path, O_CREAT | O_RDWR, 0o600)
        expectTrue(fd >= 0); expectEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        let adapter = NativeWallpaperAdapter(storeURL: file, backupDir: backups, reload: {},
            assetAvailable: { _ in true }, lockTimeout: 0.04)
        expectThrows(try adapter.apply(assetID: night, previous: nil))
        expectEqual(try Data(contentsOf: file), bytes); expectEqual(try Data(contentsOf: journal), journalBytes)
    }

    @Test func testRestoreRejectsPostReloadRewrite() throws {
        let dir = try temporary(); let file = dir.appendingPathComponent("Index.plist")
        try plist(store()).write(to: file)
        var edited = try store(); edited["SystemDefault"] = try node(sunset)
        let editedBytes = try plist(edited)
        var reloadCount = 0
        let adapter = NativeWallpaperAdapter(storeURL: file, backupDir: dir.appendingPathComponent("Backups"),
            reload: { reloadCount += 1; if reloadCount == 2 { try editedBytes.write(to: file) } },
            assetAvailable: { _ in true })
        let receipt = try adapter.apply(assetID: night, previous: nil)
        expectThrows(try adapter.restore(receipt))
        expectEqual(try Data(contentsOf: file), editedBytes)
    }

    @Test func testAtomicReplacementPreservesPermissionsAndExtendedAttributes() throws {
        let (adapter, file) = try setup()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let bytes = Array("fixture-attribute".utf8)
        let setResult = bytes.withUnsafeBytes { buffer in
            setxattr(file.path, "com.wallpaperrotation.fixture", buffer.baseAddress, buffer.count, 0, 0)
        }
        expectEqual(setResult, 0)
        _ = try adapter.apply(assetID: night, previous: nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        var result = [UInt8](repeating: 0, count: bytes.count)
        let size = result.withUnsafeMutableBytes { buffer in
            getxattr(file.path, "com.wallpaperrotation.fixture", buffer.baseAddress, buffer.count, 0, 0)
        }
        expectEqual(size, bytes.count); expectEqual(result, bytes)
    }

    @Test func testCatalogGroupsAndReviewAndLocalPreviews() throws {
        let dir = try temporary(); let manifest = dir.appendingPathComponent("entries.json")
        let gg = ["GG_A_DAY", "GG_A_SUNSET", "GG_A_EVENING", "GG_A_NIGHT"]
        let ta = ["TA_L_002", "TA_L_001", "TA_D_001", "TA_D_002"]
        let names = ["Tahoe Day", "Tahoe Morning", "Tahoe Evening", "Tahoe Night"]
        var entries: [[String: Any]] = []
        for (index, shot) in (gg + ta).enumerated() {
            entries.append(["id": UUID().uuidString, "shotID": shot,
                "accessibilityLabel": index < 4 ? shot : names[index - 4], "localizedNameKey": shot + "_NAME",
                "subcategories": [index < 4 ? "gg" : "ta"], "group": "release-tag",
                "previewImage": "https://example.invalid/never-fetch.png"])
        }
        let catalog: [String: Any] = ["version": 1, "assets": entries,
            "categories": [["subcategories": [["id": "gg", "localizedNameKey": "AerialSubcategoryGoldenGate"],
                                               ["id": "ta", "localizedNameKey": "AerialSubcategoryTahoe"]]]]]
        try JSONSerialization.data(withJSONObject: catalog).write(to: manifest)
        let id = entries[0]["id"] as! String
        try Data([1]).write(to: dir.appendingPathComponent(id + ".png"))
        let reader = AppleSetCatalog(manifestURL: manifest, fallbackManifestURL: dir.appendingPathComponent("missing"),
                                    videosDirectory: dir, previewDirectory: dir)
        let sets = try reader.discover()
        expectEqual(sets.map(\.name), ["Golden Gate", "Tahoe"])
        expectFalse(sets[0].requiresReview); expectTrue(sets[1].requiresReview)
        expectEqual(sets[0].suggestedMapping.count, 4)
        expectEqual(sets[1].asset(for: .sunset)?.name, "Tahoe Morning")
        expectEqual(sets[0].assets[0].previewURL, dir.appendingPathComponent(id + ".png"))
        expectNil(sets[0].assets[1].previewURL)
        expectTrue(sets.flatMap(\.assets).allSatisfy { !$0.isDownloaded })
    }

    @Test func testInvalidPreferredCatalogDoesNotSilentlyFallback() throws {
        let dir = try temporary(); let preferred = dir.appendingPathComponent("bad.json")
        try Data("{}".utf8).write(to: preferred)
        expectThrows(try AppleSetCatalog(manifestURL: preferred, fallbackManifestURL: preferred,
                                               videosDirectory: dir, previewDirectory: dir).discover())
    }
}

private enum FixtureError: Error { case missingValue }
private func semanticEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    func normalize(_ value: Any) -> Any {
        if let bytes = value as? Data,
           let plist = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) { return normalize(plist) }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(normalize) }
        if let array = value as? [Any] { return array.map(normalize) }
        return value
    }
    return NSDictionary(dictionary: normalize(lhs) as! [String: Any]).isEqual(to: normalize(rhs) as! [String: Any])
}
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw FixtureError.missingValue }; return value
}
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}
private func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func expectThrows(_ expression: @autoclosure () throws -> Any, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression(); Issue.record("Expected an error", sourceLocation: sourceLocation) } catch {}
}

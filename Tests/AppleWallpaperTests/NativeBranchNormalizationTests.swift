import Foundation
import Testing
@testable import AppleWallpaper

@Suite(.serialized)
struct NativeBranchNormalizationTests {
    @Test func immediateReloadNormalizationIsVerifiedAndRestoresBothBranches() throws {
        let fixture = try BranchFixture()
        var reloads = 0
        let adapter = fixture.adapter {
            reloads += 1
            if reloads == 1 { try fixture.normalize(individual: true) }
        }
        let receipt = try adapter.apply(assetID: fixture.night, previous: nil)
        #expect(try !adapter.hasExternalChange(since: receipt))
        #expect(try adapter.inspect().selections.count == 3)
        let restored = try adapter.restore(receipt)
        #expect(restored.restoredCount == 3)
        #expect(restored.skippedCount == 0)
        #expect(try adapter.inspect().selections.values.allSatisfy { $0 == fixture.day })
        try fixture.expectPreservedMetadata(individual: true)
    }

    @Test func delayedNormalizationThenNextApplyInheritsOriginalLinkedBaseline() throws {
        let fixture = try BranchFixture()
        let adapter = fixture.adapter()
        let first = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: true)
        #expect(try !adapter.hasExternalChange(since: first))
        let second = try adapter.apply(assetID: fixture.sunset, previous: first)
        for branch in ["Linked", "Desktop", "Idle"] {
            let baseline = try #require(second.originalValues[fixture.selector(branch)])
            #expect(try fixture.decode(baseline)["assetID"] as? String == fixture.day)
        }
        let third = try adapter.apply(assetID: fixture.night, previous: second)
        let restored = try adapter.restore(third)
        #expect(restored.restoredCount == 3)
        #expect(restored.skippedCount == 0)
        #expect(try adapter.inspect().selections.values.allSatisfy { $0 == fixture.day })
        try fixture.expectPreservedMetadata(individual: true)
    }

    @Test func compatibleIndividualBaselineSurvivesCollapseAndNextApply() throws {
        let fixture = try BranchFixture(individual: true)
        let adapter = fixture.adapter()
        let first = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: false)
        #expect(try !adapter.hasExternalChange(since: first))
        let second = try adapter.apply(assetID: fixture.sunset, previous: first)
        for branch in ["Linked", "Desktop", "Idle"] {
            let baseline = try #require(second.originalValues[fixture.selector(branch)])
            #expect(try fixture.decode(baseline)["assetID"] as? String == fixture.day)
        }
        let restored = try adapter.restore(second)
        #expect(restored.restoredCount == 2)
        #expect(restored.skippedCount == 0)
        #expect(try adapter.inspect().selections.values.allSatisfy { $0 == fixture.day })
        try fixture.expectPreservedMetadata(individual: false)
    }

    @Test func linkedSplitLinkedRoundTripPreservesBaselineAcrossTwoSubsequentApplies() throws {
        let fixture = try BranchFixture()
        let adapter = fixture.adapter()
        let first = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: true)
        let second = try adapter.apply(assetID: fixture.sunset, previous: first)
        try fixture.normalize(individual: false)
        #expect(try !adapter.hasExternalChange(since: second))
        let third = try adapter.apply(assetID: fixture.night, previous: second)
        #expect(third.originalValues[fixture.selector("Linked")] == first.originalValues[fixture.selector("Linked")])
        #expect(third.originalValues[fixture.selector("Desktop")] != nil)
        #expect(third.originalValues[fixture.selector("Idle")] != nil)
        let restored = try adapter.restore(third)
        #expect(restored.restoredCount == 2)
        #expect(restored.skippedCount == 0)
        #expect(try adapter.inspect().selections.values.allSatisfy { $0 == fixture.day })
        try fixture.expectPreservedMetadata(individual: false)
        let node = try fixture.displayNode()
        let branch = node["Linked"] as! [String: Any]
        let content = branch["Content"] as! [String: Any]
        #expect(try fixture.decode(content["EncodedOptionValues"] as! Data)["placement"] as? String == "Crop")
    }

    @Test func ambiguousCollapseRetainsHistoricalLinkedBaselineButCannotUseItAsFallback() throws {
        let fixture = try BranchFixture()
        let adapter = fixture.adapter()
        let first = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: true)
        let second = try adapter.apply(assetID: fixture.sunset, previous: first)
        var originals = second.originalValues
        originals[fixture.selector("Idle")] = try fixture.encode(["assetID": fixture.sunset, "preservedConfiguration": "keep"])
        let distinct = OwnershipReceipt(originalValues: originals, appliedValues: second.appliedValues,
                                        assetID: second.assetID, osBuild: second.osBuild)
        try fixture.normalize(individual: false)
        let third = try adapter.apply(assetID: fixture.night, previous: distinct)
        let fourth = try adapter.apply(assetID: fixture.sunset, previous: third)
        #expect(fourth.originalValues[fixture.selector("Linked")] == first.originalValues[fixture.selector("Linked")])
        #expect(fourth.originalValues[fixture.selector("Desktop")] == originals[fixture.selector("Desktop")])
        #expect(fourth.originalValues[fixture.selector("Idle")] == originals[fixture.selector("Idle")])
        let restored = try adapter.restore(fourth)
        #expect(restored.restoredCount == 1)
        #expect(restored.skippedCount == 1)
        #expect(try fixture.currentAsset("Linked") == fixture.sunset)
    }

    @Test func incompatibleIndividualOriginalsStayPreservedAndNeverBecomeManagedBaseline() throws {
        let fixture = try BranchFixture(individual: true, differentIdleBaseline: true)
        let adapter = fixture.adapter()
        let first = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: false)
        #expect(try !adapter.hasExternalChange(since: first))
        let second = try adapter.apply(assetID: fixture.sunset, previous: first)
        let third = try adapter.apply(assetID: fixture.night, previous: second)
        #expect(third.originalValues[fixture.selector("Linked")] == nil)
        #expect(third.originalValues[fixture.selector("Desktop")] == first.originalValues[fixture.selector("Desktop")])
        #expect(third.originalValues[fixture.selector("Idle")] == first.originalValues[fixture.selector("Idle")])
        let restored = try adapter.restore(third)
        #expect(restored.restoredCount == 1)
        #expect(restored.skippedCount == 1)
        #expect(try fixture.currentAsset("Linked") == fixture.night)
        try fixture.expectPreservedMetadata(individual: false)
    }

    @Test func directRestoreOfAmbiguousCollapsedOriginalsSkipsRatherThanGuesses() throws {
        let fixture = try BranchFixture(individual: true, differentIdleBaseline: true)
        let adapter = fixture.adapter()
        let receipt = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: false)
        let restored = try adapter.restore(receipt)
        #expect(restored.restoredCount == 1)
        #expect(restored.skippedCount == 1)
        #expect(try fixture.currentAsset("Linked") == fixture.night)
    }

    @Test func asymmetricAssetChangeRemainsInterferenceAndNeitherAliasedBranchIsRestored() throws {
        let fixture = try BranchFixture()
        let adapter = fixture.adapter()
        let receipt = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: true)
        try fixture.editContent("Idle") { content in
            var choices = content["Choices"] as! [[String: Any]]
            var configuration = try fixture.decode(choices[0]["Configuration"] as! Data)
            configuration["assetID"] = fixture.sunset
            choices[0]["Configuration"] = try fixture.encode(configuration)
            content["Choices"] = choices
        }
        #expect(try adapter.hasExternalChange(since: receipt))
        #expect(throws: AppleWallpaperError.self) { _ = try adapter.apply(assetID: fixture.day, previous: receipt) }
        let restored = try adapter.restore(receipt)
        #expect(restored.restoredCount == 1)
        #expect(restored.skippedCount == 1)
        #expect(try fixture.currentAsset("Desktop") == fixture.night)
        #expect(try fixture.currentAsset("Idle") == fixture.sunset)
    }

    @Test func filesOptionsUnknownContentAndConfigurationChangesRemainStrict() throws {
        for mutation in 0..<4 {
            let fixture = try BranchFixture()
            let adapter = fixture.adapter()
            let receipt = try adapter.apply(assetID: fixture.night, previous: nil)
            try fixture.normalize(individual: true)
            try fixture.editContent("Idle") { content in
                if mutation == 0 {
                    var choices = content["Choices"] as! [[String: Any]]
                    choices[0]["Files"] = ["manual-file"]
                    content["Choices"] = choices
                } else if mutation == 1 {
                    content["EncodedOptionValues"] = try fixture.encode(["placement": "Fit"])
                } else if mutation == 2 {
                    content["preservedContent"] = "manual-change"
                } else {
                    var choices = content["Choices"] as! [[String: Any]]
                    var configuration = try fixture.decode(choices[0]["Configuration"] as! Data)
                    configuration["preservedConfiguration"] = "manual-change"
                    choices[0]["Configuration"] = try fixture.encode(configuration)
                    content["Choices"] = choices
                }
            }
            #expect(try adapter.hasExternalChange(since: receipt))
            #expect(throws: AppleWallpaperError.self) { _ = try adapter.apply(assetID: fixture.day, previous: receipt) }
            let before = try fixture.displayNode()
            _ = try adapter.restore(receipt)
            #expect(NSDictionary(dictionary: try fixture.displayNode()).isEqual(to: before))
        }
    }

    @Test func providerChangeStillRejectsSchemaWithoutWrite() throws {
        let fixture = try BranchFixture()
        let adapter = fixture.adapter()
        let receipt = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: true)
        try fixture.editContent("Idle") { content in
            var choices = content["Choices"] as! [[String: Any]]
            choices[0]["Provider"] = "manual-provider"
            content["Choices"] = choices
        }
        let before = try Data(contentsOf: fixture.file)
        #expect(throws: AppleWallpaperError.self) { _ = try adapter.hasExternalChange(since: receipt) }
        #expect(throws: AppleWallpaperError.self) { _ = try adapter.restore(receipt) }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test func collapseDoesNotHideDifferentPreviouslyOwnedContexts() throws {
        let fixture = try BranchFixture(individual: true)
        try fixture.editContent("Idle") { $0["EncodedOptionValues"] = try fixture.encode(["placement": "Fit"]) }
        let adapter = fixture.adapter()
        let receipt = try adapter.apply(assetID: fixture.night, previous: nil)
        try fixture.normalize(individual: false)
        #expect(try adapter.hasExternalChange(since: receipt))
        #expect(throws: AppleWallpaperError.self) { _ = try adapter.apply(assetID: fixture.sunset, previous: receipt) }
    }

    @Test func postReloadAsymmetricNormalizationFailsVerificationAndRetainsReceipt() throws {
        let fixture = try BranchFixture()
        let adapter = fixture.adapter {
            try fixture.normalize(individual: true)
            try fixture.editContent("Idle") { $0["preservedContent"] = "manual-change" }
        }
        #expect(throws: AppleWallpaperError.self) { _ = try adapter.apply(assetID: fixture.night, previous: nil) }
        #expect(try adapter.recoveryReceipt() != nil)
    }

    @Test func restoreReadbackAcceptsEquivalentPostReloadNormalization() throws {
        let fixture = try BranchFixture()
        var reloads = 0
        let adapter = fixture.adapter {
            reloads += 1
            if reloads == 2 { try fixture.normalize(individual: true) }
        }
        let receipt = try adapter.apply(assetID: fixture.night, previous: nil)
        let restored = try adapter.restore(receipt)
        #expect(restored.restoredCount == 2)
        #expect(try adapter.inspect().selections.values.allSatisfy { $0 == fixture.day })
        try fixture.expectPreservedMetadata(individual: true)
    }
}

private final class BranchFixture {
    let day = "6511D2B5-E185-4886-9505-B4004E920D27"
    let night = "86E89C23-C39B-44C8-A985-E56EEA6456FE"
    let sunset = "4207734D-74FE-4F92-B5E1-6EC8DEE24A15"
    let directory: URL
    let file: URL

    init(individual: Bool = false, differentIdleBaseline: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = directory.appendingPathComponent("Index.plist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content: [String: Any] = ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [String](),
            "Configuration": try PropertyListSerialization.data(fromPropertyList: ["assetID": day, "preservedConfiguration": "keep"], format: .binary, options: 0)]],
            "Shuffle": "$null", "EncodedOptionValues": try PropertyListSerialization.data(fromPropertyList: ["placement": "Crop"], format: .binary, options: 0),
            "preservedContent": "keep"]
        let branch: [String: Any] = ["Content": content, "LastSet": Date(timeIntervalSince1970: 100), "LastUse": Date(timeIntervalSince1970: 200), "preservedBranch": "keep"]
        var node: [String: Any] = ["Type": "linked", "Linked": branch, "preservedNode": "keep"]
        if individual {
            node = ["Type": "individual", "Desktop": branch, "Idle": branch, "preservedNode": "keep"]
        }
        let root: [String: Any] = ["AllSpacesAndDisplays": "$null", "SystemDefault": ["Type": "linked", "Linked": branch],
                                   "Spaces": [String: Any](), "Displays": ["fixture": node]]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: file)
        if differentIdleBaseline {
            try editContent("Idle") { content in
                var choices = content["Choices"] as! [[String: Any]]
                choices[0]["Configuration"] = try encode(["assetID": sunset, "preservedConfiguration": "keep"])
                content["Choices"] = choices
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func adapter(reload: @escaping () throws -> Void = {}) -> NativeWallpaperAdapter {
        NativeWallpaperAdapter(storeURL: file, backupDir: directory.appendingPathComponent("Backups"),
                               reload: reload, assetAvailable: { _ in true })
    }
    func encode(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
    func decode(_ value: Data) throws -> [String: Any] { try #require(PropertyListSerialization.propertyList(from: value, options: [], format: nil) as? [String: Any]) }
    func selector(_ branch: String) -> String { "/Displays/fixture/\(branch)/Content/Choices/0/Configuration" }
    func displayNode() throws -> [String: Any] {
        let root = try decode(Data(contentsOf: file))
        return try #require((root["Displays"] as? [String: Any])?["fixture"] as? [String: Any])
    }
    func replaceDisplay(_ node: [String: Any]) throws {
        var root = try decode(Data(contentsOf: file))
        var displays = root["Displays"] as! [String: Any]
        displays["fixture"] = node; root["Displays"] = displays
        try encode(root).write(to: file)
    }
    func normalize(individual: Bool) throws {
        var node = try displayNode()
        if individual {
            let removed = node.removeValue(forKey: "Linked")
            let branch = try #require(removed)
            node["Desktop"] = branch; node["Idle"] = branch; node["Type"] = "individual"
        } else {
            let removed = node.removeValue(forKey: "Desktop")
            let branch = try #require(removed)
            node.removeValue(forKey: "Idle"); node["Linked"] = branch; node["Type"] = "linked"
        }
        try replaceDisplay(node)
    }
    func editContent(_ branch: String, edit: (inout [String: Any]) throws -> Void) throws {
        var node = try displayNode()
        var value = try #require(node[branch] as? [String: Any])
        var content = try #require(value["Content"] as? [String: Any])
        try edit(&content); value["Content"] = content; node[branch] = value
        try replaceDisplay(node)
    }
    func currentAsset(_ branch: String) throws -> String {
        let node = try displayNode()
        let value = node[branch] as! [String: Any]
        let choices = (value["Content"] as! [String: Any])["Choices"] as! [[String: Any]]
        return try #require(decode(choices[0]["Configuration"] as! Data)["assetID"] as? String)
    }
    func expectPreservedMetadata(individual: Bool) throws {
        let node = try displayNode()
        #expect(node["Type"] as? String == (individual ? "individual" : "linked"))
        #expect(node["preservedNode"] as? String == "keep")
        for branch in individual ? ["Desktop", "Idle"] : ["Linked"] {
            let value = node[branch] as! [String: Any]
            #expect(value["preservedBranch"] as? String == "keep")
            #expect(value["LastSet"] as? Date == Date(timeIntervalSince1970: 100))
            #expect(value["LastUse"] as? Date == Date(timeIntervalSince1970: 200))
            #expect((value["Content"] as? [String: Any])?["preservedContent"] as? String == "keep")
        }
    }
}

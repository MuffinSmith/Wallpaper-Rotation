import Foundation
import Darwin
import RotationCore
import AppleWallpaper

func osBuild() -> String {
    NativeWallpaperAdapter.osBuild()
}

func storageDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wallpaper Rotation")
}

func atomicJSON(_ value: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func writePending(_ value: PendingWallpaperOperation, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let staging = folder.appendingPathComponent(".smoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: staging) }
    guard FileManager.default.createFile(atPath: staging.path, contents: try JSONEncoder().encode(value),
        attributes: [.posixPermissions: 0o600]), rename(staging.path, url.path) == 0 else {
        throw NSError(domain: "WallpaperDiagnostics", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not save the pending compatibility recovery record."])
    }
}

/// The native extension holding the expected movie is activation evidence,
/// not evidence of every display or the visible screen saver.
func extensionHolds(assetID: String) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-c", "WallpaperAerials", "-Fn"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).contains("/\(assetID).mov")
}

func nativeSmoke(assetIDs: [String]? = nil) throws {
    let catalog = try AppleSetCatalog().discover()
    let scenes: [WallpaperAsset]
    if let assetIDs {
        let assets = catalog.flatMap(\.assets)
        guard assetIDs.count == 2,
              let day = assets.first(where: { $0.id == assetIDs[0] }),
              let night = assets.first(where: { $0.id == assetIDs[1] }),
              day.isDownloaded, night.isDownloaded else {
            throw NSError(domain: "WallpaperDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "The two requested scenes must be downloaded native Apple assets."])
        }
        scenes = [night, day]
    } else {
        guard let set = catalog.first(where: { $0.assets.contains(where: { $0.shotID == "GG_A_DAY" }) && $0.assets.contains(where: { $0.shotID == "GG_A_NIGHT" }) }),
              let night = set.asset(for: .night), let day = set.asset(for: .day),
              night.isDownloaded, day.isDownloaded else {
            throw NSError(domain: "WallpaperDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download Golden Gate Day and Night in Apple’s Wallpaper settings, or supply --assets dayID nightID."])
        }
        scenes = [night, day]
    }
    let lease = try NativeOperationLease(directory: storageDirectory())
    defer { lease.release() }
    let pendingURL = storageDirectory().appendingPathComponent("pending-smoke.json")
    guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
        throw NSError(domain: "WallpaperDiagnostics", code: 9, userInfo: [NSLocalizedDescriptionKey: "A previous compatibility check needs recovery. Reopen Wallpaper Rotation before retrying."])
    }
    let adapter = NativeWallpaperAdapter()
    let before = try adapter.inspect()
    let reportURL = storageDirectory().appendingPathComponent("native-smoke-report.json")
    // Invalidate a previous pass before beginning a fresh, potentially failing check.
    try atomicJSON(["schemaVersion": 1, "osBuild": osBuild(), "storeSchema": before.schemaDescription,
                    "passed": false, "checkedAt": ISO8601DateFormatter().string(from: Date())], to: reportURL)
    var receipt: OwnershipReceipt?
    var attemptStartedAt = Date.distantFuture
    var attemptAssetID: String?
    do {
        for asset in scenes {
            attemptStartedAt = Date()
            attemptAssetID = asset.id
            try writePending(PendingWallpaperOperation(assetID: asset.id, startedAt: attemptStartedAt, receipt: nil, previousReceipt: receipt), to: pendingURL)
            receipt = try adapter.apply(assetID: asset.id, previous: receipt)
            try writePending(PendingWallpaperOperation(assetID: asset.id, startedAt: attemptStartedAt, receipt: receipt), to: pendingURL)
            let selected = try adapter.inspect()
            guard !selected.selections.isEmpty, selected.selections.values.allSatisfy({ $0 == asset.id }) else {
                throw NSError(domain: "WallpaperDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native selectors did not all agree after applying the scene."])
            }
            var activated = false
            for _ in 0..<10 {
                if try extensionHolds(assetID: asset.id) { activated = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard activated else {
                throw NSError(domain: "WallpaperDiagnostics", code: 3, userInfo: [NSLocalizedDescriptionKey: "The native aerial extension did not open the selected movie. Rotation remains gated."])
            }
            print("Verified selector readback and native movie activation: \(asset.name)")
        }
        guard let owned = receipt else { return }
        let restored = try adapter.restore(owned)
        receipt = nil
        guard restored.skippedCount == 0, try adapter.inspect().selections == before.selections else {
            throw NSError(domain: "WallpaperDiagnostics", code: 4, userInfo: [NSLocalizedDescriptionKey: "Restoration could not verify all original selectors. A concurrent user change may have been preserved."])
        }
        try FileManager.default.removeItem(at: pendingURL)
        try atomicJSON(["schemaVersion": 1, "osBuild": osBuild(), "storeSchema": before.schemaDescription,
                        "passed": true, "checkedAt": ISO8601DateFormatter().string(from: Date()),
                        "selectorCount": before.selections.count,
                        "activationChecked": true, "restorationChecked": true,
                        "visualVerification": "pending", "restartVerification": "pending"], to: reportURL)
        print("Native round-trip passed; original selections restored.")
        print("Visible monitors, Spaces, screen saver and ordinary restart still require human verification.")
        print("The app will now use this compatibility result for the current OS build and schema.")
    } catch {
        // apply can fail after committing, before returning its new receipt.
        // Prefer the durable journal over a nil or stale in-memory receipt.
        let journalURL = adapter.backupDir.appendingPathComponent("ownership-recovery.json")
        let modified = (try? journalURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let pending = try? adapter.recoveryReceipt()
        let fresh = pending.map { journal in
            RecoveryJournalPolicy.canAdopt(expectedAssetID: attemptAssetID ?? "", expectedOSBuild: osBuild(),
                startedAt: attemptStartedAt, journalAssetID: journal.assetID,
                journalOSBuild: journal.osBuild, journalModifiedAt: modified)
        } ?? false
        let recovery = fresh ? pending : receipt
        if let receipt = recovery {
            do {
                let result = try adapter.restore(receipt)
                print("Recovery restored \(result.restoredCount) selectors; preserved \(result.skippedCount) changed selectors.")
                if result.skippedCount == 0, try adapter.inspect().selections == before.selections {
                    try FileManager.default.removeItem(at: pendingURL)
                } else {
                    try writePending(PendingWallpaperOperation(assetID: receipt.assetID, startedAt: attemptStartedAt, receipt: receipt), to: pendingURL)
                }
            } catch { FileHandle.standardError.write(Data("Recovery failed: \(error.localizedDescription)\n".utf8)) }
        }
        throw error
    }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "--catalog":
        for set in try AppleSetCatalog().discover() {
            print("\(set.name) [\(set.id)]\(set.requiresReview ? " — review mapping" : "")")
            for asset in set.assets { print("  \(asset.shotID): \(asset.isDownloaded ? "downloaded" : "not downloaded")") }
        }
    case "--inspect":
        let state = try NativeWallpaperAdapter().inspect()
        print("macOS build: \(osBuild())\nSchema: \(state.schemaDescription)\nSelectors: \(state.selections.count)")
        for key in state.selections.keys.sorted() { print("\(key): \(state.selections[key]!)") }
    case "--schedule":
        guard args.count == 3, let lat = Double(args[1]), let lon = Double(args[2]) else {
            throw NSError(domain: "WallpaperDiagnostics", code: 5, userInfo: [NSLocalizedDescriptionKey: "Usage: --schedule latitude longitude"])
        }
        let snapshot = try SolarSchedule().evaluate(now: Date(), at: Coordinate(latitude: lat, longitude: lon))
        print("Current: \(snapshot.phase.title); solar condition: \(snapshot.solarCondition.rawValue)")
        for transition in snapshot.transitions { print("\(transition.date.ISO8601Format()): \(transition.phase.title)") }
    case "--native-smoke":
        guard args.contains("--allow-live-changes") else {
            throw NSError(domain: "WallpaperDiagnostics", code: 6, userInfo: [NSLocalizedDescriptionKey: "This briefly changes native wallpaper selections and restores them. Run --native-smoke --allow-live-changes to proceed."])
        }
        var assetIDs: [String]?
        if let index = args.firstIndex(of: "--assets") {
            guard args.count == index + 3 else {
                throw NSError(domain: "WallpaperDiagnostics", code: 7, userInfo: [NSLocalizedDescriptionKey: "Usage: --native-smoke --allow-live-changes [--assets dayID nightID]"])
            }
            assetIDs = Array(args[(index + 1)...])
        }
        try nativeSmoke(assetIDs: assetIDs)
    default:
        print("WallpaperDiagnostics --catalog | --inspect | --schedule latitude longitude")
        print("WallpaperDiagnostics --native-smoke --allow-live-changes")
        print("Read-only commands never change wallpaper, appearance, location permissions or login items.")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

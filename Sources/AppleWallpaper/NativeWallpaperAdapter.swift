import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// An experimental adapter for Apple's undocumented store. Atomic replacement is
/// not compare-and-swap: Apple's writer does not participate in our process lock.
public final class NativeWallpaperAdapter: NativeWallpaperApplying {
    public let storeURL: URL
    public let backupDir: URL
    private let reload: () throws -> Void
    private let beforeCommit: () throws -> Void
    private let assetAvailable: (String) throws -> Bool
    private let lockTimeout: TimeInterval
    private let lock = NSRecursiveLock()
    private static let contextPrefix = "context:"
    // Reserved receipt metadata; keeps ambiguous historical baselines intact.
    private static let unrestorablePrefix = "context:adapterUnrestorable:"

    public init(
        storeURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist"),
        backupDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wallpaper Rotation/Backups"),
        reload: @escaping () throws -> Void = NativeWallpaperAdapter.reloadWallpaperAgent,
        beforeCommit: @escaping () throws -> Void = {},
        assetAvailable: @escaping (String) throws -> Bool = NativeWallpaperAdapter.nativeAssetAvailable,
        lockTimeout: TimeInterval = 3
    ) {
        self.storeURL = storeURL; self.backupDir = backupDir
        self.reload = reload; self.beforeCommit = beforeCommit
        self.assetAvailable = assetAvailable
        self.lockTimeout = lockTimeout
    }

    public func inspect() throws -> StoreInspection {
        try locked {
            let state = try read()
            return StoreInspection(fingerprint: SHA256.hash(data: state.bytes).map { String(format: "%02x", $0) }.joined(),
                selections: state.slots.mapValues(\.assetID),
                schemaDescription: "Apple aerial selector schema v1")
        }
    }

    public func hasExternalChange(since receipt: OwnershipReceipt) throws -> Bool {
        try locked { try changed(try read(), receipt: receipt) }
    }

    public func apply(assetID: String, previous: OwnershipReceipt?) throws -> OwnershipReceipt {
        guard UUID(uuidString: assetID) != nil else { throw AppleWallpaperError.invalidAssetID }
        guard try assetAvailable(assetID) else { throw AppleWallpaperError.assetUnavailable }
        _ = try locked { try read() } // Compatibility preflight before creating app storage.
        return try coordinated {
            let state = try read()
            if let previous, try changed(state, receipt: previous) { throw AppleWallpaperError.externalInterference }
            var root = state.root
            var original = previous?.originalValues ?? [:]
            let projection = try previous.map { try ownershipProjection(state, values: $0.appliedValues) } ?? [:]
            var applied: [String: Data] = [:]
            for (path, slot) in state.slots {
                let contextKey = Self.contextPrefix + path
                if let previous, let sources = projection[path] {
                    if let baseline = try originalBaseline(sources, values: previous.originalValues, target: slot) {
                        // Retain all old paths as provenance, and add aliases only
                        // after strict ownership equivalence has been established.
                        if original[path] == nil { original[path] = baseline.configuration }
                        if original[contextKey] == nil { original[contextKey] = baseline.context }
                    } else {
                        // Never adopt our currently managed movie as a fresh
                        // baseline when a collapsed pair has incompatible originals.
                        original[Self.unrestorablePrefix + path] = try encode(["sourcePaths": sources])
                    }
                } else {
                    if original[path] == nil { original[path] = slot.configuration }
                    if original[contextKey] == nil { original[contextKey] = slot.context }
                }
                var configuration = try dictionary(slot.configuration)
                configuration["assetID"] = assetID
                let updated = try encode(configuration)
                root = try replacing(root, path: path, value: updated)
                applied[path] = updated; applied[contextKey] = slot.context
            }
            let receipt = OwnershipReceipt(originalValues: original, appliedValues: applied,
                assetID: assetID, osBuild: Self.osBuild())
            try retainRecovery(state.bytes, receipt: receipt, first: previous == nil)
            try commit(root, expected: state.bytes)
            guard try verified(try read(), receipt: receipt) else { throw AppleWallpaperError.verificationFailed }
            try reload()
            guard try verified(try read(), receipt: receipt) else { throw AppleWallpaperError.verificationFailed }
            return receipt
        }
    }

    public func restore(_ receipt: OwnershipReceipt) throws -> RestoreResult {
        _ = try locked { try read() }
        return try coordinated {
            let state = try read()
            var root = state.root
            var restored = 0; var skipped = 0
            let projection = try ownershipProjection(state, values: receipt.appliedValues)
            var accountedNodes = Set<String>()
            var restoredValues: [String: Data] = [:]
            for (path, sources) in projection {
                accountedNodes.insert(nodePath(path))
                guard let slot = state.slots[path],
                      try owned(slot, matches: sources, values: receipt.appliedValues, allowingTypeProjection: sources != [path],
                                allowingEmptyIdle: branchName(path) == "Idle"),
                      let baseline = try originalBaseline(sources, values: receipt.originalValues, target: slot) else {
                    skipped += 1; continue
                }
                root = try replacing(root, path: path, value: baseline.configuration)
                restoredValues[path] = baseline.configuration
                restoredValues[Self.contextPrefix + path] = slot.context
                restored += 1
            }
            // Historical aliases in an accounted node are provenance, not extra
            // current selectors. Missing/incompatible nodes remain reported skips.
            skipped += receipt.originalValues.keys.filter {
                !$0.hasPrefix(Self.contextPrefix) && !accountedNodes.contains(nodePath($0))
            }.count
            if restored > 0 {
                try commit(root, expected: state.bytes)
                let expected = OwnershipReceipt(originalValues: [:], appliedValues: restoredValues,
                                                assetID: receipt.assetID, osBuild: receipt.osBuild)
                guard try verified(try read(), receipt: expected) else { throw AppleWallpaperError.verificationFailed }
                try reload()
                guard try verified(try read(), receipt: expected) else { throw AppleWallpaperError.verificationFailed }
            }
            return RestoreResult(restoredCount: restored, skippedCount: skipped)
        }
    }

    /// Retained before replacement, including when reload/readback fails or the
    /// process exits after a commit. Restoring it still checks current ownership.
    public func recoveryReceipt() throws -> OwnershipReceipt? {
        try locked {
            let file = backupDir.appendingPathComponent("ownership-recovery.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try coordinated {
                try JSONDecoder().decode(OwnershipReceipt.self, from: Data(contentsOf: file))
            }
        }
    }

    public static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func nativeAssetAvailable(_ id: String) throws -> Bool {
        guard let asset = try AppleSetCatalog().discover().flatMap(\.assets).first(where: { $0.id == id }) else { return false }
        return asset.isDownloaded
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try operation()
    }

    private func coordinated<T>(_ operation: () throws -> T) throws -> T {
        try locked {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let lockFile = backupDir.appendingPathComponent("transaction.lock")
            let fd = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = flock(fd, LOCK_UN); close(fd) }
            let deadline = Date().addingTimeInterval(max(0, lockTimeout))
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else { throw AppleWallpaperError.transactionBusy }
                Thread.sleep(forTimeInterval: 0.02)
            }
            // Cooperative across our app/diagnostics processes; Apple ignores this lock.
            return try operation()
        }
    }

    private struct Slot { let configuration: Data; let context: Data; let assetID: String }
    private struct State { let bytes: Data; let root: [String: Any]; let slots: [String: Slot] }

    private func read() throws -> State {
        let values = try storeURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AppleWallpaperError.unsupportedSchema("store must be a regular file")
        }
        let bytes = try Data(contentsOf: storeURL)
        let root = try dictionary(bytes)
        guard Set(root.keys) == Set(["AllSpacesAndDisplays", "SystemDefault", "Spaces", "Displays"]),
              let spaces = root["Spaces"] as? [String: Any],
              let displays = root["Displays"] as? [String: Any] else {
            throw AppleWallpaperError.unsupportedSchema("root keys or topology")
        }
        var slots: [String: Slot] = [:]
        let global = root["AllSpacesAndDisplays"]!
        if let sentinel = global as? String, sentinel == "$null" {} else {
            try collectNode(global, path: "/AllSpacesAndDisplays", into: &slots)
        }
        try collectNode(root["SystemDefault"]!, path: "/SystemDefault", into: &slots)
        for (id, value) in displays { try collectNode(value, path: "/Displays/" + escape(id), into: &slots) }
        for (id, value) in spaces {
            guard let space = value as? [String: Any], Set(space.keys) == Set(["Default", "Displays"]),
                  let displays = space["Displays"] as? [String: Any] else {
                throw AppleWallpaperError.unsupportedSchema("Space node")
            }
            let path = "/Spaces/" + escape(id)
            try collectNode(space["Default"]!, path: path + "/Default", into: &slots)
            for (id, value) in displays { try collectNode(value, path: path + "/Displays/" + escape(id), into: &slots) }
        }
        guard !slots.isEmpty else { throw AppleWallpaperError.unsupportedSchema("empty selection graph") }
        return State(bytes: bytes, root: root, slots: slots)
    }

    private func collectNode(_ value: Any, path: String, into slots: inout [String: Slot]) throws {
        guard let node = value as? [String: Any], let type = node["Type"] as? String else {
            throw AppleWallpaperError.unsupportedSchema("selection node at \(path)")
        }
        let branches: [String]
        switch type {
        case "linked":
            guard node["Desktop"] == nil, node["Idle"] == nil else { throw AppleWallpaperError.unsupportedSchema("mixed node at \(path)") }
            branches = ["Linked"]
        case "individual":
            guard node["Linked"] == nil else { throw AppleWallpaperError.unsupportedSchema("mixed node at \(path)") }
            branches = ["Desktop", "Idle"]
        default: throw AppleWallpaperError.unsupportedSchema("node type \(type)")
        }
        for name in branches {
            guard let branch = node[name] as? [String: Any], let content = branch["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
                  choices[0]["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
                  choices[0]["Files"] is [Any], content["Shuffle"] as? String == "$null",
                  let configuration = choices[0]["Configuration"] as? Data else {
                throw AppleWallpaperError.unsupportedSchema("aerial choice at \(path)/\(name)")
            }
            let decoded = try dictionary(configuration)
            guard let id = decoded["assetID"] as? String, UUID(uuidString: id) != nil else {
                throw AppleWallpaperError.unsupportedSchema("assetID at \(path)/\(name)")
            }
            var context = content
            var choice = choices[0]; choice.removeValue(forKey: "Configuration")
            context["Choices"] = [choice]
            // Type stays in the receipt; only strict equivalent-branch projection
            // may account for Apple normalizing linked and individual nodes.
            context["adapterNodeType"] = type
            let selector = path + "/" + name + "/Content/Choices/0/Configuration"
            slots[selector] = Slot(configuration: configuration, context: try encode(context), assetID: id)
        }
    }

    /// Map currently owned selectors to their receipt paths. A structural alias
    /// requires complete configuration/context agreement, or the narrowly
    /// validated Desktop-options layouts below. Unknown values stay strict.
    private func ownershipProjection(_ state: State, values: [String: Data]) throws -> [String: [String]] {
        let previous = Dictionary(grouping: values.keys.filter { !$0.hasPrefix(Self.contextPrefix) }, by: nodePath)
        let current = Dictionary(grouping: state.slots.keys, by: nodePath)
        var result: [String: [String]] = [:]
        for (node, sources) in previous {
            guard let targets = current[node] else { continue }
            let sourceBranches = Set(sources.map(branchName))
            let targetBranches = Set(targets.map(branchName))
            if sourceBranches == targetBranches {
                for path in targets { result[path] = [path] }
                continue
            }
            let linked: Set<String> = ["Linked"]
            let individual: Set<String> = ["Desktop", "Idle"]
            guard (sourceBranches == linked && targetBranches == individual)
                    || (sourceBranches == individual && targetBranches == linked) else { continue }
            var equivalent = true
            for path in targets {
                // The full pair is checked before either target is projected.
                // Only Idle may clear the bounded options; Desktop must remain exact.
                guard let slot = state.slots[path],
                      try owned(slot, matches: sources, values: values, allowingTypeProjection: true,
                                allowingEmptyIdle: branchName(path) == "Idle") else {
                    equivalent = false; break
                }
            }
            if equivalent { for path in targets { result[path] = sources.sorted() } }
        }
        return result
    }

    private func nodePath(_ selector: String) -> String {
        String(selector.dropLast("/Content/Choices/0/Configuration".count))
            .components(separatedBy: "/").dropLast().joined(separator: "/")
    }

    private func branchName(_ selector: String) -> String {
        String(selector.dropLast("/Content/Choices/0/Configuration".count))
            .components(separatedBy: "/").last ?? ""
    }

    private func projectedContext(_ data: Data, to target: Data) throws -> Data? {
        var source = try dictionary(data)
        let target = try dictionary(target)
        guard let oldType = source["adapterNodeType"] as? String,
              let newType = target["adapterNodeType"] as? String,
              ["linked", "individual"].contains(oldType), ["linked", "individual"].contains(newType) else { return nil }
        source["adapterNodeType"] = newType
        return try encode(source)
    }

    private func owned(_ slot: Slot, matches sources: [String], values: [String: Data],
                       allowingTypeProjection: Bool = true, allowingEmptyIdle: Bool = false) throws -> Bool {
        if allowingTypeProjection, try ownedDesktopOptionsCollapse(slot, sources: sources, values: values) { return true }
        if allowingTypeProjection && allowingEmptyIdle,
           try ownedEmptyIdleSplit(slot, sources: sources, values: values) { return true }
        for source in sources {
            guard let configuration = values[source], let context = values[Self.contextPrefix + source],
                  try dictionary(context)["adapterNodeType"] as? String == (branchName(source) == "Linked" ? "linked" : "individual"),
                  try equal(slot.configuration, configuration) else { return false }
            if allowingTypeProjection {
                guard let projected = try projectedContext(context, to: slot.context),
                      try equal(slot.context, projected) else { return false }
            } else if try !equal(slot.context, context) { return false }
        }
        return !sources.isEmpty
    }

    /// A narrowly observed individual -> linked representation: Linked retains
    /// Desktop verbatim while Idle had no encoded options. This does not identify
    /// the writer or declare arbitrary options equivalent. Historical originals
    /// still use the stricter originalBaseline check and may remain unrestorable.
    private func ownedDesktopOptionsCollapse(_ slot: Slot, sources: [String], values: [String: Data]) throws -> Bool {
        guard sources.count == 2, Set(sources.map(branchName)) == Set(["Desktop", "Idle"]),
              try dictionary(slot.context)["adapterNodeType"] as? String == "linked",
              let desktop = sources.first(where: { branchName($0) == "Desktop" }),
              let idle = sources.first(where: { branchName($0) == "Idle" }),
              try owned(slot, matches: [desktop], values: values, allowingTypeProjection: true),
              let idleConfiguration = values[idle], try equal(slot.configuration, idleConfiguration),
              let idleContext = values[Self.contextPrefix + idle],
              try dictionary(idleContext)["adapterNodeType"] as? String == "individual",
              let projected = try projectedContext(idleContext, to: slot.context) else { return false }
        return try emptyIdleOptionsMatch(desktopContext: slot.context, idleContext: projected)
    }

    /// Only current Idle targets use this rule. Projection publishes the node
    /// only after its complete Desktop/Idle pair passes; Desktop stays exact.
    private func ownedEmptyIdleSplit(_ slot: Slot, sources: [String], values: [String: Data]) throws -> Bool {
        guard sources.count == 1, let source = sources.first, branchName(source) == "Linked",
              try dictionary(slot.context)["adapterNodeType"] as? String == "individual",
              let configuration = values[source], try equal(slot.configuration, configuration),
              let context = values[Self.contextPrefix + source],
              try dictionary(context)["adapterNodeType"] as? String == "linked",
              let projected = try projectedContext(context, to: slot.context) else { return false }
        return try emptyIdleOptionsMatch(desktopContext: projected, idleContext: slot.context)
    }

    private func emptyIdleOptionsMatch(desktopContext: Data, idleContext: Data) throws -> Bool {
        var desktopContext = try dictionary(desktopContext)
        var emptyIdleContext = try dictionary(idleContext)
        guard let desktopOptions = desktopContext.removeValue(forKey: "EncodedOptionValues") as? Data,
              let idleOptions = emptyIdleContext.removeValue(forKey: "EncodedOptionValues") as? Data,
              try equal(encode(desktopContext), encode(emptyIdleContext)),
              try equal(idleOptions, encode(["values": [String: Any]()])),
              try observedDesktopOptions(desktopOptions) else { return false }
        return true
    }

    private func observedDesktopOptions(_ data: Data) throws -> Bool {
        let options = try dictionary(data)
        guard Set(options.keys) == Set(["values"]), let values = options["values"] as? [String: Any],
              Set(values.keys) == Set(["color", "placement"]),
              let placement = values["placement"] as? [String: Any],
              try equal(encode(placement), encode(["picker": ["_0": ["id": "Crop"]]])),
              let color = values["color"] as? [String: Any], Set(color.keys) == Set(["color"]),
              let variant = color["color"] as? [String: Any], Set(variant.keys) == Set(["_0"]),
              let payload = variant["_0"] as? [String: Any], Set(payload.keys) == Set(["color"]),
              let components = payload["color"] as? [String: Any], Set(components.keys) == Set(["components", "colorSpace"]),
              let rgba = components["components"] as? [NSNumber], rgba.count == 4,
              rgba.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && (0...1).contains($0.doubleValue) }),
              let space = components["colorSpace"] as? Data,
              let name = try? PropertyListSerialization.propertyList(from: space, options: [], format: nil) as? String,
              name == "kCGColorSpaceGenericRGB" else { return false }
        return true
    }

    private func originalBaseline(_ sources: [String], values: [String: Data], target: Slot) throws -> Slot? {
        var baseline: Slot?
        for source in sources {
            guard values[Self.unrestorablePrefix + source] == nil,
                  let configuration = values[source], let context = values[Self.contextPrefix + source],
                  let projected = try projectedContext(context, to: target.context) else { return nil }
            if let baseline {
                guard try equal(baseline.configuration, configuration), try equal(baseline.context, projected) else { return nil }
            } else {
                baseline = Slot(configuration: configuration, context: projected, assetID: "")
            }
        }
        return baseline
    }

    private func changed(_ state: State, receipt: OwnershipReceipt) throws -> Bool {
        let projection = try ownershipProjection(state, values: receipt.appliedValues)
        let mapped = Set(projection.values.flatMap { $0 })
        for path in receipt.appliedValues.keys where !path.hasPrefix(Self.contextPrefix) && !mapped.contains(path) {
            // Whole-node removal remains topology; an incompatible branch change is interference.
            if state.slots.keys.contains(where: { nodePath($0) == nodePath(path) }) { return true }
        }
        for (path, sources) in projection {
            guard let slot = state.slots[path],
                  try owned(slot, matches: sources, values: receipt.appliedValues,
                            allowingTypeProjection: sources != [path], allowingEmptyIdle: branchName(path) == "Idle") else { return true }
        }
        return false
    }

    private func verified(_ state: State, receipt: OwnershipReceipt) throws -> Bool {
        let projection = try ownershipProjection(state, values: receipt.appliedValues)
        let expected = Set(receipt.appliedValues.keys.filter { !$0.hasPrefix(Self.contextPrefix) })
        guard Set(projection.values.flatMap { $0 }) == expected else { return false }
        for (path, sources) in projection {
            guard let slot = state.slots[path],
                  try owned(slot, matches: sources, values: receipt.appliedValues,
                            allowingTypeProjection: sources != [path], allowingEmptyIdle: branchName(path) == "Idle") else { return false }
        }
        return true
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        do {
            guard let result = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw AppleWallpaperError.unsupportedSchema("expected property-list dictionary")
            }
            return result
        } catch let error as AppleWallpaperError { throw error }
        catch { throw AppleWallpaperError.unsupportedSchema("invalid embedded property list") }
    }

    private func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func equal(_ lhs: Data, _ rhs: Data) throws -> Bool {
        // Decode nested option plists too, so harmless Apple reserialization is not a manual edit.
        func normalized(_ value: Any) -> Any {
            if let bytes = value as? Data,
               let plist = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) { return normalized(plist) }
            if let dict = value as? [String: Any] { return dict.mapValues(normalized) }
            if let array = value as? [Any] { return array.map(normalized) }
            return value
        }
        let a = try normalized(dictionary(lhs)) as! [String: Any]
        let b = try normalized(dictionary(rhs)) as! [String: Any]
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    private func escape(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }

    private func replacing(_ root: [String: Any], path: String, value: Data) throws -> [String: Any] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
            String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        func descend(_ current: Any, _ index: Int) throws -> Any {
            if index == parts.count { return value }
            if var dict = current as? [String: Any], let child = dict[parts[index]] {
                dict[parts[index]] = try descend(child, index + 1); return dict
            }
            if var array = current as? [Any], let position = Int(parts[index]), array.indices.contains(position) {
                array[position] = try descend(array[position], index + 1); return array
            }
            throw AppleWallpaperError.unsupportedSchema("missing selector \(path)")
        }
        return try descend(root, 0) as! [String: Any]
    }

    private func retainRecovery(_ bytes: Data, receipt: OwnershipReceipt, first: Bool) throws {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if first {
            let backup = backupDir.appendingPathComponent("Index-" + UUID().uuidString + ".plist")
            try bytes.write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let journal = backupDir.appendingPathComponent("ownership-recovery.json")
        try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    private func commit(_ root: [String: Any], expected: Data) throws {
        let temporary = storeURL.deletingLastPathComponent().appendingPathComponent(".WallpaperRotation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encode(root).write(to: temporary, options: .withoutOverwriting)
        guard copyfile(storeURL.path, temporary.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fd = open(temporary.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let synced = fsync(fd); close(fd)
        guard synced == 0 else { throw POSIXError(.EIO) }
        try beforeCommit()
        // This is intentionally the last operation before rename, but cannot exclude
        // an uncoordinated Apple write between this read and the rename.
        guard try Data(contentsOf: storeURL) == expected else { throw AppleWallpaperError.externalInterference }
        guard rename(temporary.path, storeURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func reloadWallpaperAgent() throws {
        try WallpaperAgentReloader().reload()
    }
}

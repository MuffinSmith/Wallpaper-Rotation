import Foundation
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
            var applied: [String: Data] = [:]
            for (path, slot) in state.slots {
                if original[path] == nil { original[path] = slot.configuration }
                let contextKey = Self.contextPrefix + path
                if original[contextKey] == nil { original[contextKey] = slot.context }
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
            for (path, original) in receipt.originalValues where !path.hasPrefix(Self.contextPrefix) {
                guard let slot = state.slots[path], let owned = receipt.appliedValues[path],
                      let context = receipt.appliedValues[Self.contextPrefix + path],
                      try equal(slot.configuration, owned), try equal(slot.context, context) else {
                    skipped += 1; continue
                }
                root = try replacing(root, path: path, value: original)
                restored += 1
            }
            if restored > 0 {
                try commit(root, expected: state.bytes)
                // Verify only restored fields: unrelated later edits deliberately remain untouched.
                func verifyRestored(_ result: State) throws {
                    for (path, original) in receipt.originalValues where !path.hasPrefix(Self.contextPrefix) {
                        if let before = state.slots[path], let owned = receipt.appliedValues[path],
                           let context = receipt.appliedValues[Self.contextPrefix + path],
                           try equal(before.configuration, owned), try equal(before.context, context) {
                            guard let after = result.slots[path], try equal(after.configuration, original),
                                  try equal(after.context, context) else {
                                throw AppleWallpaperError.verificationFailed
                            }
                        }
                    }
                }
                try verifyRestored(try read())
                try reload()
                try verifyRestored(try read())
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
            // Type is ownership-relevant; LastSet/LastUse and topology membership are not.
            context["adapterNodeType"] = type
            let selector = path + "/" + name + "/Content/Choices/0/Configuration"
            slots[selector] = Slot(configuration: configuration, context: try encode(context), assetID: id)
        }
    }

    private func changed(_ state: State, receipt: OwnershipReceipt) throws -> Bool {
        for (path, owned) in receipt.appliedValues where !path.hasPrefix(Self.contextPrefix) {
            // Removed nodes are topology changes; newly added nodes are adopted at the next apply.
            guard let slot = state.slots[path] else {
                // A branch change within an existing node is a user edit, whereas
                // removal of the whole Space/display node is a topology change.
                let node = path.components(separatedBy: "/Content/Choices/0/Configuration")[0]
                    .components(separatedBy: "/").dropLast().joined(separator: "/")
                if state.slots.keys.contains(where: { $0.hasPrefix(node + "/") }) { return true }
                continue
            }
            guard let context = receipt.appliedValues[Self.contextPrefix + path],
                  try equal(slot.configuration, owned), try equal(slot.context, context) else { return true }
        }
        return false
    }

    private func verified(_ state: State, receipt: OwnershipReceipt) throws -> Bool {
        for (path, owned) in receipt.appliedValues where !path.hasPrefix(Self.contextPrefix) {
            guard let slot = state.slots[path], let context = receipt.appliedValues[Self.contextPrefix + path],
                  try equal(slot.configuration, owned), try equal(slot.context, context) else { return false }
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

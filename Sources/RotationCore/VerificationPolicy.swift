import Foundation

public struct NativeVerificationRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let osBuild: String
    public let storeSchema: String
    public let verifiedAt: String

    public init(schemaVersion: Int, osBuild: String, storeSchema: String, verifiedAt: String) {
        self.schemaVersion = schemaVersion
        self.osBuild = osBuild
        self.storeSchema = storeSchema
        self.verifiedAt = verifiedAt
    }
}

public struct NativeSmokeRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let osBuild: String
    public let storeSchema: String
    public let passed: Bool
    public let checkedAt: String

    public init(schemaVersion: Int, osBuild: String, storeSchema: String, passed: Bool, checkedAt: String) {
        self.schemaVersion = schemaVersion
        self.osBuild = osBuild
        self.storeSchema = storeSchema
        self.passed = passed
        self.checkedAt = checkedAt
    }
}

/// Native enablement requires a matching successful check and visual approval
/// at least as recent as that check. A new check invalidates older approval.
public enum NativeVerificationPolicy {
    public static func isVerified(record: NativeVerificationRecord, smoke: NativeSmokeRecord,
                                  currentOSBuild: String, currentStoreSchema: String) -> Bool {
        guard smokePassed(smoke: smoke, currentOSBuild: currentOSBuild, currentStoreSchema: currentStoreSchema),
              record.schemaVersion == 1,
              record.osBuild == currentOSBuild,
              record.storeSchema == currentStoreSchema,
              let verifiedAt = ISO8601DateFormatter().date(from: record.verifiedAt),
              let checkedAt = ISO8601DateFormatter().date(from: smoke.checkedAt) else { return false }
        return verifiedAt >= checkedAt
    }

    public static func smokePassed(smoke: NativeSmokeRecord,
                                   currentOSBuild: String, currentStoreSchema: String) -> Bool {
        let build = currentOSBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        return !build.isEmpty && build.lowercased() != "unknown"
            && smoke.schemaVersion == 1 && smoke.passed
            && smoke.osBuild == currentOSBuild && smoke.storeSchema == currentStoreSchema
            && ISO8601DateFormatter().date(from: smoke.checkedAt) != nil
    }
}

/// A durable adapter receipt belongs to a pending operation only when it was
/// written after that operation began and names its exact asset and OS build.
public enum RecoveryJournalPolicy {
    public static func canAdopt(expectedAssetID: String, expectedOSBuild: String, startedAt: Date,
                                journalAssetID: String, journalOSBuild: String,
                                journalModifiedAt: Date?) -> Bool {
        let build = expectedOSBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !build.isEmpty, build.lowercased() != "unknown",
              expectedAssetID == journalAssetID, expectedOSBuild == journalOSBuild,
              startedAt.timeIntervalSince1970.isFinite,
              let journalModifiedAt, journalModifiedAt.timeIntervalSince1970.isFinite else { return false }
        return journalModifiedAt >= startedAt
    }
}
